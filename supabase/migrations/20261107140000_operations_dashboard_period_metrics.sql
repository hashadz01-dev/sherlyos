-- UNAPPLIED. Needs owner review before any database receives this file.
-- Read-only period metrics for the Operations Dashboard.
-- Does not post stock, change RLS, or alter existing snapshot KPIs.
--
-- Explicitly excluded from period aggregation (remain snapshot-only):
--   on-hand balances, active reservations, available-to-pick,
--   open operational queues, unclassified products.
--
-- Event timestamps (Phase 3B.1):
--   Packing handoffs  → stock_picking_requests.handed_off_at
--   Dispatches confirmed → stock_dispatch_requests.dispatched_at (+ stock_consumed)
-- Window is half-open UTC: [window_from, window_to). Max span 93 days.

create or replace function public.get_operations_dashboard_period(
  filter_branch uuid default null,
  window_from timestamptz default null,
  window_to timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  orders_total integer := 0;
  picking_total integer := 0;
  dispatch_total integer := 0;
  receiving_total integer := 0;
  damage_total integer := 0;
  orders_series jsonb := '[]'::jsonb;
  picking_series jsonb := '[]'::jsonb;
  dispatch_series jsonb := '[]'::jsonb;
  receiving_series jsonb := '[]'::jsonb;
  damage_series jsonb := '[]'::jsonb;
  can_damage boolean := false;
begin
  perform app_private.report_require_auth();

  if not (
    app_private.report_can_view_inventory()
    or app_private.report_can_view_orders()
    or app_private.report_can_view_dispatch()
    or app_private.report_can_view_operations()
    or app_private.has_permission('damage.read')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.report_assert_branch(filter_branch);

  -- Function-local window contract (does not alter shared report_assert_window).
  if window_from is null or window_to is null then
    raise exception 'window_from and window_to are required' using errcode = '23514';
  end if;
  if window_from >= window_to then
    raise exception 'date range end must be after start' using errcode = '23514';
  end if;
  if window_to - window_from > interval '93 days' then
    raise exception 'reporting window cannot exceed 93 days' using errcode = '23514';
  end if;

  can_damage := app_private.has_permission('damage.read');

  -- Orders created (event = created_at). Counting unit: order rows.
  if app_private.report_can_view_orders() then
    select coalesce(count(*), 0)
    into orders_total
    from public.orders
    where app_private.report_can_see_order(orders.id)
      and app_private.can_work_at_branch(orders.branch_id)
      and (filter_branch is null or orders.branch_id = filter_branch)
      and orders.created_at >= window_from
      and orders.created_at < window_to;

    select coalesce(jsonb_agg(
      jsonb_build_object('day', bucket.day, 'count', bucket.count)
      order by bucket.day
    ), '[]'::jsonb)
    into orders_series
    from (
      select
        (date_trunc('day', orders.created_at at time zone 'UTC'))::date as day,
        count(*)::integer as count
      from public.orders
      where app_private.report_can_see_order(orders.id)
        and app_private.can_work_at_branch(orders.branch_id)
        and (filter_branch is null or orders.branch_id = filter_branch)
        and orders.created_at >= window_from
        and orders.created_at < window_to
      group by 1
    ) bucket;
  end if;

  -- Packing handoffs (event = handed_off_at). Count once per picking request.
  -- Do not require current status — later workflow must not erase the historical handoff.
  if app_private.report_can_view_orders()
    and (
      app_private.has_permission('picking.allocate')
      or app_private.has_permission('picking.manage')
      or app_private.has_permission('picking.execute')
      or app_private.has_permission('operations.monitor')
    )
  then
    select coalesce(count(*), 0)
    into picking_total
    from public.stock_picking_requests
    where stock_picking_requests.handed_off_at is not null
      and app_private.can_work_at_branch(stock_picking_requests.branch_id)
      and (filter_branch is null or stock_picking_requests.branch_id = filter_branch)
      and stock_picking_requests.handed_off_at >= window_from
      and stock_picking_requests.handed_off_at < window_to;

    select coalesce(jsonb_agg(
      jsonb_build_object('day', bucket.day, 'count', bucket.count)
      order by bucket.day
    ), '[]'::jsonb)
    into picking_series
    from (
      select
        (date_trunc('day', stock_picking_requests.handed_off_at at time zone 'UTC'))::date as day,
        count(*)::integer as count
      from public.stock_picking_requests
      where stock_picking_requests.handed_off_at is not null
        and app_private.can_work_at_branch(stock_picking_requests.branch_id)
        and (filter_branch is null or stock_picking_requests.branch_id = filter_branch)
        and stock_picking_requests.handed_off_at >= window_from
        and stock_picking_requests.handed_off_at < window_to
      group by 1
    ) bucket;
  end if;

  -- Dispatches confirmed (event = dispatched_at). Counting unit: dispatch-request rows.
  -- stock_consumed marks the confirmed consumption event; later delivery updates do not
  -- rewrite dispatched_at, so historical buckets stay stable.
  if app_private.report_can_view_dispatch() then
    select coalesce(count(*), 0)
    into dispatch_total
    from public.stock_dispatch_requests
    where stock_dispatch_requests.stock_consumed
      and stock_dispatch_requests.dispatched_at is not null
      and (
        app_private.has_permission('dispatch.view')
        or app_private.has_permission('operations.monitor')
        or stock_dispatch_requests.assigned_to = auth.uid()
      )
      and app_private.can_work_at_branch(stock_dispatch_requests.branch_id)
      and (filter_branch is null or stock_dispatch_requests.branch_id = filter_branch)
      and stock_dispatch_requests.dispatched_at >= window_from
      and stock_dispatch_requests.dispatched_at < window_to;

    select coalesce(jsonb_agg(
      jsonb_build_object('day', bucket.day, 'count', bucket.count)
      order by bucket.day
    ), '[]'::jsonb)
    into dispatch_series
    from (
      select
        (date_trunc('day', stock_dispatch_requests.dispatched_at at time zone 'UTC'))::date as day,
        count(*)::integer as count
      from public.stock_dispatch_requests
      where stock_dispatch_requests.stock_consumed
        and stock_dispatch_requests.dispatched_at is not null
        and (
          app_private.has_permission('dispatch.view')
          or app_private.has_permission('operations.monitor')
          or stock_dispatch_requests.assigned_to = auth.uid()
        )
        and app_private.can_work_at_branch(stock_dispatch_requests.branch_id)
        and (filter_branch is null or stock_dispatch_requests.branch_id = filter_branch)
        and stock_dispatch_requests.dispatched_at >= window_from
        and stock_dispatch_requests.dispatched_at < window_to
      group by 1
    ) bucket;
  end if;

  -- Receipts created (event = created_at). Counting unit: receipt rows.
  if app_private.report_can_view_operations() then
    select coalesce(count(*), 0)
    into receiving_total
    from public.stock_receipts
    where app_private.can_work_at_branch(stock_receipts.godown_id)
      and (filter_branch is null or stock_receipts.godown_id = filter_branch)
      and stock_receipts.created_at >= window_from
      and stock_receipts.created_at < window_to;

    select coalesce(jsonb_agg(
      jsonb_build_object('day', bucket.day, 'count', bucket.count)
      order by bucket.day
    ), '[]'::jsonb)
    into receiving_series
    from (
      select
        (date_trunc('day', stock_receipts.created_at at time zone 'UTC'))::date as day,
        count(*)::integer as count
      from public.stock_receipts
      where app_private.can_work_at_branch(stock_receipts.godown_id)
        and (filter_branch is null or stock_receipts.godown_id = filter_branch)
        and stock_receipts.created_at >= window_from
        and stock_receipts.created_at < window_to
      group by 1
    ) bucket;
  end if;

  -- Damage reports created (event = created_at). Counting unit: report rows.
  if can_damage then
    select coalesce(count(*), 0)
    into damage_total
    from public.damage_reports
    where app_private.can_work_at_branch(damage_reports.godown_id)
      and (filter_branch is null or damage_reports.godown_id = filter_branch)
      and damage_reports.created_at >= window_from
      and damage_reports.created_at < window_to;

    select coalesce(jsonb_agg(
      jsonb_build_object('day', bucket.day, 'count', bucket.count)
      order by bucket.day
    ), '[]'::jsonb)
    into damage_series
    from (
      select
        (date_trunc('day', damage_reports.created_at at time zone 'UTC'))::date as day,
        count(*)::integer as count
      from public.damage_reports
      where app_private.can_work_at_branch(damage_reports.godown_id)
        and (filter_branch is null or damage_reports.godown_id = filter_branch)
        and damage_reports.created_at >= window_from
        and damage_reports.created_at < window_to
      group by 1
    ) bucket;
  end if;

  return jsonb_build_object(
    'timezone', 'UTC',
    'filter_branch', filter_branch,
    'window_from', window_from,
    'window_to', window_to,
    'scope_note', 'Period event counts only. On-hand, reserved, ATP, and open queues stay on get_operations_dashboard.',
    'orders_created', jsonb_build_object(
      'visible', app_private.report_can_view_orders(),
      'label', 'Orders created',
      'total', orders_total,
      'series', orders_series
    ),
    'picking_completed', jsonb_build_object(
      'visible', app_private.report_can_view_orders()
        and (
          app_private.has_permission('picking.allocate')
          or app_private.has_permission('picking.manage')
          or app_private.has_permission('picking.execute')
          or app_private.has_permission('operations.monitor')
        ),
      'label', 'Packing handoffs',
      'total', picking_total,
      'series', picking_series
    ),
    'dispatches_consumed', jsonb_build_object(
      'visible', app_private.report_can_view_dispatch(),
      'label', 'Dispatches confirmed',
      'total', dispatch_total,
      'series', dispatch_series
    ),
    'receipts_created', jsonb_build_object(
      'visible', app_private.report_can_view_operations(),
      'label', 'Receipts created',
      'total', receiving_total,
      'series', receiving_series
    ),
    'damage_reports_created', jsonb_build_object(
      'visible', can_damage,
      'label', 'Damage reports created',
      'total', damage_total,
      'series', damage_series
    )
  );
end;
$$;

revoke all on function public.get_operations_dashboard_period(uuid, timestamptz, timestamptz)
  from public, anon, service_role;
grant execute on function public.get_operations_dashboard_period(uuid, timestamptz, timestamptz)
  to authenticated;

comment on function public.get_operations_dashboard_period(uuid, timestamptz, timestamptz) is
  'UNAPPLIED until owner review. Read-only UTC half-open period event counts (max 93 days). Packing uses handed_off_at; dispatch uses dispatched_at. Does not return stock snapshots.';
