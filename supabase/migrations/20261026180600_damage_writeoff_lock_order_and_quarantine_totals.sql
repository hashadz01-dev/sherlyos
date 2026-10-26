-- M5.4C review: align write-off grain locks with confirm_dispatch / transfer,
-- and publish filter-wide quarantine class totals so pagination cannot be
-- mistaken for current stock.
-- Local only. Does not flip damage.stock_hold_ready or lot cutover flags.

-- Isolation class is a reporting label, not a persisted hold status.
create or replace function app_private.damage_hold_isolation_class(
  hold_status text,
  hold_kind text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when hold_status = 'written_off' then 'written_off'
    when hold_status = 'returned_supplier' then 'returned_supplier'
    when hold_status = 'released' then 'released'
    when hold_status = 'transferred' then 'transferred_quarantine'
    when hold_kind = 'quarantine_intake' then 'shop_return_intake'
    when hold_kind = 'reservation_conversion' then 'reservation_converted'
    else 'logical_hold'
  end;
$$;

revoke all on function app_private.damage_hold_isolation_class(text, text)
  from public, anon, authenticated, service_role;

comment on function app_private.damage_hold_isolation_class(text, text) is
  'M5.4C. Map hold status/kind to a reporting isolation class. Written-off is never current stock.';

-- Lock products → locations before hold rows so consume cannot invert
-- confirm_dispatch / transfer_verified_damage_to_quarantine.
create or replace function app_private.consume_damage_holds(
  target_report uuid,
  next_hold_status text,
  posting_kind text,
  notes text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.damage_reports;
  hold public.damage_stock_holds;
  signed jsonb := '[]'::jsonb;
  dest uuid;
  posted uuid;
  crate_ids uuid[];
  product_ids uuid[];
  lot_ids uuid[];
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.enable_trusted_guc('app.damage_stock_write');
  select * into header from public.damage_reports where id = target_report for update;

  select coalesce(array_agg(distinct crate_id), '{}')
  into crate_ids
  from public.damage_stock_holds
  where damage_report_id = target_report
    and status in ('active', 'transferred');

  if cardinality(crate_ids) < 1 then
    raise exception 'no isolated damage quantity remains' using errcode = '23514';
  end if;

  select coalesce(array_agg(distinct product_id), '{}')
  into product_ids
  from public.damage_stock_holds
  where damage_report_id = target_report
    and status in ('active', 'transferred');

  select coalesce(array_agg(distinct lot_id), '{}')
  into lot_ids
  from public.damage_stock_holds
  where damage_report_id = target_report
    and status in ('active', 'transferred')
    and lot_id is not null;

  -- Products then zones → crates → branch, matching lock_damage_stock_grains.
  perform app_private.lock_damage_stock_grains(
    header.godown_id, crate_ids, product_ids, lot_ids
  );

  -- Branch is now locked via prepare_stock_locations. Re-read is_active so a
  -- concurrent deactivation cannot sneak past the earlier snapshot.
  if not exists (
    select 1
    from public.branches
    where branches.id = header.godown_id
      and branches.is_active
  ) then
    raise exception 'godown is inactive' using errcode = '23514';
  end if;

  for hold in
    select * from public.damage_stock_holds
    where damage_report_id = target_report
      and status in ('active', 'transferred')
    order by crate_id, product_id, id
    for update
  loop
    dest := coalesce(dest, hold.crate_id);
    signed := signed || jsonb_build_array(jsonb_build_object(
      'product_id', hold.product_id,
      'crate_id', hold.crate_id,
      'lot_id', hold.lot_id,
      'quantity', - hold.quantity_cases
    ));
  end loop;

  if dest is null then
    raise exception 'no isolated damage quantity remains' using errcode = '23514';
  end if;

  update public.damage_stock_holds
  set status = next_hold_status
  where damage_report_id = target_report
    and status in ('active', 'transferred');

  posted := app_private.post_damage_adjustment(target_report, posting_kind, dest, signed, notes);

  update public.damage_stock_holds
  set posted_transaction_id = posted
  where damage_report_id = target_report
    and status = next_hold_status
    and posted_transaction_id is null;

  return posted;
end;
$$;

revoke all on function app_private.consume_damage_holds(uuid, text, text, text)
  from public, anon, authenticated, service_role;

create or replace function public.post_ordinary_damage_writeoff(
  target_report uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  posted uuid;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);

  -- Snapshot without locking the branch row. consume_damage_holds then
  -- lock_damage_stock_grains (products → locations) matches confirm_dispatch.
  if not exists (
    select 1
    from public.branches
    where branches.id = selected.godown_id
      and branches.is_active
  ) then
    raise exception 'godown is inactive' using errcode = '23514';
  end if;
  if not app_private.can_work_at_branch(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_damage_disposition_ready(selected);

  if app_private.has_permission('damage.dispose')
    and not app_private.has_permission('damage.verify')
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.damage_exceptional_requests
    where damage_report_id = selected.id
      and status in ('requested', 'approved')
  ) then
    raise exception 'an exceptional disposition is already open' using errcode = '23514';
  end if;

  select stock_transactions.id into posted
  from public.stock_transactions
  where stock_transactions.damage_report_id = selected.id
    and stock_transactions.damage_posting_kind = 'ordinary_writeoff';
  if found then
    return app_private.damage_report_payload(selected.id);
  end if;

  posted := app_private.consume_damage_holds(
    selected.id, 'written_off', 'ordinary_writeoff', 'Ordinary damage write-off'
  );

  perform app_private.record_damage_event(
    selected.id, 'ordinary_writeoff', selected.status, selected.status,
    jsonb_build_object('transaction_id', posted, 'idempotency_key', idempotency_key)
  );
  perform app_private.write_audit(
    auth.uid(), 'post_ordinary_damage_writeoff', 'damage_reports', selected.id,
    jsonb_build_object('transaction_id', posted)
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

revoke all on function public.post_ordinary_damage_writeoff(uuid, integer, text)
  from public, anon, service_role;
grant execute on function public.post_ordinary_damage_writeoff(uuid, integer, text)
  to authenticated;

comment on function public.post_ordinary_damage_writeoff(uuid, integer, text) is
  'Ordinary write-off. Snapshots godown activity, then locks products before locations. Exact-once by posting kind.';

create or replace function public.post_exceptional_damage_disposition(
  target_request uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_exceptional_requests;
  header public.damage_reports;
  posted uuid;
  hold_status text;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');

  select * into selected
  from public.damage_exceptional_requests
  where id = target_request
  for update;
  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  header := app_private.lock_damage_report(selected.damage_report_id);

  -- Same snapshot as ordinary write-off: do not FOR UPDATE the branch first.
  if not exists (
    select 1
    from public.branches
    where branches.id = header.godown_id
      and branches.is_active
  ) then
    raise exception 'godown is inactive' using errcode = '23514';
  end if;
  if not app_private.can_work_at_branch(header.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'changed by someone else' using errcode = 'PT409';
  end if;
  if selected.status = 'posted' and selected.post_idempotency_key = app_private.clean_idempotency_key(idempotency_key) then
    return app_private.damage_report_payload(header.id);
  end if;
  if selected.status is distinct from 'approved' then
    raise exception 'exceptional request is not approved' using errcode = '42501';
  end if;

  hold_status := case
    when selected.disposition_kind = 'return_supplier' then 'returned_supplier'
    else 'written_off'
  end;

  posted := app_private.consume_damage_holds(
    header.id, hold_status, 'exceptional_writeoff',
    'Exceptional ' || selected.disposition_kind
  );

  update public.damage_exceptional_requests
  set
    status = 'posted',
    posted_by = auth.uid(),
    posted_at = clock_timestamp(),
    posted_transaction_id = posted,
    post_idempotency_key = app_private.clean_idempotency_key(idempotency_key),
    version = selected.version + 1
  where id = selected.id;

  perform app_private.record_damage_event(
    header.id, 'exceptional_posted', header.status, header.status,
    jsonb_build_object('request_id', selected.id, 'transaction_id', posted)
  );
  return app_private.damage_report_payload(header.id);
end;
$$;

revoke all on function public.post_exceptional_damage_disposition(uuid, integer, text)
  from public, anon, service_role;
grant execute on function public.post_exceptional_damage_disposition(uuid, integer, text)
  to authenticated;

comment on function public.post_exceptional_damage_disposition(uuid, integer, text) is
  'Exceptional stock posting. Snapshots godown activity, then locks products before locations.';

-- Filter-wide class totals. Page items never feed these aggregates.
create or replace function public.list_damage_quarantine_inventory(
  page integer default 1,
  page_size integer default 50,
  target_godown uuid default null,
  target_product uuid default null,
  scenario_filter text default null,
  hold_kind_filter text default null,
  hold_status_filter text default null,
  product_search text default null,
  from_date date default null,
  to_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  safe_page integer := greatest(coalesce(page, 1), 1);
  safe_size integer := least(greatest(coalesce(page_size, 50), 1), 50);
  cleaned_scenario text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(scenario_filter, ''))), '');
  cleaned_kind text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(hold_kind_filter, ''))), '');
  cleaned_status text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(hold_status_filter, ''))), '');
  cleaned_search text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(product_search, ''))), '');
  from_ts timestamptz := case when from_date is null then null else from_date::timestamp at time zone 'utc' end;
  to_ts timestamptz := case when to_date is null then null else (to_date + 1)::timestamp at time zone 'utc' end;
  total_count integer;
  class_totals jsonb;
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  -- Not deliveries.execute. Drivers must not browse quarantine inventory.
  if not (
    app_private.has_permission('damage.read')
    or app_private.has_permission('damage.record')
    or app_private.has_permission('damage.verify')
    or app_private.has_permission('operations.monitor')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if cleaned_scenario is not null
    and cleaned_scenario not in (
      'refill_supply', 'unloading', 'storage', 'loading', 'transit', 'shop_return'
    )
  then
    raise exception 'damage scenario filter is invalid' using errcode = '23514';
  end if;

  if cleaned_kind is not null
    and cleaned_kind not in ('on_hand_deduction', 'reservation_conversion', 'quarantine_intake')
  then
    raise exception 'damage hold kind filter is invalid' using errcode = '23514';
  end if;

  if cleaned_status is not null
    and cleaned_status not in (
      'active', 'released', 'transferred', 'written_off', 'returned_supplier'
    )
  then
    raise exception 'damage hold status filter is invalid' using errcode = '23514';
  end if;

  if from_date is not null and to_date is not null and from_date > to_date then
    raise exception 'damage date range is invalid' using errcode = '23514';
  end if;

  if cleaned_search is not null then
    cleaned_search := replace(replace(replace(cleaned_search, '\', '\\'), '%', '\%'), '_', '\_');
  end if;

  select
    count(*)::integer,
    pg_catalog.jsonb_build_object(
      'hold_rows', count(*)::integer,
      'current_unavailable_cases', coalesce(
        sum(damage_stock_holds.quantity_cases) filter (
          where damage_stock_holds.status in ('active', 'transferred')
        ),
        0
      )::integer,
      'logical_hold_cases', coalesce(
        sum(damage_stock_holds.quantity_cases) filter (
          where app_private.damage_hold_isolation_class(
            damage_stock_holds.status, damage_stock_holds.hold_kind
          ) = 'logical_hold'
        ),
        0
      )::integer,
      'reservation_converted_cases', coalesce(
        sum(damage_stock_holds.quantity_cases) filter (
          where app_private.damage_hold_isolation_class(
            damage_stock_holds.status, damage_stock_holds.hold_kind
          ) = 'reservation_converted'
        ),
        0
      )::integer,
      'shop_return_intake_cases', coalesce(
        sum(damage_stock_holds.quantity_cases) filter (
          where app_private.damage_hold_isolation_class(
            damage_stock_holds.status, damage_stock_holds.hold_kind
          ) = 'shop_return_intake'
        ),
        0
      )::integer,
      'transferred_quarantine_cases', coalesce(
        sum(damage_stock_holds.quantity_cases) filter (
          where app_private.damage_hold_isolation_class(
            damage_stock_holds.status, damage_stock_holds.hold_kind
          ) = 'transferred_quarantine'
        ),
        0
      )::integer,
      'written_off_cases', coalesce(
        sum(damage_stock_holds.quantity_cases) filter (
          where app_private.damage_hold_isolation_class(
            damage_stock_holds.status, damage_stock_holds.hold_kind
          ) = 'written_off'
        ),
        0
      )::integer,
      'returned_supplier_cases', coalesce(
        sum(damage_stock_holds.quantity_cases) filter (
          where app_private.damage_hold_isolation_class(
            damage_stock_holds.status, damage_stock_holds.hold_kind
          ) = 'returned_supplier'
        ),
        0
      )::integer,
      'released_cases', coalesce(
        sum(damage_stock_holds.quantity_cases) filter (
          where app_private.damage_hold_isolation_class(
            damage_stock_holds.status, damage_stock_holds.hold_kind
          ) = 'released'
        ),
        0
      )::integer
    )
  into total_count, class_totals
  from public.damage_stock_holds
  join public.damage_reports
    on damage_reports.id = damage_stock_holds.damage_report_id
  join public.products on products.id = damage_stock_holds.product_id
  where (target_godown is null or damage_reports.godown_id = target_godown)
    and (target_product is null or damage_stock_holds.product_id = target_product)
    and (cleaned_scenario is null or damage_reports.scenario = cleaned_scenario)
    and (cleaned_kind is null or damage_stock_holds.hold_kind = cleaned_kind)
    and (cleaned_status is null or damage_stock_holds.status = cleaned_status)
    and (
      cleaned_search is null
      or pg_catalog.lower(products.sku) like '%' || cleaned_search || '%' escape '\'
      or pg_catalog.lower(products.name) like '%' || cleaned_search || '%' escape '\'
    )
    and (from_ts is null or damage_stock_holds.created_at >= from_ts)
    and (to_ts is null or damage_stock_holds.created_at < to_ts)
    and app_private.can_view_damage_report(
      damage_reports.godown_id,
      damage_reports.scenario,
      damage_reports.reporter_user_id,
      damage_reports.dispatch_id
    );

  return pg_catalog.jsonb_build_object(
    'total', total_count,
    'page', safe_page,
    'page_size', safe_size,
    'totals', class_totals,
    'items', coalesce((
      select pg_catalog.jsonb_agg(item)
      from (
        select pg_catalog.jsonb_build_object(
          'hold_id', damage_stock_holds.id,
          'damage_report_id', damage_reports.id,
          'report_number', damage_reports.report_number,
          'report_status', damage_reports.status,
          'scenario', damage_reports.scenario,
          'godown_id', damage_reports.godown_id,
          'godown_name', branches.name,
          'godown_active', branches.is_active,
          'product_id', products.id,
          'product_sku', products.sku,
          'product_name', products.name,
          'quantity_cases', damage_stock_holds.quantity_cases,
          'hold_kind', damage_stock_holds.hold_kind,
          'hold_status', damage_stock_holds.status,
          'isolation_class', app_private.damage_hold_isolation_class(
            damage_stock_holds.status, damage_stock_holds.hold_kind
          ),
          'crate_id', damage_stock_holds.crate_id,
          'crate_code', crates.code,
          'location_role', crates.location_role,
          'zone_code', zones.code,
          'zone_name', zones.name,
          'lot_id', damage_stock_holds.lot_id,
          'source_reservation_id', damage_stock_holds.source_reservation_id,
          'posted_transaction_id', damage_stock_holds.posted_transaction_id,
          'created_at', damage_stock_holds.created_at
        ) as item
        from public.damage_stock_holds
        join public.damage_reports
          on damage_reports.id = damage_stock_holds.damage_report_id
        join public.branches on branches.id = damage_reports.godown_id
        join public.products on products.id = damage_stock_holds.product_id
        left join public.crates on crates.id = damage_stock_holds.crate_id
        left join public.zones on zones.id = crates.zone_id
        where (target_godown is null or damage_reports.godown_id = target_godown)
          and (target_product is null or damage_stock_holds.product_id = target_product)
          and (cleaned_scenario is null or damage_reports.scenario = cleaned_scenario)
          and (cleaned_kind is null or damage_stock_holds.hold_kind = cleaned_kind)
          and (cleaned_status is null or damage_stock_holds.status = cleaned_status)
          and (
            cleaned_search is null
            or pg_catalog.lower(products.sku) like '%' || cleaned_search || '%' escape '\'
            or pg_catalog.lower(products.name) like '%' || cleaned_search || '%' escape '\'
          )
          and (from_ts is null or damage_stock_holds.created_at >= from_ts)
          and (to_ts is null or damage_stock_holds.created_at < to_ts)
          and app_private.can_view_damage_report(
            damage_reports.godown_id,
            damage_reports.scenario,
            damage_reports.reporter_user_id,
            damage_reports.dispatch_id
          )
        order by damage_stock_holds.created_at desc, damage_stock_holds.id desc
        offset (safe_page - 1) * safe_size
        limit safe_size
      ) listed
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.list_damage_quarantine_inventory(
  integer, integer, uuid, uuid, text, text, text, text, date, date
) from public, anon, service_role;
grant execute on function public.list_damage_quarantine_inventory(
  integer, integer, uuid, uuid, text, text, text, text, date, date
) to authenticated;

comment on function public.list_damage_quarantine_inventory(
  integer, integer, uuid, uuid, text, text, text, text, date, date
) is
  'Authorized damage holds. totals are filter-wide, not page sums. Written-off is excluded from current_unavailable_cases.';
