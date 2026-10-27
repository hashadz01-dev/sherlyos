-- M7.4A. Vehicle master, assignment, POD metadata, and non-posting delivery exceptions.
-- Reuses the M3 dispatch/delivery engine. Does not write stock. Does not restock.
-- Does not change confirm_dispatch or verify_stock_receipt posting semantics.
-- Physical return-to-stock is M7.4B.

-- ---------------------------------------------------------------------------
-- 1. Permissions. Admin and GM maintain vehicles. Drivers never write the master.
-- ---------------------------------------------------------------------------
insert into public.permissions (code, description)
values
  (
    'vehicles.view',
    'View the vehicle master for authorized godowns. Historical inactive rows remain readable.'
  ),
  (
    'vehicles.manage',
    'Create, edit, or deactivate vehicles. Does not assign a delivery or consume stock.'
  )
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from (
  values
    ('admin', 'vehicles.view'),
    ('admin', 'vehicles.manage'),
    ('godown_manager', 'vehicles.view'),
    ('godown_manager', 'vehicles.manage')
) as grants (role_code, permission_code)
join public.roles on roles.code = grants.role_code
join public.permissions on permissions.code = grants.permission_code
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. Vehicle master
-- ---------------------------------------------------------------------------
create table public.vehicles (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches (id) on delete restrict,
  registration_number text not null,
  registration_normalized text not null,
  vehicle_type text not null,
  display_name text not null,
  capacity_cases integer,
  notes text,
  is_active boolean not null default true,
  created_by uuid not null references public.profiles (id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_by uuid references public.profiles (id) on delete restrict,
  updated_at timestamptz not null default pg_catalog.now(),
  deactivated_at timestamptz,
  deactivated_by uuid references public.profiles (id) on delete restrict,
  constraint vehicles_type_check check (
    vehicle_type in ('truck', 'van', 'two_wheeler', 'other')
  ),
  constraint vehicles_registration_length check (
    char_length(btrim(registration_number)) between 4 and 32
    and registration_number = btrim(registration_number)
  ),
  constraint vehicles_registration_normalized_shape check (
    char_length(registration_normalized) between 4 and 20
    and registration_normalized = lower(registration_normalized)
  ),
  constraint vehicles_capacity_check check (
    capacity_cases is null or capacity_cases >= 1
  ),
  constraint vehicles_notes_length check (
    notes is null
    or (
      char_length(btrim(notes)) between 1 and 500
      and notes = btrim(notes)
    )
  ),
  constraint vehicles_inactive_shape check (
    (is_active = true and deactivated_at is null and deactivated_by is null)
    or (is_active = false and deactivated_at is not null and deactivated_by is not null)
  )
);

comment on table public.vehicles is
  'M7.4A vehicle master. Capacity is informational. Inactive rows stay for historical deliveries. Hard delete is refused.';

-- One active identity globally. Inactive plates may be reused; reactivation races fail closed.
create unique index vehicles_active_registration_uidx
  on public.vehicles (registration_normalized)
  where is_active;

create index vehicles_branch_active_idx
  on public.vehicles (branch_id, is_active, display_name);

create trigger vehicles_set_updated_at
  before update on public.vehicles
  for each row execute function app_private.set_updated_at();

create or replace function app_private.guard_vehicle_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'vehicles cannot be deleted' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function app_private.guard_vehicle_mutation()
  from public, anon, authenticated, service_role;

create trigger vehicles_guard
  before delete on public.vehicles
  for each row execute function app_private.guard_vehicle_mutation();

alter table public.vehicles enable row level security;
alter table public.vehicles force row level security;

create policy vehicles_select_readers
  on public.vehicles
  for select
  to authenticated
  using (
    (select app_private.has_permission('vehicles.view'))
    and (select app_private.can_work_at_branch(vehicles.branch_id))
  );

revoke all on table public.vehicles from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate on table public.vehicles from service_role;
grant select on table public.vehicles to authenticated;

create or replace function app_private.normalize_vehicle_registration(raw_value text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  cleaned text;
begin
  cleaned := lower(regexp_replace(btrim(coalesce(raw_value, '')), '[^A-Za-z0-9]', '', 'g'));
  if char_length(cleaned) < 4 or char_length(cleaned) > 20 then
    raise exception 'registration number is invalid' using errcode = '23514';
  end if;
  return cleaned;
end;
$$;

revoke all on function app_private.normalize_vehicle_registration(text)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_vehicle_manager(target_branch uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('vehicles.manage');
  if not app_private.can_work_at_branch(target_branch) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_vehicle_manager(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.clean_vehicle_type(raw_value text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  cleaned text := lower(btrim(coalesce(raw_value, '')));
begin
  if cleaned not in ('truck', 'van', 'two_wheeler', 'other') then
    raise exception 'vehicle type is invalid' using errcode = '23514';
  end if;
  return cleaned;
end;
$$;

revoke all on function app_private.clean_vehicle_type(text)
  from public, anon, authenticated, service_role;

create or replace function public.create_vehicle(
  target_branch uuid,
  registration_number text,
  vehicle_type text,
  display_name text,
  capacity_cases integer,
  operational_notes text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
  cleaned_registration text := btrim(coalesce(registration_number, ''));
  normalized text;
begin
  perform app_private.assert_vehicle_manager(target_branch);
  if not exists (
    select 1 from public.branches
    where branches.id = target_branch and branches.is_active
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  normalized := app_private.normalize_vehicle_registration(cleaned_registration);

  insert into public.vehicles (
    branch_id, registration_number, registration_normalized, vehicle_type,
    display_name, capacity_cases, notes, created_by, updated_by
  )
  values (
    target_branch,
    cleaned_registration,
    normalized,
    app_private.clean_vehicle_type(vehicle_type),
    app_private.clean_required_name(display_name),
    capacity_cases,
    app_private.clean_optional_text(operational_notes, 500),
    auth.uid(),
    auth.uid()
  )
  returning id into created_id;

  perform app_private.write_audit(
    auth.uid(), 'create_vehicle', 'vehicles', created_id,
    pg_catalog.jsonb_build_object(
      'branch_id', target_branch,
      'registration_normalized', normalized
    )
  );

  return created_id;
exception
  when unique_violation then
    raise exception 'an active vehicle with this registration already exists'
      using errcode = '23505';
end;
$$;

create or replace function public.update_vehicle(
  target_vehicle uuid,
  registration_number text,
  vehicle_type text,
  display_name text,
  capacity_cases integer,
  operational_notes text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.vehicles%rowtype;
  cleaned_registration text := btrim(coalesce(registration_number, ''));
  normalized text;
begin
  select * into selected from public.vehicles where vehicles.id = target_vehicle;
  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_vehicle_manager(selected.branch_id);
  normalized := app_private.normalize_vehicle_registration(cleaned_registration);

  update public.vehicles
  set
    registration_number = cleaned_registration,
    registration_normalized = normalized,
    vehicle_type = app_private.clean_vehicle_type(vehicle_type),
    display_name = app_private.clean_required_name(display_name),
    capacity_cases = capacity_cases,
    notes = app_private.clean_optional_text(operational_notes, 500),
    updated_by = auth.uid()
  where vehicles.id = target_vehicle;

  perform app_private.write_audit(
    auth.uid(), 'update_vehicle', 'vehicles', target_vehicle,
    pg_catalog.jsonb_build_object('registration_normalized', normalized)
  );
exception
  when unique_violation then
    raise exception 'an active vehicle with this registration already exists'
      using errcode = '23505';
end;
$$;

create or replace function public.set_vehicle_active(
  target_vehicle uuid,
  active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.vehicles%rowtype;
begin
  select * into selected
  from public.vehicles
  where vehicles.id = target_vehicle
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_vehicle_manager(selected.branch_id);

  if active is not distinct from selected.is_active then
    return;
  end if;

  if active is distinct from true then
    if exists (
      select 1
      from public.stock_dispatch_requests
      where stock_dispatch_requests.vehicle_id = selected.id
        and stock_dispatch_requests.status in ('dispatched', 'in_transit')
    ) then
      raise exception 'vehicle is assigned to an active delivery'
        using errcode = '23514';
    end if;

    update public.vehicles
    set
      is_active = false,
      deactivated_at = pg_catalog.clock_timestamp(),
      deactivated_by = auth.uid(),
      updated_by = auth.uid()
    where vehicles.id = selected.id;
  else
    update public.vehicles
    set
      is_active = true,
      deactivated_at = null,
      deactivated_by = null,
      updated_by = auth.uid()
    where vehicles.id = selected.id;
  end if;

  perform app_private.write_audit(
    auth.uid(), 'set_vehicle_active', 'vehicles', selected.id,
    pg_catalog.jsonb_build_object('is_active', active)
  );
exception
  when unique_violation then
    raise exception 'an active vehicle with this registration already exists'
      using errcode = '23505';
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Dispatch assignment, POD metadata, non-posting outcome lines
-- ---------------------------------------------------------------------------
alter table public.stock_dispatch_requests
  add column vehicle_id uuid references public.vehicles (id) on delete restrict,
  add column delivery_outcome text,
  add column proof_reference text,
  add column return_required boolean not null default false,
  add column attempted_at timestamptz;

alter table public.stock_dispatch_requests
  add constraint stock_dispatch_requests_outcome_check check (
    delivery_outcome is null
    or delivery_outcome in ('delivered', 'failed', 'partial')
  );

alter table public.stock_dispatch_requests
  add constraint stock_dispatch_requests_proof_length check (
    proof_reference is null
    or (
      char_length(btrim(proof_reference)) between 1 and 200
      and     proof_reference = btrim(proof_reference)
    )
  );

-- Backfill new outcome columns. Guard requires app.dispatch_write.
do $$
begin
  perform set_config('app.dispatch_write', 'on', true);

  update public.stock_dispatch_requests
  set delivery_outcome = 'delivered'
  where status = 'delivered'
    and delivery_outcome is null;

  update public.stock_dispatch_requests
  set
    delivery_outcome = 'failed',
    return_required = true
  where status = 'exception'
    and delivery_outcome is null;
end;
$$;

alter table public.stock_dispatch_requests
  add constraint stock_dispatch_requests_outcome_shape check (
    (
      status = 'delivered'
      and delivery_outcome in ('delivered')
    )
    or (
      status = 'exception'
      and delivery_outcome in ('failed', 'partial')
      and return_required = true
    )
    or (
      status not in ('delivered', 'exception')
      and delivery_outcome is null
    )
  );

-- One vehicle on at most one live run. Historical delivered/exception rows stay readable.
create unique index stock_dispatch_requests_active_vehicle_uidx
  on public.stock_dispatch_requests (vehicle_id)
  where vehicle_id is not null
    and status in ('dispatched', 'in_transit');

alter table public.stock_dispatch_assignments
  add column vehicle_id uuid references public.vehicles (id) on delete restrict;

alter table public.stock_dispatch_events
  drop constraint stock_dispatch_events_type_check;

alter table public.stock_dispatch_events
  add constraint stock_dispatch_events_type_check check (
    event_type in (
      'prepared',
      'cancelled',
      'dispatched',
      'assigned',
      'in_transit',
      'delivered',
      'exception_recorded',
      'partial_recorded'
    )
  );

create table public.stock_dispatch_outcome_lines (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid not null
    references public.stock_dispatch_requests (id) on delete restrict,
  order_line_id uuid not null
    references public.order_lines (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  dispatched_cases integer not null,
  delivered_cases integer not null,
  undelivered_cases integer not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_dispatch_outcome_lines_qty_check check (
    dispatched_cases >= 0
    and delivered_cases >= 0
    and undelivered_cases >= 0
    and delivered_cases + undelivered_cases = dispatched_cases
    and delivered_cases <= dispatched_cases
  ),
  constraint stock_dispatch_outcome_lines_dispatch_line_key unique (dispatch_id, order_line_id)
);

comment on table public.stock_dispatch_outcome_lines is
  'M7.4A non-posting delivery outcome per order line. Does not restore stock. Undelivered cases stay deducted until M7.4B.';

create table public.stock_dispatch_delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid not null
    references public.stock_dispatch_requests (id) on delete restrict,
  attempt_number integer not null,
  outcome text not null,
  actor_id uuid not null references public.profiles (id) on delete restrict,
  attempted_at timestamptz not null default pg_catalog.clock_timestamp(),
  reason text,
  payload jsonb not null default '{}'::jsonb,
  constraint stock_dispatch_delivery_attempts_number_check check (attempt_number >= 1),
  constraint stock_dispatch_delivery_attempts_outcome_check check (
    outcome in ('in_transit', 'delivered', 'failed', 'partial')
  ),
  constraint stock_dispatch_delivery_attempts_dispatch_number_key unique (dispatch_id, attempt_number)
);

comment on table public.stock_dispatch_delivery_attempts is
  'M7.4A append-only delivery attempt history. Start, POD, fail, and partial each insert one row.';

create index stock_dispatch_outcome_lines_dispatch_idx
  on public.stock_dispatch_outcome_lines (dispatch_id);

create index stock_dispatch_delivery_attempts_dispatch_idx
  on public.stock_dispatch_delivery_attempts (dispatch_id, attempt_number);

create or replace function app_private.guard_dispatch_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if pg_catalog.current_setting('app.dispatch_write', true) is distinct from 'on' then
    raise exception 'dispatch records cannot be changed directly'
      using errcode = '42501';
  end if;

  if tg_table_name in (
    'stock_dispatch_events',
    'stock_dispatch_outcome_lines',
    'stock_dispatch_delivery_attempts'
  ) and tg_op <> 'INSERT' then
    raise exception 'dispatch history cannot be changed' using errcode = '42501';
  end if;

  if tg_op = 'DELETE' then
    raise exception 'dispatch records cannot be deleted' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and tg_table_name = 'stock_dispatch_requests' then
    if old.stock_consumed and new.stock_consumed is distinct from true then
      raise exception 'dispatched stock consumption cannot be reversed'
        using errcode = '23514';
    end if;
    if old.posted_transaction_id is not null
      and new.posted_transaction_id is distinct from old.posted_transaction_id
    then
      raise exception 'dispatch stock transaction cannot be replaced'
        using errcode = '23514';
    end if;
    if old.status = 'cancelled' and new.status is distinct from 'cancelled' then
      raise exception 'cancelled dispatch cannot consume stock'
        using errcode = '23514';
    end if;
    if old.status in ('dispatched', 'in_transit', 'delivered', 'exception')
      and new.status in ('preparing', 'cancelled')
    then
      raise exception 'dispatched documents cannot revert to a pre-dispatch state'
        using errcode = '23514';
    end if;
    if old.status = 'delivered' and new.status is distinct from 'delivered' then
      raise exception 'delivered dispatch cannot change status'
        using errcode = '23514';
    end if;
    if old.status = 'exception' and new.status is distinct from 'exception' then
      raise exception 'delivery exception cannot change status'
        using errcode = '23514';
    end if;
  end if;

  if tg_op = 'UPDATE' and tg_table_name = 'stock_dispatch_assignments' then
    if old.assignee is distinct from new.assignee
      or old.assigned_by is distinct from new.assigned_by
      or old.assigned_at is distinct from new.assigned_at
      or old.vehicle_id is distinct from new.vehicle_id
    then
      raise exception 'assignment history cannot be rewritten' using errcode = '42501';
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

create trigger stock_dispatch_outcome_lines_guard
  before insert or update or delete on public.stock_dispatch_outcome_lines
  for each row execute function app_private.guard_dispatch_write();

create trigger stock_dispatch_delivery_attempts_guard
  before insert or update or delete on public.stock_dispatch_delivery_attempts
  for each row execute function app_private.guard_dispatch_write();

alter table public.stock_dispatch_outcome_lines enable row level security;
alter table public.stock_dispatch_outcome_lines force row level security;
alter table public.stock_dispatch_delivery_attempts enable row level security;
alter table public.stock_dispatch_delivery_attempts force row level security;

create policy stock_dispatch_outcome_lines_select
  on public.stock_dispatch_outcome_lines
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.stock_dispatch_requests header
      where header.id = stock_dispatch_outcome_lines.dispatch_id
        and (select app_private.dispatch_can_view(header))
    )
  );

create policy stock_dispatch_delivery_attempts_select
  on public.stock_dispatch_delivery_attempts
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.stock_dispatch_requests header
      where header.id = stock_dispatch_delivery_attempts.dispatch_id
        and (select app_private.dispatch_can_view(header))
    )
  );

revoke all on table public.stock_dispatch_outcome_lines
  from public, anon, authenticated, service_role;
revoke all on table public.stock_dispatch_delivery_attempts
  from public, anon, authenticated, service_role;
grant select on table public.stock_dispatch_outcome_lines to authenticated;
grant select on table public.stock_dispatch_delivery_attempts to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Delivery quantity helpers (read dispatched qty; never write stock)
-- ---------------------------------------------------------------------------
create or replace function app_private.dispatch_line_quantities(
  header public.stock_dispatch_requests
)
returns table (
  order_line_id uuid,
  product_id uuid,
  dispatched_cases integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  shipment public.order_shipments%rowtype;
begin
  shipment := app_private.open_shipment_for_picking(header.picking_request_id);

  if shipment.id is not null then
    return query
    select
      order_shipment_lines.order_line_id,
      order_shipment_lines.product_id,
      order_shipment_lines.approved_cases
    from public.order_shipment_lines
    where order_shipment_lines.shipment_id = shipment.id
      and order_shipment_lines.approved_cases > 0;
    return;
  end if;

  return query
  select
    stock_reservations.order_line_id,
    stock_reservations.product_id,
    sum(stock_reservations.reserved_cases)::integer
  from public.stock_reservations
  where stock_reservations.picking_request_id = header.picking_request_id
    and stock_reservations.status in ('active', 'consumed')
  group by stock_reservations.order_line_id, stock_reservations.product_id;
end;
$$;

revoke all on function app_private.dispatch_line_quantities(public.stock_dispatch_requests)
  from public, anon, authenticated, service_role;

create or replace function app_private.write_dispatch_outcome_lines(
  header public.stock_dispatch_requests,
  outcome_mode text,
  delivered_by_line jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  line record;
  delivered integer;
  total_dispatched integer := 0;
  total_delivered integer := 0;
begin
  if exists (
    select 1
    from public.stock_dispatch_outcome_lines
    where stock_dispatch_outcome_lines.dispatch_id = header.id
  ) then
    raise exception 'delivery outcome is already recorded' using errcode = '23514';
  end if;

  for line in
    select * from app_private.dispatch_line_quantities(header)
  loop
    total_dispatched := total_dispatched + line.dispatched_cases;
    if outcome_mode = 'delivered' then
      delivered := line.dispatched_cases;
    elsif outcome_mode = 'failed' then
      delivered := 0;
    else
      if delivered_by_line is null
        or not (delivered_by_line ? line.order_line_id::text)
      then
        raise exception 'partial delivery requires a quantity for every dispatched line'
          using errcode = '23514';
      end if;
      begin
        delivered := (delivered_by_line ->> line.order_line_id::text)::integer;
      exception
        when invalid_text_representation then
          raise exception 'delivered quantity is invalid' using errcode = '23514';
      end;
    end if;

    if delivered is null or delivered < 0 or delivered > line.dispatched_cases then
      raise exception 'delivered quantity cannot exceed dispatched quantity'
        using errcode = '23514';
    end if;

    total_delivered := total_delivered + delivered;

    insert into public.stock_dispatch_outcome_lines (
      dispatch_id, order_line_id, product_id,
      dispatched_cases, delivered_cases, undelivered_cases
    )
    values (
      header.id, line.order_line_id, line.product_id,
      line.dispatched_cases, delivered, line.dispatched_cases - delivered
    );
  end loop;

  if total_dispatched < 1 then
    raise exception 'dispatch has no delivered quantity grain' using errcode = '23514';
  end if;

  if outcome_mode = 'partial'
    and (total_delivered < 1 or total_delivered >= total_dispatched)
  then
    raise exception 'partial delivery requires some but not all cases to be delivered'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.write_dispatch_outcome_lines(public.stock_dispatch_requests, text, jsonb)
  from public, anon, authenticated, service_role;

create or replace function app_private.record_delivery_attempt(
  header public.stock_dispatch_requests,
  attempt_outcome text,
  attempt_reason text,
  attempt_payload jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.stock_dispatch_delivery_attempts (
    dispatch_id, attempt_number, outcome, actor_id, reason, payload
  )
  values (
    header.id,
    coalesce((
      select max(stock_dispatch_delivery_attempts.attempt_number)
      from public.stock_dispatch_delivery_attempts
      where stock_dispatch_delivery_attempts.dispatch_id = header.id
    ), 0) + 1,
    attempt_outcome,
    auth.uid(),
    nullif(btrim(coalesce(attempt_reason, '')), ''),
    coalesce(attempt_payload, '{}'::jsonb)
  );
end;
$$;

revoke all on function app_private.record_delivery_attempt(public.stock_dispatch_requests, text, text, jsonb)
  from public, anon, authenticated, service_role;

create or replace function app_private.lock_vehicle_for_dispatch(
  target_vehicle uuid,
  target_dispatch uuid,
  target_branch uuid
)
returns public.vehicles
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.vehicles%rowtype;
begin
  if target_vehicle is null then
    raise exception 'an active vehicle is required' using errcode = '23514';
  end if;

  select * into selected
  from public.vehicles
  where vehicles.id = target_vehicle
  for update;

  if not found then
    raise exception 'vehicle not found' using errcode = '23514';
  end if;

  if selected.is_active is distinct from true then
    raise exception 'inactive vehicles cannot be assigned' using errcode = '23514';
  end if;

  if selected.branch_id is distinct from target_branch then
    raise exception 'vehicle belongs to another godown' using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.stock_dispatch_requests
    where stock_dispatch_requests.vehicle_id = selected.id
      and stock_dispatch_requests.id is distinct from target_dispatch
      and stock_dispatch_requests.status in ('dispatched', 'in_transit')
  ) then
    raise exception 'vehicle is already assigned to an active delivery'
      using errcode = '23514';
  end if;

  return selected;
end;
$$;

revoke all on function app_private.lock_vehicle_for_dispatch(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.clean_proof_reference(raw_value text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  cleaned text := btrim(coalesce(raw_value, ''));
begin
  if cleaned = '' then
    return null;
  end if;
  if char_length(cleaned) > 200 then
    raise exception 'proof reference is too long' using errcode = '23514';
  end if;
  if cleaned ~* '^(javascript|data):' or cleaned !~ '^[A-Za-z0-9._:/\- ]+$' then
    raise exception 'proof reference is invalid' using errcode = '23514';
  end if;
  return cleaned;
end;
$$;

revoke all on function app_private.clean_proof_reference(text)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Replace assignment / start / POD / exception (no stock writers)
-- ---------------------------------------------------------------------------
drop function if exists public.assign_dispatch_delivery(uuid, uuid, integer, text);

create function public.assign_dispatch_delivery(
  target_dispatch uuid,
  assignee uuid,
  expected_version integer,
  idempotency_key text,
  target_vehicle uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  header public.stock_dispatch_requests;
  replay uuid;
  worker public.profiles%rowtype;
  has_role boolean := false;
  selected_vehicle public.vehicles%rowtype;
  next_vehicle uuid;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_dispatch_event(cleaned_key, 'assigned', target_dispatch);
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

  perform app_private.assert_dispatch_assigner(header.branch_id);

  if header.version is distinct from expected_version then
    raise exception 'dispatch was changed by someone else' using errcode = 'PT409';
  end if;

  -- Reassignment is allowed only before the run starts.
  if header.stock_consumed is distinct from true
    or header.status is distinct from 'dispatched'
  then
    raise exception 'delivery can be assigned only after stock consumption and before transit'
      using errcode = '23514';
  end if;

  select * into worker from public.profiles where profiles.id = assignee;
  if not found or worker.is_active is distinct from true then
    raise exception 'delivery personnel must be an active employee'
      using errcode = '23514';
  end if;

  select exists (
    select 1
    from public.user_roles
    join public.roles on roles.id = user_roles.role_id
    where user_roles.user_id = assignee
      and roles.code = 'delivery_person'
  )
  into has_role;

  if not has_role then
    raise exception 'assignee must have the delivery personnel role'
      using errcode = '23514';
  end if;

  if not exists (
    select 1
    from public.user_branch_assignments
    where user_branch_assignments.user_id = assignee
      and user_branch_assignments.branch_id = header.branch_id
  ) and not exists (
    select 1
    from public.user_roles
    join public.roles on roles.id = user_roles.role_id
    join public.role_permissions on role_permissions.role_id = roles.id
    join public.permissions on permissions.id = role_permissions.permission_id
    where user_roles.user_id = assignee
      and permissions.code = 'branches.access_all'
  ) then
    raise exception 'delivery personnel must be assigned to this godown'
      using errcode = '23514';
  end if;

  next_vehicle := coalesce(target_vehicle, header.vehicle_id);
  if next_vehicle is not null then
    selected_vehicle := app_private.lock_vehicle_for_dispatch(
      next_vehicle, header.id, header.branch_id
    );
    next_vehicle := selected_vehicle.id;
  end if;

  if header.assigned_to is not distinct from assignee
    and header.vehicle_id is not distinct from next_vehicle
  then
    perform app_private.dispatch_event(
      header.id, 'assigned', header.status, header.status, header.version,
      pg_catalog.jsonb_build_object(
        'assignee', assignee,
        'vehicle_id', next_vehicle,
        'unchanged', true
      ),
      cleaned_key
    );
    return app_private.dispatch_payload(header.id);
  end if;

  update public.stock_dispatch_assignments
  set
    unassigned_at = pg_catalog.clock_timestamp(),
    unassigned_by = auth.uid(),
    reason = 'reassigned'
  where dispatch_id = header.id
    and unassigned_at is null;

  insert into public.stock_dispatch_assignments (
    dispatch_id, assignee, assigned_by, vehicle_id
  )
  values (header.id, assignee, auth.uid(), next_vehicle);

  update public.stock_dispatch_requests
  set
    assigned_to = assignee,
    assigned_by = auth.uid(),
    assigned_at = pg_catalog.clock_timestamp(),
    vehicle_id = next_vehicle,
    version = header.version + 1
  where id = header.id;

  perform app_private.dispatch_event(
    header.id, 'assigned', header.status, header.status, header.version + 1,
    pg_catalog.jsonb_build_object('assignee', assignee, 'vehicle_id', next_vehicle),
    cleaned_key
  );

  perform app_private.write_audit(
    auth.uid(), 'assign_dispatch_delivery', 'stock_dispatch_requests', header.id,
    pg_catalog.jsonb_build_object('assignee', assignee, 'vehicle_id', next_vehicle)
  );

  return app_private.dispatch_payload(header.id);
exception
  when unique_violation then
    raise exception 'vehicle is already assigned to an active delivery'
      using errcode = '23514';
end;
$$;

create or replace function public.start_dispatch_delivery(
  target_dispatch uuid,
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
  header public.stock_dispatch_requests;
  replay uuid;
  selected_vehicle public.vehicles%rowtype;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_dispatch_event(cleaned_key, 'in_transit', target_dispatch);
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

  perform app_private.assert_dispatch_executor(header);

  if header.version is distinct from expected_version then
    raise exception 'dispatch was changed by someone else' using errcode = 'PT409';
  end if;

  if header.status = 'in_transit' then
    return app_private.dispatch_payload(header.id);
  end if;

  if header.status is distinct from 'dispatched' or header.stock_consumed is distinct from true then
    raise exception 'delivery can start only from a dispatched document'
      using errcode = '23514';
  end if;

  if header.assigned_to is null or header.vehicle_id is null then
    raise exception 'an active vehicle and delivery person must be assigned before delivery starts'
      using errcode = '23514';
  end if;

  selected_vehicle := app_private.lock_vehicle_for_dispatch(
    header.vehicle_id, header.id, header.branch_id
  );

  update public.stock_dispatch_requests
  set
    status = 'in_transit',
    in_transit_at = pg_catalog.clock_timestamp(),
    attempted_at = pg_catalog.clock_timestamp(),
    version = header.version + 1
  where id = header.id;

  perform app_private.record_delivery_attempt(
    header, 'in_transit', null,
    pg_catalog.jsonb_build_object('vehicle_id', selected_vehicle.id)
  );

  perform app_private.dispatch_event(
    header.id, 'in_transit', 'dispatched', 'in_transit', header.version + 1,
    pg_catalog.jsonb_build_object('vehicle_id', selected_vehicle.id),
    cleaned_key
  );

  return app_private.dispatch_payload(header.id);
end;
$$;

drop function if exists public.acknowledge_dispatch_delivery(uuid, text, text, integer, text);

create function public.acknowledge_dispatch_delivery(
  target_dispatch uuid,
  recipient_name text,
  acknowledgement_notes text,
  expected_version integer,
  idempotency_key text,
  proof_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  cleaned_name text;
  cleaned_notes text;
  cleaned_proof text;
  header public.stock_dispatch_requests;
  replay uuid;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_dispatch_event(cleaned_key, 'delivered', target_dispatch);
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

  perform app_private.assert_dispatch_executor(header);

  if header.version is distinct from expected_version then
    raise exception 'dispatch was changed by someone else' using errcode = 'PT409';
  end if;

  if header.status = 'delivered' then
    return app_private.dispatch_payload(header.id);
  end if;

  if header.stock_consumed is distinct from true
    or header.status not in ('dispatched', 'in_transit')
  then
    raise exception 'proof of delivery requires a dispatched document'
      using errcode = '23514';
  end if;

  cleaned_name := btrim(coalesce(recipient_name, ''));
  if char_length(cleaned_name) not between 1 and 120 then
    raise exception 'recipient name is required' using errcode = '23514';
  end if;

  cleaned_notes := nullif(btrim(coalesce(acknowledgement_notes, '')), '');
  if cleaned_notes is not null and char_length(cleaned_notes) > 500 then
    raise exception 'acknowledgement notes are too long' using errcode = '23514';
  end if;

  cleaned_proof := app_private.clean_proof_reference(proof_reference);

  perform app_private.write_dispatch_outcome_lines(header, 'delivered', null);

  update public.stock_dispatch_requests
  set
    status = 'delivered',
    delivery_outcome = 'delivered',
    recipient_name = cleaned_name,
    acknowledgement_notes = cleaned_notes,
    proof_reference = cleaned_proof,
    acknowledged_at = pg_catalog.clock_timestamp(),
    acknowledged_by = auth.uid(),
    delivered_at = pg_catalog.clock_timestamp(),
    attempted_at = coalesce(header.attempted_at, pg_catalog.clock_timestamp()),
    return_required = false,
    version = header.version + 1
  where id = header.id;

  perform app_private.record_delivery_attempt(
    header, 'delivered', cleaned_notes,
    pg_catalog.jsonb_build_object(
      'recipient_name', cleaned_name,
      'proof_reference', cleaned_proof
    )
  );

  perform app_private.dispatch_event(
    header.id, 'delivered', header.status, 'delivered', header.version + 1,
    pg_catalog.jsonb_build_object(
      'recipient_name', cleaned_name,
      'proof_reference', cleaned_proof
    ),
    cleaned_key
  );

  perform app_private.write_audit(
    auth.uid(), 'acknowledge_dispatch_delivery', 'stock_dispatch_requests', header.id,
    pg_catalog.jsonb_build_object(
      'recipient_name', cleaned_name,
      'proof_reference', cleaned_proof
    )
  );

  return app_private.dispatch_payload(header.id);
end;
$$;

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

  perform app_private.write_dispatch_outcome_lines(header, 'failed', null);

  update public.stock_dispatch_requests
  set
    status = 'exception',
    delivery_outcome = 'failed',
    exception_reason = cleaned_reason,
    exception_at = pg_catalog.clock_timestamp(),
    attempted_at = coalesce(header.attempted_at, pg_catalog.clock_timestamp()),
    physical_return_status = 'pending_verification',
    return_required = true,
    version = header.version + 1
  where id = header.id;

  perform app_private.record_delivery_attempt(
    header, 'failed', cleaned_reason,
    pg_catalog.jsonb_build_object(
      'physical_return_status', 'pending_verification',
      'stock_restored', false
    )
  );

  perform app_private.dispatch_event(
    header.id, 'exception_recorded', header.status, 'exception', header.version + 1,
    pg_catalog.jsonb_build_object(
      'reason', cleaned_reason,
      'delivery_outcome', 'failed',
      'physical_return_status', 'pending_verification',
      'return_required', true,
      'stock_restored', false
    ),
    cleaned_key
  );

  perform app_private.write_audit(
    auth.uid(), 'report_dispatch_delivery_exception', 'stock_dispatch_requests', header.id,
    pg_catalog.jsonb_build_object(
      'reason', cleaned_reason,
      'physical_return_status', 'pending_verification',
      'return_required', true
    )
  );

  return app_private.dispatch_payload(header.id);
end;
$$;

create or replace function public.record_partial_dispatch_delivery(
  target_dispatch uuid,
  delivered_lines jsonb,
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
  delivered_by_line jsonb := '{}'::jsonb;
  entry jsonb;
  line_id text;
  line_qty integer;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_dispatch_event(cleaned_key, 'partial_recorded', target_dispatch);
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

  if header.status in ('delivered', 'exception') then
    raise exception 'delivery outcome is already recorded' using errcode = '23514';
  end if;

  if header.stock_consumed is distinct from true
    or header.status not in ('dispatched', 'in_transit')
  then
    raise exception 'partial delivery requires dispatched stock'
      using errcode = '23514';
  end if;

  cleaned_reason := btrim(coalesce(exception_reason, ''));
  if char_length(cleaned_reason) not between 1 and 500 then
    raise exception 'exception reason is required' using errcode = '23514';
  end if;

  if jsonb_typeof(delivered_lines) is distinct from 'array'
    or jsonb_array_length(delivered_lines) < 1
  then
    raise exception 'partial delivery requires line quantities' using errcode = '23514';
  end if;

  for entry in select jsonb_array_elements(delivered_lines)
  loop
    line_id := entry ->> 'order_line_id';
    begin
      line_qty := (entry ->> 'delivered_cases')::integer;
    exception
      when invalid_text_representation then
        raise exception 'delivered quantity is invalid' using errcode = '23514';
    end;
    if line_id is null or line_id !~ '^[0-9a-f-]{36}$' then
      raise exception 'delivered quantity is invalid' using errcode = '23514';
    end if;
    delivered_by_line := delivered_by_line || pg_catalog.jsonb_build_object(line_id, line_qty);
  end loop;

  perform app_private.write_dispatch_outcome_lines(header, 'partial', delivered_by_line);

  update public.stock_dispatch_requests
  set
    status = 'exception',
    delivery_outcome = 'partial',
    exception_reason = cleaned_reason,
    exception_at = pg_catalog.clock_timestamp(),
    attempted_at = coalesce(header.attempted_at, pg_catalog.clock_timestamp()),
    physical_return_status = 'pending_verification',
    return_required = true,
    version = header.version + 1
  where id = header.id;

  perform app_private.record_delivery_attempt(
    header, 'partial', cleaned_reason,
    pg_catalog.jsonb_build_object(
      'delivered_lines', delivered_lines,
      'physical_return_status', 'pending_verification',
      'stock_restored', false
    )
  );

  perform app_private.dispatch_event(
    header.id, 'partial_recorded', header.status, 'exception', header.version + 1,
    pg_catalog.jsonb_build_object(
      'reason', cleaned_reason,
      'delivery_outcome', 'partial',
      'physical_return_status', 'pending_verification',
      'return_required', true,
      'stock_restored', false
    ),
    cleaned_key
  );

  perform app_private.write_audit(
    auth.uid(), 'record_partial_dispatch_delivery', 'stock_dispatch_requests', header.id,
    pg_catalog.jsonb_build_object(
      'reason', cleaned_reason,
      'return_required', true
    )
  );

  return app_private.dispatch_payload(header.id);
end;
$$;

create or replace function public.list_assignable_vehicles(target_branch uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_dispatch_assigner(target_branch);

  return coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', vehicles.id,
      'display_name', vehicles.display_name,
      'registration_number', vehicles.registration_number,
      'vehicle_type', vehicles.vehicle_type,
      'in_use', exists (
        select 1
        from public.stock_dispatch_requests
        where stock_dispatch_requests.vehicle_id = vehicles.id
          and stock_dispatch_requests.status in ('dispatched', 'in_transit')
      )
    ) order by vehicles.display_name, vehicles.registration_number, vehicles.id)
    from public.vehicles
    where vehicles.branch_id = target_branch
      and vehicles.is_active
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Payload: vehicle, outcome, attempts. No stock fields rewritten.
-- ---------------------------------------------------------------------------
create or replace function app_private.dispatch_payload(target_dispatch uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  header public.stock_dispatch_requests;
  selected_order public.orders%rowtype;
  picking public.stock_picking_requests%rowtype;
  shipment public.order_shipments%rowtype;
  selected_vehicle public.vehicles%rowtype;
begin
  select * into header
  from public.stock_dispatch_requests
  where id = target_dispatch;

  if not found or not app_private.dispatch_can_view(header) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select * into selected_order from public.orders where id = header.order_id;
  select * into picking from public.stock_picking_requests where id = header.picking_request_id;
  shipment := app_private.open_shipment_for_picking(header.picking_request_id);
  if header.vehicle_id is not null then
    select * into selected_vehicle from public.vehicles where vehicles.id = header.vehicle_id;
  end if;

  -- jsonb_build_object is capped at 100 arguments. Concatenate two objects.
  return pg_catalog.jsonb_build_object(
    'id', header.id,
    'request_number', header.request_number,
    'order_id', header.order_id,
    'order_number', selected_order.order_number,
    'order_status', selected_order.status,
    'order_version', selected_order.version,
    'fulfilment_status', selected_order.fulfilment_status,
    'shop_id', selected_order.shop_id,
    'branch_id', header.branch_id,
    'picking_request_id', header.picking_request_id,
    'picking_request_number', picking.request_number,
    'picking_status', picking.status,
    'picking_version', picking.version,
    'delivery_note_id', header.delivery_note_id,
    'delivery_note_number', (
      select delivery_notes.delivery_note_number
      from public.delivery_notes
      where delivery_notes.id = header.delivery_note_id
    ),
    'delivery_note_status', (
      select delivery_notes.status
      from public.delivery_notes
      where delivery_notes.id = header.delivery_note_id
    ),
    'shipment_id', shipment.id,
    'shipment_number', shipment.shipment_number,
    'shipment_status', shipment.status,
    'shipment_revision', shipment.revision,
    'backorder_id', shipment.backorder_id,
    'status', header.status,
    'version', header.version,
    'stock_consumed', header.stock_consumed,
    'posted_transaction_id', header.posted_transaction_id,
    'physical_return_status', header.physical_return_status,
    'return_required', header.return_required,
    'delivery_outcome', header.delivery_outcome,
    'proof_reference', header.proof_reference,
    'attempted_at', header.attempted_at,
    'assigned_to', header.assigned_to,
    'assigned_to_name', (
      select profiles.full_name from public.profiles where profiles.id = header.assigned_to
    ),
    'assigned_at', header.assigned_at,
    'vehicle_id', header.vehicle_id,
    'vehicle_registration', selected_vehicle.registration_number,
    'vehicle_name', selected_vehicle.display_name,
    'vehicle_type', selected_vehicle.vehicle_type
  ) || pg_catalog.jsonb_build_object(
    'dispatched_by', header.dispatched_by,
    'dispatched_at', header.dispatched_at,
    'in_transit_at', header.in_transit_at,
    'delivered_at', header.delivered_at,
    'exception_at', header.exception_at,
    'exception_reason', header.exception_reason,
    'recipient_name', header.recipient_name,
    'acknowledgement_notes', header.acknowledgement_notes,
    'acknowledged_at', header.acknowledged_at,
    'cancelled_at', header.cancelled_at,
    'cancellation_reason', header.cancellation_reason,
    'created_by', header.created_by,
    'created_at', header.created_at,
    'updated_at', header.updated_at,
    'cutover', pg_catalog.jsonb_build_object(
      'dual_write_enabled', exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.dual_write_enabled' and value = 'true'::jsonb
      ),
      'aggregate_only_blocked', exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.aggregate_only_blocked' and value = 'true'::jsonb
      )
    ),
    'total_cases', coalesce((
      select sum(q.dispatched_cases)::integer
      from app_private.dispatch_line_quantities(header) q
    ), 0),
    'reservations', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_reservations.id,
        'order_line_id', stock_reservations.order_line_id,
        'product_id', stock_reservations.product_id,
        'sku', products.sku,
        'product_name', products.name,
        'crate_id', stock_reservations.crate_id,
        'crate_code', crates.code,
        'zone_code', zones.code,
        'lot_id', stock_reservations.lot_id,
        'manufacturer_lot_code', stock_lots.manufacturer_lot_code,
        'expiry_date', stock_lots.expiry_date,
        'received_on', stock_lots.received_on,
        'lot_status', stock_lots.status,
        'reserved_cases', stock_reservations.reserved_cases,
        'picked_cases', stock_reservations.picked_cases,
        'status', stock_reservations.status
      ) order by products.sku, crates.code, stock_lots.id)
      from public.stock_reservations
      join public.products on products.id = stock_reservations.product_id
      join public.crates on crates.id = stock_reservations.crate_id
      join public.zones on zones.id = crates.zone_id
      join public.stock_lots on stock_lots.id = stock_reservations.lot_id
      where stock_reservations.picking_request_id = header.picking_request_id
        and stock_reservations.status in ('active', 'consumed')
    ), '[]'::jsonb),
    'delivery_lines', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'order_line_id', qty.order_line_id,
        'product_id', qty.product_id,
        'sku', products.sku,
        'product_name', products.name,
        'dispatched_cases', qty.dispatched_cases,
        'delivered_cases', stock_dispatch_outcome_lines.delivered_cases,
        'undelivered_cases', stock_dispatch_outcome_lines.undelivered_cases
      ) order by products.sku, qty.order_line_id)
      from app_private.dispatch_line_quantities(header) qty
      join public.products on products.id = qty.product_id
      left join public.stock_dispatch_outcome_lines
        on stock_dispatch_outcome_lines.dispatch_id = header.id
       and stock_dispatch_outcome_lines.order_line_id = qty.order_line_id
    ), '[]'::jsonb),
    'assignments', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_dispatch_assignments.id,
        'assignee', stock_dispatch_assignments.assignee,
        'assignee_name', profiles.full_name,
        'vehicle_id', stock_dispatch_assignments.vehicle_id,
        'assigned_by', stock_dispatch_assignments.assigned_by,
        'assigned_at', stock_dispatch_assignments.assigned_at,
        'unassigned_at', stock_dispatch_assignments.unassigned_at,
        'reason', stock_dispatch_assignments.reason
      ) order by stock_dispatch_assignments.assigned_at, stock_dispatch_assignments.id)
      from public.stock_dispatch_assignments
      join public.profiles on profiles.id = stock_dispatch_assignments.assignee
      where stock_dispatch_assignments.dispatch_id = header.id
    ), '[]'::jsonb),
    'attempts', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_dispatch_delivery_attempts.id,
        'attempt_number', stock_dispatch_delivery_attempts.attempt_number,
        'outcome', stock_dispatch_delivery_attempts.outcome,
        'actor_id', stock_dispatch_delivery_attempts.actor_id,
        'attempted_at', stock_dispatch_delivery_attempts.attempted_at,
        'reason', stock_dispatch_delivery_attempts.reason
      ) order by stock_dispatch_delivery_attempts.attempt_number, stock_dispatch_delivery_attempts.id)
      from public.stock_dispatch_delivery_attempts
      where stock_dispatch_delivery_attempts.dispatch_id = header.id
    ), '[]'::jsonb),
    'events', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_dispatch_events.id,
        'event_type', stock_dispatch_events.event_type,
        'actor_id', stock_dispatch_events.actor_id,
        'from_status', stock_dispatch_events.from_status,
        'to_status', stock_dispatch_events.to_status,
        'dispatch_version', stock_dispatch_events.dispatch_version,
        'payload', stock_dispatch_events.payload,
        'created_at', stock_dispatch_events.created_at
      ) order by stock_dispatch_events.created_at, stock_dispatch_events.id)
      from public.stock_dispatch_events
      where stock_dispatch_events.dispatch_id = header.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.create_vehicle(uuid, text, text, text, integer, text)
  from public, anon, service_role;
revoke all on function public.update_vehicle(uuid, text, text, text, integer, text)
  from public, anon, service_role;
revoke all on function public.set_vehicle_active(uuid, boolean)
  from public, anon, service_role;
revoke all on function public.assign_dispatch_delivery(uuid, uuid, integer, text, uuid)
  from public, anon, service_role;
revoke all on function public.acknowledge_dispatch_delivery(uuid, text, text, integer, text, text)
  from public, anon, service_role;
revoke all on function public.record_partial_dispatch_delivery(uuid, jsonb, text, integer, text)
  from public, anon, service_role;
revoke all on function public.list_assignable_vehicles(uuid)
  from public, anon, service_role;

grant execute on function public.create_vehicle(uuid, text, text, text, integer, text)
  to authenticated;
grant execute on function public.update_vehicle(uuid, text, text, text, integer, text)
  to authenticated;
grant execute on function public.set_vehicle_active(uuid, boolean)
  to authenticated;
grant execute on function public.assign_dispatch_delivery(uuid, uuid, integer, text, uuid)
  to authenticated;
grant execute on function public.acknowledge_dispatch_delivery(uuid, text, text, integer, text, text)
  to authenticated;
grant execute on function public.record_partial_dispatch_delivery(uuid, jsonb, text, integer, text)
  to authenticated;
grant execute on function public.list_assignable_vehicles(uuid)
  to authenticated;

comment on function public.create_vehicle(uuid, text, text, text, integer, text) is
  'M7.4A. Requires vehicles.manage at the godown. Unique active registration. Does not assign a delivery.';
comment on function public.assign_dispatch_delivery(uuid, uuid, integer, text, uuid) is
  'M3/M7.4A. Assigns an active delivery person and optional vehicle before in_transit. No stock write.';
comment on function public.record_partial_dispatch_delivery(uuid, jsonb, text, integer, text) is
  'M7.4A. Records line-level delivered vs undelivered cases. Does not restore stock or credit finance.';

notify pgrst, 'reload schema';
