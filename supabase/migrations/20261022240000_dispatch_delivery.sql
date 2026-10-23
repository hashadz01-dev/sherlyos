-- M3: Dispatch sidecar, atomic stock consumption, and physical delivery tracking.
-- Forward-only after 20261022230000. Local-first. Does not seed inventory,
-- attribute lots, or flip cutover flags. Phase 4.2 delivery notes stay paperwork.
-- Orders stay on draft|submitted|held|verified|cancelled.

-- ---------------------------------------------------------------------------
-- 1. Permissions
-- ---------------------------------------------------------------------------

insert into public.permissions (code, description)
values
  (
    'dispatch.view',
    'View the dispatch queue, dispatch detail, and delivery history for authorized godowns.'
  ),
  (
    'dispatch.confirm',
    'Confirm dispatch and consume reserved carton cases through the trusted stock writer.'
  ),
  (
    'dispatch.exception',
    'Record a failed delivery. Does not restore inventory.'
  ),
  (
    'dispatch.history',
    'Read dispatch and delivery audit history for authorized godowns.'
  )
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from (
  values
    ('admin', 'dispatch.view'),
    ('admin', 'dispatch.confirm'),
    ('admin', 'dispatch.exception'),
    ('admin', 'dispatch.history'),
    ('godown_manager', 'dispatch.view'),
    ('godown_manager', 'dispatch.confirm'),
    ('godown_manager', 'dispatch.exception'),
    ('godown_manager', 'dispatch.history')
) as grants (role_code, permission_code)
join public.roles on roles.code = grants.role_code
join public.permissions on permissions.code = grants.permission_code
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. Reservation consumption status (still counted only while active)
-- ---------------------------------------------------------------------------

alter table public.stock_reservations
  drop constraint stock_reservations_status_check;

alter table public.stock_reservations
  add constraint stock_reservations_status_check check (
    status in ('active', 'released', 'consumed')
  );

comment on table public.stock_reservations is
  'M2/M3. Active rows hold reserved_cases against on-hand lot×crate stock. released = picking cancelled. consumed = dispatched in the same transaction as the ledger debit. picked_cases is warehouse confirmation only.';

-- Reservation DML during dispatch uses app.dispatch_write. Picking RPCs keep app.picking_write.
create or replace function app_private.guard_picking_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_name = 'stock_reservations' then
    if pg_catalog.current_setting('app.picking_write', true) is distinct from 'on'
      and pg_catalog.current_setting('app.dispatch_write', true) is distinct from 'on'
    then
      raise exception 'picking records cannot be changed directly'
        using errcode = '42501';
    end if;
    return coalesce(new, old);
  end if;

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

-- ---------------------------------------------------------------------------
-- 3. Dispatch sidecar
-- ---------------------------------------------------------------------------

create sequence public.stock_dispatch_request_seq;

revoke all on sequence public.stock_dispatch_request_seq
  from public, anon, authenticated, service_role;

create table public.stock_dispatch_requests (
  id uuid primary key default gen_random_uuid(),
  request_number text not null,
  order_id uuid not null references public.orders (id) on delete restrict,
  picking_request_id uuid not null
    references public.stock_picking_requests (id) on delete restrict,
  delivery_note_id uuid references public.delivery_notes (id) on delete restrict,
  branch_id uuid not null references public.branches (id) on delete restrict,
  status text not null,
  version integer not null default 1,
  stock_consumed boolean not null default false,
  posted_transaction_id uuid,
  dispatched_by uuid references public.profiles (id) on delete restrict,
  dispatched_at timestamptz,
  assigned_to uuid references public.profiles (id) on delete restrict,
  assigned_by uuid references public.profiles (id) on delete restrict,
  assigned_at timestamptz,
  in_transit_at timestamptz,
  delivered_at timestamptz,
  exception_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id) on delete restrict,
  cancellation_reason text,
  exception_reason text,
  physical_return_status text,
  recipient_name text,
  acknowledgement_notes text,
  acknowledged_at timestamptz,
  acknowledged_by uuid references public.profiles (id) on delete restrict,
  created_by uuid not null references public.profiles (id) on delete restrict,
  idempotency_key text not null,
  request_fingerprint text not null,
  confirm_idempotency_key text,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint stock_dispatch_requests_number_key unique (request_number),
  constraint stock_dispatch_requests_idempotency_key unique (idempotency_key),
  constraint stock_dispatch_requests_status_check check (
    status in (
      'preparing',
      'dispatched',
      'in_transit',
      'delivered',
      'exception',
      'cancelled'
    )
  ),
  constraint stock_dispatch_requests_version_check check (version >= 1),
  constraint stock_dispatch_requests_consumed_shape check (
    (stock_consumed = false and posted_transaction_id is null and dispatched_at is null)
    or (
      stock_consumed = true
      and posted_transaction_id is not null
      and dispatched_at is not null
      and dispatched_by is not null
      and status in ('dispatched', 'in_transit', 'delivered', 'exception')
    )
  ),
  constraint stock_dispatch_requests_cancel_shape check (
    status <> 'cancelled'
    or (
      stock_consumed = false
      and cancelled_at is not null
      and cancelled_by is not null
      and cancellation_reason is not null
    )
  ),
  constraint stock_dispatch_requests_return_check check (
    physical_return_status is null
    or physical_return_status in ('pending_verification')
  ),
  constraint stock_dispatch_requests_exception_shape check (
    status <> 'exception'
    or (
      stock_consumed = true
      and exception_at is not null
      and exception_reason is not null
      and physical_return_status = 'pending_verification'
    )
  ),
  constraint stock_dispatch_requests_delivered_shape check (
    status <> 'delivered'
    or (
      stock_consumed = true
      and delivered_at is not null
      and acknowledged_at is not null
      and acknowledged_by is not null
      and recipient_name is not null
    )
  ),
  constraint stock_dispatch_requests_reason_length check (
    cancellation_reason is null
    or (
      char_length(btrim(cancellation_reason)) between 1 and 500
      and cancellation_reason = btrim(cancellation_reason)
    )
  ),
  constraint stock_dispatch_requests_exception_length check (
    exception_reason is null
    or (
      char_length(btrim(exception_reason)) between 1 and 500
      and exception_reason = btrim(exception_reason)
    )
  ),
  constraint stock_dispatch_requests_recipient_length check (
    recipient_name is null
    or (
      char_length(btrim(recipient_name)) between 1 and 120
      and recipient_name = btrim(recipient_name)
    )
  ),
  constraint stock_dispatch_requests_ack_notes_length check (
    acknowledgement_notes is null
    or (
      char_length(btrim(acknowledgement_notes)) between 1 and 500
      and acknowledgement_notes = btrim(acknowledgement_notes)
    )
  )
);

comment on table public.stock_dispatch_requests is
  'M3 sidecar. One physical dispatch per picking handoff. Stock consumption is stock_consumed plus posted_transaction_id. Delivery-note FK is optional paperwork only.';

create unique index stock_dispatch_requests_picking_active_idx
  on public.stock_dispatch_requests (picking_request_id)
  where status is distinct from 'cancelled';

create unique index stock_dispatch_requests_picking_consumed_idx
  on public.stock_dispatch_requests (picking_request_id)
  where stock_consumed;

create unique index stock_dispatch_requests_order_active_idx
  on public.stock_dispatch_requests (order_id)
  where status is distinct from 'cancelled';

create unique index stock_dispatch_requests_confirm_key_idx
  on public.stock_dispatch_requests (confirm_idempotency_key)
  where confirm_idempotency_key is not null;

create unique index stock_dispatch_requests_delivery_note_idx
  on public.stock_dispatch_requests (delivery_note_id)
  where delivery_note_id is not null and status is distinct from 'cancelled';

create index stock_dispatch_requests_branch_status_idx
  on public.stock_dispatch_requests (branch_id, status, created_at desc);

create index stock_dispatch_requests_assigned_idx
  on public.stock_dispatch_requests (assigned_to)
  where assigned_to is not null;

create trigger stock_dispatch_requests_set_updated_at
  before update on public.stock_dispatch_requests
  for each row execute function app_private.set_updated_at();

create table public.stock_dispatch_assignments (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid not null
    references public.stock_dispatch_requests (id) on delete restrict,
  assignee uuid not null references public.profiles (id) on delete restrict,
  assigned_by uuid not null references public.profiles (id) on delete restrict,
  assigned_at timestamptz not null default pg_catalog.clock_timestamp(),
  unassigned_at timestamptz,
  unassigned_by uuid references public.profiles (id) on delete restrict,
  reason text,
  constraint stock_dispatch_assignments_reason_length check (
    reason is null
    or (
      char_length(btrim(reason)) between 1 and 500
      and reason = btrim(reason)
    )
  )
);

comment on table public.stock_dispatch_assignments is
  'M3. Append-friendly assignment history. Current assignee also lives on stock_dispatch_requests.assigned_to.';

create index stock_dispatch_assignments_dispatch_idx
  on public.stock_dispatch_assignments (dispatch_id, assigned_at, id);

create table public.stock_dispatch_events (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid not null
    references public.stock_dispatch_requests (id) on delete restrict,
  event_type text not null,
  actor_id uuid not null,
  from_status text,
  to_status text not null,
  dispatch_version integer not null,
  payload jsonb not null default '{}'::jsonb,
  idempotency_key text,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_dispatch_events_type_check check (
    event_type in (
      'prepared',
      'cancelled',
      'dispatched',
      'assigned',
      'in_transit',
      'delivered',
      'exception_recorded'
    )
  ),
  constraint stock_dispatch_events_version_check check (dispatch_version >= 1)
);

create unique index stock_dispatch_events_idempotency_idx
  on public.stock_dispatch_events (idempotency_key)
  where idempotency_key is not null;

create index stock_dispatch_events_dispatch_idx
  on public.stock_dispatch_events (dispatch_id, created_at, id);

comment on table public.stock_dispatch_events is
  'M3. Append-only dispatch and delivery history. Rows cannot be updated or deleted.';

-- ---------------------------------------------------------------------------
-- 4. DISPATCH stock transaction shape
-- ---------------------------------------------------------------------------

alter table public.stock_transactions
  add column dispatch_request_id uuid
    references public.stock_dispatch_requests (id) on delete restrict;

alter table public.stock_dispatch_requests
  add constraint stock_dispatch_requests_transaction_fk
  foreign key (posted_transaction_id) references public.stock_transactions (id)
  on delete restrict;

alter table public.stock_transactions
  drop constraint stock_transactions_type_check,
  add constraint stock_transactions_type_check
    check (transaction_type in (
      'OPENING_STOCK', 'CRATE_TRANSFER', 'RECEIPT', 'ADJUSTMENT', 'DISPATCH'
    ));

alter table public.stock_transactions
  drop constraint stock_transactions_shape_check,
  add constraint stock_transactions_shape_check check (
    (
      transaction_type = 'OPENING_STOCK'
      and source_crate_id is null
      and destination_crate_id is not null
      and receipt_id is null
      and receipt_line_id is null
      and adjustment_request_id is null
      and dispatch_request_id is null
    )
    or (
      transaction_type = 'CRATE_TRANSFER'
      and source_crate_id is not null
      and destination_crate_id is not null
      and source_crate_id <> destination_crate_id
      and receipt_id is null
      and receipt_line_id is null
      and adjustment_request_id is null
      and dispatch_request_id is null
    )
    or (
      transaction_type = 'RECEIPT'
      and source_crate_id is null
      and destination_crate_id is not null
      and receipt_id is not null
      and receipt_line_id is not null
      and adjustment_request_id is null
      and dispatch_request_id is null
    )
    or (
      transaction_type = 'ADJUSTMENT'
      and source_crate_id is null
      and receipt_id is null
      and receipt_line_id is null
      and adjustment_request_id is not null
      and dispatch_request_id is null
    )
    or (
      transaction_type = 'DISPATCH'
      and destination_crate_id is null
      and receipt_id is null
      and receipt_line_id is null
      and adjustment_request_id is null
      and dispatch_request_id is not null
    )
  );

create unique index stock_transactions_dispatch_once
  on public.stock_transactions (dispatch_request_id)
  where dispatch_request_id is not null;

-- DISPATCH has no destination crate. Keep stock.read visibility on the godown.
drop policy if exists stock_transactions_select_authorized on public.stock_transactions;
create policy stock_transactions_select_authorized
  on public.stock_transactions
  for select
  to authenticated
  using (
    (select app_private.has_permission('stock.read'))
    and (
      exists (
        select 1
        from public.crates
        join public.zones on zones.id = crates.zone_id
        where crates.id = stock_transactions.destination_crate_id
          and (select app_private.can_work_at_branch(zones.branch_id))
      )
      or exists (
        select 1
        from public.crates
        join public.zones on zones.id = crates.zone_id
        where crates.id = stock_transactions.source_crate_id
          and (select app_private.can_work_at_branch(zones.branch_id))
      )
      or exists (
        select 1
        from public.stock_dispatch_requests
        where stock_dispatch_requests.id = stock_transactions.dispatch_request_id
          and (select app_private.can_work_at_branch(stock_dispatch_requests.branch_id))
      )
    )
  );

create or replace function app_private.assert_stock_transaction_complete()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  selected_type text;
  entry_count integer;
  entry_sum integer;
  linked_receipt uuid;
  linked_line uuid;
  linked_adjustment uuid;
  linked_dispatch uuid;
  header_qty integer;
  line_count integer;
  line_sum integer;
begin
  select
    stock_transactions.transaction_type,
    stock_transactions.receipt_id,
    stock_transactions.receipt_line_id,
    stock_transactions.adjustment_request_id,
    stock_transactions.dispatch_request_id,
    stock_transactions.quantity
  into selected_type, linked_receipt, linked_line, linked_adjustment, linked_dispatch, header_qty
  from public.stock_transactions
  where stock_transactions.id = new.transaction_id;

  select count(*), coalesce(sum(stock_ledger.quantity), 0)
  into entry_count, entry_sum
  from public.stock_ledger
  where stock_ledger.transaction_id = new.transaction_id;

  if selected_type = 'OPENING_STOCK' and (entry_count <> 1 or entry_sum <= 0) then
    raise exception 'opening stock ledger is incomplete' using errcode = '23514';
  end if;

  if selected_type = 'CRATE_TRANSFER' and (entry_count <> 2 or entry_sum <> 0) then
    raise exception 'transfer ledger must net to zero' using errcode = '23514';
  end if;

  if selected_type = 'RECEIPT' and (
    entry_count <> 1
    or entry_sum <= 0
    or linked_receipt is null
    or linked_line is null
  ) then
    raise exception 'receipt ledger is incomplete' using errcode = '23514';
  end if;

  if selected_type = 'ADJUSTMENT' then
    select count(*), coalesce(sum(stock_adjustment_lines.requested_cases), 0)
    into line_count, line_sum
    from public.stock_adjustment_lines
    where stock_adjustment_lines.request_id = linked_adjustment
      and not stock_adjustment_lines.released;

    if linked_adjustment is null or entry_count <> line_count or entry_sum is distinct from line_sum or entry_count < 1 then
      raise exception 'adjustment ledger is incomplete' using errcode = '23514';
    end if;
  end if;

  if selected_type = 'DISPATCH' then
    if linked_dispatch is null
      or entry_count < 1
      or entry_sum >= 0
      or entry_sum is distinct from (- header_qty)
    then
      raise exception 'dispatch ledger is incomplete' using errcode = '23514';
    end if;
  end if;

  if selected_type not in ('OPENING_STOCK', 'CRATE_TRANSFER', 'RECEIPT', 'ADJUSTMENT', 'DISPATCH') then
    raise exception 'stock transaction type is not supported' using errcode = '23514';
  end if;

  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Write guards, transitions, RLS
-- ---------------------------------------------------------------------------

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

  if tg_table_name = 'stock_dispatch_events' and tg_op <> 'INSERT' then
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
    then
      raise exception 'assignment history cannot be rewritten' using errcode = '42501';
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

revoke all on function app_private.guard_dispatch_write()
  from public, anon, authenticated, service_role;

create trigger stock_dispatch_requests_guard
  before insert or update or delete on public.stock_dispatch_requests
  for each row execute function app_private.guard_dispatch_write();

create trigger stock_dispatch_assignments_guard
  before insert or update or delete on public.stock_dispatch_assignments
  for each row execute function app_private.guard_dispatch_write();

create trigger stock_dispatch_events_guard
  before insert or update or delete on public.stock_dispatch_events
  for each row execute function app_private.guard_dispatch_write();

alter table public.stock_dispatch_requests enable row level security;
alter table public.stock_dispatch_requests force row level security;
alter table public.stock_dispatch_assignments enable row level security;
alter table public.stock_dispatch_assignments force row level security;
alter table public.stock_dispatch_events enable row level security;
alter table public.stock_dispatch_events force row level security;

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
  if not app_private.can_work_at_branch(header.branch_id) then
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

revoke all on function app_private.dispatch_can_view(public.stock_dispatch_requests)
  from public, anon, service_role;
grant execute on function app_private.dispatch_can_view(public.stock_dispatch_requests)
  to authenticated;

create policy stock_dispatch_requests_select_authorized
  on public.stock_dispatch_requests
  for select
  to authenticated
  using ((select app_private.dispatch_can_view(stock_dispatch_requests)));

create policy stock_dispatch_assignments_select_authorized
  on public.stock_dispatch_assignments
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.stock_dispatch_requests header
      where header.id = stock_dispatch_assignments.dispatch_id
    )
  );

create policy stock_dispatch_events_select_authorized
  on public.stock_dispatch_events
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.stock_dispatch_requests header
      where header.id = stock_dispatch_events.dispatch_id
    )
  );

revoke all on table public.stock_dispatch_requests
  from public, anon, authenticated, service_role;
revoke all on table public.stock_dispatch_assignments
  from public, anon, authenticated, service_role;
revoke all on table public.stock_dispatch_events
  from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate
  on table public.stock_dispatch_requests from service_role;
revoke insert, update, delete, truncate
  on table public.stock_dispatch_assignments from service_role;
revoke insert, update, delete, truncate
  on table public.stock_dispatch_events from service_role;
grant select on table public.stock_dispatch_requests to authenticated;
grant select on table public.stock_dispatch_assignments to authenticated;
grant select on table public.stock_dispatch_events to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Private helpers
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_dispatch_confirmer(target_branch uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('dispatch.confirm');
  if not app_private.can_work_at_branch(target_branch) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_dispatch_confirmer(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_dispatch_assigner(target_branch uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('deliveries.assign');
  if not app_private.can_work_at_branch(target_branch) then
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
  if not app_private.can_work_at_branch(header.branch_id) then
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

create or replace function app_private.dispatch_cutover_blockers()
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

  if not coalesce(dual_write, false) then
    blockers := array_append(
      blockers,
      'Lot-aware dispatch requires dual-write to be enabled. Aggregate-only stock has no valid lot identities.'
    );
  end if;
  if coalesce(blocked, false) and not coalesce(dual_write, false) then
    blockers := array_append(
      blockers,
      'Aggregate posting is blocked until lot-aware dual-write is enabled.'
    );
  end if;
  return blockers;
end;
$$;

revoke all on function app_private.dispatch_cutover_blockers()
  from public, anon, authenticated, service_role;

create or replace function app_private.dispatch_reservation_fingerprint(p_picking uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select md5(coalesce(string_agg(
    stock_reservations.id::text
      || ':' || stock_reservations.lot_id::text
      || ':' || stock_reservations.crate_id::text
      || ':' || stock_reservations.reserved_cases::text,
    '|'
    order by stock_reservations.crate_id, stock_reservations.lot_id, stock_reservations.id
  ), ''))
  from public.stock_reservations
  where stock_reservations.picking_request_id = p_picking
    and stock_reservations.status = 'active';
$$;

revoke all on function app_private.dispatch_reservation_fingerprint(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.dispatch_event(
  target_dispatch uuid,
  event_type text,
  from_status text,
  to_status text,
  dispatch_version integer,
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
  insert into public.stock_dispatch_events (
    dispatch_id, event_type, actor_id, from_status, to_status,
    dispatch_version, payload, idempotency_key
  )
  values (
    target_dispatch, event_type, auth.uid(), from_status, to_status,
    dispatch_version, coalesce(payload, '{}'::jsonb), idempotency_key
  )
  returning id into created;
  return created;
end;
$$;

revoke all on function app_private.dispatch_event(uuid, text, text, text, integer, jsonb, text)
  from public, anon, authenticated, service_role;

create or replace function app_private.replay_dispatch_event(
  cleaned_key text,
  expected_type text,
  target_dispatch uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  existing public.stock_dispatch_events%rowtype;
begin
  if cleaned_key is null then
    return null;
  end if;

  select *
  into existing
  from public.stock_dispatch_events
  where stock_dispatch_events.idempotency_key = cleaned_key;

  if not found then
    return null;
  end if;

  if existing.event_type is distinct from expected_type
    or existing.dispatch_id is distinct from target_dispatch
  then
    raise exception 'idempotency key does not match the original request'
      using errcode = '23514';
  end if;

  return existing.dispatch_id;
end;
$$;

revoke all on function app_private.replay_dispatch_event(text, text, uuid)
  from public, anon, authenticated, service_role;

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
begin
  select * into header
  from public.stock_dispatch_requests
  where id = target_dispatch;

  if not found or not app_private.dispatch_can_view(header) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select * into selected_order from public.orders where id = header.order_id;
  select * into picking from public.stock_picking_requests where id = header.picking_request_id;

  return pg_catalog.jsonb_build_object(
    'id', header.id,
    'request_number', header.request_number,
    'order_id', header.order_id,
    'order_number', selected_order.order_number,
    'order_status', selected_order.status,
    'order_version', selected_order.version,
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
    'status', header.status,
    'version', header.version,
    'stock_consumed', header.stock_consumed,
    'posted_transaction_id', header.posted_transaction_id,
    'physical_return_status', header.physical_return_status,
    'assigned_to', header.assigned_to,
    'assigned_to_name', (
      select profiles.full_name from public.profiles where profiles.id = header.assigned_to
    ),
    'assigned_at', header.assigned_at,
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
      select sum(stock_reservations.reserved_cases)::integer
      from public.stock_reservations
      where stock_reservations.picking_request_id = header.picking_request_id
        and stock_reservations.status in ('active', 'consumed')
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
    'assignments', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_dispatch_assignments.id,
        'assignee', stock_dispatch_assignments.assignee,
        'assignee_name', profiles.full_name,
        'assigned_by', stock_dispatch_assignments.assigned_by,
        'assigned_at', stock_dispatch_assignments.assigned_at,
        'unassigned_at', stock_dispatch_assignments.unassigned_at,
        'reason', stock_dispatch_assignments.reason
      ) order by stock_dispatch_assignments.assigned_at, stock_dispatch_assignments.id)
      from public.stock_dispatch_assignments
      join public.profiles on profiles.id = stock_dispatch_assignments.assignee
      where stock_dispatch_assignments.dispatch_id = header.id
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

revoke all on function app_private.dispatch_payload(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_dispatch_handoff_ready(
  selected public.orders,
  picking public.stock_picking_requests
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  handoff uuid;
  cutover text[];
  mismatch integer;
  blocking integer;
  unclassified integer;
  bad_lot integer;
begin
  if selected.status is distinct from 'verified' then
    raise exception 'dispatch requires a verified order' using errcode = '23514';
  end if;

  cutover := app_private.dispatch_cutover_blockers();
  if coalesce(pg_catalog.array_length(cutover, 1), 0) > 0 then
    raise exception '%', cutover[1] using errcode = '23514';
  end if;

  handoff := app_private.assert_picking_handoff_for_dispatch(selected.id);
  if handoff is distinct from picking.id then
    raise exception 'dispatch picking request does not match the ready_for_dispatch handoff'
      using errcode = '23514';
  end if;

  if picking.branch_id is distinct from selected.branch_id then
    raise exception 'picking godown does not match the order' using errcode = '23514';
  end if;

  select count(*)
  into mismatch
  from public.order_lines
  where order_lines.order_id = selected.id
    and order_lines.requested_cases is distinct from (
      select coalesce(sum(stock_reservations.reserved_cases), 0)
      from public.stock_reservations
      where stock_reservations.order_line_id = order_lines.id
        and stock_reservations.status = 'active'
    );

  if mismatch > 0 then
    raise exception 'dispatch quantities do not match the verified order'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.stock_reservations
    where stock_reservations.picking_request_id = picking.id
      and stock_reservations.status = 'active'
      and stock_reservations.picked_cases is distinct from stock_reservations.reserved_cases
  ) then
    raise exception 'dispatch requires every reserved carton to be picked'
      using errcode = '23514';
  end if;

  if not exists (
    select 1
    from public.stock_reservations
    where stock_reservations.picking_request_id = picking.id
      and stock_reservations.status = 'active'
  ) then
    raise exception 'dispatch requires active reservations' using errcode = '23514';
  end if;

  select count(*)
  into blocking
  from public.stock_picking_exceptions
  where stock_picking_exceptions.picking_request_id = picking.id
    and stock_picking_exceptions.exception_type in (
      'shortage',
      'expired_stock',
      'unknown_legacy',
      'unclassified',
      'cutover_blocked',
      'conflict'
    );

  if blocking > 0 then
    raise exception 'dispatch is blocked by unresolved picking exceptions'
      using errcode = '23514';
  end if;

  select count(*)
  into unclassified
  from public.order_lines
  join public.products on products.id = order_lines.product_id
  where order_lines.order_id = selected.id
    and products.expiry_policy is null;

  if unclassified > 0 then
    raise exception 'dispatch requires classified products' using errcode = '23514';
  end if;

  select count(*)
  into bad_lot
  from public.stock_reservations
  join public.stock_lots on stock_lots.id = stock_reservations.lot_id
  join public.products on products.id = stock_reservations.product_id
  join public.crates on crates.id = stock_reservations.crate_id
  join public.zones on zones.id = crates.zone_id
  where stock_reservations.picking_request_id = picking.id
    and stock_reservations.status = 'active'
    and (
      stock_lots.status is distinct from 'available'
      or zones.branch_id is distinct from picking.branch_id
      or stock_lots.branch_id is distinct from picking.branch_id
      or (
        products.expiry_policy = 'expiry_controlled'
        and (stock_lots.expiry_date is null or stock_lots.expiry_date < current_date)
      )
    );

  if bad_lot > 0 then
    raise exception 'dispatch reservations are not valid lot identities'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.assert_dispatch_handoff_ready(
  public.orders, public.stock_picking_requests
)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Public RPCs
-- ---------------------------------------------------------------------------

create or replace function public.preview_dispatch(target_order uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  selected public.orders%rowtype;
  picking public.stock_picking_requests%rowtype;
  existing public.stock_dispatch_requests%rowtype;
  blockers text[] := '{}';
  cutover text[];
  eligible boolean := true;
  note public.delivery_notes%rowtype;
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select * into selected from public.orders where orders.id = target_order;
  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if not (
    app_private.has_permission('dispatch.view')
    or app_private.has_permission('dispatch.confirm')
    or app_private.has_permission('operations.monitor')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if not app_private.can_work_at_branch(selected.branch_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  cutover := app_private.dispatch_cutover_blockers();
  blockers := blockers || cutover;

  select * into picking
  from public.stock_picking_requests
  where stock_picking_requests.order_id = selected.id
    and stock_picking_requests.status = 'ready_for_dispatch'
  order by stock_picking_requests.handed_off_at desc, stock_picking_requests.id
  limit 1;

  if not found then
    eligible := false;
    blockers := array_append(blockers, 'Dispatch requires a ready_for_dispatch picking handoff.');
  else
    begin
      perform app_private.assert_dispatch_handoff_ready(selected, picking);
    exception
      when sqlstate '23514' then
        eligible := false;
        -- Handoff re-raises the first cutover blocker; keep the advisory list unique.
        if coalesce(pg_catalog.array_length(blockers, 1), 0) = 0
          or sqlerrm <> all (blockers)
        then
          blockers := array_append(blockers, sqlerrm);
        end if;
    end;
  end if;

  select * into existing
  from public.stock_dispatch_requests
  where stock_dispatch_requests.order_id = selected.id
    and stock_dispatch_requests.status is distinct from 'cancelled'
  order by stock_dispatch_requests.created_at desc
  limit 1;

  select * into note
  from public.delivery_notes
  where delivery_notes.order_id = selected.id
    and delivery_notes.status is distinct from 'voided'
  order by delivery_notes.created_at desc
  limit 1;

  if existing.id is not null and existing.stock_consumed then
    eligible := false;
    blockers := array_append(blockers, 'Stock for this picking request was already consumed.');
  end if;

  return pg_catalog.jsonb_build_object(
    'order_id', selected.id,
    'order_number', selected.order_number,
    'order_status', selected.status,
    'order_version', selected.version,
    'branch_id', selected.branch_id,
    'shop_id', selected.shop_id,
    'picking_request_id', picking.id,
    'picking_request_number', picking.request_number,
    'picking_status', picking.status,
    'picking_version', picking.version,
    'dispatch_id', existing.id,
    'dispatch_number', existing.request_number,
    'dispatch_status', existing.status,
    'dispatch_version', existing.version,
    'stock_consumed', coalesce(existing.stock_consumed, false),
    'delivery_note_id', note.id,
    'delivery_note_number', note.delivery_note_number,
    'delivery_note_status', note.status,
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
    'total_cases', coalesce((
      select sum(stock_reservations.reserved_cases)::integer
      from public.stock_reservations
      where stock_reservations.picking_request_id = picking.id
        and stock_reservations.status = 'active'
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
        'reserved_cases', stock_reservations.reserved_cases,
        'picked_cases', stock_reservations.picked_cases,
        'status', stock_reservations.status
      ) order by products.sku, crates.code, stock_lots.id)
      from public.stock_reservations
      join public.products on products.id = stock_reservations.product_id
      join public.crates on crates.id = stock_reservations.crate_id
      join public.zones on zones.id = crates.zone_id
      join public.stock_lots on stock_lots.id = stock_reservations.lot_id
      where stock_reservations.picking_request_id = picking.id
        and stock_reservations.status = 'active'
    ), '[]'::jsonb)
  );
end;
$$;

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

create or replace function public.confirm_dispatch(
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
  selected public.orders%rowtype;
  picking public.stock_picking_requests%rowtype;
  looked_up_order uuid;
  looked_up_picking uuid;
  crate_ids uuid[];
  fingerprint text;
  grain record;
  created_txn uuid;
  lot_deltas jsonb := '[]'::jsonb;
  total_cases integer := 0;
  first_product uuid;
  single_crate uuid;
  crate_count integer;
  txn_key text;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.dispatch_write', 'on', true);
  perform set_config('app.picking_write', 'on', true);

  -- Resolve keys first so row locks follow M1/M2 order:
  -- order → picking → dispatch → reservations → products → locations → lots → balances.
  select
    stock_dispatch_requests.order_id,
    stock_dispatch_requests.picking_request_id
  into looked_up_order, looked_up_picking
  from public.stock_dispatch_requests
  where stock_dispatch_requests.id = target_dispatch;

  if looked_up_order is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select * into selected
  from public.orders
  where orders.id = looked_up_order
  for update;

  select * into picking
  from public.stock_picking_requests
  where stock_picking_requests.id = looked_up_picking
  for update;

  select * into header
  from public.stock_dispatch_requests
  where stock_dispatch_requests.id = target_dispatch
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if header.order_id is distinct from selected.id
    or header.picking_request_id is distinct from picking.id
  then
    raise exception 'dispatch was changed by someone else' using errcode = 'PT409';
  end if;

  perform app_private.assert_dispatch_confirmer(header.branch_id);

  if header.confirm_idempotency_key is not null
    and header.confirm_idempotency_key is distinct from cleaned_key
    and header.stock_consumed
  then
    return app_private.dispatch_payload(header.id);
  end if;

  if header.confirm_idempotency_key is not distinct from cleaned_key
    and header.stock_consumed
  then
    return app_private.dispatch_payload(header.id);
  end if;

  if header.stock_consumed then
    return app_private.dispatch_payload(header.id);
  end if;

  if header.status is distinct from 'preparing' then
    raise exception 'dispatch cannot consume stock from status %', header.status
      using errcode = '23514';
  end if;

  if header.version is distinct from expected_version then
    raise exception 'dispatch was changed by someone else' using errcode = 'PT409';
  end if;

  perform app_private.assert_dispatch_handoff_ready(selected, picking);

  fingerprint := app_private.dispatch_reservation_fingerprint(picking.id);
  if fingerprint is distinct from header.request_fingerprint then
    raise exception 'idempotency key was already used for a different request'
      using errcode = '23514';
  end if;

  perform stock_reservations.id
  from public.stock_reservations
  where stock_reservations.picking_request_id = picking.id
    and stock_reservations.status = 'active'
  order by stock_reservations.crate_id, stock_reservations.lot_id, stock_reservations.id
  for update;

  -- Match apply_lot_aware_stock_deltas: products, then zones/crates, then lots, then balances.
  perform products.id
  from public.products
  where products.id in (
    select stock_reservations.product_id
    from public.stock_reservations
    where stock_reservations.picking_request_id = picking.id
      and stock_reservations.status = 'active'
  )
  order by products.id
  for update;

  select array_agg(distinct stock_reservations.crate_id order by stock_reservations.crate_id)
  into crate_ids
  from public.stock_reservations
  where stock_reservations.picking_request_id = picking.id
    and stock_reservations.status = 'active';

  if crate_ids is null or cardinality(crate_ids) < 1 then
    raise exception 'dispatch requires active reservations' using errcode = '23514';
  end if;

  perform app_private.prepare_stock_locations(crate_ids);

  perform stock_lots.id
  from public.stock_lots
  where stock_lots.id in (
    select stock_reservations.lot_id
    from public.stock_reservations
    where stock_reservations.picking_request_id = picking.id
      and stock_reservations.status = 'active'
  )
  order by stock_lots.id
  for update;

  perform stock_lot_balances.lot_id
  from public.stock_lot_balances
  join public.stock_reservations
    on stock_reservations.lot_id = stock_lot_balances.lot_id
   and stock_reservations.crate_id = stock_lot_balances.crate_id
  where stock_reservations.picking_request_id = picking.id
    and stock_reservations.status = 'active'
  order by stock_lot_balances.crate_id, stock_lot_balances.lot_id
  for update of stock_lot_balances;

  perform stock_balances.crate_id
  from public.stock_balances
  join public.stock_reservations
    on stock_reservations.crate_id = stock_balances.crate_id
   and stock_reservations.product_id = stock_balances.product_id
  where stock_reservations.picking_request_id = picking.id
    and stock_reservations.status = 'active'
  order by stock_balances.crate_id, stock_balances.product_id
  for update of stock_balances;

  perform app_private.assert_dispatch_handoff_ready(selected, picking);

  if exists (
    select 1
    from public.stock_reservations
    join public.stock_lot_balances
      on stock_lot_balances.lot_id = stock_reservations.lot_id
     and stock_lot_balances.crate_id = stock_reservations.crate_id
    where stock_reservations.picking_request_id = picking.id
      and stock_reservations.status = 'active'
      and stock_lot_balances.quantity < stock_reservations.reserved_cases
  ) then
    raise exception 'reserved cartons are no longer physically available'
      using errcode = '23514';
  end if;

  -- Release the hold first so reservation guards allow the debit in this same transaction.
  update public.stock_reservations
  set status = 'consumed'
  where picking_request_id = picking.id
    and status = 'active';

  select
    coalesce(sum(stock_reservations.reserved_cases), 0),
    (array_agg(stock_reservations.product_id order by stock_reservations.product_id))[1],
    count(distinct stock_reservations.crate_id),
    (array_agg(stock_reservations.crate_id order by stock_reservations.crate_id))[1]
  into total_cases, first_product, crate_count, single_crate
  from public.stock_reservations
  where stock_reservations.picking_request_id = picking.id
    and stock_reservations.status = 'consumed';

  if total_cases < 1 then
    raise exception 'dispatch requires active reservations' using errcode = '23514';
  end if;

  txn_key := 'dispatch:' || header.id::text;

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    notes, product_id, source_crate_id, quantity, dispatch_request_id
  )
  values (
    'DISPATCH',
    header.request_number,
    auth.uid(),
    txn_key,
    fingerprint,
    'Dispatch ' || header.request_number,
    first_product,
    case when crate_count = 1 then single_crate else null end,
    total_cases,
    header.id
  )
  returning id into created_txn;

  for grain in
    select
      stock_reservations.product_id,
      stock_reservations.crate_id,
      stock_reservations.lot_id,
      sum(stock_reservations.reserved_cases)::integer as reserved_cases
    from public.stock_reservations
    where stock_reservations.picking_request_id = picking.id
      and stock_reservations.status = 'consumed'
    group by stock_reservations.product_id, stock_reservations.crate_id, stock_reservations.lot_id
    order by stock_reservations.crate_id, stock_reservations.lot_id
  loop
    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
    )
    values (
      created_txn,
      grain.product_id,
      grain.crate_id,
      - grain.reserved_cases,
      auth.uid(),
      pg_catalog.clock_timestamp(),
      grain.lot_id
    );

    lot_deltas := lot_deltas || jsonb_build_array(jsonb_build_object(
      'product_id', grain.product_id,
      'lot_id', grain.lot_id,
      'crate_id', grain.crate_id,
      'quantity', - grain.reserved_cases
    ));
  end loop;

  perform app_private.apply_lot_aware_stock_deltas(created_txn, lot_deltas);

  update public.stock_dispatch_requests
  set
    status = 'dispatched',
    stock_consumed = true,
    posted_transaction_id = created_txn,
    dispatched_by = auth.uid(),
    dispatched_at = pg_catalog.clock_timestamp(),
    confirm_idempotency_key = cleaned_key,
    version = header.version + 1
  where id = header.id;

  perform app_private.dispatch_event(
    header.id, 'dispatched', 'preparing', 'dispatched', header.version + 1,
    pg_catalog.jsonb_build_object(
      'transaction_id', created_txn,
      'total_cases', total_cases,
      'fingerprint', fingerprint
    ),
    cleaned_key
  );

  perform app_private.write_audit(
    auth.uid(), 'confirm_dispatch', 'stock_dispatch_requests', header.id,
    pg_catalog.jsonb_build_object(
      'request_number', header.request_number,
      'transaction_id', created_txn,
      'total_cases', total_cases
    )
  );

  return app_private.dispatch_payload(header.id);
exception
  when unique_violation then
    if header.id is not null and exists (
      select 1
      from public.stock_dispatch_requests
      where stock_dispatch_requests.id = header.id
        and stock_dispatch_requests.stock_consumed
    ) then
      return app_private.dispatch_payload(header.id);
    end if;
    raise exception 'idempotency key was already used for a different request'
      using errcode = '23505';
end;
$$;

create or replace function public.cancel_dispatch(
  target_dispatch uuid,
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
  header public.stock_dispatch_requests;
  replay uuid;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_dispatch_event(cleaned_key, 'cancelled', target_dispatch);
  if replay is not null then
    return app_private.dispatch_payload(replay);
  end if;

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.dispatch_write', 'on', true);

  select * into header
  from public.stock_dispatch_requests
  where id = target_dispatch
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_dispatch_confirmer(header.branch_id);

  if header.version is distinct from expected_version then
    raise exception 'dispatch was changed by someone else' using errcode = 'PT409';
  end if;

  if header.stock_consumed or header.status is distinct from 'preparing' then
    raise exception 'only a preparing dispatch can be cancelled before stock consumption'
      using errcode = '23514';
  end if;

  cleaned_reason := btrim(coalesce(cancel_reason, ''));
  if char_length(cleaned_reason) not between 1 and 500 then
    raise exception 'cancellation reason is required' using errcode = '23514';
  end if;

  update public.stock_dispatch_requests
  set
    status = 'cancelled',
    cancelled_at = pg_catalog.clock_timestamp(),
    cancelled_by = auth.uid(),
    cancellation_reason = cleaned_reason,
    version = header.version + 1
  where id = header.id;

  perform app_private.dispatch_event(
    header.id, 'cancelled', 'preparing', 'cancelled', header.version + 1,
    pg_catalog.jsonb_build_object('reason', cleaned_reason),
    cleaned_key
  );

  perform app_private.write_audit(
    auth.uid(), 'cancel_dispatch', 'stock_dispatch_requests', header.id,
    pg_catalog.jsonb_build_object('reason', cleaned_reason)
  );

  return app_private.dispatch_payload(header.id);
end;
$$;

create or replace function public.assign_dispatch_delivery(
  target_dispatch uuid,
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
  header public.stock_dispatch_requests;
  replay uuid;
  worker public.profiles%rowtype;
  has_role boolean := false;
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

  if header.stock_consumed is distinct from true
    or header.status not in ('dispatched', 'in_transit')
  then
    raise exception 'delivery can be assigned only after stock consumption'
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

  if header.assigned_to is not distinct from assignee then
    perform app_private.dispatch_event(
      header.id, 'assigned', header.status, header.status, header.version,
      pg_catalog.jsonb_build_object('assignee', assignee, 'unchanged', true),
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
    dispatch_id, assignee, assigned_by
  )
  values (header.id, assignee, auth.uid());

  update public.stock_dispatch_requests
  set
    assigned_to = assignee,
    assigned_by = auth.uid(),
    assigned_at = pg_catalog.clock_timestamp(),
    version = header.version + 1
  where id = header.id;

  perform app_private.dispatch_event(
    header.id, 'assigned', header.status, header.status, header.version + 1,
    pg_catalog.jsonb_build_object('assignee', assignee),
    cleaned_key
  );

  perform app_private.write_audit(
    auth.uid(), 'assign_dispatch_delivery', 'stock_dispatch_requests', header.id,
    pg_catalog.jsonb_build_object('assignee', assignee)
  );

  return app_private.dispatch_payload(header.id);
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

  update public.stock_dispatch_requests
  set
    status = 'in_transit',
    in_transit_at = pg_catalog.clock_timestamp(),
    version = header.version + 1
  where id = header.id;

  perform app_private.dispatch_event(
    header.id, 'in_transit', 'dispatched', 'in_transit', header.version + 1,
    '{}'::jsonb,
    cleaned_key
  );

  return app_private.dispatch_payload(header.id);
end;
$$;

create or replace function public.acknowledge_dispatch_delivery(
  target_dispatch uuid,
  recipient_name text,
  acknowledgement_notes text,
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
  cleaned_name text;
  cleaned_notes text;
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

  update public.stock_dispatch_requests
  set
    status = 'delivered',
    recipient_name = cleaned_name,
    acknowledgement_notes = cleaned_notes,
    acknowledged_at = pg_catalog.clock_timestamp(),
    acknowledged_by = auth.uid(),
    delivered_at = pg_catalog.clock_timestamp(),
    version = header.version + 1
  where id = header.id;

  perform app_private.dispatch_event(
    header.id, 'delivered', header.status, 'delivered', header.version + 1,
    pg_catalog.jsonb_build_object('recipient_name', cleaned_name),
    cleaned_key
  );

  perform app_private.write_audit(
    auth.uid(), 'acknowledge_dispatch_delivery', 'stock_dispatch_requests', header.id,
    pg_catalog.jsonb_build_object('recipient_name', cleaned_name)
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
    and app_private.can_work_at_branch(header.branch_id)
  then
    can_report := true;
  end if;
  if app_private.has_permission('deliveries.execute')
    and header.assigned_to is not distinct from auth.uid()
    and app_private.can_work_at_branch(header.branch_id)
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

create or replace function public.get_dispatch_request(target_dispatch uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  return app_private.dispatch_payload(target_dispatch);
end;
$$;

create or replace function public.list_dispatch_queue(status_filter text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  cleaned text;
  rows jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  cleaned := nullif(btrim(coalesce(status_filter, '')), '');
  if cleaned is not null and cleaned not in (
    'ready_for_dispatch',
    'preparing',
    'dispatched',
    'in_transit',
    'delivered',
    'exception',
    'cancelled'
  ) then
    raise exception 'dispatch status filter is invalid' using errcode = '23514';
  end if;

  if cleaned is null or cleaned = 'ready_for_dispatch' then
    if app_private.has_permission('dispatch.view')
      or app_private.has_permission('dispatch.confirm')
      or app_private.has_permission('operations.monitor')
    then
      rows := rows || coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'kind', 'handoff',
          'id', stock_picking_requests.id,
          'request_number', stock_picking_requests.request_number,
          'order_id', orders.id,
          'order_number', orders.order_number,
          'branch_id', orders.branch_id,
          'status', 'ready_for_dispatch',
          'picking_version', stock_picking_requests.version,
          'created_at', stock_picking_requests.handed_off_at
        ) order by stock_picking_requests.handed_off_at desc, stock_picking_requests.id)
        from public.stock_picking_requests
        join public.orders on orders.id = stock_picking_requests.order_id
        where stock_picking_requests.status = 'ready_for_dispatch'
          and app_private.can_work_at_branch(orders.branch_id)
          and not exists (
            select 1
            from public.stock_dispatch_requests
            where stock_dispatch_requests.picking_request_id = stock_picking_requests.id
              and stock_dispatch_requests.status is distinct from 'cancelled'
          )
      ), '[]'::jsonb);
    end if;
  end if;

  rows := rows || coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'kind', 'dispatch',
      'id', header.id,
      'request_number', header.request_number,
      'order_id', header.order_id,
      'order_number', orders.order_number,
      'branch_id', header.branch_id,
      'status', header.status,
      'version', header.version,
      'stock_consumed', header.stock_consumed,
      'assigned_to', header.assigned_to,
      'assigned_to_name', profiles.full_name,
      'created_at', header.created_at
    ) order by header.updated_at desc, header.id)
    from public.stock_dispatch_requests header
    join public.orders on orders.id = header.order_id
    left join public.profiles on profiles.id = header.assigned_to
    where app_private.dispatch_can_view(header)
      and (
        cleaned is null
        or (cleaned = 'ready_for_dispatch' and header.status = 'preparing')
        or header.status = cleaned
      )
  ), '[]'::jsonb);

  return coalesce(rows, '[]'::jsonb);
end;
$$;

create or replace function public.list_assigned_deliveries()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if not (
    app_private.has_permission('deliveries.execute')
    or app_private.has_permission('deliveries.assign')
    or app_private.has_permission('dispatch.view')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'kind', 'dispatch',
      'id', header.id,
      'request_number', header.request_number,
      'order_id', header.order_id,
      'order_number', orders.order_number,
      'branch_id', header.branch_id,
      'status', header.status,
      'version', header.version,
      'stock_consumed', header.stock_consumed,
      'assigned_to', header.assigned_to,
      'assigned_to_name', profiles.full_name,
      'created_at', header.created_at
    ) order by header.assigned_at desc nulls last, header.id)
    from public.stock_dispatch_requests header
    join public.orders on orders.id = header.order_id
    left join public.profiles on profiles.id = header.assigned_to
    where app_private.dispatch_can_view(header)
      and header.stock_consumed
      and header.status in ('dispatched', 'in_transit', 'delivered', 'exception')
      and (
        app_private.has_permission('deliveries.assign')
        or app_private.has_permission('dispatch.view')
        or header.assigned_to is not distinct from auth.uid()
      )
  ), '[]'::jsonb);
end;
$$;

create or replace function public.list_dispatch_assignees(target_branch uuid)
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
      'id', profiles.id,
      'full_name', profiles.full_name
    ) order by profiles.full_name, profiles.id)
    from public.profiles
    join public.user_roles on user_roles.user_id = profiles.id
    join public.roles on roles.id = user_roles.role_id
    join public.user_branch_assignments
      on user_branch_assignments.user_id = profiles.id
     and user_branch_assignments.branch_id = target_branch
    where roles.code = 'delivery_person'
      and profiles.is_active
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.preview_dispatch(uuid) from public, anon, service_role;
revoke all on function public.prepare_dispatch(uuid, integer, text) from public, anon, service_role;
revoke all on function public.confirm_dispatch(uuid, integer, text) from public, anon, service_role;
revoke all on function public.cancel_dispatch(uuid, integer, text, text) from public, anon, service_role;
revoke all on function public.assign_dispatch_delivery(uuid, uuid, integer, text) from public, anon, service_role;
revoke all on function public.start_dispatch_delivery(uuid, integer, text) from public, anon, service_role;
revoke all on function public.acknowledge_dispatch_delivery(uuid, text, text, integer, text) from public, anon, service_role;
revoke all on function public.report_dispatch_delivery_exception(uuid, text, integer, text) from public, anon, service_role;
revoke all on function public.get_dispatch_request(uuid) from public, anon, service_role;
revoke all on function public.list_dispatch_queue(text) from public, anon, service_role;
revoke all on function public.list_assigned_deliveries() from public, anon, service_role;
revoke all on function public.list_dispatch_assignees(uuid) from public, anon, service_role;

grant execute on function public.preview_dispatch(uuid) to authenticated;
grant execute on function public.prepare_dispatch(uuid, integer, text) to authenticated;
grant execute on function public.confirm_dispatch(uuid, integer, text) to authenticated;
grant execute on function public.cancel_dispatch(uuid, integer, text, text) to authenticated;
grant execute on function public.assign_dispatch_delivery(uuid, uuid, integer, text) to authenticated;
grant execute on function public.start_dispatch_delivery(uuid, integer, text) to authenticated;
grant execute on function public.acknowledge_dispatch_delivery(uuid, text, text, integer, text) to authenticated;
grant execute on function public.report_dispatch_delivery_exception(uuid, text, integer, text) to authenticated;
grant execute on function public.get_dispatch_request(uuid) to authenticated;
grant execute on function public.list_dispatch_queue(text) to authenticated;
grant execute on function public.list_assigned_deliveries() to authenticated;
grant execute on function public.list_dispatch_assignees(uuid) to authenticated;

comment on function public.preview_dispatch(uuid) is
  'Advisory dispatch preview. Delivery-note existence never authorizes stock consumption.';

comment on function public.prepare_dispatch(uuid, integer, text) is
  'Creates a preparing dispatch sidecar after a ready_for_dispatch picking handoff. Does not write stock_ledger.';

comment on function public.confirm_dispatch(uuid, integer, text) is
  'Exactly-once dispatch stock consumption. Consumes reservations and posts DISPATCH ledger rows in one transaction.';

comment on function public.acknowledge_dispatch_delivery(uuid, text, text, integer, text) is
  'Customer proof of delivery. Distinct from delivery_notes.acknowledge godown paperwork.';

comment on function public.report_dispatch_delivery_exception(uuid, text, integer, text) is
  'Failed delivery. Marks physical return pending verification and does not restore inventory.';

-- ---------------------------------------------------------------------------
-- 8. Order cancel cannot reverse consumed dispatch
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
  dispatch public.stock_dispatch_requests%rowtype;
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

  select *
  into dispatch
  from public.stock_dispatch_requests
  where stock_dispatch_requests.order_id = selected.id
    and stock_dispatch_requests.status is distinct from 'cancelled'
  for update;

  if found then
    if dispatch.stock_consumed then
      raise exception 'dispatched stock cannot be reversed by order cancellation'
        using errcode = '23514';
    end if;
    raise exception 'cancel the preparing dispatch before cancelling this order'
      using errcode = '23514';
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
    -- Preserve the Phase 4.2F HTTP stale-version contract (PT409), not 40001.
    raise exception 'order was changed by someone else' using errcode = 'PT409';
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

-- PostgREST sessions load safeupdate, which rejects DELETE without WHERE.
-- The lot-aware helper only clears transaction-local scratch tables.
do $$
declare
  def text;
begin
  def := pg_get_functiondef('app_private.apply_lot_aware_stock_deltas(uuid, jsonb)'::regprocedure);
  def := replace(def, 'delete from pg_temp._lot_aware_lines;', 'delete from pg_temp._lot_aware_lines where true;');
  def := replace(def, 'delete from pg_temp._lot_aware_agg;', 'delete from pg_temp._lot_aware_agg where true;');
  execute def;

  def := pg_get_functiondef('app_private.lot_aware_delta_fingerprint(jsonb)'::regprocedure);
  def := replace(def, 'delete from pg_temp._lot_fp_lines;', 'delete from pg_temp._lot_fp_lines where true;');
  execute def;
end;
$$;

-- Lock-order: post_stock_adjustment must match apply_lot_aware / confirm_dispatch
-- (shared cutover → products → locations → lots → lot_balances → stock_balances).
create or replace function public.post_stock_adjustment(
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
  selected public.stock_adjustment_requests;
  cleaned_key text;
  fingerprint text;
  replay jsonb;
  crate_ids uuid[];
  line record;
  allocation_row record;
  baseline_quantity integer;
  later_count integer;
  created_id uuid;
  absolute_quantity integer;
  single_crate uuid;
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
  alloc_total integer;
  lot_deltas jsonb := '[]'::jsonb;
begin
  perform set_config('app.adjustment_write', 'on', true);
  perform app_private.assert_permission('stock.adjustment.post');
  perform app_private.acquire_stock_cutover_shared_lock();

  select *
  into selected
  from public.stock_adjustment_requests
  where stock_adjustment_requests.id = target_request
  for update;

  if not found or not app_private.can_work_at_branch(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if selected.compensates_request_id is not null then
    raise exception 'compensation is not available' using errcode = '23514';
  end if;

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  if selected.status = 'posted' then
    select pg_catalog.jsonb_build_object(
      'id', stock_transactions.id,
      'reference_number', stock_transactions.reference_number
    )
    into replay
    from public.stock_transactions
    where stock_transactions.adjustment_request_id = selected.id
      and stock_transactions.idempotency_key = cleaned_key;

    if replay is null then
      raise exception 'adjustment was already posted' using errcode = '23505';
    end if;
    return replay;
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'adjustment was changed by someone else' using errcode = 'PT409';
  end if;

  if selected.status <> 'approved' then
    raise exception 'adjustment cannot be posted' using errcode = '42501';
  end if;

  fingerprint := 'ADJUSTMENT:' || selected.id::text || ':' || selected.version::text;

  select coalesce(pg_catalog.array_agg(distinct stock_adjustment_lines.crate_id), '{}')
  into crate_ids
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released;

  if pg_catalog.cardinality(crate_ids) < 1 then
    raise exception 'an adjustment line is required' using errcode = '23514';
  end if;

  perform products.id
  from public.products
  where products.id in (
    select stock_adjustment_lines.product_id
    from public.stock_adjustment_lines
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
  )
  order by products.id
  for update;

  if app_private.prepare_stock_locations(crate_ids) is distinct from selected.godown_id then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if dual_write then
    perform stock_lots.id
    from public.stock_lots
    where stock_lots.id in (
      select allocations.lot_id
      from public.stock_adjustment_line_lot_allocations allocations
      join public.stock_adjustment_lines
        on stock_adjustment_lines.id = allocations.adjustment_line_id
      where stock_adjustment_lines.request_id = selected.id
        and not stock_adjustment_lines.released
    )
    order by stock_lots.id
    for update;

    perform stock_lot_balances.lot_id
    from public.stock_lot_balances
    join public.stock_adjustment_line_lot_allocations allocations
      on allocations.lot_id = stock_lot_balances.lot_id
    join public.stock_adjustment_lines
      on stock_adjustment_lines.id = allocations.adjustment_line_id
     and stock_adjustment_lines.crate_id = stock_lot_balances.crate_id
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
    order by stock_lot_balances.crate_id, stock_lot_balances.lot_id
    for update of stock_lot_balances;
  end if;

  perform stock_balances.crate_id
  from public.stock_balances
  join public.stock_adjustment_lines
    on stock_adjustment_lines.crate_id = stock_balances.crate_id
    and stock_adjustment_lines.product_id = stock_balances.product_id
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released
  order by stock_balances.crate_id, stock_balances.product_id
  for update;

  for line in
    select
      stock_adjustment_lines.id as line_id,
      stock_adjustment_lines.requested_cases,
      stock_adjustment_lines.crate_id,
      stock_adjustment_lines.product_id,
      stock_verification_lines.reconciled_expected_cases,
      stock_verification_lines.acknowledged_ledger_ids,
      stock_verification_lines.recount_cases,
      stock_verification_lines.final_variance_cases
    from public.stock_adjustment_lines
    join public.stock_verification_lines
      on stock_verification_lines.id = stock_adjustment_lines.verification_line_id
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
    order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id
  loop
    if line.final_variance_cases is distinct from line.requested_cases
      or line.final_variance_cases is distinct from (line.recount_cases - line.reconciled_expected_cases)
    then
      raise exception 'verification line cannot be adjusted' using errcode = '23514';
    end if;

    select count(*) into later_count
    from public.stock_ledger
    where stock_ledger.crate_id = line.crate_id
      and stock_ledger.product_id = line.product_id
      and not (
        stock_ledger.id = any (coalesce(line.acknowledged_ledger_ids, '{}'))
        or exists (
          select 1 from public.stock_verification_snapshot_entries snapshot_entries
          where snapshot_entries.verification_id = selected.verification_id
            and snapshot_entries.ledger_id = stock_ledger.id
        )
      );

    if later_count > 0 then
      raise exception 'adjustment is stale and needs a new verification' using errcode = '23514';
    end if;

    select coalesce(sum(stock_ledger.quantity), 0) into baseline_quantity
    from public.stock_ledger
    where stock_ledger.crate_id = line.crate_id
      and stock_ledger.product_id = line.product_id;

    if baseline_quantity is distinct from line.reconciled_expected_cases then
      raise exception 'adjustment is stale and needs a new verification' using errcode = '23514';
    end if;

    if dual_write then
      select coalesce(sum(allocations.quantity), 0) into alloc_total
      from public.stock_adjustment_line_lot_allocations allocations
      where allocations.adjustment_line_id = line.line_id;

      if alloc_total is distinct from line.requested_cases then
        raise exception
          'adjustment line % requires lot allocations totaling requested_cases (%)',
          line.line_id, line.requested_cases
          using errcode = '23514';
      end if;
    end if;
  end loop;

  select coalesce(sum(pg_catalog.abs(stock_adjustment_lines.requested_cases)), 0)
  into absolute_quantity
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released;

  select case when count(distinct stock_adjustment_lines.crate_id) = 1
    then (pg_catalog.array_agg(stock_adjustment_lines.crate_id))[1] else null end
  into single_crate
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released;

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    notes, product_id, destination_crate_id, quantity, adjustment_request_id
  )
  select
    'ADJUSTMENT', selected.request_number, auth.uid(), cleaned_key, fingerprint,
    selected.note, stock_adjustment_lines.product_id, single_crate, absolute_quantity, selected.id
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released
  order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id
  limit 1
  returning id into created_id;

  if dual_write then
    for allocation_row in
      select
        stock_adjustment_lines.product_id,
        stock_adjustment_lines.crate_id,
        alloc_rows.lot_id,
        alloc_rows.quantity
      from public.stock_adjustment_lines
      join public.stock_adjustment_line_lot_allocations alloc_rows
        on alloc_rows.adjustment_line_id = stock_adjustment_lines.id
      where stock_adjustment_lines.request_id = selected.id
        and not stock_adjustment_lines.released
      order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id, alloc_rows.lot_id
    loop
      insert into public.stock_ledger (
        transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
      ) values (
        created_id, allocation_row.product_id, allocation_row.crate_id, allocation_row.quantity,
        auth.uid(), pg_catalog.clock_timestamp(), allocation_row.lot_id
      );

      lot_deltas := lot_deltas || jsonb_build_array(jsonb_build_object(
        'product_id', allocation_row.product_id,
        'lot_id', allocation_row.lot_id,
        'crate_id', allocation_row.crate_id,
        'quantity', allocation_row.quantity
      ));
    end loop;

    perform app_private.apply_lot_aware_stock_deltas(created_id, lot_deltas);
  else
    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at
    )
    select created_id, stock_adjustment_lines.product_id, stock_adjustment_lines.crate_id,
      stock_adjustment_lines.requested_cases, auth.uid(), pg_catalog.clock_timestamp()
    from public.stock_adjustment_lines
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
    order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id;

    for line in
      select stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id,
        stock_adjustment_lines.requested_cases
      from public.stock_adjustment_lines
      where stock_adjustment_lines.request_id = selected.id
        and not stock_adjustment_lines.released
      order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id
    loop
      perform app_private.apply_stock_delta(line.crate_id, line.product_id, line.requested_cases);
    end loop;
  end if;

  update public.stock_adjustment_requests
  set
    status = 'posted',
    posted_by = auth.uid(),
    posted_at = pg_catalog.clock_timestamp(),
    posted_transaction_id = created_id,
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where stock_adjustment_requests.id = selected.id;

  perform app_private.adjustment_event(
    selected.id, 'posted', 'approved', 'posted', selected.version + 1, selected.note
  );
  perform app_private.write_audit(
    auth.uid(), 'post_stock_adjustment', 'stock_adjustment_requests', selected.id,
    pg_catalog.jsonb_build_object(
      'transaction_id', created_id,
      'request_number', selected.request_number,
      'dual_write', dual_write
    )
  );

  return pg_catalog.jsonb_build_object(
    'id', created_id,
    'reference_number', selected.request_number
  );
end;
$$;

-- Lock-order: post_crate_transfer previously locked stock_balances before lots
-- and before apply_lot_aware's product lock. That inverted confirm_dispatch and
-- post_stock_adjustment (products → locations → lots → lot_balances →
-- stock_balances). Replace in this pending migration; do not rewrite 22190000.
create or replace function public.post_crate_transfer(
  target_product uuid,
  source_crate uuid,
  destination_crate uuid,
  carton_quantity integer,
  idempotency_key text,
  posting_notes text,
  lot_moves jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  cleaned_notes text;
  fingerprint text;
  replay jsonb;
  created_id uuid;
  reference_number text;
  source_quantity integer;
  first_crate uuid;
  second_crate uuid;
  conflict_name text;
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
  item jsonb;
  move_lot uuid;
  move_qty integer;
  move_total integer := 0;
  lot_qty integer;
  source_branch uuid;
  dest_branch uuid;
  lot_deltas jsonb := '[]'::jsonb;
  lot_fp text := '';
begin
  perform app_private.assert_permission('stock.transfer.post');
  perform app_private.assert_carton_quantity(carton_quantity);
  -- Shared cutover first so exclusive seed/cutover serializes ahead of row locks.
  perform app_private.acquire_stock_cutover_shared_lock();

  if source_crate is not distinct from destination_crate then
    raise exception 'source and destination must be different' using errcode = '23514';
  end if;

  if not dual_write then
    if lot_moves is not null then
      raise exception 'lot_moves is only accepted when lot-aware dual-write is enabled'
        using errcode = '23514';
    end if;
  else
    if lot_moves is null or jsonb_typeof(lot_moves) is distinct from 'array'
      or jsonb_array_length(lot_moves) < 1
    then
      raise exception 'lot_moves must be a non-empty json array when dual-write is enabled'
        using errcode = '23514';
    end if;
  end if;

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_notes := app_private.clean_optional_text(posting_notes, 500);
  fingerprint := app_private.stock_request_fingerprint(
    'CRATE_TRANSFER', target_product, source_crate, destination_crate,
    carton_quantity, cleaned_notes
  );

  if dual_write then
    for item in select value from jsonb_array_elements(lot_moves)
    loop
      move_lot := (item ->> 'lot_id')::uuid;
      move_qty := coalesce(item ->> 'quantity', item ->> 'carton_quantity')::integer;
      if move_lot is null or move_qty is null or move_qty < 1 then
        raise exception 'each lot move requires lot_id and positive quantity'
          using errcode = '23514';
      end if;
      move_total := move_total + move_qty;
      lot_fp := lot_fp || '|' || move_lot::text || ':' || move_qty::text;
    end loop;
    if move_total is distinct from carton_quantity then
      raise exception 'lot move quantities (%) must equal carton_quantity (%)',
        move_total, carton_quantity
        using errcode = '23514';
    end if;
    fingerprint := fingerprint || '|LOTS' || lot_fp;
  end if;

  replay := app_private.replay_stock_transaction(cleaned_key, fingerprint);
  if replay is not null then
    return replay;
  end if;

  if not exists (
    select 1 from public.products
    where products.id = target_product and products.is_active
  ) then
    raise exception 'product not found or inactive' using errcode = '23514';
  end if;

  -- Product row before locations: apply_lot_aware and confirm_dispatch lock
  -- products first. Holding crates while waiting on products deadlocked.
  perform products.id
  from public.products
  where products.id = target_product
  for update;

  if source_crate < destination_crate then
    first_crate := source_crate;
    second_crate := destination_crate;
  else
    first_crate := destination_crate;
    second_crate := source_crate;
  end if;

  perform app_private.prepare_stock_locations(array[first_crate, second_crate]);

  select zones.branch_id into source_branch
  from public.crates join public.zones on zones.id = crates.zone_id
  where crates.id = source_crate;
  select zones.branch_id into dest_branch
  from public.crates join public.zones on zones.id = crates.zone_id
  where crates.id = destination_crate;

  if source_branch is distinct from dest_branch then
    raise exception 'crate transfers across godowns are not allowed' using errcode = '23514';
  end if;

  replay := app_private.replay_stock_transaction(cleaned_key, fingerprint);
  if replay is not null then
    return replay;
  end if;

  -- Lots then lot_balances then aggregate balances. Source-then-dest balance
  -- locks inverted crate_id order used by apply_lot_aware.
  if dual_write then
    perform stock_lots.id
    from public.stock_lots
    where stock_lots.id in (
      select (move.value ->> 'lot_id')::uuid
      from jsonb_array_elements(lot_moves) as move
    )
    order by stock_lots.id
    for update;

    perform stock_lot_balances.lot_id
    from public.stock_lot_balances
    where stock_lot_balances.lot_id in (
      select (move.value ->> 'lot_id')::uuid
      from jsonb_array_elements(lot_moves) as move
    )
      and stock_lot_balances.crate_id in (source_crate, destination_crate)
    order by stock_lot_balances.crate_id, stock_lot_balances.lot_id
    for update;
  end if;

  perform stock_balances.crate_id
  from public.stock_balances
  where stock_balances.product_id = target_product
    and stock_balances.crate_id in (source_crate, destination_crate)
  order by stock_balances.crate_id, stock_balances.product_id
  for update;

  select stock_balances.quantity into source_quantity
  from public.stock_balances
  where stock_balances.crate_id = source_crate
    and stock_balances.product_id = target_product;

  if coalesce(source_quantity, 0) < carton_quantity then
    raise exception 'insufficient stock' using errcode = '23514';
  end if;

  reference_number := 'TR-'
    || to_char(pg_catalog.clock_timestamp() at time zone 'UTC', 'YYYYMMDD')
    || '-'
    || pg_catalog.lpad(pg_catalog.nextval('public.stock_reference_seq')::text, 6, '0');

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    notes, product_id, source_crate_id, destination_crate_id, quantity
  ) values (
    'CRATE_TRANSFER', reference_number, auth.uid(), cleaned_key, fingerprint,
    cleaned_notes, target_product, source_crate, destination_crate, carton_quantity
  )
  returning id into created_id;

  if dual_write then
    for item in select value from jsonb_array_elements(lot_moves)
    loop
      move_lot := (item ->> 'lot_id')::uuid;
      move_qty := coalesce(item ->> 'quantity', item ->> 'carton_quantity')::integer;

      if exists (
        select 1 from jsonb_array_elements(lot_deltas) existing
        where (existing ->> 'lot_id')::uuid = move_lot
          and (existing ->> 'crate_id')::uuid = source_crate
      ) then
        raise exception 'duplicate lot_id in lot_moves is not allowed' using errcode = '23514';
      end if;

      if not exists (
        select 1 from public.stock_lots
        where stock_lots.id = move_lot
          and stock_lots.product_id = target_product
          and stock_lots.branch_id = source_branch
      ) then
        raise exception 'stock lot not found for product/godown' using errcode = '23514';
      end if;

      -- Re-lock of rows already ordered above; still enforces unreserved qty.
      select stock_lot_balances.quantity into lot_qty
      from public.stock_lot_balances
      where stock_lot_balances.lot_id = move_lot
        and stock_lot_balances.crate_id = source_crate
      for update;

      if coalesce(lot_qty, 0) < move_qty then
        raise exception 'insufficient lot stock' using errcode = '23514';
      end if;

      insert into public.stock_ledger (
        transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
      )
      select created_id, target_product, entries.crate_id, entries.quantity,
        stock_transactions.actor_id, stock_transactions.posted_at, move_lot
      from public.stock_transactions
      cross join (
        values (source_crate, -move_qty), (destination_crate, move_qty)
      ) as entries(crate_id, quantity)
      where stock_transactions.id = created_id;

      lot_deltas := lot_deltas || jsonb_build_array(
        jsonb_build_object(
          'product_id', target_product, 'lot_id', move_lot,
          'crate_id', source_crate, 'quantity', -move_qty
        ),
        jsonb_build_object(
          'product_id', target_product, 'lot_id', move_lot,
          'crate_id', destination_crate, 'quantity', move_qty
        )
      );
    end loop;

    perform app_private.apply_lot_aware_stock_deltas(created_id, lot_deltas);
  else
    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at
    )
    select created_id, target_product, entries.crate_id, entries.quantity,
      stock_transactions.actor_id, stock_transactions.posted_at
    from public.stock_transactions
    cross join (
      values (source_crate, -carton_quantity), (destination_crate, carton_quantity)
    ) as entries(crate_id, quantity)
    where stock_transactions.id = created_id;

    perform app_private.apply_stock_delta(source_crate, target_product, -carton_quantity);
    perform app_private.apply_stock_delta(destination_crate, target_product, carton_quantity);
  end if;

  perform app_private.write_audit(
    auth.uid(), 'post_crate_transfer', 'stock_transactions', created_id,
    pg_catalog.jsonb_build_object(
      'reference_number', reference_number,
      'product_id', target_product,
      'source_crate_id', source_crate,
      'destination_crate_id', destination_crate,
      'quantity', carton_quantity,
      'dual_write', dual_write
    )
  );

  return pg_catalog.jsonb_build_object('id', created_id, 'reference_number', reference_number);
exception
  when unique_violation then
    get stacked diagnostics conflict_name = constraint_name;
    if conflict_name = 'stock_transactions_idempotency_key' then
      replay := app_private.replay_stock_transaction(cleaned_key, fingerprint);
      if replay is not null then
        return replay;
      end if;
    end if;
    raise;
end;
$$;

comment on function public.post_crate_transfer(uuid, uuid, uuid, integer, text, text, jsonb) is
  'Same-godown crate transfer. Dual-write requires explicit lot_moves. Lock order matches trusted writers: shared cutover, product, locations, lots, lot_balances, stock_balances.';

