-- M5.4F read-only dashboard totals for posted ordinary/exceptional quantities.
-- Does not add stock writers, flip damage.stock_hold_ready, or mix posted
-- history into current unavailable (active/transferred) totals.

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
      ),
      -- Historical posted cartons. Never added into active_hold_cases.
      'ordinary_writeoff_cases', coalesce((
        select sum(damage_stock_holds.quantity_cases)::integer
        from public.damage_stock_holds
        where damage_stock_holds.damage_report_id = any (visible_ids)
          and damage_stock_holds.status = 'written_off'
          and exists (
            select 1
            from public.damage_report_events
            where damage_report_events.damage_report_id =
              damage_stock_holds.damage_report_id
              and damage_report_events.action = 'ordinary_writeoff'
          )
      ), 0),
      'exceptional_writeoff_cases', coalesce((
        select sum(damage_stock_holds.quantity_cases)::integer
        from public.damage_stock_holds
        where damage_stock_holds.damage_report_id = any (visible_ids)
          and damage_stock_holds.status = 'written_off'
          and exists (
            select 1
            from public.damage_report_events
            where damage_report_events.damage_report_id =
              damage_stock_holds.damage_report_id
              and damage_report_events.action = 'exceptional_posted'
          )
      ), 0),
      'returned_supplier_cases', coalesce((
        select sum(damage_stock_holds.quantity_cases)::integer
        from public.damage_stock_holds
        where damage_stock_holds.damage_report_id = any (visible_ids)
          and damage_stock_holds.status = 'returned_supplier'
      ), 0)
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
      'awaiting_custody', coalesce((
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
            and damage_reports.scenario = 'shop_return'
            and damage_reports.status in ('draft', 'returned')
            and damage_reports.physical_custody_confirmed_at is null
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

comment on function public.get_damage_dashboard(uuid) is
  'Authorized damage dashboard. Posted ordinary/exceptional/return-supplier carton totals are historical and excluded from current unavailable.';
