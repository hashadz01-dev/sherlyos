-- M5.4E: exceptional request queue reads, payload actor/decision facts,
-- unlocked godown snapshot on request, remaining-hold gates, and completed
-- identification for approve/reject/post before stale-version rejection.
-- Local only. Does not flip damage.stock_hold_ready or lot cutover flags.

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
        'requested_by', damage_exceptional_requests.requested_by,
        'requested_by_name', requester.full_name,
        'requested_at', damage_exceptional_requests.requested_at,
        'decided_by', damage_exceptional_requests.decided_by,
        'decided_by_name', decider.full_name,
        'decided_at', damage_exceptional_requests.decided_at,
        'decision_reason', damage_exceptional_requests.decision_reason,
        'posted_by', damage_exceptional_requests.posted_by,
        'posted_by_name', poster.full_name,
        'posted_at', damage_exceptional_requests.posted_at,
        'posted_transaction_id', damage_exceptional_requests.posted_transaction_id
      ) order by damage_exceptional_requests.created_at)
      from public.damage_exceptional_requests
      join public.profiles requester
        on requester.id = damage_exceptional_requests.requested_by
      left join public.profiles decider
        on decider.id = damage_exceptional_requests.decided_by
      left join public.profiles poster
        on poster.id = damage_exceptional_requests.posted_by
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

create or replace function public.request_exceptional_damage_disposition(
  target_report uuid,
  expected_version integer,
  disposition_kind text,
  request_reason text,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  cleaned_key text;
  cleaned_kind text;
  cleaned_reason text;
  existing public.damage_exceptional_requests;
  created_id uuid;
begin
  perform set_config('app.damage_write', 'on', true);
  -- Permission and report visibility (lock_damage_report / can_view) run
  -- before completed identification so a reused key cannot skip auth.
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  -- Same key on this report is not a new request. A key that already belongs
  -- to a different report is a different operation, not a replay.
  select * into existing
  from public.damage_exceptional_requests
  where request_idempotency_key = cleaned_key;
  if found then
    if existing.damage_report_id is distinct from selected.id then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    return app_private.damage_report_payload(selected.id);
  end if;

  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_damage_godown_active_unlocked(selected.godown_id);
  perform app_private.assert_damage_disposition_ready(selected);
  cleaned_kind := pg_catalog.lower(pg_catalog.btrim(coalesce(disposition_kind, '')));
  cleaned_reason := app_private.clean_verification_text(request_reason, true);

  if cleaned_kind not in ('return_supplier', 'destroy') then
    raise exception 'exceptional disposition is invalid' using errcode = '23514';
  end if;

  if exists (
    select 1 from public.stock_transactions
    where stock_transactions.damage_report_id = selected.id
      and stock_transactions.damage_posting_kind = 'ordinary_writeoff'
  ) then
    raise exception 'an ordinary write-off is already posted' using errcode = '23514';
  end if;

  if not exists (
    select 1 from public.damage_stock_holds
    where damage_report_id = selected.id
      and status in ('active', 'transferred')
  ) then
    raise exception 'no isolated damage quantity remains' using errcode = '23514';
  end if;

  begin
    insert into public.damage_exceptional_requests (
      damage_report_id, disposition_kind, status, request_reason,
      requested_by, request_idempotency_key
    )
    values (
      selected.id, cleaned_kind, 'requested', cleaned_reason, auth.uid(), cleaned_key
    )
    returning id into created_id;
  exception
    when unique_violation then
      select * into existing
      from public.damage_exceptional_requests
      where request_idempotency_key = cleaned_key;
      if found then
        if existing.damage_report_id is distinct from selected.id then
          raise exception 'not authorized' using errcode = '42501';
        end if;
        return app_private.damage_report_payload(selected.id);
      end if;
      raise exception 'an exceptional disposition is already open'
        using errcode = '23514';
  end;

  perform app_private.record_damage_event(
    selected.id, 'exceptional_requested', selected.status, selected.status,
    jsonb_build_object('request_id', created_id, 'kind', cleaned_kind)
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

revoke all on function public.request_exceptional_damage_disposition(uuid, integer, text, text, text)
  from public, anon, service_role;
grant execute on function public.request_exceptional_damage_disposition(uuid, integer, text, text, text)
  to authenticated;

comment on function public.request_exceptional_damage_disposition(uuid, integer, text, text, text) is
  'GM exceptional request. Remaining holds required. Replay by request key. Does not post stock.';

create or replace function public.approve_exceptional_damage_disposition(
  target_request uuid,
  expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_exceptional_requests;
  header public.damage_reports;
begin
  perform set_config('app.damage_write', 'on', true);
  -- Current dispose permission and report visibility are required even when
  -- the request is already approved or posted.
  perform app_private.assert_permission('damage.dispose');

  select * into selected
  from public.damage_exceptional_requests
  where id = target_request
  for update;
  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  header := app_private.lock_damage_report(selected.damage_report_id);

  -- Completed identification: already approved or posted is not a new decision.
  if selected.status in ('approved', 'posted') then
    return app_private.damage_report_payload(header.id);
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'changed by someone else' using errcode = 'PT409';
  end if;
  if selected.status is distinct from 'requested' then
    raise exception 'exceptional request cannot be approved' using errcode = '42501';
  end if;

  update public.damage_exceptional_requests
  set
    status = 'approved',
    decided_by = auth.uid(),
    decided_at = clock_timestamp(),
    version = selected.version + 1
  where id = selected.id;

  perform app_private.record_damage_event(
    header.id, 'exceptional_approved', header.status, header.status,
    jsonb_build_object('request_id', selected.id, 'kind', selected.disposition_kind)
  );
  return app_private.damage_report_payload(header.id);
end;
$$;

revoke all on function public.approve_exceptional_damage_disposition(uuid, integer)
  from public, anon, service_role;
grant execute on function public.approve_exceptional_damage_disposition(uuid, integer)
  to authenticated;

comment on function public.approve_exceptional_damage_disposition(uuid, integer) is
  'Admin authorization only. Does not post stock. Completed approve/post identifies without a new decision.';

create or replace function public.reject_exceptional_damage_disposition(
  target_request uuid,
  expected_version integer,
  decision_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_exceptional_requests;
  header public.damage_reports;
  cleaned_reason text;
begin
  perform set_config('app.damage_write', 'on', true);
  -- Current dispose permission and report visibility run before replay so a
  -- completed reject cannot disclose payload after authorization is lost.
  perform app_private.assert_permission('damage.dispose');

  select * into selected
  from public.damage_exceptional_requests
  where id = target_request
  for update;
  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  header := app_private.lock_damage_report(selected.damage_report_id);

  if selected.status = 'rejected' then
    return app_private.damage_report_payload(header.id);
  end if;

  cleaned_reason := app_private.clean_verification_text(decision_reason, true);

  if selected.version is distinct from expected_version then
    raise exception 'changed by someone else' using errcode = 'PT409';
  end if;
  if selected.status is distinct from 'requested' then
    raise exception 'exceptional request cannot be rejected' using errcode = '42501';
  end if;

  update public.damage_exceptional_requests
  set
    status = 'rejected',
    decided_by = auth.uid(),
    decided_at = clock_timestamp(),
    decision_reason = cleaned_reason,
    version = selected.version + 1
  where id = selected.id;

  perform app_private.record_damage_event(
    header.id, 'exceptional_rejected', header.status, header.status,
    jsonb_build_object('request_id', selected.id, 'reason', cleaned_reason)
  );
  return app_private.damage_report_payload(header.id);
end;
$$;

revoke all on function public.reject_exceptional_damage_disposition(uuid, integer, text)
  from public, anon, service_role;
grant execute on function public.reject_exceptional_damage_disposition(uuid, integer, text)
  to authenticated;

comment on function public.reject_exceptional_damage_disposition(uuid, integer, text) is
  'Admin rejection. Reason required. Holds stay. Completed reject identifies without a new decision.';

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
  -- Completed posting is identified without asserting version, key, or
  -- godown activity, but never before current verify permission and
  -- can_view. Identification is read-only and must not re-consume holds.
  perform app_private.assert_permission('damage.verify');

  select * into selected
  from public.damage_exceptional_requests
  where id = target_request
  for update;
  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  header := app_private.lock_damage_report(selected.damage_report_id);

  if selected.status = 'posted' then
    return app_private.damage_report_payload(header.id);
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'changed by someone else' using errcode = 'PT409';
  end if;

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

  if selected.status is distinct from 'approved' then
    raise exception 'exceptional request is not approved' using errcode = '42501';
  end if;

  if app_private.has_permission('damage.dispose')
    and not app_private.has_permission('damage.verify')
  then
    raise exception 'not authorized' using errcode = '42501';
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
    jsonb_build_object(
      'request_id', selected.id,
      'transaction_id', posted,
      'kind', selected.disposition_kind,
      'idempotency_key', idempotency_key
    )
  );
  perform app_private.write_audit(
    auth.uid(), 'post_exceptional_damage_disposition', 'damage_reports', header.id,
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
  'GM execution after admin approval. Completed postings replay without version. Snapshots godown, then products before locations.';

-- Server-paged exceptional request queue. Visibility is can_view_damage_report.
create or replace function public.list_exceptional_damage_requests(
  page integer default 1,
  page_size integer default 50,
  target_godown uuid default null,
  status_filter text default null,
  kind_filter text default null,
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
  cleaned_kind text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(kind_filter, ''))), '');
  cleaned_scenario text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(scenario_filter, ''))), '');
  cleaned_search text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(search_text, ''))), '');
  from_ts timestamptz := case when from_date is null then null else from_date::timestamp at time zone 'utc' end;
  to_ts timestamptz := case when to_date is null then null else (to_date + 1)::timestamp at time zone 'utc' end;
  total_count integer;
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if not (
    app_private.has_permission('damage.dispose')
    or app_private.has_permission('operations.monitor')
    or app_private.has_permission('damage.verify')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if cleaned_status is not null
    and cleaned_status not in ('requested', 'approved', 'rejected', 'posted')
  then
    raise exception 'exceptional status filter is invalid' using errcode = '23514';
  end if;
  if cleaned_kind is not null
    and cleaned_kind not in ('return_supplier', 'destroy')
  then
    raise exception 'exceptional disposition is invalid' using errcode = '23514';
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
  from public.damage_exceptional_requests
  join public.damage_reports
    on damage_reports.id = damage_exceptional_requests.damage_report_id
  where (target_godown is null or damage_reports.godown_id = target_godown)
    and (cleaned_status is null or damage_exceptional_requests.status = cleaned_status)
    and (cleaned_kind is null or damage_exceptional_requests.disposition_kind = cleaned_kind)
    and (cleaned_scenario is null or damage_reports.scenario = cleaned_scenario)
    and (
      cleaned_search is null
      or pg_catalog.lower(damage_reports.report_number) like '%' || cleaned_search || '%' escape '\'
    )
    and (from_ts is null or damage_exceptional_requests.requested_at >= from_ts)
    and (to_ts is null or damage_exceptional_requests.requested_at < to_ts)
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
          'id', damage_exceptional_requests.id,
          'damage_report_id', damage_reports.id,
          'report_number', damage_reports.report_number,
          'report_status', damage_reports.status,
          'report_version', damage_reports.version,
          'scenario', damage_reports.scenario,
          'godown_id', damage_reports.godown_id,
          'godown_name', branches.name,
          'godown_active', branches.is_active,
          'kind', damage_exceptional_requests.disposition_kind,
          'status', damage_exceptional_requests.status,
          'version', damage_exceptional_requests.version,
          'request_reason', damage_exceptional_requests.request_reason,
          'requested_by', damage_exceptional_requests.requested_by,
          'requested_by_name', requester.full_name,
          'requested_at', damage_exceptional_requests.requested_at,
          'decided_by', damage_exceptional_requests.decided_by,
          'decided_by_name', decider.full_name,
          'decided_at', damage_exceptional_requests.decided_at,
          'decision_reason', damage_exceptional_requests.decision_reason,
          'posted_by', damage_exceptional_requests.posted_by,
          'posted_by_name', poster.full_name,
          'posted_at', damage_exceptional_requests.posted_at,
          'posted_transaction_id', damage_exceptional_requests.posted_transaction_id,
          'has_finalized_evidence', exists (
            select 1 from public.damage_evidence
            where damage_evidence.damage_report_id = damage_reports.id
              and damage_evidence.verified_at is not null
          ),
          'total_cases', coalesce((
            select sum(damage_report_lines.quantity_cases)
            from public.damage_report_lines
            where damage_report_lines.damage_report_id = damage_reports.id
          ), 0),
          'remaining_hold_cases', coalesce((
            select sum(damage_stock_holds.quantity_cases)
            from public.damage_stock_holds
            where damage_stock_holds.damage_report_id = damage_reports.id
              and damage_stock_holds.status in ('active', 'transferred')
          ), 0)
        ) as item
        from public.damage_exceptional_requests
        join public.damage_reports
          on damage_reports.id = damage_exceptional_requests.damage_report_id
        join public.branches on branches.id = damage_reports.godown_id
        join public.profiles requester
          on requester.id = damage_exceptional_requests.requested_by
        left join public.profiles decider
          on decider.id = damage_exceptional_requests.decided_by
        left join public.profiles poster
          on poster.id = damage_exceptional_requests.posted_by
        where (target_godown is null or damage_reports.godown_id = target_godown)
          and (cleaned_status is null or damage_exceptional_requests.status = cleaned_status)
          and (cleaned_kind is null or damage_exceptional_requests.disposition_kind = cleaned_kind)
          and (cleaned_scenario is null or damage_reports.scenario = cleaned_scenario)
          and (
            cleaned_search is null
            or pg_catalog.lower(damage_reports.report_number) like '%' || cleaned_search || '%' escape '\'
          )
          and (from_ts is null or damage_exceptional_requests.requested_at >= from_ts)
          and (to_ts is null or damage_exceptional_requests.requested_at < to_ts)
          and app_private.can_view_damage_report(
            damage_reports.godown_id,
            damage_reports.scenario,
            damage_reports.reporter_user_id,
            damage_reports.dispatch_id
          )
        order by damage_exceptional_requests.requested_at asc, damage_exceptional_requests.id asc
        offset (safe_page - 1) * safe_size
        limit safe_size
      ) listed
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.list_exceptional_damage_requests(integer, integer, uuid, text, text, text, text, date, date)
  from public, anon, service_role;
grant execute on function public.list_exceptional_damage_requests(integer, integer, uuid, text, text, text, text, date, date)
  to authenticated;

comment on function public.list_exceptional_damage_requests(integer, integer, uuid, text, text, text, text, date, date) is
  'Server-paged exceptional request queue. damage.dispose, operations.monitor, or damage.verify. Rows still pass can_view_damage_report.';
