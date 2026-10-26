-- M5.4D: verification/return/reject actor fields on the authorized payload,
-- list facts needed by the GM verification queue, and lock-order alignment
-- for verify/return/reject (snapshot is_active without early branch FOR UPDATE).
-- Local only. Does not flip damage.stock_hold_ready or lot cutover flags.

-- Snapshot godown activity without locking the branch row. Verify/return/reject
-- do not post stock through lock_damage_stock_grains; an early branch lock
-- inverts confirm_dispatch (products then locations).
create or replace function app_private.assert_damage_godown_active_unlocked(
  target_godown uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if target_godown is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  if not exists (
    select 1
    from public.branches
    where branches.id = target_godown
      and branches.is_active
  ) then
    raise exception 'godown is inactive' using errcode = '23514';
  end if;
  if not app_private.can_work_at_branch(target_godown) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_damage_godown_active_unlocked(uuid)
  from public, anon, authenticated, service_role;

comment on function app_private.assert_damage_godown_active_unlocked(uuid) is
  'M5.4D. Require an active assigned godown without FOR UPDATE on branches.';

create or replace function app_private.damage_report_payload(target_report uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  header public.damage_reports;
begin
  select * into header from public.damage_reports where damage_reports.id = target_report;

  if not found
    or not app_private.can_view_damage_report(
      header.godown_id, header.scenario, header.reporter_user_id, header.dispatch_id
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'id', header.id,
    'report_number', header.report_number,
    'scenario', header.scenario,
    'godown_id', header.godown_id,
    'godown_name', (select branches.name from public.branches where branches.id = header.godown_id),
    'godown_active', (select branches.is_active from public.branches where branches.id = header.godown_id),
    'status', header.status,
    'version', header.version,
    'receipt_id', header.receipt_id,
    'picking_request_id', header.picking_request_id,
    'dispatch_id', header.dispatch_id,
    'order_id', header.order_id,
    'shop_id', header.shop_id,
    'shop_name', (select shops.name from public.shops where shops.id = header.shop_id),
    'notes', header.notes,
    'reporter_user_id', header.reporter_user_id,
    'physical_custody_confirmed', header.physical_custody_confirmed_at is not null,
    'physical_custody_confirmed_at', header.physical_custody_confirmed_at,
    'physical_custody_confirmed_by', header.physical_custody_confirmed_by,
    'physical_custody_confirmed_by_name', (
      select profiles.full_name
      from public.profiles
      where profiles.id = header.physical_custody_confirmed_by
    ),
    'reporter_name', (
      select profiles.full_name from public.profiles where profiles.id = header.reporter_user_id
    ),
    'verifier_user_id', header.verifier_user_id,
    'verifier_name', (
      select profiles.full_name from public.profiles where profiles.id = header.verifier_user_id
    ),
    'verified_at', header.verified_at,
    'returned_at', header.returned_at,
    'returned_by', header.returned_by,
    'returned_by_name', (
      select profiles.full_name from public.profiles where profiles.id = header.returned_by
    ),
    'return_reason', header.return_reason,
    'rejected_at', header.rejected_at,
    'rejected_by', header.rejected_by,
    'rejected_by_name', (
      select profiles.full_name from public.profiles where profiles.id = header.rejected_by
    ),
    'rejection_reason', header.rejection_reason,
    'created_at', header.created_at,
    'updated_at', header.updated_at,
    'lines', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', damage_report_lines.id,
        'product_id', damage_report_lines.product_id,
        'product_sku', products.sku,
        'product_name', products.name,
        'crate_id', damage_report_lines.crate_id,
        'crate_code', crates.code,
        'lot_id', damage_report_lines.lot_id,
        'quantity_cases', damage_report_lines.quantity_cases,
        'damage_reason', damage_report_lines.damage_reason,
        'notes', damage_report_lines.notes,
        'receipt_line_id', damage_report_lines.receipt_line_id
      ) order by damage_report_lines.sort_order, damage_report_lines.id)
      from public.damage_report_lines
      join public.products on products.id = damage_report_lines.product_id
      left join public.crates on crates.id = damage_report_lines.crate_id
      where damage_report_lines.damage_report_id = header.id
    ), '[]'::jsonb),
    'holds', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', damage_stock_holds.id,
        'line_id', damage_stock_holds.damage_report_line_id,
        'product_id', damage_stock_holds.product_id,
        'product_sku', products.sku,
        'product_name', products.name,
        'crate_id', damage_stock_holds.crate_id,
        'crate_code', crates.code,
        'location_role', crates.location_role,
        'zone_code', zones.code,
        'zone_name', zones.name,
        'lot_id', damage_stock_holds.lot_id,
        'quantity_cases', damage_stock_holds.quantity_cases,
        'hold_kind', damage_stock_holds.hold_kind,
        'status', damage_stock_holds.status,
        'source_reservation_id', damage_stock_holds.source_reservation_id,
        'posted_transaction_id', damage_stock_holds.posted_transaction_id,
        'created_at', damage_stock_holds.created_at
      ) order by damage_stock_holds.created_at, damage_stock_holds.id)
      from public.damage_stock_holds
      join public.products on products.id = damage_stock_holds.product_id
      left join public.crates on crates.id = damage_stock_holds.crate_id
      left join public.zones on zones.id = crates.zone_id
      where damage_stock_holds.damage_report_id = header.id
    ), '[]'::jsonb),
    'exceptional_requests', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', damage_exceptional_requests.id,
        'kind', damage_exceptional_requests.disposition_kind,
        'status', damage_exceptional_requests.status,
        'version', damage_exceptional_requests.version,
        'request_reason', damage_exceptional_requests.request_reason,
        'requested_at', damage_exceptional_requests.requested_at
      ) order by damage_exceptional_requests.created_at)
      from public.damage_exceptional_requests
      where damage_exceptional_requests.damage_report_id = header.id
    ), '[]'::jsonb),
    'events', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'action', damage_report_events.action,
        'actor_name', profiles.full_name,
        'previous_status', damage_report_events.previous_status,
        'next_status', damage_report_events.next_status,
        'created_at', damage_report_events.created_at,
        'metadata', damage_report_events.metadata
      ) order by damage_report_events.created_at, damage_report_events.id)
      from public.damage_report_events
      join public.profiles on profiles.id = damage_report_events.actor_id
      where damage_report_events.damage_report_id = header.id
    ), '[]'::jsonb),
    'evidence', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', damage_evidence.id,
        'finalized', damage_evidence.verified_at is not null,
        'mime_type', damage_evidence.mime_type,
        'uploaded_at', damage_evidence.uploaded_at,
        'note', damage_evidence.note
      ) order by damage_evidence.uploaded_at, damage_evidence.id)
      from public.damage_evidence
      where damage_evidence.damage_report_id = header.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app_private.damage_report_payload(uuid)
  from public, anon, authenticated, service_role;

create or replace function public.list_damage_reports(
  page integer default 1,
  page_size integer default 50,
  target_godown uuid default null,
  status_filter text default null,
  scenario_filter text default null,
  search_text text default null,
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
  safe_size integer := least(greatest(coalesce(page_size, 50), 1), 100);
  cleaned_status text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(status_filter, ''))), '');
  cleaned_scenario text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(scenario_filter, ''))), '');
  cleaned_search text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(search_text, ''))), '');
  from_ts timestamptz := case when from_date is null then null else from_date::timestamp at time zone 'utc' end;
  to_ts timestamptz := case when to_date is null then null else (to_date + 1)::timestamp at time zone 'utc' end;
  total_count integer;
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if cleaned_status is not null
    and cleaned_status not in ('draft', 'submitted', 'returned', 'verified', 'cancelled', 'rejected')
  then
    raise exception 'damage status filter is invalid' using errcode = '23514';
  end if;

  if cleaned_scenario is not null
    and cleaned_scenario not in (
      'refill_supply', 'unloading', 'storage', 'loading', 'transit', 'shop_return'
    )
  then
    raise exception 'damage scenario filter is invalid' using errcode = '23514';
  end if;

  if from_date is not null and to_date is not null and from_date > to_date then
    raise exception 'damage date range is invalid' using errcode = '23514';
  end if;

  if cleaned_search is not null then
    cleaned_search := replace(replace(replace(cleaned_search, '\', '\\'), '%', '\%'), '_', '\_');
  end if;

  select count(*)
  into total_count
  from public.damage_reports
  where (target_godown is null or damage_reports.godown_id = target_godown)
    and (cleaned_status is null or damage_reports.status = cleaned_status)
    and (cleaned_scenario is null or damage_reports.scenario = cleaned_scenario)
    and (
      cleaned_search is null
      or pg_catalog.lower(damage_reports.report_number) like '%' || cleaned_search || '%' escape '\'
    )
    and (from_ts is null or damage_reports.created_at >= from_ts)
    and (to_ts is null or damage_reports.created_at < to_ts)
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
    'items', coalesce((
      select pg_catalog.jsonb_agg(item)
      from (
        select pg_catalog.jsonb_build_object(
          'id', damage_reports.id,
          'report_number', damage_reports.report_number,
          'scenario', damage_reports.scenario,
          'godown_id', damage_reports.godown_id,
          'godown_name', branches.name,
          'godown_active', branches.is_active,
          'status', damage_reports.status,
          'version', damage_reports.version,
          'reporter_user_id', damage_reports.reporter_user_id,
          'reporter_name', profiles.full_name,
          'created_at', damage_reports.created_at,
          'receipt_id', damage_reports.receipt_id,
          'picking_request_id', damage_reports.picking_request_id,
          'dispatch_id', damage_reports.dispatch_id,
          'order_id', damage_reports.order_id,
          'shop_id', damage_reports.shop_id,
          'physical_custody_confirmed', damage_reports.physical_custody_confirmed_at is not null,
          'has_finalized_evidence', exists (
            select 1 from public.damage_evidence
            where damage_evidence.damage_report_id = damage_reports.id
              and damage_evidence.verified_at is not null
          ),
          'finalized_evidence_count', (
            select count(*)::integer
            from public.damage_evidence
            where damage_evidence.damage_report_id = damage_reports.id
              and damage_evidence.verified_at is not null
          ),
          'total_cases', coalesce((
            select sum(damage_report_lines.quantity_cases)
            from public.damage_report_lines
            where damage_report_lines.damage_report_id = damage_reports.id
          ), 0),
          'active_hold_cases', coalesce((
            select sum(damage_stock_holds.quantity_cases)
            from public.damage_stock_holds
            where damage_stock_holds.damage_report_id = damage_reports.id
              and damage_stock_holds.status in ('active', 'transferred')
          ), 0),
          'exceptional_open', exists (
            select 1
            from public.damage_exceptional_requests
            where damage_exceptional_requests.damage_report_id = damage_reports.id
              and damage_exceptional_requests.status in ('requested', 'approved')
          )
        ) as item
        from public.damage_reports
        join public.branches on branches.id = damage_reports.godown_id
        join public.profiles on profiles.id = damage_reports.reporter_user_id
        where (target_godown is null or damage_reports.godown_id = target_godown)
          and (cleaned_status is null or damage_reports.status = cleaned_status)
          and (cleaned_scenario is null or damage_reports.scenario = cleaned_scenario)
          and (
            cleaned_search is null
            or pg_catalog.lower(damage_reports.report_number) like '%' || cleaned_search || '%' escape '\'
          )
          and (from_ts is null or damage_reports.created_at >= from_ts)
          and (to_ts is null or damage_reports.created_at < to_ts)
          and app_private.can_view_damage_report(
            damage_reports.godown_id,
            damage_reports.scenario,
            damage_reports.reporter_user_id,
            damage_reports.dispatch_id
          )
        order by damage_reports.created_at desc, damage_reports.id desc
        offset (safe_page - 1) * safe_size
        limit safe_size
      ) listed
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.list_damage_reports(integer, integer, uuid, text, text, text, date, date)
  from public, anon, service_role;
grant execute on function public.list_damage_reports(integer, integer, uuid, text, text, text, date, date)
  to authenticated;

create or replace function public.verify_damage_report(
  target_report uuid,
  expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_damage_godown_active_unlocked(selected.godown_id);

  if selected.status is distinct from 'submitted' then
    raise exception 'damage report cannot be verified' using errcode = '42501';
  end if;

  if selected.reporter_user_id is not distinct from auth.uid() then
    raise exception 'the reporter cannot verify this damage report' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.damage_evidence
    where damage_evidence.damage_report_id = selected.id
      and damage_evidence.verified_at is not null
  ) then
    raise exception 'photographic evidence is required' using errcode = '23514';
  end if;

  if app_private.damage_requires_stock_hold(selected.scenario)
    and not exists (
      select 1 from public.damage_stock_holds
      where damage_report_id = selected.id
        and status in ('active', 'transferred')
    )
  then
    raise exception 'damage stock isolation is not ready' using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.damage_report_lines
    where damage_report_id = selected.id
      and quantity_cases is distinct from (
        select coalesce(sum(damage_stock_holds.quantity_cases), 0)
        from public.damage_stock_holds
        where damage_stock_holds.damage_report_line_id = damage_report_lines.id
          and damage_stock_holds.status in ('active', 'transferred')
      )
      and app_private.damage_requires_stock_hold(selected.scenario)
  ) then
    raise exception 'verified quantities cannot exceed isolated quantities'
      using errcode = '23514';
  end if;

  update public.damage_reports
  set
    status = 'verified',
    verifier_user_id = auth.uid(),
    verified_at = pg_catalog.clock_timestamp(),
    version = selected.version + 1
  where damage_reports.id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'verified', selected.status, 'verified', '{}'::jsonb
  );
  perform app_private.write_audit(
    auth.uid(), 'verify_damage_report', 'damage_reports', selected.id, '{}'::jsonb
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

revoke all on function public.verify_damage_report(uuid, integer)
  from public, anon, service_role;
grant execute on function public.verify_damage_report(uuid, integer)
  to authenticated;

comment on function public.verify_damage_report(uuid, integer) is
  'GM verification. Submitted only. Reporter cannot self-verify. Finalized evidence required. Isolation scenarios require matching holds.';

create or replace function public.return_damage_report(
  target_report uuid,
  expected_version integer,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  cleaned_reason text;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_damage_godown_active_unlocked(selected.godown_id);
  cleaned_reason := app_private.clean_verification_text(reason, true);

  if selected.status is distinct from 'submitted' then
    raise exception 'damage report cannot be returned' using errcode = '42501';
  end if;

  if selected.scenario = 'shop_return' then
    raise exception 'submitted shop-return damage cannot return to draft'
      using errcode = '23514';
  end if;

  perform app_private.release_damage_holds(selected.id, 'returned');

  update public.damage_reports
  set
    status = 'returned',
    returned_at = pg_catalog.clock_timestamp(),
    returned_by = auth.uid(),
    return_reason = cleaned_reason,
    version = selected.version + 1
  where id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'returned', selected.status, 'returned',
    jsonb_build_object('reason', cleaned_reason)
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

revoke all on function public.return_damage_report(uuid, integer, text)
  from public, anon, service_role;
grant execute on function public.return_damage_report(uuid, integer, text)
  to authenticated;

comment on function public.return_damage_report(uuid, integer, text) is
  'Return submitted non-shop-return reports for correction. Releases logical holds. Reason required.';

create or replace function public.reject_damage_report(
  target_report uuid,
  expected_version integer,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  cleaned_reason text;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_damage_godown_active_unlocked(selected.godown_id);
  cleaned_reason := app_private.clean_verification_text(reason, true);

  if selected.status is distinct from 'submitted' then
    raise exception 'damage report cannot be rejected' using errcode = '42501';
  end if;

  if selected.reporter_user_id is not distinct from auth.uid() then
    raise exception 'the reporter cannot verify this damage report' using errcode = '42501';
  end if;

  perform app_private.release_damage_holds(selected.id, 'rejected');

  update public.damage_reports
  set
    status = 'rejected',
    rejected_at = pg_catalog.clock_timestamp(),
    rejected_by = auth.uid(),
    rejection_reason = cleaned_reason,
    version = selected.version + 1
  where id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'rejected', selected.status, 'rejected',
    jsonb_build_object('reason', cleaned_reason)
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

revoke all on function public.reject_damage_report(uuid, integer, text)
  from public, anon, service_role;
grant execute on function public.reject_damage_report(uuid, integer, text)
  to authenticated;

comment on function public.reject_damage_report(uuid, integer, text) is
  'Reject submitted reports. Reporter cannot reject own report. Shop-return quarantine intake stays unavailable.';
