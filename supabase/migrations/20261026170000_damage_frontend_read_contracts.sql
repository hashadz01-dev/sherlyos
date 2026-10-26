-- M5.4A read-only damage frontend contracts.
-- Local-first. Does not flip damage.stock_hold_ready or lot cutover flags.
-- Extends list filters, dashboard aggregates, and detail hold visibility.

create or replace function public.damage_stock_hold_ready_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  -- Any damage nav permission may learn whether stock-affecting submit is ready.
  if not (
    app_private.has_permission('damage.read')
    or app_private.has_permission('damage.record')
    or app_private.has_permission('damage.verify')
    or app_private.has_permission('operations.monitor')
    or app_private.has_permission('deliveries.execute')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'stock_hold_ready', app_private.damage_stock_hold_ready()
  );
end;
$$;

revoke all on function public.damage_stock_hold_ready_status() from public, anon, service_role;
grant execute on function public.damage_stock_hold_ready_status() to authenticated;

-- SECURITY DEFINER reads bypass FORCE RLS. Every query must call
-- app_private.can_view_damage_report so godown scope and assigned-driver
-- transit-only access stay identical to M5.2 table policies.
drop function if exists public.list_damage_reports(integer, integer, uuid);
drop function if exists public.list_damage_reports(integer, integer, uuid, text, text, text);

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
          'status', damage_reports.status,
          'version', damage_reports.version,
          'reporter_name', profiles.full_name,
          'created_at', damage_reports.created_at,
          'receipt_id', damage_reports.receipt_id,
          'picking_request_id', damage_reports.picking_request_id,
          'dispatch_id', damage_reports.dispatch_id,
          'order_id', damage_reports.order_id,
          'shop_id', damage_reports.shop_id,
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

create or replace function public.get_damage_dashboard(target_godown uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  visible_ids uuid[];
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  -- Same nav gate as the ready-status RPC. Aggregates still use can_view so
  -- a driver cannot inflate totals with other godowns' storage reports.
  if not (
    app_private.has_permission('damage.read')
    or app_private.has_permission('damage.record')
    or app_private.has_permission('damage.verify')
    or app_private.has_permission('operations.monitor')
    or app_private.has_permission('deliveries.execute')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select coalesce(array_agg(damage_reports.id), '{}'::uuid[])
  into visible_ids
  from public.damage_reports
  where (target_godown is null or damage_reports.godown_id = target_godown)
    and app_private.can_view_damage_report(
      damage_reports.godown_id,
      damage_reports.scenario,
      damage_reports.reporter_user_id,
      damage_reports.dispatch_id
    );

  return pg_catalog.jsonb_build_object(
    'stock_hold_ready', app_private.damage_stock_hold_ready(),
    'totals', pg_catalog.jsonb_build_object(
      'reports', coalesce(pg_catalog.cardinality(visible_ids), 0),
      'pending_verification', (
        select count(*)::integer from public.damage_reports
        where id = any (visible_ids) and status = 'submitted'
      ),
      'verified', (
        select count(*)::integer from public.damage_reports
        where id = any (visible_ids) and status = 'verified'
      ),
      'active_hold_cases', coalesce((
        select sum(damage_stock_holds.quantity_cases)::integer
        from public.damage_stock_holds
        where damage_stock_holds.damage_report_id = any (visible_ids)
          and damage_stock_holds.status in ('active', 'transferred')
      ), 0),
      'quarantined_cases', coalesce((
        select sum(damage_stock_holds.quantity_cases)::integer
        from public.damage_stock_holds
        join public.crates on crates.id = damage_stock_holds.crate_id
        where damage_stock_holds.damage_report_id = any (visible_ids)
          and damage_stock_holds.status in ('active', 'transferred')
          and (
            damage_stock_holds.hold_kind = 'quarantine_intake'
            or crates.location_role = 'quarantine'
          )
      ), 0),
      'pending_exceptional', (
        select count(*)::integer
        from public.damage_exceptional_requests
        where damage_exceptional_requests.damage_report_id = any (visible_ids)
          and damage_exceptional_requests.status in ('requested', 'approved')
      )
    ),
    'queues', pg_catalog.jsonb_build_object(
      'recent_submitted', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', q.id,
          'report_number', q.report_number,
          'scenario', q.scenario,
          'status', q.status,
          'godown_name', q.godown_name,
          'created_at', q.created_at
        ))
        from (
          select damage_reports.id, damage_reports.report_number, damage_reports.scenario,
            damage_reports.status, branches.name as godown_name, damage_reports.created_at
          from public.damage_reports
          join public.branches on branches.id = damage_reports.godown_id
          where damage_reports.id = any (visible_ids)
            and damage_reports.status = 'submitted'
          order by damage_reports.created_at desc
          limit 8
        ) q
      ), '[]'::jsonb),
      'awaiting_verification', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', q.id,
          'report_number', q.report_number,
          'scenario', q.scenario,
          'status', q.status,
          'godown_name', q.godown_name,
          'created_at', q.created_at
        ))
        from (
          select damage_reports.id, damage_reports.report_number, damage_reports.scenario,
            damage_reports.status, branches.name as godown_name, damage_reports.created_at
          from public.damage_reports
          join public.branches on branches.id = damage_reports.godown_id
          where damage_reports.id = any (visible_ids)
            and damage_reports.status = 'submitted'
          order by damage_reports.created_at asc
          limit 8
        ) q
      ), '[]'::jsonb),
      'awaiting_disposition', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', q.id,
          'report_number', q.report_number,
          'scenario', q.scenario,
          'status', q.status,
          'godown_name', q.godown_name,
          'created_at', q.created_at
        ))
        from (
          select damage_reports.id, damage_reports.report_number, damage_reports.scenario,
            damage_reports.status, branches.name as godown_name, damage_reports.created_at
          from public.damage_reports
          join public.branches on branches.id = damage_reports.godown_id
          where damage_reports.id = any (visible_ids)
            and damage_reports.status = 'verified'
            and exists (
              select 1 from public.damage_stock_holds
              where damage_stock_holds.damage_report_id = damage_reports.id
                and damage_stock_holds.status in ('active', 'transferred')
            )
          order by damage_reports.created_at asc
          limit 8
        ) q
      ), '[]'::jsonb),
      'exceptional_pending', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', q.id,
          'report_number', q.report_number,
          'scenario', q.scenario,
          'status', q.status,
          'godown_name', q.godown_name,
          'disposition_kind', q.disposition_kind,
          'exceptional_status', q.exceptional_status,
          'created_at', q.created_at
        ))
        from (
          select damage_reports.id, damage_reports.report_number, damage_reports.scenario,
            damage_reports.status, branches.name as godown_name,
            damage_exceptional_requests.disposition_kind,
            damage_exceptional_requests.status as exceptional_status,
            damage_exceptional_requests.requested_at as created_at
          from public.damage_exceptional_requests
          join public.damage_reports
            on damage_reports.id = damage_exceptional_requests.damage_report_id
          join public.branches on branches.id = damage_reports.godown_id
          where damage_reports.id = any (visible_ids)
            and damage_exceptional_requests.status in ('requested', 'approved')
          order by damage_exceptional_requests.requested_at asc
          limit 8
        ) q
      ), '[]'::jsonb),
      'recently_resolved', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', q.id,
          'report_number', q.report_number,
          'scenario', q.scenario,
          'status', q.status,
          'godown_name', q.godown_name,
          'created_at', q.created_at
        ))
        from (
          select damage_reports.id, damage_reports.report_number, damage_reports.scenario,
            damage_reports.status, branches.name as godown_name, damage_reports.updated_at as created_at
          from public.damage_reports
          join public.branches on branches.id = damage_reports.godown_id
          where damage_reports.id = any (visible_ids)
            and damage_reports.status in ('verified', 'rejected', 'cancelled')
            and not exists (
              select 1 from public.damage_stock_holds
              where damage_stock_holds.damage_report_id = damage_reports.id
                and damage_stock_holds.status in ('active', 'transferred')
            )
          order by damage_reports.updated_at desc
          limit 8
        ) q
      ), '[]'::jsonb)
    )
  );
end;
$$;

revoke all on function public.get_damage_dashboard(uuid) from public, anon, service_role;
grant execute on function public.get_damage_dashboard(uuid) to authenticated;

-- Enrich detail holds with crate identity and quarantine role for the read UI.
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
    'status', header.status,
    'version', header.version,
    'receipt_id', header.receipt_id,
    'picking_request_id', header.picking_request_id,
    'dispatch_id', header.dispatch_id,
    'order_id', header.order_id,
    'shop_id', header.shop_id,
    'notes', header.notes,
    'reporter_user_id', header.reporter_user_id,
    'physical_custody_confirmed', header.physical_custody_confirmed_at is not null,
    'reporter_name', (
      select profiles.full_name from public.profiles where profiles.id = header.reporter_user_id
    ),
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
        'crate_id', damage_stock_holds.crate_id,
        'crate_code', crates.code,
        'location_role', crates.location_role,
        'lot_id', damage_stock_holds.lot_id,
        'quantity_cases', damage_stock_holds.quantity_cases,
        'hold_kind', damage_stock_holds.hold_kind,
        'status', damage_stock_holds.status,
        'posted_transaction_id', damage_stock_holds.posted_transaction_id
      ) order by damage_stock_holds.created_at, damage_stock_holds.id)
      from public.damage_stock_holds
      left join public.crates on crates.id = damage_stock_holds.crate_id
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
        'uploaded_at', damage_evidence.uploaded_at
      ) order by damage_evidence.uploaded_at, damage_evidence.id)
      from public.damage_evidence
      where damage_evidence.damage_report_id = header.id
        and damage_evidence.verified_at is not null
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app_private.damage_report_payload(uuid)
  from public, anon, authenticated, service_role;
