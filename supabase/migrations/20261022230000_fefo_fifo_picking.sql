-- M2: FEFO/FIFO allocation, crate/lot reservation, and warehouse picking.
-- Forward-only after 20261022220000. Local-first. Does not seed, attribute,
-- or flip cutover flags. Does not debit stock_ledger; M3 dispatch consumes holds.
-- When dual_write_enabled is false, lot-aware picking fails closed.

-- ---------------------------------------------------------------------------
-- 1. Permissions (reuse picking.execute; add allocate/manage)
-- ---------------------------------------------------------------------------

insert into public.permissions (code, description)
values
  (
    'picking.allocate',
    'Preview FEFO/FIFO allocation and confirm crate/lot reservations for a verified order.'
  ),
  (
    'picking.manage',
    'Assign picking work, approve handoff to dispatch, cancel picking, and review exceptions.'
  )
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from (
  values
    ('admin', 'picking.allocate'),
    ('admin', 'picking.manage'),
    ('admin', 'picking.execute'),
    ('godown_manager', 'picking.allocate'),
    ('godown_manager', 'picking.manage'),
    ('store_keeper', 'picking.execute')
) as grants (role_code, permission_code)
join public.roles on roles.code = grants.role_code
join public.permissions on permissions.code = grants.permission_code
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. Picking documents
-- ---------------------------------------------------------------------------

create sequence public.stock_picking_request_seq;

revoke all on sequence public.stock_picking_request_seq
  from public, anon, authenticated;

create table public.stock_picking_requests (
  id uuid primary key default gen_random_uuid(),
  request_number text not null,
  order_id uuid not null references public.orders (id) on delete restrict,
  branch_id uuid not null references public.branches (id) on delete restrict,
  status text not null,
  version integer not null default 1,
  assigned_to uuid references public.profiles (id) on delete restrict,
  created_by uuid not null references public.profiles (id) on delete restrict,
  started_by uuid references public.profiles (id) on delete restrict,
  started_at timestamptz,
  completed_by uuid references public.profiles (id) on delete restrict,
  completed_at timestamptz,
  handed_off_by uuid references public.profiles (id) on delete restrict,
  handed_off_at timestamptz,
  cancelled_by uuid references public.profiles (id) on delete restrict,
  cancelled_at timestamptz,
  cancellation_reason text,
  blocked_reason text,
  idempotency_key text not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint stock_picking_requests_number_key unique (request_number),
  constraint stock_picking_requests_idempotency_key unique (idempotency_key),
  constraint stock_picking_requests_status_check check (
    status in (
      'allocated',
      'picking',
      'picked',
      'ready_for_dispatch',
      'cancelled',
      'blocked'
    )
  ),
  constraint stock_picking_requests_version_check check (version >= 1),
  constraint stock_picking_requests_cancel_shape check (
    status <> 'cancelled'
    or (
      cancelled_by is not null
      and cancelled_at is not null
      and cancellation_reason is not null
    )
  ),
  constraint stock_picking_requests_reason_length check (
    cancellation_reason is null
    or (
      char_length(btrim(cancellation_reason)) between 1 and 500
      and cancellation_reason = btrim(cancellation_reason)
    )
  ),
  constraint stock_picking_requests_blocked_length check (
    blocked_reason is null
    or (
      char_length(btrim(blocked_reason)) between 1 and 500
      and blocked_reason = btrim(blocked_reason)
    )
  )
);

comment on table public.stock_picking_requests is
  'M2. One active picking document per verified order. Status is warehouse work, not a replacement of orders.status.';

create unique index stock_picking_requests_order_active_idx
  on public.stock_picking_requests (order_id)
  where status is distinct from 'cancelled';

create index stock_picking_requests_branch_status_idx
  on public.stock_picking_requests (branch_id, status, created_at desc);

create index stock_picking_requests_assigned_idx
  on public.stock_picking_requests (assigned_to)
  where assigned_to is not null;

create trigger stock_picking_requests_set_updated_at
  before update on public.stock_picking_requests
  for each row execute function app_private.set_updated_at();

create table public.stock_reservations (
  id uuid primary key default gen_random_uuid(),
  picking_request_id uuid not null
    references public.stock_picking_requests (id) on delete restrict,
  order_id uuid not null references public.orders (id) on delete restrict,
  order_line_id uuid not null references public.order_lines (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  crate_id uuid not null references public.crates (id) on delete restrict,
  lot_id uuid not null references public.stock_lots (id) on delete restrict,
  branch_id uuid not null references public.branches (id) on delete restrict,
  reserved_cases integer not null,
  picked_cases integer not null default 0,
  status text not null,
  created_by uuid not null references public.profiles (id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint stock_reservations_reserved_check
    check (reserved_cases >= 1 and reserved_cases <= 1000000),
  constraint stock_reservations_picked_check
    check (picked_cases >= 0 and picked_cases <= reserved_cases),
  constraint stock_reservations_status_check check (
    status in ('active', 'released')
  )
);

comment on table public.stock_reservations is
  'M2. Active rows hold reserved_cases against on-hand lot×crate stock until M3 consumes them or picking is cancelled. picked_cases is warehouse confirmation only.';

create unique index stock_reservations_grain_active_idx
  on public.stock_reservations (
    picking_request_id, order_line_id, crate_id, lot_id
  )
  where status = 'active';

create index stock_reservations_lot_crate_active_idx
  on public.stock_reservations (lot_id, crate_id)
  where status = 'active';

create index stock_reservations_request_idx
  on public.stock_reservations (picking_request_id);

create trigger stock_reservations_set_updated_at
  before update on public.stock_reservations
  for each row execute function app_private.set_updated_at();

create table public.stock_picking_exceptions (
  id uuid primary key default gen_random_uuid(),
  picking_request_id uuid not null
    references public.stock_picking_requests (id) on delete restrict,
  reservation_id uuid references public.stock_reservations (id) on delete restrict,
  exception_type text not null,
  message text not null,
  quantity integer,
  created_by uuid not null references public.profiles (id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_picking_exceptions_type_check check (
    exception_type in (
      'shortage',
      'expired_stock',
      'unknown_legacy',
      'missing_received_on',
      'unclassified',
      'cutover_blocked',
      'stale',
      'conflict',
      'cancelled'
    )
  ),
  constraint stock_picking_exceptions_message_length check (
    char_length(btrim(message)) between 1 and 500
    and message = btrim(message)
  ),
  constraint stock_picking_exceptions_quantity_check check (
    quantity is null or (quantity >= 0 and quantity <= 1000000)
  )
);

create index stock_picking_exceptions_request_idx
  on public.stock_picking_exceptions (picking_request_id, created_at);

create table public.stock_picking_events (
  id uuid primary key default gen_random_uuid(),
  picking_request_id uuid not null
    references public.stock_picking_requests (id) on delete restrict,
  event_type text not null,
  actor_id uuid not null,
  from_status text,
  to_status text not null,
  request_version integer not null,
  payload jsonb not null default '{}'::jsonb,
  idempotency_key text,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_picking_events_type_check check (
    event_type in (
      'allocated',
      'assigned',
      'picking_started',
      'quantity_confirmed',
      'exception_recorded',
      'reservation_released',
      'picking_completed',
      'handed_off',
      'cancelled',
      'blocked'
    )
  ),
  constraint stock_picking_events_version_check check (request_version >= 1)
);

create unique index stock_picking_events_idempotency_idx
  on public.stock_picking_events (idempotency_key)
  where idempotency_key is not null;

create index stock_picking_events_request_idx
  on public.stock_picking_events (picking_request_id, created_at, id);

-- ---------------------------------------------------------------------------
-- 3. RLS, grants, write guards
-- ---------------------------------------------------------------------------

create or replace function app_private.guard_picking_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if pg_catalog.current_setting('app.picking_write', true) is distinct from 'on' then
    raise exception 'picking records cannot be changed directly'
      using errcode = '42501';
  end if;

  if tg_table_name = 'stock_picking_events' and tg_op <> 'INSERT' then
    raise exception 'picking history cannot be changed' using errcode = '42501';
  end if;

  if tg_table_name = 'stock_picking_exceptions' and tg_op <> 'INSERT' then
    raise exception 'picking exceptions cannot be changed' using errcode = '42501';
  end if;

  return coalesce(new, old);
end;
$$;

revoke all on function app_private.guard_picking_write()
  from public, anon, authenticated, service_role;

create trigger stock_picking_requests_guard
  before insert or update or delete on public.stock_picking_requests
  for each row execute function app_private.guard_picking_write();

create trigger stock_reservations_guard
  before insert or update or delete on public.stock_reservations
  for each row execute function app_private.guard_picking_write();

create trigger stock_picking_exceptions_guard
  before insert or update or delete on public.stock_picking_exceptions
  for each row execute function app_private.guard_picking_write();

create trigger stock_picking_events_guard
  before insert or update or delete on public.stock_picking_events
  for each row execute function app_private.guard_picking_write();

alter table public.stock_picking_requests enable row level security;
alter table public.stock_picking_requests force row level security;
alter table public.stock_reservations enable row level security;
alter table public.stock_reservations force row level security;
alter table public.stock_picking_exceptions enable row level security;
alter table public.stock_picking_exceptions force row level security;
alter table public.stock_picking_events enable row level security;
alter table public.stock_picking_events force row level security;

create policy stock_picking_requests_select_authorized
  on public.stock_picking_requests
  for select
  to authenticated
  using (
    (select app_private.can_work_at_branch(branch_id))
    and (
      (select app_private.has_permission('picking.allocate'))
      or (select app_private.has_permission('picking.manage'))
      or (select app_private.has_permission('operations.monitor'))
      or (
        (select app_private.has_permission('picking.execute'))
        and assigned_to is not distinct from (select auth.uid())
      )
    )
  );

create policy stock_reservations_select_authorized
  on public.stock_reservations
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.stock_picking_requests header
      where header.id = stock_reservations.picking_request_id
    )
  );

create policy stock_picking_exceptions_select_authorized
  on public.stock_picking_exceptions
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.stock_picking_requests header
      where header.id = stock_picking_exceptions.picking_request_id
    )
  );

create policy stock_picking_events_select_authorized
  on public.stock_picking_events
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.stock_picking_requests header
      where header.id = stock_picking_events.picking_request_id
    )
  );

revoke all on table public.stock_picking_requests
  from public, anon, authenticated, service_role;
revoke all on table public.stock_reservations
  from public, anon, authenticated, service_role;
revoke all on table public.stock_picking_exceptions
  from public, anon, authenticated, service_role;
revoke all on table public.stock_picking_events
  from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate
  on table public.stock_picking_requests from service_role;
revoke insert, update, delete, truncate
  on table public.stock_reservations from service_role;
revoke insert, update, delete, truncate
  on table public.stock_picking_exceptions from service_role;
revoke insert, update, delete, truncate
  on table public.stock_picking_events from service_role;
grant select on table public.stock_picking_requests to authenticated;
grant select on table public.stock_reservations to authenticated;
grant select on table public.stock_picking_exceptions to authenticated;
grant select on table public.stock_picking_events to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Reservation conservation against trusted posting
-- ---------------------------------------------------------------------------

create or replace function app_private.active_reserved_lot_cases(
  p_lot uuid,
  p_crate uuid
)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(stock_reservations.reserved_cases), 0)::integer
  from public.stock_reservations
  where stock_reservations.lot_id = p_lot
    and stock_reservations.crate_id = p_crate
    and stock_reservations.status = 'active';
$$;

revoke all on function app_private.active_reserved_lot_cases(uuid, uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.active_reserved_grain_cases(
  p_crate uuid,
  p_product uuid
)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(stock_reservations.reserved_cases), 0)::integer
  from public.stock_reservations
  where stock_reservations.crate_id = p_crate
    and stock_reservations.product_id = p_product
    and stock_reservations.status = 'active';
$$;

revoke all on function app_private.active_reserved_grain_cases(uuid, uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_lot_not_below_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.quantity < old.quantity then
    if new.quantity < app_private.active_reserved_lot_cases(new.lot_id, new.crate_id) then
      raise exception 'insufficient unreserved lot stock'
        using errcode = '23514';
    end if;
  end if;
  if tg_op = 'DELETE' then
    if app_private.active_reserved_lot_cases(old.lot_id, old.crate_id) > 0 then
      raise exception 'insufficient unreserved lot stock'
        using errcode = '23514';
    end if;
    return old;
  end if;
  return new;
end;
$$;

revoke all on function app_private.assert_lot_not_below_reservation()
  from public, anon, authenticated, service_role;

create trigger stock_lot_balances_reservation_guard
  before update or delete on public.stock_lot_balances
  for each row execute function app_private.assert_lot_not_below_reservation();

create or replace function app_private.assert_balance_not_below_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if app_private.active_reserved_grain_cases(old.crate_id, old.product_id) > 0 then
      raise exception 'insufficient unreserved stock'
        using errcode = '23514';
    end if;
    return old;
  end if;
  if tg_op = 'UPDATE' and new.quantity < old.quantity then
    if new.quantity < app_private.active_reserved_grain_cases(new.crate_id, new.product_id) then
      raise exception 'insufficient unreserved stock'
        using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function app_private.assert_balance_not_below_reservation()
  from public, anon, authenticated, service_role;

create trigger stock_balances_reservation_guard
  before update or delete on public.stock_balances
  for each row execute function app_private.assert_balance_not_below_reservation();

-- ---------------------------------------------------------------------------
-- 5. Authorization and cutover helpers
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_picking_allocator(target_branch uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('picking.allocate');
  if not app_private.can_work_at_branch(target_branch) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_picking_allocator(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_picking_manager(target_branch uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('picking.manage');
  if not app_private.can_work_at_branch(target_branch) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_picking_manager(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_picking_executor(
  header public.stock_picking_requests
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app_private.can_work_at_branch(header.branch_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
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

create or replace function app_private.picking_cutover_blockers()
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  dual_write boolean := false;
  blocked boolean := false;
  blockers text[] := '{}';
begin
  select coalesce(app_configuration.value, 'false'::jsonb) = 'true'::jsonb
  into dual_write
  from public.app_configuration
  where app_configuration.key = 'stock.lots.dual_write_enabled';

  select coalesce(app_configuration.value, 'false'::jsonb) = 'true'::jsonb
  into blocked
  from public.app_configuration
  where app_configuration.key = 'stock.lots.aggregate_only_blocked';

  -- Lot identities are only trustworthy after dual-write. Seed-only
  -- (blocked, dual-write still off) is the cutover window, not picking.
  if not coalesce(dual_write, false) then
    blockers := array_append(
      blockers,
      'Lot-aware picking requires dual-write to be enabled. Aggregate-only stock has no valid lot identities.'
    );
  end if;
  if coalesce(blocked, false) and not coalesce(dual_write, false) then
    blockers := array_append(
      blockers,
      'Legacy seed has blocked aggregate posting. Finish attribution and enable dual-write before picking.'
    );
  end if;
  return blockers;
end;
$$;

revoke all on function app_private.picking_cutover_blockers()
  from public, anon, authenticated, service_role;

create or replace function app_private.picking_can_view(header public.stock_picking_requests)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app_private.can_work_at_branch(header.branch_id) then
    return false;
  end if;
  if app_private.has_permission('picking.allocate')
    or app_private.has_permission('picking.manage')
    or app_private.has_permission('operations.monitor')
  then
    return true;
  end if;
  return app_private.has_permission('picking.execute')
    and header.assigned_to is not distinct from auth.uid();
end;
$$;

revoke all on function app_private.picking_can_view(public.stock_picking_requests)
  from public, anon, authenticated, service_role;

create or replace function app_private.lock_picking_request(
  target_request uuid,
  expected_version integer
)
returns public.stock_picking_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_picking_requests;
begin
  select *
  into header
  from public.stock_picking_requests
  where stock_picking_requests.id = target_request
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if header.version is distinct from expected_version then
    raise exception 'picking was changed by someone else' using errcode = 'PT409';
  end if;

  return header;
end;
$$;

revoke all on function app_private.lock_picking_request(uuid, integer)
  from public, anon, authenticated, service_role;

create or replace function app_private.picking_event(
  target_request uuid,
  event_type text,
  from_status text,
  to_status text,
  request_version integer,
  payload jsonb,
  idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created uuid;
begin
  insert into public.stock_picking_events (
    picking_request_id,
    event_type,
    actor_id,
    from_status,
    to_status,
    request_version,
    payload,
    idempotency_key
  )
  values (
    target_request,
    event_type,
    auth.uid(),
    from_status,
    to_status,
    request_version,
    coalesce(payload, '{}'::jsonb),
    idempotency_key
  )
  returning id into created;
  return created;
end;
$$;

revoke all on function app_private.picking_event(uuid, text, text, text, integer, jsonb, text)
  from public, anon, authenticated, service_role;

create or replace function app_private.replay_picking_event(
  cleaned_key text,
  expected_type text,
  target_request uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  existing public.stock_picking_events%rowtype;
begin
  if cleaned_key is null then
    return null;
  end if;

  select *
  into existing
  from public.stock_picking_events
  where stock_picking_events.idempotency_key = cleaned_key;

  if not found then
    return null;
  end if;

  if existing.event_type is distinct from expected_type
    or existing.picking_request_id is distinct from target_request
  then
    raise exception 'idempotency key does not match the original request'
      using errcode = '23514';
  end if;

  return existing.picking_request_id;
end;
$$;

revoke all on function app_private.replay_picking_event(text, text, uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. FEFO/FIFO engine
-- ---------------------------------------------------------------------------

create or replace function app_private.picking_available_cases(
  p_lot uuid,
  p_crate uuid
)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  on_hand integer := 0;
begin
  select coalesce(stock_lot_balances.quantity, 0)
  into on_hand
  from public.stock_lot_balances
  where stock_lot_balances.lot_id = p_lot
    and stock_lot_balances.crate_id = p_crate;

  return greatest(on_hand - app_private.active_reserved_lot_cases(p_lot, p_crate), 0);
end;
$$;

revoke all on function app_private.picking_available_cases(uuid, uuid)
  from public, anon, authenticated, service_role;

-- Eligible grains only. Status available excludes quarantined, expired_blocked,
-- and legacy_unattributed. NULL received_on is never treated as oldest.
create or replace function app_private.picking_line_plan(
  p_product uuid,
  p_branch uuid,
  p_requested integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  product_policy text;
  blockers text[] := '{}';
  remaining integer;
  take_qty integer;
  allocated integer := 0;
  slices jsonb := '[]'::jsonb;
  grain record;
begin
  select products.expiry_policy
  into product_policy
  from public.products
  where products.id = p_product;

  if product_policy is distinct from 'expiry_controlled'
    and product_policy is distinct from 'non_expiring'
  then
    return pg_catalog.jsonb_build_object(
      'product_id', p_product,
      'requested_cases', p_requested,
      'allocated_cases', 0,
      'shortfall_cases', p_requested,
      'eligible', false,
      'blockers', jsonb_build_array('Unclassified products cannot be allocated.'),
      'slices', '[]'::jsonb
    );
  end if;

  remaining := p_requested;

  for grain in
    select
      stock_lots.id as lot_id,
      stock_lot_balances.crate_id,
      stock_lots.expiry_date,
      stock_lots.received_on,
      stock_lots.manufacturer_lot_code,
      stock_lots.status,
      crates.code as crate_code,
      zones.code as zone_code,
      app_private.picking_available_cases(stock_lots.id, stock_lot_balances.crate_id) as available
    from public.stock_lot_balances
    join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
    join public.crates on crates.id = stock_lot_balances.crate_id
    join public.zones on zones.id = crates.zone_id
    where stock_lots.product_id = p_product
      and stock_lots.branch_id = p_branch
      and zones.branch_id = p_branch
      and stock_lots.status = 'available'
      and stock_lot_balances.quantity > 0
      and (
        (
          product_policy = 'expiry_controlled'
          and stock_lots.expiry_date is not null
          and stock_lots.expiry_date >= current_date
        )
        or (
          product_policy = 'non_expiring'
          and stock_lots.expiry_date is null
          and stock_lots.received_on is not null
        )
      )
    order by
      case when product_policy = 'expiry_controlled' then stock_lots.expiry_date end asc nulls last,
      stock_lots.received_on asc nulls last,
      stock_lots.id,
      stock_lot_balances.crate_id
  loop
    if grain.available < 1 or remaining < 1 then
      continue;
    end if;
    take_qty := least(remaining, grain.available);
    allocated := allocated + take_qty;
    remaining := remaining - take_qty;
    slices := slices || jsonb_build_array(pg_catalog.jsonb_build_object(
      'lot_id', grain.lot_id,
      'crate_id', grain.crate_id,
      'crate_code', grain.crate_code,
      'zone_code', grain.zone_code,
      'manufacturer_lot_code', grain.manufacturer_lot_code,
      'expiry_date', grain.expiry_date,
      'received_on', grain.received_on,
      'available_cases', grain.available,
      'reserved_cases', take_qty,
      'policy', product_policy
    ));
  end loop;

  if remaining > 0 then
    if product_policy = 'expiry_controlled' then
      blockers := array_append(
        blockers,
        'Insufficient eligible FEFO stock. Expired, unknown-expiry, and legacy-unattributed lots are excluded.'
      );
    else
      blockers := array_append(
        blockers,
        'Insufficient eligible FIFO stock. Lots without received_on and legacy-unattributed lots are excluded.'
      );
    end if;
  end if;

  return pg_catalog.jsonb_build_object(
    'product_id', p_product,
    'expiry_policy', product_policy,
    'requested_cases', p_requested,
    'allocated_cases', allocated,
    'shortfall_cases', remaining,
    'eligible', remaining = 0,
    'blockers', to_jsonb(blockers),
    'slices', slices
  );
end;
$$;

revoke all on function app_private.picking_line_plan(uuid, uuid, integer)
  from public, anon, authenticated, service_role;

create or replace function app_private.picking_payload(target_request uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  header public.stock_picking_requests;
  selected_order public.orders%rowtype;
begin
  select *
  into header
  from public.stock_picking_requests
  where id = target_request;

  if not found or not app_private.picking_can_view(header) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select * into selected_order from public.orders where id = header.order_id;

  return pg_catalog.jsonb_build_object(
    'id', header.id,
    'request_number', header.request_number,
    'order_id', header.order_id,
    'order_number', selected_order.order_number,
    'order_status', selected_order.status,
    'order_version', selected_order.version,
    'shop_id', selected_order.shop_id,
    'branch_id', header.branch_id,
    'status', header.status,
    'version', header.version,
    'assigned_to', header.assigned_to,
    'created_by', header.created_by,
    'started_at', header.started_at,
    'completed_at', header.completed_at,
    'handed_off_at', header.handed_off_at,
    'cancelled_at', header.cancelled_at,
    'cancellation_reason', header.cancellation_reason,
    'blocked_reason', header.blocked_reason,
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
        'remaining_cases', stock_reservations.reserved_cases - stock_reservations.picked_cases,
        'status', stock_reservations.status
      ) order by products.sku, crates.code, stock_lots.id)
      from public.stock_reservations
      join public.products on products.id = stock_reservations.product_id
      join public.crates on crates.id = stock_reservations.crate_id
      join public.zones on zones.id = crates.zone_id
      join public.stock_lots on stock_lots.id = stock_reservations.lot_id
      where stock_reservations.picking_request_id = header.id
    ), '[]'::jsonb),
    'exceptions', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_picking_exceptions.id,
        'reservation_id', stock_picking_exceptions.reservation_id,
        'exception_type', stock_picking_exceptions.exception_type,
        'message', stock_picking_exceptions.message,
        'quantity', stock_picking_exceptions.quantity,
        'created_at', stock_picking_exceptions.created_at
      ) order by stock_picking_exceptions.created_at, stock_picking_exceptions.id)
      from public.stock_picking_exceptions
      where stock_picking_exceptions.picking_request_id = header.id
    ), '[]'::jsonb),
    'events', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_picking_events.id,
        'event_type', stock_picking_events.event_type,
        'actor_id', stock_picking_events.actor_id,
        'from_status', stock_picking_events.from_status,
        'to_status', stock_picking_events.to_status,
        'request_version', stock_picking_events.request_version,
        'payload', stock_picking_events.payload,
        'created_at', stock_picking_events.created_at
      ) order by stock_picking_events.created_at, stock_picking_events.id)
      from public.stock_picking_events
      where stock_picking_events.picking_request_id = header.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app_private.picking_payload(uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Public RPCs
-- ---------------------------------------------------------------------------

create or replace function public.preview_order_allocation(target_order uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  selected public.orders%rowtype;
  cutover text[];
  line public.order_lines%rowtype;
  plans jsonb := '[]'::jsonb;
  plan jsonb;
  blockers text[] := '{}';
  eligible boolean := true;
begin
  select * into selected from public.orders where orders.id = target_order;
  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_picking_allocator(selected.branch_id);

  cutover := app_private.picking_cutover_blockers();
  blockers := blockers || cutover;

  if selected.status is distinct from 'verified' then
    blockers := array_append(blockers, 'Picking can start only from a verified order.');
  end if;

  if exists (
    select 1 from public.stock_picking_requests
    where stock_picking_requests.order_id = selected.id
      and stock_picking_requests.status is distinct from 'cancelled'
  ) then
    blockers := array_append(blockers, 'This order already has an active picking request.');
  end if;

  for line in
    select * from public.order_lines
    where order_lines.order_id = selected.id
    order by order_lines.created_at, order_lines.id
  loop
    plan := app_private.picking_line_plan(
      line.product_id, selected.branch_id, line.requested_cases
    );
    plan := plan || pg_catalog.jsonb_build_object(
      'order_line_id', line.id,
      'sku', (select products.sku from public.products where products.id = line.product_id),
      'product_name', (select products.name from public.products where products.id = line.product_id)
    );
    plans := plans || jsonb_build_array(plan);
    if coalesce(plan ->> 'eligible', 'false') is distinct from 'true' then
      eligible := false;
      blockers := blockers || coalesce(
        array(select jsonb_array_elements_text(plan -> 'blockers')),
        '{}'
      );
    end if;
  end loop;

  if coalesce(jsonb_array_length(plans), 0) < 1 then
    eligible := false;
    blockers := array_append(blockers, 'The order has no lines to allocate.');
  end if;

  if coalesce(pg_catalog.array_length(cutover, 1), 0) > 0 then
    eligible := false;
  end if;

  if selected.status is distinct from 'verified' then
    eligible := false;
  end if;

  return pg_catalog.jsonb_build_object(
    'order_id', selected.id,
    'order_number', selected.order_number,
    'order_status', selected.status,
    'order_version', selected.version,
    'branch_id', selected.branch_id,
    'shop_id', selected.shop_id,
    'eligible', eligible and coalesce(pg_catalog.array_length(blockers, 1), 0) = 0,
    'blockers', to_jsonb(blockers),
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
    'lines', plans
  );
end;
$$;

create or replace function public.reserve_order_allocation(
  target_order uuid,
  expected_order_version integer,
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
  existing public.stock_picking_requests%rowtype;
  created uuid;
  request_number text;
  preview jsonb;
  line jsonb;
  slice jsonb;
  blockers text[];
  first_blocker text;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select * into existing
  from public.stock_picking_requests
  where stock_picking_requests.idempotency_key = cleaned_key;
  if found then
    return app_private.picking_payload(existing.id);
  end if;

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.picking_write', 'on', true);

  select * into selected
  from public.orders
  where orders.id = target_order
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_picking_allocator(selected.branch_id);

  if selected.version is distinct from expected_order_version then
    raise exception 'order was changed by someone else' using errcode = 'PT409';
  end if;

  preview := public.preview_order_allocation(selected.id);
  if coalesce(preview ->> 'eligible', 'false') is distinct from 'true' then
    blockers := coalesce(
      array(select jsonb_array_elements_text(preview -> 'blockers')),
      '{}'
    );
    first_blocker := blockers[1];
    raise exception '%', coalesce(first_blocker, 'Allocation is not eligible.')
      using errcode = '23514';
  end if;

  -- Lock every candidate grain in crate/lot order so competing orders cannot deadlock.
  perform stock_lot_balances.lot_id
  from public.stock_lot_balances
  join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
  join public.order_lines on order_lines.product_id = stock_lots.product_id
  where order_lines.order_id = selected.id
    and stock_lots.branch_id = selected.branch_id
  order by stock_lot_balances.crate_id, stock_lot_balances.lot_id
  for update of stock_lot_balances;

  preview := public.preview_order_allocation(selected.id);
  if coalesce(preview ->> 'eligible', 'false') is distinct from 'true' then
    raise exception 'insufficient eligible stock'
      using errcode = '23514';
  end if;

  request_number := 'PK-'
    || to_char(pg_catalog.clock_timestamp() at time zone 'UTC', 'YYYYMMDD')
    || '-'
    || pg_catalog.lpad(
      pg_catalog.nextval('public.stock_picking_request_seq')::text, 6, '0'
    );

  insert into public.stock_picking_requests (
    request_number, order_id, branch_id, status, created_by, idempotency_key
  )
  values (
    request_number, selected.id, selected.branch_id, 'allocated', auth.uid(), cleaned_key
  )
  returning id into created;

  for line in select value from jsonb_array_elements(preview -> 'lines')
  loop
    for slice in select value from jsonb_array_elements(line -> 'slices')
    loop
      if app_private.picking_available_cases(
        (slice ->> 'lot_id')::uuid,
        (slice ->> 'crate_id')::uuid
      ) < (slice ->> 'reserved_cases')::integer then
        raise exception 'insufficient eligible stock' using errcode = '23514';
      end if;

      insert into public.stock_reservations (
        picking_request_id,
        order_id,
        order_line_id,
        product_id,
        crate_id,
        lot_id,
        branch_id,
        reserved_cases,
        picked_cases,
        status,
        created_by
      )
      values (
        created,
        selected.id,
        (line ->> 'order_line_id')::uuid,
        (line ->> 'product_id')::uuid,
        (slice ->> 'crate_id')::uuid,
        (slice ->> 'lot_id')::uuid,
        selected.branch_id,
        (slice ->> 'reserved_cases')::integer,
        0,
        'active',
        auth.uid()
      );
    end loop;
  end loop;

  perform app_private.picking_event(
    created, 'allocated', null, 'allocated', 1, preview, cleaned_key
  );
  perform app_private.write_audit(
    auth.uid(),
    'reserve_order_allocation',
    'stock_picking_requests',
    created,
    pg_catalog.jsonb_build_object('order_id', selected.id, 'request_number', request_number)
  );

  return app_private.picking_payload(created);
end;
$$;

create or replace function public.list_picking_requests(status_filter text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cleaned text;
begin
  cleaned := nullif(pg_catalog.btrim(coalesce(status_filter, '')), '');
  if cleaned is not null and cleaned is distinct from 'pending_allocation'
    and cleaned not in (
      'allocated', 'picking', 'picked', 'ready_for_dispatch', 'cancelled', 'blocked'
    )
  then
    raise exception 'picking status is invalid' using errcode = '23514';
  end if;

  if cleaned is not distinct from 'pending_allocation' then
    if not (
      app_private.has_permission('picking.allocate')
      or app_private.has_permission('picking.manage')
      or app_private.has_permission('operations.monitor')
    ) then
      return '[]'::jsonb;
    end if;

    return coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'kind', 'pending_order',
        'order_id', orders.id,
        'order_number', orders.order_number,
        'order_status', orders.status,
        'order_version', orders.version,
        'branch_id', orders.branch_id,
        'shop_id', orders.shop_id,
        'created_at', orders.verified_at,
        'status', 'pending_allocation'
      ) order by orders.verified_at, orders.order_number)
      from public.orders
      where orders.status = 'verified'
        and app_private.can_work_at_branch(orders.branch_id)
        and not exists (
          select 1 from public.stock_picking_requests
          where stock_picking_requests.order_id = orders.id
            and stock_picking_requests.status is distinct from 'cancelled'
        )
    ), '[]'::jsonb);
  end if;

  return coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'kind', 'picking_request',
      'id', header.id,
      'request_number', header.request_number,
      'order_id', header.order_id,
      'order_number', orders.order_number,
      'branch_id', header.branch_id,
      'status', header.status,
      'version', header.version,
      'assigned_to', header.assigned_to,
      'created_at', header.created_at,
      'updated_at', header.updated_at
    ) order by header.created_at desc)
    from public.stock_picking_requests header
    join public.orders on orders.id = header.order_id
    where app_private.picking_can_view(header)
      and (cleaned is null or header.status = cleaned)
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_picking_request(target_request uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  return app_private.picking_payload(target_request);
end;
$$;

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

create or replace function public.start_picking(
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
  replay := app_private.replay_picking_event(cleaned_key, 'picking_started', target_request);
  if replay is not null then
    return app_private.picking_payload(replay);
  end if;

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.picking_write', 'on', true);
  header := app_private.lock_picking_request(target_request, expected_version);
  perform app_private.assert_picking_executor(header);

  if header.status is distinct from 'allocated' then
    raise exception 'picking cannot start from %', header.status using errcode = '23514';
  end if;

  update public.stock_picking_requests
  set
    status = 'picking',
    started_by = auth.uid(),
    started_at = pg_catalog.clock_timestamp(),
    version = header.version + 1
  where id = header.id;

  perform app_private.picking_event(
    header.id, 'picking_started', 'allocated', 'picking', header.version + 1,
    '{}'::jsonb, cleaned_key
  );

  return app_private.picking_payload(header.id);
end;
$$;

create or replace function public.confirm_picking_quantity(
  target_request uuid,
  target_reservation uuid,
  picked_quantity integer,
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
  selected public.stock_reservations%rowtype;
  replay uuid;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_picking_event(cleaned_key, 'quantity_confirmed', target_request);
  if replay is not null then
    return app_private.picking_payload(replay);
  end if;

  perform app_private.assert_carton_quantity(picked_quantity);
  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.picking_write', 'on', true);
  header := app_private.lock_picking_request(target_request, expected_version);
  perform app_private.assert_picking_executor(header);

  if header.status is distinct from 'picking' then
    raise exception 'quantities can be confirmed only while picking'
      using errcode = '23514';
  end if;

  select * into selected
  from public.stock_reservations
  where stock_reservations.id = target_reservation
    and stock_reservations.picking_request_id = header.id
  for update;

  if not found or selected.status is distinct from 'active' then
    raise exception 'reservation cannot be confirmed' using errcode = '23514';
  end if;

  if picked_quantity > selected.reserved_cases then
    raise exception 'picked quantity cannot exceed reserved quantity'
      using errcode = '23514';
  end if;

  update public.stock_reservations
  set picked_cases = picked_quantity
  where id = selected.id;

  update public.stock_picking_requests
  set version = header.version + 1
  where id = header.id;

  perform app_private.picking_event(
    header.id, 'quantity_confirmed', 'picking', 'picking', header.version + 1,
    pg_catalog.jsonb_build_object(
      'reservation_id', selected.id,
      'picked_cases', picked_quantity
    ),
    cleaned_key
  );

  return app_private.picking_payload(header.id);
end;
$$;

create or replace function public.report_picking_shortage(
  target_request uuid,
  target_reservation uuid,
  short_quantity integer,
  shortage_note text,
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
  cleaned_note text;
  header public.stock_picking_requests;
  selected public.stock_reservations%rowtype;
  replay uuid;
  remaining integer;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_picking_event(cleaned_key, 'exception_recorded', target_request);
  if replay is not null then
    return app_private.picking_payload(replay);
  end if;

  perform app_private.assert_carton_quantity(short_quantity);
  cleaned_note := coalesce(
    app_private.clean_optional_text(shortage_note, 500),
    'Shortage reported during picking'
  );

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.picking_write', 'on', true);
  header := app_private.lock_picking_request(target_request, expected_version);
  perform app_private.assert_picking_executor(header);

  if header.status is distinct from 'picking' then
    raise exception 'shortages can be recorded only while picking'
      using errcode = '23514';
  end if;

  select * into selected
  from public.stock_reservations
  where stock_reservations.id = target_reservation
    and stock_reservations.picking_request_id = header.id
  for update;

  if not found or selected.status is distinct from 'active' then
    raise exception 'reservation cannot record a shortage' using errcode = '23514';
  end if;

  remaining := selected.reserved_cases - selected.picked_cases;
  if short_quantity > remaining then
    raise exception 'shortage cannot exceed remaining reserved quantity'
      using errcode = '23514';
  end if;

  -- Active holds equal reserved_cases. Full unpicked shortage releases the row
  -- instead of storing reserved_cases = 0, which the quantity check forbids.
  if short_quantity = selected.reserved_cases and selected.picked_cases = 0 then
    update public.stock_reservations
    set status = 'released'
    where id = selected.id;
  else
    update public.stock_reservations
    set reserved_cases = selected.reserved_cases - short_quantity
    where id = selected.id;
  end if;

  insert into public.stock_picking_exceptions (
    picking_request_id, reservation_id, exception_type, message, quantity, created_by
  )
  values (
    header.id, selected.id, 'shortage', cleaned_note, short_quantity, auth.uid()
  );

  update public.stock_picking_requests
  set version = header.version + 1
  where id = header.id;

  perform app_private.picking_event(
    header.id, 'exception_recorded', 'picking', 'picking', header.version + 1,
    pg_catalog.jsonb_build_object(
      'reservation_id', selected.id,
      'exception_type', 'shortage',
      'quantity', short_quantity
    ),
    cleaned_key
  );

  return app_private.picking_payload(header.id);
end;
$$;

create or replace function public.complete_picking(
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
  unfinished integer;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_picking_event(cleaned_key, 'picking_completed', target_request);
  if replay is not null then
    return app_private.picking_payload(replay);
  end if;

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.picking_write', 'on', true);
  header := app_private.lock_picking_request(target_request, expected_version);
  perform app_private.assert_picking_executor(header);

  if header.status is distinct from 'picking' then
    raise exception 'picking cannot complete from %', header.status
      using errcode = '23514';
  end if;

  select count(*)::integer
  into unfinished
  from public.stock_reservations
  where picking_request_id = header.id
    and status = 'active'
    and picked_cases is distinct from reserved_cases;

  if unfinished > 0 then
    raise exception 'every reservation must be fully picked or have a shortage recorded'
      using errcode = '23514';
  end if;

  update public.stock_picking_requests
  set
    status = 'picked',
    completed_by = auth.uid(),
    completed_at = pg_catalog.clock_timestamp(),
    version = header.version + 1
  where id = header.id;

  perform app_private.picking_event(
    header.id, 'picking_completed', 'picking', 'picked', header.version + 1,
    '{}'::jsonb, cleaned_key
  );

  return app_private.picking_payload(header.id);
end;
$$;

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

create or replace function public.cancel_picking_request(
  target_request uuid,
  expected_version integer,
  cancel_reason text,
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
  header public.stock_picking_requests;
  replay uuid;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_picking_event(cleaned_key, 'cancelled', target_request);
  if replay is not null then
    return app_private.picking_payload(replay);
  end if;

  cleaned_reason := app_private.clean_optional_text(cancel_reason, 500);
  if cleaned_reason is null then
    raise exception 'cancellation reason is required' using errcode = '23514';
  end if;

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.picking_write', 'on', true);
  header := app_private.lock_picking_request(target_request, expected_version);
  perform app_private.assert_picking_manager(header.branch_id);

  if header.status in ('ready_for_dispatch') then
    raise exception 'ready-for-dispatch picking cannot be cancelled from M2'
      using errcode = '23514';
  end if;
  if header.status = 'cancelled' then
    return app_private.picking_payload(header.id);
  end if;
  if header.status not in ('allocated', 'picking', 'picked', 'blocked') then
    raise exception 'picking cannot be cancelled from %', header.status
      using errcode = '23514';
  end if;

  update public.stock_reservations
  set status = 'released'
  where picking_request_id = header.id
    and status = 'active';

  insert into public.stock_picking_exceptions (
    picking_request_id, exception_type, message, created_by
  )
  values (header.id, 'cancelled', cleaned_reason, auth.uid());

  update public.stock_picking_requests
  set
    status = 'cancelled',
    cancelled_by = auth.uid(),
    cancelled_at = pg_catalog.clock_timestamp(),
    cancellation_reason = cleaned_reason,
    version = header.version + 1
  where id = header.id;

  perform app_private.picking_event(
    header.id, 'cancelled', header.status, 'cancelled', header.version + 1,
    pg_catalog.jsonb_build_object('reason', cleaned_reason),
    cleaned_key
  );
  perform app_private.picking_event(
    header.id, 'reservation_released', header.status, 'cancelled', header.version + 1,
    '{}'::jsonb, null
  );

  return app_private.picking_payload(header.id);
end;
$$;

create or replace function public.get_picking_handoff(target_request uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  header public.stock_picking_requests;
  selected_order public.orders%rowtype;
begin
  select * into header
  from public.stock_picking_requests
  where id = target_request;

  if not found or not app_private.picking_can_view(header) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if header.status is distinct from 'ready_for_dispatch' then
    raise exception 'picking is not ready for dispatch' using errcode = '23514';
  end if;

  select * into selected_order from public.orders where id = header.order_id;

  return pg_catalog.jsonb_build_object(
    'picking_request_id', header.id,
    'request_number', header.request_number,
    'order_id', selected_order.id,
    'order_number', selected_order.order_number,
    'branch_id', header.branch_id,
    'status', header.status,
    'version', header.version,
    'stock_consumed', false,
    'reservation_state', 'held_until_dispatch',
    'handed_off_at', header.handed_off_at,
    'lines', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'order_line_id', order_lines.id,
        'product_id', order_lines.product_id,
        'sku', products.sku,
        'requested_cases', order_lines.requested_cases,
        'reserved_cases', coalesce(res.reserved_cases, 0),
        'picked_cases', coalesce(res.picked_cases, 0),
        'shortage_cases', greatest(order_lines.requested_cases - coalesce(res.picked_cases, 0), 0),
        'picks', coalesce(res.picks, '[]'::jsonb)
      ) order by order_lines.created_at)
      from public.order_lines
      join public.products on products.id = order_lines.product_id
      left join lateral (
        select
          coalesce(sum(stock_reservations.reserved_cases) filter (
            where stock_reservations.status = 'active'
          ), 0)::integer as reserved_cases,
          coalesce(sum(stock_reservations.picked_cases), 0)::integer as picked_cases,
          coalesce(jsonb_agg(pg_catalog.jsonb_build_object(
            'reservation_id', stock_reservations.id,
            'crate_id', stock_reservations.crate_id,
            'lot_id', stock_reservations.lot_id,
            'picked_cases', stock_reservations.picked_cases,
            'reserved_cases', stock_reservations.reserved_cases,
            'manufacturer_lot_code', stock_lots.manufacturer_lot_code,
            'expiry_date', stock_lots.expiry_date
          ) order by stock_reservations.created_at)
          filter (where stock_reservations.id is not null), '[]'::jsonb) as picks
        from public.stock_reservations
        join public.stock_lots on stock_lots.id = stock_reservations.lot_id
        where stock_reservations.picking_request_id = header.id
          and stock_reservations.order_line_id = order_lines.id
      ) res on true
      where order_lines.order_id = header.order_id
    ), '[]'::jsonb),
    'exceptions', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'exception_type', stock_picking_exceptions.exception_type,
        'message', stock_picking_exceptions.message,
        'quantity', stock_picking_exceptions.quantity
      ) order by stock_picking_exceptions.created_at)
      from public.stock_picking_exceptions
      where stock_picking_exceptions.picking_request_id = header.id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.list_picking_exceptions()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (
    app_private.has_permission('picking.manage')
    or app_private.has_permission('picking.allocate')
    or app_private.has_permission('operations.monitor')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', stock_picking_exceptions.id,
      'picking_request_id', header.id,
      'request_number', header.request_number,
      'order_number', orders.order_number,
      'exception_type', stock_picking_exceptions.exception_type,
      'message', stock_picking_exceptions.message,
      'quantity', stock_picking_exceptions.quantity,
      'created_at', stock_picking_exceptions.created_at
    ) order by stock_picking_exceptions.created_at desc)
    from public.stock_picking_exceptions
    join public.stock_picking_requests header
      on header.id = stock_picking_exceptions.picking_request_id
    join public.orders on orders.id = header.order_id
    where app_private.picking_can_view(header)
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.preview_order_allocation(uuid)
  from public, anon, service_role;
revoke all on function public.reserve_order_allocation(uuid, integer, text)
  from public, anon, service_role;
revoke all on function public.list_picking_requests(text)
  from public, anon, service_role;
revoke all on function public.get_picking_request(uuid)
  from public, anon, service_role;
revoke all on function public.assign_picking_request(uuid, uuid, integer, text)
  from public, anon, service_role;
revoke all on function public.start_picking(uuid, integer, text)
  from public, anon, service_role;
revoke all on function public.confirm_picking_quantity(uuid, uuid, integer, integer, text)
  from public, anon, service_role;
revoke all on function public.report_picking_shortage(uuid, uuid, integer, text, integer, text)
  from public, anon, service_role;
revoke all on function public.complete_picking(uuid, integer, text)
  from public, anon, service_role;
revoke all on function public.confirm_picking_handoff(uuid, integer, text)
  from public, anon, service_role;
revoke all on function public.cancel_picking_request(uuid, integer, text, text)
  from public, anon, service_role;
revoke all on function public.get_picking_handoff(uuid)
  from public, anon, service_role;
revoke all on function public.list_picking_exceptions()
  from public, anon, service_role;

grant execute on function public.preview_order_allocation(uuid) to authenticated;
grant execute on function public.reserve_order_allocation(uuid, integer, text) to authenticated;
grant execute on function public.list_picking_requests(text) to authenticated;
grant execute on function public.get_picking_request(uuid) to authenticated;
grant execute on function public.assign_picking_request(uuid, uuid, integer, text) to authenticated;
grant execute on function public.start_picking(uuid, integer, text) to authenticated;
grant execute on function public.confirm_picking_quantity(uuid, uuid, integer, integer, text) to authenticated;
grant execute on function public.report_picking_shortage(uuid, uuid, integer, text, integer, text) to authenticated;
grant execute on function public.complete_picking(uuid, integer, text) to authenticated;
grant execute on function public.confirm_picking_handoff(uuid, integer, text) to authenticated;
grant execute on function public.cancel_picking_request(uuid, integer, text, text) to authenticated;
grant execute on function public.get_picking_handoff(uuid) to authenticated;
grant execute on function public.list_picking_exceptions() to authenticated;

comment on function public.preview_order_allocation(uuid) is
  'Advisory FEFO/FIFO plan. Recomputed under lock at reserve time. Fails closed when dual-write is off.';

comment on function public.reserve_order_allocation(uuid, integer, text) is
  'Confirms a full-line FEFO/FIFO reservation. Does not write stock_ledger.';

comment on function public.get_picking_handoff(uuid) is
  'M3 contract: ready_for_dispatch picks, shortages, and held reservations. Stock is not consumed.';

-- M3 must call this before any stock-reducing dispatch posting. Delivery notes
-- remain Phase 4.2 paperwork and do not consume reservations or ledger.
create or replace function app_private.assert_picking_handoff_for_dispatch(target_order uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  header public.stock_picking_requests;
begin
  if target_order is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into header
  from public.stock_picking_requests
  where stock_picking_requests.order_id = target_order
    and stock_picking_requests.status = 'ready_for_dispatch'
  order by stock_picking_requests.handed_off_at desc, stock_picking_requests.id
  limit 1;

  if not found then
    raise exception 'dispatch requires a ready_for_dispatch picking handoff'
      using errcode = '23514';
  end if;

  return header.id;
end;
$$;

revoke all on function app_private.assert_picking_handoff_for_dispatch(uuid)
  from public, anon, authenticated, service_role;

comment on function app_private.assert_picking_handoff_for_dispatch(uuid) is
  'M3 gate: stock-reducing dispatch posting must not run without a ready_for_dispatch handoff. Not used by delivery-note paperwork.';

-- ---------------------------------------------------------------------------
-- 8. Order cancel releases allocated/picking holds
-- ---------------------------------------------------------------------------

create or replace function public.cancel_order(
  target_order uuid,
  expected_version integer,
  cancellation_reason text,
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
  selected public.orders%rowtype;
  existing_event public.order_events%rowtype;
  open_note public.delivery_notes%rowtype;
  picking public.stock_picking_requests%rowtype;
  is_creator boolean;
  is_accounts boolean;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select *
  into selected
  from public.orders
  where orders.id = target_order
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into picking
  from public.stock_picking_requests
  where stock_picking_requests.order_id = selected.id
    and stock_picking_requests.status is distinct from 'cancelled'
  for update;

  if found then
    if picking.status in ('picking', 'picked', 'ready_for_dispatch') then
      raise exception 'cancel picking or finish dispatch before cancelling this order'
        using errcode = '23514';
    end if;
  end if;

  open_note := app_private.lock_open_delivery_note_for_order(selected.id);
  if open_note.id is not null then
    if open_note.status = 'acknowledged' then
      raise exception 'order cannot be cancelled while an acknowledged delivery note exists'
        using errcode = '23514';
    end if;

    raise exception
      'void the active delivery note before cancelling this order'
      using errcode = '23514';
  end if;

  is_creator := selected.created_by = (select auth.uid())
    and (select app_private.has_permission('orders.capture'));
  is_accounts := (select app_private.has_permission('orders.verify'))
    and (select app_private.can_work_at_branch(selected.branch_id));

  select *
  into existing_event
  from public.order_events
  where order_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.order_id is distinct from selected.id
      or existing_event.event_type is distinct from 'cancelled'
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;
    return public.get_order(selected.id);
  end if;

  if selected.status = 'cancelled' then
    raise exception 'order cannot change from cancelled to cancelled'
      using errcode = '23514';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'order was changed by someone else' using errcode = '40001';
  end if;

  if selected.status in ('draft', 'held') then
    if not is_creator then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    cleaned_reason := app_private.clean_optional_order_text(cancellation_reason, 500);
  elsif selected.status in ('submitted', 'verified') then
    if not is_accounts then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    cleaned_reason := app_private.clean_required_order_text(cancellation_reason, 500);
  else
    raise exception 'order cannot change from % to cancelled', selected.status
      using errcode = '23514';
  end if;

  if picking.id is not null and picking.status = 'allocated' then
    perform set_config('app.picking_write', 'on', true);
    update public.stock_reservations
    set status = 'released'
    where picking_request_id = picking.id
      and status = 'active';
    update public.stock_picking_requests
    set
      status = 'cancelled',
      cancelled_by = auth.uid(),
      cancelled_at = pg_catalog.clock_timestamp(),
      cancellation_reason = cleaned_reason,
      version = picking.version + 1
    where id = picking.id;
    perform app_private.picking_event(
      picking.id, 'cancelled', 'allocated', 'cancelled', picking.version + 1,
      pg_catalog.jsonb_build_object('reason', 'order cancelled'),
      null
    );
  end if;

  update public.orders
  set
    status = 'cancelled',
    cancelled_at = pg_catalog.clock_timestamp(),
    cancelled_by = (select auth.uid()),
    cancellation_reason = cleaned_reason,
    version = selected.version + 1
  where orders.id = selected.id;

  insert into public.order_events (
    order_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    note,
    version,
    idempotency_key,
    line_snapshot
  )
  values (
    selected.id,
    'cancelled',
    selected.status,
    'cancelled',
    (select auth.uid()),
    cleaned_reason,
    selected.version + 1,
    cleaned_key,
    app_private.current_order_line_snapshot(selected.id)
  );

  return public.get_order(selected.id);
end;
$$;
