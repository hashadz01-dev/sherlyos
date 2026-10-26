-- M4.1 Inactive godown operational hardening (local-first, forward-only).
-- Does not change can_work_at_branch (Admin reporting still sees inactive stock).
-- Does not mutate historical ledger rows or auto-cancel in-flight documents.

-- ---------------------------------------------------------------------------
-- 1. Central operational-active guard
-- Lock the branch row so concurrent set_branch_active cannot sneak past a
-- snapshot is_active check. Called after existing document locks
-- (order / picking / dispatch) so it does not invert trusted writer order.
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_operational_active_branch(target_branch uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  locked public.branches%rowtype;
begin
  if target_branch is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into locked
  from public.branches
  where branches.id = target_branch
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if not app_private.can_work_at_branch(target_branch) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if not locked.is_active then
    raise exception 'godown is inactive' using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.assert_operational_active_branch(uuid)
  from public, anon, authenticated, service_role;

comment on function app_private.assert_operational_active_branch(uuid) is
  'M4.1. Authorize the caller at the godown and require branches.is_active. Locks the branch row. Does not replace can_work_at_branch for reporting.';

-- ---------------------------------------------------------------------------
-- 2. Location lock: freeze branch status after zone/crate locks
-- Opening, transfer, receiving, verification, adjustment post, and
-- confirm_dispatch already fail closed on inactive crates via this helper.
-- ---------------------------------------------------------------------------

create or replace function app_private.prepare_stock_locations(crate_ids uuid[])
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_branch uuid;
  found_count integer;
  branch_count integer;
  inactive_count integer;
begin
  if crate_ids is null or cardinality(crate_ids) < 1 then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  -- H1 fix: cutover shared lock before any zone/crate FOR UPDATE.
  perform app_private.acquire_stock_cutover_shared_lock();

  perform zones.id
  from public.zones
  where zones.id in (
    select crates.zone_id
    from public.crates
    where crates.id = any (crate_ids)
  )
  order by zones.id
  for update;

  perform crates.id
  from public.crates
  where crates.id = any (crate_ids)
  order by crates.id
  for update;

  -- After crates, lock owning godowns so deactivation cannot commit mid-post.
  perform branches.id
  from public.branches
  where branches.id in (
    select zones.branch_id
    from public.crates
    join public.zones on zones.id = crates.zone_id
    where crates.id = any (crate_ids)
  )
  order by branches.id
  for update;

  select
    count(*),
    count(distinct zones.branch_id),
    count(*) filter (
      where not crates.is_active
        or not zones.is_active
        or not branches.is_active
    )
  into found_count, branch_count, inactive_count
  from public.crates
  join public.zones on zones.id = crates.zone_id
  join public.branches on branches.id = zones.branch_id
  where crates.id = any (crate_ids);

  if found_count is distinct from cardinality(crate_ids) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.crates
    join public.zones on zones.id = crates.zone_id
    where crates.id = any (crate_ids)
      and not app_private.can_work_at_branch(zones.branch_id)
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if branch_count <> 1 then
    raise exception 'crates must belong to the same godown' using errcode = '23514';
  end if;

  if inactive_count > 0 then
    raise exception 'location is inactive' using errcode = '23514';
  end if;

  select zones.branch_id
  into selected_branch
  from public.crates
  join public.zones on zones.id = crates.zone_id
  where crates.id = crate_ids[1];

  return selected_branch;
end;
$$;

revoke all on function app_private.prepare_stock_locations(uuid[])
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. New orders already checked is_active; lock the row too.
-- Keep the historical 42501 "godown is not authorized" contract.
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_order_branch(target_branch uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if target_branch is null then
    raise exception 'godown is not authorized' using errcode = '42501';
  end if;

  begin
    perform app_private.assert_operational_active_branch(target_branch);
  exception
    when sqlstate '42501' then
      raise exception 'godown is not authorized' using errcode = '42501';
    when sqlstate '23514' then
      raise exception 'godown is not authorized' using errcode = '42501';
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Picking: new allocation and warehouse progression. Cancel stays on
-- assert_picking_manager (authorization only) so reservations can be released.
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_picking_allocator(target_branch uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('picking.allocate');
  perform app_private.assert_operational_active_branch(target_branch);
end;
$$;

revoke all on function app_private.assert_picking_allocator(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_picking_executor(
  header public.stock_picking_requests
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_operational_active_branch(header.branch_id);
  if app_private.has_permission('picking.manage')
    or app_private.has_permission('picking.allocate')
  then
    return;
  end if;
  if app_private.has_permission('picking.execute')
    and header.assigned_to is not distinct from auth.uid()
  then
    return;
  end if;
  raise exception 'not authorized' using errcode = '42501';
end;
$$;

revoke all on function app_private.assert_picking_executor(public.stock_picking_requests)
  from public, anon, authenticated, service_role;

create or replace function public.assign_picking_request(
  target_request uuid,
  assignee uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  header public.stock_picking_requests;
  replay uuid;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_picking_event(cleaned_key, 'assigned', target_request);
  if replay is not null then
    return app_private.picking_payload(replay);
  end if;

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.picking_write', 'on', true);
  header := app_private.lock_picking_request(target_request, expected_version);
  perform app_private.assert_picking_manager(header.branch_id);
  perform app_private.assert_operational_active_branch(header.branch_id);

  if header.status not in ('allocated', 'picking') then
    raise exception 'picking cannot be assigned from %', header.status
      using errcode = '23514';
  end if;

  if not exists (
    select 1
    from public.user_roles
    join public.role_permissions on role_permissions.role_id = user_roles.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where user_roles.user_id = assignee
      and permissions.code = 'picking.execute'
  ) then
    raise exception 'assignee cannot execute picking' using errcode = '23514';
  end if;

  if not exists (
    select 1 from public.profiles
    where profiles.id = assignee and profiles.is_active
  ) then
    raise exception 'assignee is not active' using errcode = '23514';
  end if;

  update public.stock_picking_requests
  set assigned_to = assignee, version = header.version + 1
  where id = header.id;

  perform app_private.picking_event(
    header.id, 'assigned', header.status, header.status, header.version + 1,
    pg_catalog.jsonb_build_object('assigned_to', assignee), cleaned_key
  );

  return app_private.picking_payload(header.id);
end;
$$;

-- Handoff uses manager, not executor. Keep cancel on manager-only auth.
create or replace function public.confirm_picking_handoff(
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
  cleaned_key text;
  header public.stock_picking_requests;
  replay uuid;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_picking_event(cleaned_key, 'handed_off', target_request);
  if replay is not null then
    return app_private.picking_payload(replay);
  end if;

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.picking_write', 'on', true);
  header := app_private.lock_picking_request(target_request, expected_version);
  perform app_private.assert_picking_manager(header.branch_id);
  perform app_private.assert_operational_active_branch(header.branch_id);

  if header.status is distinct from 'picked' then
    raise exception 'handoff requires completed picking' using errcode = '23514';
  end if;

  update public.stock_picking_requests
  set
    status = 'ready_for_dispatch',
    handed_off_by = auth.uid(),
    handed_off_at = pg_catalog.clock_timestamp(),
    version = header.version + 1
  where id = header.id;

  perform app_private.picking_event(
    header.id, 'handed_off', 'picked', 'ready_for_dispatch', header.version + 1,
    '{}'::jsonb, cleaned_key
  );
  perform app_private.write_audit(
    auth.uid(),
    'confirm_picking_handoff',
    'stock_picking_requests',
    header.id,
    pg_catalog.jsonb_build_object('status', 'ready_for_dispatch')
  );

  return app_private.picking_payload(header.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. New dispatch preparation. confirm_dispatch still consumes only after
-- prepare_stock_locations, which now locks the inactive branch. Replay of an
-- already-consumed dispatch must not take this guard (confirmer stays auth-only).
-- ---------------------------------------------------------------------------

create or replace function public.prepare_dispatch(
  target_order uuid,
  expected_picking_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  selected public.orders%rowtype;
  picking public.stock_picking_requests%rowtype;
  existing public.stock_dispatch_requests%rowtype;
  created uuid;
  request_number text;
  fingerprint text;
  note_id uuid;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select * into existing
  from public.stock_dispatch_requests
  where stock_dispatch_requests.idempotency_key = cleaned_key;
  if found then
    if existing.order_id is distinct from target_order then
      raise exception 'idempotency key was already used for a different request'
        using errcode = '23505';
    end if;
    return app_private.dispatch_payload(existing.id);
  end if;

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.dispatch_write', 'on', true);

  select * into selected
  from public.orders
  where orders.id = target_order
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_dispatch_confirmer(selected.branch_id);
  perform app_private.assert_operational_active_branch(selected.branch_id);

  select * into picking
  from public.stock_picking_requests
  where stock_picking_requests.order_id = selected.id
    and stock_picking_requests.status is distinct from 'cancelled'
  for update;

  if not found then
    raise exception 'dispatch requires a ready_for_dispatch picking handoff'
      using errcode = '23514';
  end if;

  if picking.version is distinct from expected_picking_version then
    raise exception 'picking was changed by someone else' using errcode = 'PT409';
  end if;

  perform app_private.assert_dispatch_handoff_ready(selected, picking);

  fingerprint := app_private.dispatch_reservation_fingerprint(picking.id);

  select delivery_notes.id
  into note_id
  from public.delivery_notes
  where delivery_notes.order_id = selected.id
    and delivery_notes.status is distinct from 'voided'
  order by delivery_notes.created_at desc
  limit 1;

  request_number := 'DS-'
    || to_char(pg_catalog.clock_timestamp() at time zone 'UTC', 'YYYYMMDD')
    || '-'
    || pg_catalog.lpad(
      pg_catalog.nextval('public.stock_dispatch_request_seq')::text, 6, '0'
    );

  insert into public.stock_dispatch_requests (
    request_number, order_id, picking_request_id, delivery_note_id, branch_id,
    status, created_by, idempotency_key, request_fingerprint
  )
  values (
    request_number, selected.id, picking.id, note_id, selected.branch_id,
    'preparing', auth.uid(), cleaned_key, fingerprint
  )
  returning id into created;

  perform app_private.dispatch_event(
    created, 'prepared', null, 'preparing', 1,
    pg_catalog.jsonb_build_object(
      'picking_request_id', picking.id,
      'delivery_note_id', note_id,
      'fingerprint', fingerprint
    ),
    cleaned_key
  );

  perform app_private.write_audit(
    auth.uid(), 'prepare_dispatch', 'stock_dispatch_requests', created,
    pg_catalog.jsonb_build_object(
      'request_number', request_number,
      'order_id', selected.id,
      'picking_request_id', picking.id
    )
  );

  return app_private.dispatch_payload(created);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. New stock-adjustment drafts. Posting is additionally blocked by
-- prepare_stock_locations. Reject/return remain unwind paths.
-- ---------------------------------------------------------------------------

create or replace function public.create_stock_adjustment(
  target_verification uuid,
  reason_code text,
  request_note text,
  line_ids uuid[],
  idempotency_key text,
  compensates_request uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_verifications;
  cleaned_key text;
  cleaned_note text;
  cleaned_reason text;
  request_id uuid;
  request_number text;
  existing public.stock_adjustment_requests;
begin
  perform set_config('app.adjustment_write', 'on', true);
  perform app_private.assert_permission('stock.adjustment.request');
  if compensates_request is not null then
    raise exception 'compensation is not available' using errcode = '23514';
  end if;
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_note := app_private.clean_verification_text(request_note, true);
  cleaned_reason := pg_catalog.lower(pg_catalog.btrim(coalesce(reason_code, '')));

  if cleaned_reason not in ('shortage', 'surplus', 'mixed') then
    raise exception 'adjustment reason is invalid' using errcode = '23514';
  end if;

  select *
  into existing
  from public.stock_adjustment_requests
  where stock_adjustment_requests.idempotency_key = cleaned_key;

  if found then
    if not app_private.can_view_stock_adjustment(existing.godown_id) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    return pg_catalog.jsonb_build_object('id', existing.id, 'request_number', existing.request_number);
  end if;

  select *
  into header
  from public.stock_verifications
  where stock_verifications.id = target_verification
  for update;

  if not found or header.status <> 'closed' then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_operational_active_branch(header.godown_id);

  request_number := 'AJ-' || to_char(pg_catalog.clock_timestamp() at time zone 'utc', 'YYYYMMDD')
    || '-' || pg_catalog.lpad(pg_catalog.nextval('public.stock_adjustment_seq')::text, 6, '0');

  insert into public.stock_adjustment_requests (
    request_number, godown_id, verification_id, evidence_id, compensates_request_id,
    status, reason_code, note, requested_by, idempotency_key
  )
  select
    request_number,
    header.godown_id,
    header.id,
    stock_verification_evidence.id,
    compensates_request,
    'draft',
    cleaned_reason,
    cleaned_note,
    auth.uid(),
    cleaned_key
  from public.stock_verification_evidence
  where stock_verification_evidence.verification_id = header.id
    and stock_verification_evidence.verified_at is not null
  order by stock_verification_evidence.verified_at, stock_verification_evidence.id
  limit 1
  returning id into request_id;

  if request_id is null then
    raise exception 'photo evidence is required' using errcode = '23514';
  end if;

  perform app_private.replace_adjustment_lines(
    (select stock_adjustment_requests from public.stock_adjustment_requests where id = request_id),
    line_ids
  );
  perform app_private.adjustment_event(request_id, 'created', null, 'draft', 1, cleaned_note);

  return pg_catalog.jsonb_build_object('id', request_id, 'request_number', request_number);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Post-consume delivery at an inactive godown
-- Stock has already left. Assignment / start / POD / exception stay on the
-- existing M3 state machine and do not call the operational-active guard.
-- Assigned drivers still need a branch assignment, but not branches.is_active.
-- ---------------------------------------------------------------------------

create or replace function app_private.can_complete_consumed_delivery_at_branch(target_branch uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    app_private.has_permission('branches.access_all')
    or exists (
      select 1
      from public.user_branch_assignments
      where user_branch_assignments.user_id = auth.uid()
        and user_branch_assignments.branch_id = target_branch
    );
$$;

revoke all on function app_private.can_complete_consumed_delivery_at_branch(uuid)
  from public, anon, authenticated, service_role;

comment on function app_private.can_complete_consumed_delivery_at_branch(uuid) is
  'M4.1. Branch assignment or access_all without requiring is_active. Used only for consumed-dispatch delivery completion.';

create or replace function app_private.dispatch_can_view(
  header public.stock_dispatch_requests
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if header.id is null then
    return false;
  end if;
  -- Active godowns keep the existing can_work rule. Consumed rows at an
  -- inactive godown remain visible to assigned delivery actors.
  if not (
    app_private.can_work_at_branch(header.branch_id)
    or (
      header.stock_consumed
      and app_private.can_complete_consumed_delivery_at_branch(header.branch_id)
    )
  ) then
    return false;
  end if;
  if app_private.has_permission('dispatch.view')
    or app_private.has_permission('dispatch.confirm')
    or app_private.has_permission('dispatch.exception')
    or app_private.has_permission('dispatch.history')
    or app_private.has_permission('deliveries.assign')
    or app_private.has_permission('operations.monitor')
  then
    return true;
  end if;
  return app_private.has_permission('deliveries.execute')
    and header.assigned_to is not distinct from auth.uid();
end;
$$;

create or replace function app_private.assert_dispatch_assigner(target_branch uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('deliveries.assign');
  if not app_private.can_complete_consumed_delivery_at_branch(target_branch) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_dispatch_assigner(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_dispatch_executor(
  header public.stock_dispatch_requests
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app_private.can_complete_consumed_delivery_at_branch(header.branch_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  if app_private.has_permission('deliveries.execute')
    and header.assigned_to is not distinct from auth.uid()
  then
    return;
  end if;
  raise exception 'not authorized' using errcode = '42501';
end;
$$;

revoke all on function app_private.assert_dispatch_executor(public.stock_dispatch_requests)
  from public, anon, authenticated, service_role;

create or replace function public.report_dispatch_delivery_exception(
  target_dispatch uuid,
  exception_reason text,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  cleaned_reason text;
  header public.stock_dispatch_requests;
  replay uuid;
  can_report boolean := false;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_dispatch_event(cleaned_key, 'exception_recorded', target_dispatch);
  if replay is not null then
    return app_private.dispatch_payload(replay);
  end if;

  perform set_config('app.dispatch_write', 'on', true);

  select * into header
  from public.stock_dispatch_requests
  where id = target_dispatch
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if app_private.has_permission('dispatch.exception')
    and app_private.can_complete_consumed_delivery_at_branch(header.branch_id)
  then
    can_report := true;
  end if;
  if app_private.has_permission('deliveries.execute')
    and header.assigned_to is not distinct from auth.uid()
    and app_private.can_complete_consumed_delivery_at_branch(header.branch_id)
  then
    can_report := true;
  end if;
  if not can_report then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if header.version is distinct from expected_version then
    raise exception 'dispatch was changed by someone else' using errcode = 'PT409';
  end if;

  if header.status = 'exception' then
    return app_private.dispatch_payload(header.id);
  end if;

  if header.stock_consumed is distinct from true
    or header.status not in ('dispatched', 'in_transit')
  then
    raise exception 'a delivery exception requires dispatched stock'
      using errcode = '23514';
  end if;

  cleaned_reason := btrim(coalesce(exception_reason, ''));
  if char_length(cleaned_reason) not between 1 and 500 then
    raise exception 'exception reason is required' using errcode = '23514';
  end if;

  update public.stock_dispatch_requests
  set
    status = 'exception',
    exception_reason = cleaned_reason,
    exception_at = pg_catalog.clock_timestamp(),
    physical_return_status = 'pending_verification',
    version = header.version + 1
  where id = header.id;

  perform app_private.dispatch_event(
    header.id, 'exception_recorded', header.status, 'exception', header.version + 1,
    pg_catalog.jsonb_build_object(
      'reason', cleaned_reason,
      'physical_return_status', 'pending_verification',
      'stock_restored', false
    ),
    cleaned_key
  );

  perform app_private.write_audit(
    auth.uid(), 'report_dispatch_delivery_exception', 'stock_dispatch_requests', header.id,
    pg_catalog.jsonb_build_object(
      'reason', cleaned_reason,
      'physical_return_status', 'pending_verification'
    )
  );

  return app_private.dispatch_payload(header.id);
end;
$$;
