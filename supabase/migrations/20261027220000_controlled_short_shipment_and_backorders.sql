-- M7.3B. Controlled short-shipment, versioned shipment documents, linked backorders.
-- Narrowly approved confirm_dispatch posting change (D4.1–D4.5).
-- Reuses M2 reservations (lot-attributed picked_cases), M3 DISPATCH writer,
-- M7.2 acknowledged DN, M7.3A shortage audit. Does not touch verify_stock_receipt.
-- Does not flip cutover or damage.stock_hold_ready. Shipment rows are operational
-- records, not tax invoices.

-- ---------------------------------------------------------------------------
-- 1. Permissions. GM manages/confirms picked snapshot. Accounts approves qty.
-- ---------------------------------------------------------------------------
insert into public.permissions (code, description)
values
  (
    'shipments.view',
    'View short-shipment documents for authorized godowns. Not a tax-invoice permission.'
  ),
  (
    'shipments.manage',
    'Create, GM-confirm, or cancel a short-shipment document from trusted picked lots.'
  ),
  (
    'shipments.approve',
    'Accounts approval of commercial short-shipment quantities. Does not consume stock.'
  )
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from (
  values
    ('admin', 'shipments.view'),
    ('admin', 'shipments.manage'),
    ('admin', 'shipments.approve'),
    ('godown_manager', 'shipments.view'),
    ('godown_manager', 'shipments.manage'),
    ('accounts', 'shipments.view'),
    ('accounts', 'shipments.approve')
) as grants (role_code, permission_code)
join public.roles on roles.code = grants.role_code
join public.permissions on permissions.code = grants.permission_code
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. Order parent/backorder columns. Original requested_cases stay immutable.
-- ---------------------------------------------------------------------------
alter table public.orders
  add column if not exists parent_order_id uuid
    references public.orders (id) on delete restrict,
  add column if not exists originating_shipment_id uuid,
  add column if not exists fulfilment_status text not null default 'open';

alter table public.orders
  drop constraint if exists orders_source_check;

alter table public.orders
  add constraint orders_source_check check (
    source in ('salesperson', 'accounts', 'telecalling', 'enquiry', 'backorder')
  );

alter table public.orders
  drop constraint if exists orders_fulfilment_status_check;

alter table public.orders
  add constraint orders_fulfilment_status_check check (
    fulfilment_status in ('open', 'partially_fulfilled', 'fulfilled')
  );

alter table public.orders
  drop constraint if exists orders_parent_not_self;

alter table public.orders
  add constraint orders_parent_not_self check (
    parent_order_id is null or parent_order_id <> id
  );

-- One open backorder per original order. Repeated partials of the same parent
-- fail closed rather than stacking remainder documents.
create unique index if not exists orders_parent_open_backorder_idx
  on public.orders (parent_order_id)
  where parent_order_id is not null
    and status is distinct from 'cancelled';

create unique index if not exists orders_originating_shipment_open_idx
  on public.orders (originating_shipment_id)
  where originating_shipment_id is not null
    and status is distinct from 'cancelled';

create index if not exists orders_parent_order_id_idx
  on public.orders (parent_order_id)
  where parent_order_id is not null;

comment on column public.orders.parent_order_id is
  'M7.3B. Set only on a linked backorder. Original order rows stay historically unchanged.';

comment on column public.orders.originating_shipment_id is
  'M7.3B. Short-shipment that created this backorder. Null on original orders.';

comment on column public.orders.fulfilment_status is
  'M7.3B. open | partially_fulfilled | fulfilled. Independent of delivery POD and of order.status.';

-- ---------------------------------------------------------------------------
-- 3. Versioned shipment document (not a DN, not a tax invoice).
-- ---------------------------------------------------------------------------
create sequence if not exists public.shop_shipment_seq;

revoke all on sequence public.shop_shipment_seq
  from public, anon, authenticated, service_role;

create table if not exists public.order_shipments (
  id uuid primary key default gen_random_uuid(),
  shipment_number text not null,
  order_id uuid not null references public.orders (id) on delete restrict,
  picking_request_id uuid not null
    references public.stock_picking_requests (id) on delete restrict,
  delivery_note_id uuid
    references public.delivery_notes (id) on delete restrict,
  dispatch_request_id uuid
    references public.stock_dispatch_requests (id) on delete restrict,
  backorder_id uuid references public.orders (id) on delete restrict,
  branch_id uuid not null references public.branches (id) on delete restrict,
  shop_id uuid not null references public.shops (id) on delete restrict,
  status text not null default 'draft',
  revision integer not null default 1,
  version integer not null default 1,
  picked_fingerprint text,
  approval_fingerprint text,
  created_by uuid not null references public.profiles (id) on delete restrict,
  gm_confirmed_by uuid references public.profiles (id) on delete restrict,
  gm_confirmed_at timestamptz,
  accounts_approved_by uuid references public.profiles (id) on delete restrict,
  accounts_approved_at timestamptz,
  dispatched_by uuid references public.profiles (id) on delete restrict,
  dispatched_at timestamptz,
  cancelled_by uuid references public.profiles (id) on delete restrict,
  cancelled_at timestamptz,
  cancellation_reason text,
  create_idempotency_key text not null,
  confirm_idempotency_key text,
  approve_idempotency_key text,
  cancel_idempotency_key text,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint order_shipments_number_key unique (shipment_number),
  constraint order_shipments_create_key unique (create_idempotency_key),
  constraint order_shipments_status_check check (
    status in ('draft', 'gm_confirmed', 'approved', 'dispatched', 'cancelled')
  ),
  constraint order_shipments_revision_check check (revision >= 1),
  constraint order_shipments_version_check check (version >= 1),
  constraint order_shipments_cancel_reason_length check (
    cancellation_reason is null
    or (
      char_length(btrim(cancellation_reason)) between 1 and 500
      and cancellation_reason = btrim(cancellation_reason)
    )
  ),
  constraint order_shipments_gm_shape check (
    status in ('draft', 'cancelled')
    or (gm_confirmed_by is not null and gm_confirmed_at is not null)
  ),
  constraint order_shipments_accounts_shape check (
    status not in ('approved', 'dispatched')
    or (accounts_approved_by is not null and accounts_approved_at is not null)
  ),
  constraint order_shipments_dispatched_shape check (
    status <> 'dispatched'
    or (
      dispatched_by is not null
      and dispatched_at is not null
      and dispatch_request_id is not null
    )
  ),
  constraint order_shipments_cancelled_shape check (
    status <> 'cancelled'
    or (cancelled_by is not null and cancelled_at is not null)
  )
);

comment on table public.order_shipments is
  'M7.3B operational shipment document. Preserves the acknowledged DN. Not a GST tax invoice.';

create unique index order_shipments_picking_open_idx
  on public.order_shipments (picking_request_id)
  where status is distinct from 'cancelled';

create unique index order_shipments_confirm_key_idx
  on public.order_shipments (confirm_idempotency_key)
  where confirm_idempotency_key is not null;

create unique index order_shipments_approve_key_idx
  on public.order_shipments (approve_idempotency_key)
  where approve_idempotency_key is not null;

create index order_shipments_order_id_idx
  on public.order_shipments (order_id, created_at desc);

create index order_shipments_branch_status_idx
  on public.order_shipments (branch_id, status, created_at desc);

create table if not exists public.order_shipment_lines (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null
    references public.order_shipments (id) on delete restrict,
  order_line_id uuid not null references public.order_lines (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  ordered_cases integer not null,
  reserved_cases integer not null,
  picked_cases integer not null,
  proposed_cases integer not null,
  approved_cases integer not null default 0,
  constraint order_shipment_lines_unique unique (shipment_id, order_line_id),
  constraint order_shipment_lines_qty_check check (
    ordered_cases between 1 and 1000000
    and reserved_cases >= 0
    and picked_cases >= 0
    and proposed_cases >= 0
    and approved_cases >= 0
    and picked_cases <= reserved_cases
    and proposed_cases <= picked_cases
    and approved_cases <= picked_cases
    and approved_cases <= ordered_cases
  )
);

comment on table public.order_shipment_lines is
  'M7.3B per-line snapshot. ordered_cases is copied from the original order and never rewritten there.';

create table if not exists public.order_shipment_lots (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null
    references public.order_shipments (id) on delete restrict,
  shipment_line_id uuid not null
    references public.order_shipment_lines (id) on delete restrict,
  reservation_id uuid not null
    references public.stock_reservations (id) on delete restrict,
  order_line_id uuid not null references public.order_lines (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  lot_id uuid not null references public.stock_lots (id) on delete restrict,
  crate_id uuid not null references public.crates (id) on delete restrict,
  reserved_cases integer not null,
  picked_cases integer not null,
  proposed_cases integer not null,
  approved_cases integer not null default 0,
  shipped_cases integer not null default 0,
  released_cases integer not null default 0,
  constraint order_shipment_lots_unique unique (shipment_id, reservation_id),
  constraint order_shipment_lots_qty_check check (
    reserved_cases >= 0
    and picked_cases >= 0
    and proposed_cases >= 0
    and approved_cases >= 0
    and shipped_cases >= 0
    and released_cases >= 0
    and picked_cases <= reserved_cases
    and proposed_cases <= picked_cases
    and approved_cases <= picked_cases
    and shipped_cases <= approved_cases
    and shipped_cases + released_cases <= reserved_cases
  )
);

comment on table public.order_shipment_lots is
  'M7.3B lot attribution copied from stock_reservations. Callers cannot introduce lots.';

comment on column public.order_shipment_lots.released_cases is
  'Unused reserved cases released in the same confirm_dispatch transaction. Not a stock receipt.';

create table if not exists public.order_shipment_events (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null
    references public.order_shipments (id) on delete restrict,
  event_type text not null,
  from_status text,
  to_status text not null,
  actor_id uuid not null,
  shipment_version integer not null,
  payload jsonb not null default '{}'::jsonb,
  idempotency_key text not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint order_shipment_events_idempotency_key unique (idempotency_key),
  constraint order_shipment_events_type_check check (
    event_type in (
      'created', 'gm_confirmed', 'approved', 'dispatched', 'cancelled'
    )
  ),
  constraint order_shipment_events_status_check check (
    to_status in ('draft', 'gm_confirmed', 'approved', 'dispatched', 'cancelled')
    and (
      from_status is null
      or from_status in ('draft', 'gm_confirmed', 'approved', 'dispatched', 'cancelled')
    )
  )
);

create index order_shipment_events_shipment_idx
  on public.order_shipment_events (shipment_id, created_at);

comment on table public.order_shipment_events is
  'M7.3B append-only shipment history. actor_id is copied from auth.uid() in trusted RPCs.';

alter table public.orders
  add constraint orders_originating_shipment_fk
  foreign key (originating_shipment_id)
  references public.order_shipments (id)
  on delete restrict;

create trigger order_shipments_set_updated_at
  before update on public.order_shipments
  for each row execute function app_private.set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. Numbering, write guard, FORCE RLS.
-- ---------------------------------------------------------------------------
create or replace function app_private.assign_shipment_number()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' and new.shipment_number is null then
    new.shipment_number := 'SH-'
      || to_char(pg_catalog.clock_timestamp() at time zone 'utc', 'YYYYMMDD')
      || '-'
      || pg_catalog.lpad(pg_catalog.nextval('public.shop_shipment_seq')::text, 6, '0');
  end if;

  if tg_op = 'UPDATE' and new.shipment_number is distinct from old.shipment_number then
    raise exception 'shipment number is immutable' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and new.create_idempotency_key is distinct from old.create_idempotency_key then
    raise exception 'idempotency key is immutable' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and old.status = 'cancelled' and new.status is distinct from old.status then
    raise exception 'shipment is cancelled' using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' and old.status = 'dispatched'
    and new.status is distinct from old.status
  then
    raise exception 'dispatched shipment is immutable' using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger order_shipments_assign_number
  before insert or update on public.order_shipments
  for each row execute function app_private.assign_shipment_number();

revoke all on function app_private.assign_shipment_number()
  from public, anon, authenticated, service_role;

create or replace function app_private.guard_shipment_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Dispatch posting also mutates shipped/released columns in the same txn.
  if pg_catalog.current_setting('app.shipment_write', true) is distinct from 'on'
    and pg_catalog.current_setting('app.dispatch_write', true) is distinct from 'on'
  then
    raise exception 'shipment records cannot be changed directly'
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function app_private.guard_shipment_write()
  from public, anon, authenticated, service_role;

create trigger order_shipments_guard
  before insert or update or delete on public.order_shipments
  for each row execute function app_private.guard_shipment_write();

create trigger order_shipment_lines_guard
  before insert or update or delete on public.order_shipment_lines
  for each row execute function app_private.guard_shipment_write();

create trigger order_shipment_lots_guard
  before insert or update or delete on public.order_shipment_lots
  for each row execute function app_private.guard_shipment_write();

create trigger order_shipment_events_guard
  before insert or update or delete on public.order_shipment_events
  for each row execute function app_private.guard_shipment_write();

create or replace function app_private.reject_shipment_event_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    return new;
  end if;
  raise exception 'shipment history is append-only' using errcode = '42501';
end;
$$;

create trigger order_shipment_events_append_only
  before update or delete on public.order_shipment_events
  for each row execute function app_private.reject_shipment_event_change();

revoke all on function app_private.reject_shipment_event_change()
  from public, anon, authenticated, service_role;

alter table public.order_shipments enable row level security;
alter table public.order_shipments force row level security;
alter table public.order_shipment_lines enable row level security;
alter table public.order_shipment_lines force row level security;
alter table public.order_shipment_lots enable row level security;
alter table public.order_shipment_lots force row level security;
alter table public.order_shipment_events enable row level security;
alter table public.order_shipment_events force row level security;

create or replace function app_private.shipment_can_view(
  header public.order_shipments
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
  if app_private.has_permission('shipments.view')
    or app_private.has_permission('shipments.manage')
    or app_private.has_permission('shipments.approve')
    or app_private.has_permission('operations.monitor')
  then
    return true;
  end if;
  -- Order viewers (salesperson creator / Accounts) may read the linked document.
  return app_private.can_view_order(header.order_id);
end;
$$;

revoke all on function app_private.shipment_can_view(public.order_shipments)
  from public, anon, service_role;
grant execute on function app_private.shipment_can_view(public.order_shipments)
  to authenticated;

create policy order_shipments_select_authorized
  on public.order_shipments
  for select
  to authenticated
  using ((select app_private.shipment_can_view(order_shipments)));

create policy order_shipment_lines_select_authorized
  on public.order_shipment_lines
  for select
  to authenticated
  using (
    exists (
      select 1 from public.order_shipments
      where order_shipments.id = order_shipment_lines.shipment_id
        and app_private.shipment_can_view(order_shipments)
    )
  );

create policy order_shipment_lots_select_authorized
  on public.order_shipment_lots
  for select
  to authenticated
  using (
    exists (
      select 1 from public.order_shipments
      where order_shipments.id = order_shipment_lots.shipment_id
        and app_private.shipment_can_view(order_shipments)
    )
  );

create policy order_shipment_events_select_authorized
  on public.order_shipment_events
  for select
  to authenticated
  using (
    exists (
      select 1 from public.order_shipments
      where order_shipments.id = order_shipment_events.shipment_id
        and app_private.shipment_can_view(order_shipments)
    )
  );

revoke all on table public.order_shipments from public, anon, authenticated, service_role;
revoke all on table public.order_shipment_lines from public, anon, authenticated, service_role;
revoke all on table public.order_shipment_lots from public, anon, authenticated, service_role;
revoke all on table public.order_shipment_events from public, anon, authenticated, service_role;

grant select on table public.order_shipments to authenticated;
grant select on table public.order_shipment_lines to authenticated;
grant select on table public.order_shipment_lots to authenticated;
grant select on table public.order_shipment_events to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Private helpers: fingerprints, lock, events, payload, auth.
-- ---------------------------------------------------------------------------
create or replace function app_private.shipment_picked_fingerprint(p_picking uuid)
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
      || ':' || stock_reservations.picked_cases::text,
    '|'
    order by stock_reservations.crate_id, stock_reservations.lot_id, stock_reservations.id
  ), ''))
  from public.stock_reservations
  where stock_reservations.picking_request_id = p_picking
    and stock_reservations.status = 'active';
$$;

revoke all on function app_private.shipment_picked_fingerprint(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.shipment_approved_fingerprint(p_shipment uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select md5(coalesce(string_agg(
    order_shipment_lots.reservation_id::text
      || ':' || order_shipment_lots.lot_id::text
      || ':' || order_shipment_lots.crate_id::text
      || ':' || order_shipment_lots.approved_cases::text,
    '|'
    order by order_shipment_lots.crate_id, order_shipment_lots.lot_id,
      order_shipment_lots.reservation_id
  ), ''))
  from public.order_shipment_lots
  where order_shipment_lots.shipment_id = p_shipment;
$$;

revoke all on function app_private.shipment_approved_fingerprint(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.open_shipment_for_picking(p_picking uuid)
returns public.order_shipments
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected public.order_shipments%rowtype;
begin
  select *
    into selected
  from public.order_shipments
  where order_shipments.picking_request_id = p_picking
    and order_shipments.status is distinct from 'cancelled'
  order by order_shipments.created_at desc, order_shipments.id desc
  limit 1;

  return selected;
end;
$$;

revoke all on function app_private.open_shipment_for_picking(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_shipment_manager(target_branch uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('shipments.manage');
  if not app_private.can_work_at_branch(target_branch) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform app_private.assert_operational_active_branch(target_branch);
end;
$$;

revoke all on function app_private.assert_shipment_manager(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_shipment_approver(target_branch uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('shipments.approve');
  if not app_private.can_work_at_branch(target_branch) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform app_private.assert_operational_active_branch(target_branch);
end;
$$;

revoke all on function app_private.assert_shipment_approver(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.lock_shipment(
  target_shipment uuid,
  expected_version integer
)
returns public.order_shipments
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.order_shipments;
begin
  select *
    into header
  from public.order_shipments
  where order_shipments.id = target_shipment
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if header.version is distinct from expected_version then
    raise exception 'shipment was changed by someone else' using errcode = 'PT409';
  end if;

  return header;
end;
$$;

revoke all on function app_private.lock_shipment(uuid, integer)
  from public, anon, authenticated, service_role;

create or replace function app_private.shipment_event(
  target_shipment uuid,
  event_type text,
  from_status text,
  to_status text,
  shipment_version integer,
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
  insert into public.order_shipment_events (
    shipment_id, event_type, from_status, to_status, actor_id,
    shipment_version, payload, idempotency_key
  )
  values (
    target_shipment, event_type, from_status, to_status, auth.uid(),
    shipment_version, coalesce(payload, '{}'::jsonb), idempotency_key
  )
  returning id into created;

  return created;
end;
$$;

revoke all on function app_private.shipment_event(uuid, text, text, text, integer, jsonb, text)
  from public, anon, authenticated, service_role;

drop function if exists app_private.replay_shipment_event(text, text, uuid);

create or replace function app_private.replay_shipment_event(
  p_idempotency_key text,
  p_event_type text,
  p_target_shipment uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  existing uuid;
begin
  select order_shipment_events.shipment_id
    into existing
  from public.order_shipment_events
  where order_shipment_events.idempotency_key = p_idempotency_key
    and order_shipment_events.event_type = p_event_type
    and order_shipment_events.shipment_id = p_target_shipment;

  return existing;
end;
$$;

revoke all on function app_private.replay_shipment_event(text, text, uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.shipment_payload(target_shipment uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  header public.order_shipments;
begin
  select * into header
  from public.order_shipments
  where id = target_shipment;

  if not found or not app_private.shipment_can_view(header) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'id', header.id,
    'shipment_number', header.shipment_number,
    'order_id', header.order_id,
    'picking_request_id', header.picking_request_id,
    'delivery_note_id', header.delivery_note_id,
    'dispatch_request_id', header.dispatch_request_id,
    'backorder_id', header.backorder_id,
    'branch_id', header.branch_id,
    'shop_id', header.shop_id,
    'status', header.status,
    'revision', header.revision,
    'version', header.version,
    'gm_confirmed_by', header.gm_confirmed_by,
    'gm_confirmed_at', header.gm_confirmed_at,
    'accounts_approved_by', header.accounts_approved_by,
    'accounts_approved_at', header.accounts_approved_at,
    'dispatched_by', header.dispatched_by,
    'dispatched_at', header.dispatched_at,
    'cancelled_at', header.cancelled_at,
    'cancellation_reason', header.cancellation_reason,
    'created_at', header.created_at,
    'updated_at', header.updated_at,
    'ordered_cases', coalesce((
      select sum(order_shipment_lines.ordered_cases)::integer
      from public.order_shipment_lines
      where order_shipment_lines.shipment_id = header.id
    ), 0),
    'reserved_cases', coalesce((
      select sum(order_shipment_lines.reserved_cases)::integer
      from public.order_shipment_lines
      where order_shipment_lines.shipment_id = header.id
    ), 0),
    'picked_cases', coalesce((
      select sum(order_shipment_lines.picked_cases)::integer
      from public.order_shipment_lines
      where order_shipment_lines.shipment_id = header.id
    ), 0),
    'proposed_cases', coalesce((
      select sum(order_shipment_lines.proposed_cases)::integer
      from public.order_shipment_lines
      where order_shipment_lines.shipment_id = header.id
    ), 0),
    'approved_cases', coalesce((
      select sum(order_shipment_lines.approved_cases)::integer
      from public.order_shipment_lines
      where order_shipment_lines.shipment_id = header.id
    ), 0),
    'shipped_cases', coalesce((
      select sum(order_shipment_lots.shipped_cases)::integer
      from public.order_shipment_lots
      where order_shipment_lots.shipment_id = header.id
    ), 0),
    'released_cases', coalesce((
      select sum(order_shipment_lots.released_cases)::integer
      from public.order_shipment_lots
      where order_shipment_lots.shipment_id = header.id
    ), 0),
    'outstanding_cases', coalesce((
      select sum(order_shipment_lines.ordered_cases - order_shipment_lines.approved_cases)::integer
      from public.order_shipment_lines
      where order_shipment_lines.shipment_id = header.id
    ), 0),
    'lines', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', order_shipment_lines.id,
        'order_line_id', order_shipment_lines.order_line_id,
        'product_id', order_shipment_lines.product_id,
        'ordered_cases', order_shipment_lines.ordered_cases,
        'reserved_cases', order_shipment_lines.reserved_cases,
        'picked_cases', order_shipment_lines.picked_cases,
        'proposed_cases', order_shipment_lines.proposed_cases,
        'approved_cases', order_shipment_lines.approved_cases
      ) order by order_shipment_lines.order_line_id)
      from public.order_shipment_lines
      where order_shipment_lines.shipment_id = header.id
    ), '[]'::jsonb),
    'lots', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', order_shipment_lots.id,
        'reservation_id', order_shipment_lots.reservation_id,
        'order_line_id', order_shipment_lots.order_line_id,
        'product_id', order_shipment_lots.product_id,
        'sku', products.sku,
        'product_name', products.name,
        'lot_id', order_shipment_lots.lot_id,
        'crate_id', order_shipment_lots.crate_id,
        'crate_code', crates.code,
        'zone_code', zones.code,
        'manufacturer_lot_code', stock_lots.manufacturer_lot_code,
        'expiry_date', stock_lots.expiry_date,
        'reserved_cases', order_shipment_lots.reserved_cases,
        'picked_cases', order_shipment_lots.picked_cases,
        'proposed_cases', order_shipment_lots.proposed_cases,
        'approved_cases', order_shipment_lots.approved_cases,
        'shipped_cases', order_shipment_lots.shipped_cases,
        'released_cases', order_shipment_lots.released_cases
      ) order by products.sku, crates.code, stock_lots.id)
      from public.order_shipment_lots
      join public.products on products.id = order_shipment_lots.product_id
      join public.crates on crates.id = order_shipment_lots.crate_id
      join public.zones on zones.id = crates.zone_id
      join public.stock_lots on stock_lots.id = order_shipment_lots.lot_id
      where order_shipment_lots.shipment_id = header.id
    ), '[]'::jsonb),
    'events', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', order_shipment_events.id,
        'event_type', order_shipment_events.event_type,
        'actor_id', order_shipment_events.actor_id,
        'from_status', order_shipment_events.from_status,
        'to_status', order_shipment_events.to_status,
        'shipment_version', order_shipment_events.shipment_version,
        'payload', order_shipment_events.payload,
        'created_at', order_shipment_events.created_at
      ) order by order_shipment_events.created_at, order_shipment_events.id)
      from public.order_shipment_events
      where order_shipment_events.shipment_id = header.id
    ), '[]'::jsonb),
    'cutover', pg_catalog.jsonb_build_object(
      'dual_write_enabled', exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.dual_write_enabled' and value = 'true'::jsonb
      ),
      'aggregate_only_blocked', exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.aggregate_only_blocked' and value = 'true'::jsonb
      )
    )
  );
end;
$$;

revoke all on function app_private.shipment_payload(uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Public shipment RPCs.
-- ---------------------------------------------------------------------------
create or replace function public.get_shipment(target_shipment uuid)
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
  return app_private.shipment_payload(target_shipment);
end;
$$;

create or replace function public.create_short_shipment(
  target_request uuid,
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
  picking public.stock_picking_requests;
  selected public.orders%rowtype;
  note public.delivery_notes%rowtype;
  existing public.order_shipments%rowtype;
  created_id uuid;
  line_row record;
  total_picked integer := 0;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select * into existing
  from public.order_shipments
  where order_shipments.create_idempotency_key = cleaned_key;

  if found then
    if not app_private.shipment_can_view(existing) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    if existing.picking_request_id is distinct from target_request then
      raise exception 'idempotency key was already used for a different request'
        using errcode = '23514';
    end if;
    return app_private.shipment_payload(existing.id);
  end if;

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.shipment_write', 'on', true);

  picking := app_private.lock_picking_request(target_request, expected_picking_version);
  perform app_private.assert_shipment_manager(picking.branch_id);

  select * into selected
  from public.orders
  where orders.id = picking.order_id
  for update;

  if selected.parent_order_id is not null then
    raise exception 'short-shipment of a backorder is not supported'
      using errcode = '23514';
  end if;

  if selected.status is distinct from 'verified' then
    raise exception 'short-shipment requires a verified order' using errcode = '23514';
  end if;

  if picking.status not in ('picked', 'ready_for_dispatch') then
    raise exception 'short-shipment requires completed picking' using errcode = '23514';
  end if;

  note := app_private.open_delivery_note_for_order(selected.id);
  if note.id is null or note.status is distinct from 'acknowledged' then
    raise exception 'short-shipment requires an acknowledged delivery note'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.order_shipments
    where order_shipments.picking_request_id = picking.id
      and order_shipments.status is distinct from 'cancelled'
  ) then
    raise exception 'an open short-shipment already exists for this picking request'
      using errcode = '23514';
  end if;

  select coalesce(sum(stock_reservations.picked_cases), 0)
    into total_picked
  from public.stock_reservations
  where stock_reservations.picking_request_id = picking.id
    and stock_reservations.status = 'active';

  if total_picked < 1 then
    raise exception 'short-shipment requires at least one picked carton'
      using errcode = '23514';
  end if;

  begin
    insert into public.order_shipments (
      order_id, picking_request_id, delivery_note_id, branch_id, shop_id,
      status, revision, version, created_by, create_idempotency_key
    )
    values (
      selected.id, picking.id, note.id, picking.branch_id, selected.shop_id,
      'draft', 1, 1, auth.uid(), cleaned_key
    )
    returning id into created_id;
  exception
    when unique_violation then
      select * into existing
      from public.order_shipments
      where order_shipments.create_idempotency_key = cleaned_key;
      if not found then
        raise exception 'an open short-shipment already exists for this picking request'
          using errcode = '23514';
      end if;
      return app_private.shipment_payload(existing.id);
  end;

  -- Snapshot only currently active reservations. Shortage-released rows are history.
  for line_row in
    select
      order_lines.id as order_line_id,
      order_lines.product_id,
      order_lines.requested_cases,
      coalesce(sum(stock_reservations.reserved_cases), 0)::integer as reserved_cases,
      coalesce(sum(stock_reservations.picked_cases), 0)::integer as picked_cases
    from public.order_lines
    left join public.stock_reservations
      on stock_reservations.order_line_id = order_lines.id
     and stock_reservations.picking_request_id = picking.id
     and stock_reservations.status = 'active'
    where order_lines.order_id = selected.id
    group by order_lines.id, order_lines.product_id, order_lines.requested_cases
    order by order_lines.id
  loop
    insert into public.order_shipment_lines (
      shipment_id, order_line_id, product_id,
      ordered_cases, reserved_cases, picked_cases, proposed_cases, approved_cases
    )
    values (
      created_id,
      line_row.order_line_id,
      line_row.product_id,
      line_row.requested_cases,
      line_row.reserved_cases,
      line_row.picked_cases,
      line_row.picked_cases,
      0
    );
  end loop;

  insert into public.order_shipment_lots (
    shipment_id, shipment_line_id, reservation_id, order_line_id, product_id,
    lot_id, crate_id, reserved_cases, picked_cases, proposed_cases, approved_cases
  )
  select
    created_id,
    order_shipment_lines.id,
    stock_reservations.id,
    stock_reservations.order_line_id,
    stock_reservations.product_id,
    stock_reservations.lot_id,
    stock_reservations.crate_id,
    stock_reservations.reserved_cases,
    stock_reservations.picked_cases,
    stock_reservations.picked_cases,
    0
  from public.stock_reservations
  join public.order_shipment_lines
    on order_shipment_lines.shipment_id = created_id
   and order_shipment_lines.order_line_id = stock_reservations.order_line_id
  where stock_reservations.picking_request_id = picking.id
    and stock_reservations.status = 'active';

  perform app_private.shipment_event(
    created_id, 'created', null, 'draft', 1,
    pg_catalog.jsonb_build_object(
      'picked_cases', total_picked,
      'picked_fingerprint', app_private.shipment_picked_fingerprint(picking.id)
    ),
    cleaned_key
  );
  perform app_private.write_audit(
    auth.uid(), 'create_short_shipment', 'order_shipments', created_id,
    pg_catalog.jsonb_build_object('picking_request_id', picking.id)
  );

  return app_private.shipment_payload(created_id);
end;
$$;

create or replace function public.confirm_short_shipment_quantities(
  target_shipment uuid,
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
  header public.order_shipments;
  picking public.stock_picking_requests;
  replay uuid;
  current_fp text;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_shipment_event(cleaned_key, 'gm_confirmed', target_shipment);
  if replay is not null then
    return app_private.shipment_payload(replay);
  end if;

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.shipment_write', 'on', true);

  header := app_private.lock_shipment(target_shipment, expected_version);
  perform app_private.assert_shipment_manager(header.branch_id);

  select * into picking
  from public.stock_picking_requests
  where stock_picking_requests.id = header.picking_request_id
  for update;

  if header.status is distinct from 'draft' then
    raise exception 'Godown Manager confirmation requires a draft shipment'
      using errcode = '23514';
  end if;

  if picking.status not in ('picked', 'ready_for_dispatch') then
    raise exception 'short-shipment requires completed picking' using errcode = '23514';
  end if;

  current_fp := app_private.shipment_picked_fingerprint(picking.id);
  if exists (
    select 1
    from public.order_shipment_lots
    join public.stock_reservations
      on stock_reservations.id = order_shipment_lots.reservation_id
    where order_shipment_lots.shipment_id = header.id
      and (
        stock_reservations.status is distinct from 'active'
        or stock_reservations.lot_id is distinct from order_shipment_lots.lot_id
        or stock_reservations.crate_id is distinct from order_shipment_lots.crate_id
        or stock_reservations.picked_cases is distinct from order_shipment_lots.picked_cases
      )
  ) then
    raise exception 'picked lots changed after the shipment snapshot. Cancel and recreate the document.'
      using errcode = '23514';
  end if;

  update public.order_shipments
  set
    status = 'gm_confirmed',
    picked_fingerprint = current_fp,
    gm_confirmed_by = auth.uid(),
    gm_confirmed_at = pg_catalog.clock_timestamp(),
    confirm_idempotency_key = cleaned_key,
    version = header.version + 1
  where id = header.id;

  perform app_private.shipment_event(
    header.id, 'gm_confirmed', 'draft', 'gm_confirmed', header.version + 1,
    pg_catalog.jsonb_build_object('picked_fingerprint', current_fp),
    cleaned_key
  );
  perform app_private.write_audit(
    auth.uid(), 'confirm_short_shipment_quantities', 'order_shipments', header.id,
    pg_catalog.jsonb_build_object('status', 'gm_confirmed')
  );

  return app_private.shipment_payload(header.id);
end;
$$;

create or replace function public.approve_short_shipment(
  target_shipment uuid,
  expected_version integer,
  lot_quantities jsonb,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  header public.order_shipments;
  picking public.stock_picking_requests;
  replay uuid;
  qty_row record;
  total_approved integer := 0;
  current_picked_fp text;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_shipment_event(cleaned_key, 'approved', target_shipment);
  if replay is not null then
    return app_private.shipment_payload(replay);
  end if;

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.shipment_write', 'on', true);

  header := app_private.lock_shipment(target_shipment, expected_version);
  perform app_private.assert_shipment_approver(header.branch_id);

  select * into picking
  from public.stock_picking_requests
  where stock_picking_requests.id = header.picking_request_id
  for update;

  if header.status is distinct from 'gm_confirmed' then
    raise exception 'Accounts approval requires Godown Manager confirmation'
      using errcode = '23514';
  end if;

  current_picked_fp := app_private.shipment_picked_fingerprint(picking.id);
  if current_picked_fp is distinct from header.picked_fingerprint then
    raise exception 'picked lots changed after Godown Manager confirmation. Recreate the shipment.'
      using errcode = '23514';
  end if;

  if lot_quantities is not null
    and pg_catalog.jsonb_typeof(lot_quantities) is distinct from 'array'
  then
    raise exception 'lot quantities must be an array' using errcode = '23514';
  end if;

  if lot_quantities is not null and pg_catalog.jsonb_array_length(lot_quantities) > 0 then
    -- Reject unknown lot ids so a caller cannot smuggle extra grains.
    if exists (
      select 1
      from pg_catalog.jsonb_array_elements(lot_quantities) as entry
      where (entry ->> 'shipment_lot_id') is null
        or (entry ->> 'approved_cases') is null
        or (entry ->> 'approved_cases') !~ '^[0-9]+$'
        or not exists (
          select 1
          from public.order_shipment_lots
          where order_shipment_lots.id = (entry ->> 'shipment_lot_id')::uuid
            and order_shipment_lots.shipment_id = header.id
        )
    ) then
      raise exception 'approved lot quantities do not match the shipment snapshot'
        using errcode = '23514';
    end if;

    for qty_row in
      select
        (entry ->> 'shipment_lot_id')::uuid as shipment_lot_id,
        (entry ->> 'approved_cases')::integer as approved_cases
      from pg_catalog.jsonb_array_elements(lot_quantities) as entry
    loop
      update public.order_shipment_lots
      set approved_cases = qty_row.approved_cases
      where id = qty_row.shipment_lot_id
        and shipment_id = header.id
        and qty_row.approved_cases <= picked_cases;

      if not found then
        raise exception 'approved quantity exceeds confirmed picked cases'
          using errcode = '23514';
      end if;
    end loop;
  else
    -- Default commercial quantity is the GM-confirmed picked snapshot.
    update public.order_shipment_lots
    set approved_cases = picked_cases
    where shipment_id = header.id;
  end if;

  update public.order_shipment_lines as lines
  set approved_cases = coalesce((
    select sum(order_shipment_lots.approved_cases)
    from public.order_shipment_lots
    where order_shipment_lots.shipment_line_id = lines.id
  ), 0)
  where lines.shipment_id = header.id;

  select coalesce(sum(order_shipment_lots.approved_cases), 0)
    into total_approved
  from public.order_shipment_lots
  where order_shipment_lots.shipment_id = header.id;

  if total_approved < 1 then
    raise exception 'Accounts must approve at least one shipped carton'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.order_shipment_lines
    where order_shipment_lines.shipment_id = header.id
      and order_shipment_lines.approved_cases > order_shipment_lines.ordered_cases
  ) then
    raise exception 'approved shipment cannot exceed the original ordered quantity'
      using errcode = '23514';
  end if;

  update public.order_shipments
  set
    status = 'approved',
    approval_fingerprint = app_private.shipment_approved_fingerprint(header.id),
    accounts_approved_by = auth.uid(),
    accounts_approved_at = pg_catalog.clock_timestamp(),
    approve_idempotency_key = cleaned_key,
    version = header.version + 1
  where id = header.id;

  perform app_private.shipment_event(
    header.id, 'approved', 'gm_confirmed', 'approved', header.version + 1,
    pg_catalog.jsonb_build_object(
      'approved_cases', total_approved,
      'approval_fingerprint', app_private.shipment_approved_fingerprint(header.id)
    ),
    cleaned_key
  );
  perform app_private.write_audit(
    auth.uid(), 'approve_short_shipment', 'order_shipments', header.id,
    pg_catalog.jsonb_build_object('approved_cases', total_approved)
  );

  return app_private.shipment_payload(header.id);
end;
$$;

create or replace function public.cancel_short_shipment(
  target_shipment uuid,
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
  header public.order_shipments;
  replay uuid;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_reason := pg_catalog.btrim(coalesce(cancel_reason, ''));
  if char_length(cleaned_reason) not between 1 and 500 then
    raise exception 'cancellation reason is required' using errcode = '23514';
  end if;

  replay := app_private.replay_shipment_event(cleaned_key, 'cancelled', target_shipment);
  if replay is not null then
    return app_private.shipment_payload(replay);
  end if;

  perform set_config('app.shipment_write', 'on', true);
  header := app_private.lock_shipment(target_shipment, expected_version);

  if not (
    app_private.has_permission('shipments.manage')
    or app_private.has_permission('shipments.approve')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  if not app_private.can_work_at_branch(header.branch_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if header.status in ('dispatched', 'cancelled') then
    raise exception 'shipment cannot be cancelled from status %', header.status
      using errcode = '23514';
  end if;

  update public.order_shipments
  set
    status = 'cancelled',
    cancelled_by = auth.uid(),
    cancelled_at = pg_catalog.clock_timestamp(),
    cancellation_reason = cleaned_reason,
    cancel_idempotency_key = cleaned_key,
    version = header.version + 1
  where id = header.id;

  perform app_private.shipment_event(
    header.id, 'cancelled', header.status, 'cancelled', header.version + 1,
    pg_catalog.jsonb_build_object('reason', cleaned_reason),
    cleaned_key
  );
  perform app_private.write_audit(
    auth.uid(), 'cancel_short_shipment', 'order_shipments', header.id,
    pg_catalog.jsonb_build_object('reason', cleaned_reason)
  );

  return app_private.shipment_payload(header.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Handoff + dispatch readiness. Shortage is allowed iff approved shipment.
-- ---------------------------------------------------------------------------
create or replace function app_private.assert_picking_no_short_shipment(target_request uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  shipment public.order_shipments%rowtype;
begin
  if not exists (
    select 1
    from public.stock_picking_exceptions
    where stock_picking_exceptions.picking_request_id = target_request
      and stock_picking_exceptions.exception_type = 'shortage'
  ) then
    return;
  end if;

  shipment := app_private.open_shipment_for_picking(target_request);
  if shipment.id is null or shipment.status is distinct from 'approved' then
    raise exception
      'Short picks cannot be handed to dispatch until Accounts approves a short-shipment document for the confirmed picked lots.'
      using errcode = '23514';
  end if;

  if shipment.picked_fingerprint is distinct from
      app_private.shipment_picked_fingerprint(target_request)
  then
    raise exception
      'short-shipment picked quantities no longer match the warehouse snapshot'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.assert_picking_no_short_shipment(uuid)
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
  shipment public.order_shipments%rowtype;
  has_shortage boolean := false;
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

  shipment := app_private.open_shipment_for_picking(picking.id);
  has_shortage := exists (
    select 1
    from public.stock_picking_exceptions
    where stock_picking_exceptions.picking_request_id = picking.id
      and stock_picking_exceptions.exception_type = 'shortage'
  );

  if shipment.id is not null then
    if shipment.status is distinct from 'approved' then
      raise exception 'dispatch of a short shipment requires Accounts approval'
        using errcode = '23514';
    end if;
    if shipment.order_id is distinct from selected.id
      or shipment.branch_id is distinct from picking.branch_id
      or shipment.shop_id is distinct from selected.shop_id
    then
      raise exception 'short-shipment does not match the order godown'
        using errcode = '23514';
    end if;
    if shipment.picked_fingerprint is distinct from
        app_private.shipment_picked_fingerprint(picking.id)
    then
      raise exception 'short-shipment picked quantities no longer match the warehouse snapshot'
        using errcode = '23514';
    end if;
    if shipment.approval_fingerprint is distinct from
        app_private.shipment_approved_fingerprint(shipment.id)
    then
      raise exception 'short-shipment approval is stale' using errcode = '23514';
    end if;
    if exists (
      select 1
      from public.stock_reservations
      where stock_reservations.picking_request_id = picking.id
        and stock_reservations.status = 'active'
        and not exists (
          select 1
          from public.order_shipment_lots
          where order_shipment_lots.shipment_id = shipment.id
            and order_shipment_lots.reservation_id = stock_reservations.id
        )
    ) then
      raise exception 'short-shipment is missing a reserved lot' using errcode = '23514';
    end if;
    if exists (
      select 1
      from public.order_shipment_lots
      join public.stock_reservations
        on stock_reservations.id = order_shipment_lots.reservation_id
      where order_shipment_lots.shipment_id = shipment.id
        and order_shipment_lots.approved_cases > stock_reservations.picked_cases
    ) then
      raise exception 'approved shipment exceeds confirmed picked cases'
        using errcode = '23514';
    end if;
  elsif has_shortage then
    raise exception 'dispatch is blocked by unresolved picking exceptions'
      using errcode = '23514';
  else
    select count(*)
    into mismatch
    from public.order_lines
    where order_lines.order_id = selected.id
      and order_lines.requested_cases is distinct from (
        select coalesce(sum(stock_reservations.reserved_cases), 0)
          + coalesce((
            select sum(damage_stock_holds.quantity_cases)
            from public.damage_stock_holds
            join public.stock_reservations converted
              on converted.id = damage_stock_holds.source_reservation_id
            where converted.order_line_id = order_lines.id
              and damage_stock_holds.hold_kind = 'reservation_conversion'
              and damage_stock_holds.status in (
                'active', 'transferred', 'written_off', 'returned_supplier'
              )
          ), 0)
        from public.stock_reservations
        where stock_reservations.order_line_id = order_lines.id
          and stock_reservations.status = 'active'
      );

    if mismatch > 0 then
      raise exception 'dispatch quantities do not match the verified order'
        using errcode = '23514';
    end if;
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

  if shipment.id is null then
    select count(*)
    into blocking
    from public.stock_picking_exceptions
    where stock_picking_exceptions.picking_request_id = picking.id
      and stock_picking_exceptions.exception_type = 'shortage';

    if blocking > 0 then
      raise exception 'dispatch is blocked by unresolved picking exceptions'
        using errcode = '23514';
    end if;
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

create or replace function app_private.create_linked_backorder(
  p_shipment uuid,
  p_parent public.orders,
  p_actor uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
  remainder jsonb;
  existing uuid;
  bo_key text;
begin
  if p_parent.parent_order_id is not null then
    raise exception 'short-shipment of a backorder is not supported'
      using errcode = '23514';
  end if;

  select orders.id into existing
  from public.orders
  where orders.originating_shipment_id = p_shipment
    and orders.status is distinct from 'cancelled';

  if existing is not null then
    return existing;
  end if;

  select coalesce(
    (
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'product_id', order_shipment_lines.product_id,
          'requested_cases',
            order_shipment_lines.ordered_cases - order_shipment_lines.approved_cases
        )
        order by order_shipment_lines.product_id
      )
      from public.order_shipment_lines
      where order_shipment_lines.shipment_id = p_shipment
        and order_shipment_lines.ordered_cases > order_shipment_lines.approved_cases
    ),
    '[]'::jsonb
  )
  into remainder;

  if pg_catalog.jsonb_array_length(remainder) < 1 then
    return null;
  end if;

  -- Idempotency keys allow letters, numbers, underscore, hyphen only.
  bo_key := 'bo-' || replace(p_shipment::text, '-', '');

  insert into public.orders (
    shop_id, branch_id, source, source_reference, notes, created_by,
    status, version, idempotency_key, parent_order_id, originating_shipment_id,
    fulfilment_status, submitted_at, submitted_by
  )
  values (
    p_parent.shop_id,
    p_parent.branch_id,
    'backorder',
    p_parent.order_number,
    'Linked backorder for unfulfilled cases from ' || p_parent.order_number,
    p_parent.created_by,
    'submitted',
    1,
    bo_key,
    p_parent.id,
    p_shipment,
    'open',
    pg_catalog.clock_timestamp(),
    p_actor
  )
  returning id into created_id;

  perform app_private.replace_order_lines(created_id, remainder);

  insert into public.order_events (
    order_id, event_type, from_status, to_status, actor_id, note, version,
    idempotency_key, line_snapshot
  )
  values (
    created_id, 'created', null, 'draft', p_actor,
    'Linked backorder', 1, bo_key || '-created', remainder
  );

  insert into public.order_events (
    order_id, event_type, from_status, to_status, actor_id, note, version,
    idempotency_key, line_snapshot
  )
  values (
    created_id, 'submitted', 'draft', 'submitted', p_actor,
    'Awaiting verification. Stock is not reserved.', 1, bo_key || '-submitted', remainder
  );

  return created_id;
exception
  when unique_violation then
    select orders.id into existing
    from public.orders
    where orders.originating_shipment_id = p_shipment
      and orders.status is distinct from 'cancelled';
    if existing is not null then
      return existing;
    end if;
    raise;
end;
$$;

revoke all on function app_private.create_linked_backorder(uuid, public.orders, uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. confirm_dispatch: full path unchanged; partial path uses approved lots.
-- ---------------------------------------------------------------------------
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
  shipment public.order_shipments%rowtype;
  note public.delivery_notes%rowtype;
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
  backorder uuid;
  debit_sql_cases integer;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.dispatch_write', 'on', true);
  perform set_config('app.picking_write', 'on', true);
  perform set_config('app.shipment_write', 'on', true);

  -- Lock order: order → DN → picking → shipment → dispatch → reservations →
  -- products → locations → lots → balances.
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

  select * into note
  from public.delivery_notes
  where delivery_notes.order_id = selected.id
    and delivery_notes.status is distinct from 'voided'
  order by delivery_notes.created_at desc
  for update
  limit 1;

  select * into picking
  from public.stock_picking_requests
  where stock_picking_requests.id = looked_up_picking
  for update;

  select * into shipment
  from public.order_shipments
  where order_shipments.picking_request_id = picking.id
    and order_shipments.status is distinct from 'cancelled'
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

  if note.id is not null and note.status is distinct from 'acknowledged' then
    raise exception 'dispatch requires an acknowledged delivery note'
      using errcode = '23514';
  end if;

  if shipment.id is not null and shipment.status is distinct from 'approved' then
    raise exception 'dispatch of a short shipment requires Accounts approval'
      using errcode = '23514';
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

  if shipment.id is not null then
    if exists (
      select 1
      from public.order_shipment_lots
      join public.stock_lot_balances
        on stock_lot_balances.lot_id = order_shipment_lots.lot_id
       and stock_lot_balances.crate_id = order_shipment_lots.crate_id
      where order_shipment_lots.shipment_id = shipment.id
        and order_shipment_lots.approved_cases > 0
        and stock_lot_balances.quantity < order_shipment_lots.approved_cases
    ) then
      raise exception 'reserved cartons are no longer physically available'
        using errcode = '23514';
    end if;

    -- reserved_cases >= 1 on every row. Zero-ship grains are released in place.
    -- original_reserved (snapshot) = shipped + released_unused + remaining(0).
    update public.stock_reservations as reserved
    set
      reserved_cases = case
        when lots.approved_cases > 0 then lots.approved_cases
        else reserved.reserved_cases
      end,
      picked_cases = case
        when lots.approved_cases > 0 then lots.approved_cases
        else reserved.picked_cases
      end,
      status = case
        when lots.approved_cases > 0 then 'consumed'
        else 'released'
      end
    from public.order_shipment_lots as lots
    where lots.reservation_id = reserved.id
      and lots.shipment_id = shipment.id
      and reserved.status = 'active';

    update public.order_shipment_lots
    set
      shipped_cases = approved_cases,
      released_cases = reserved_cases - approved_cases
    where shipment_id = shipment.id;

    select
      coalesce(sum(order_shipment_lots.shipped_cases), 0),
      (array_agg(order_shipment_lots.product_id order by order_shipment_lots.product_id))[1],
      count(distinct order_shipment_lots.crate_id)
        filter (where order_shipment_lots.shipped_cases > 0),
      (
        array_agg(order_shipment_lots.crate_id order by order_shipment_lots.crate_id)
        filter (where order_shipment_lots.shipped_cases > 0)
      )[1]
    into total_cases, first_product, crate_count, single_crate
    from public.order_shipment_lots
    where order_shipment_lots.shipment_id = shipment.id;
  else
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
  end if;

  if total_cases < 1 then
    raise exception 'dispatch requires active reservations' using errcode = '23514';
  end if;

  txn_key := 'dispatch:' || header.id::text;

  -- Unique-violation handling is scoped to the DISPATCH transaction row so a
  -- later backorder uniqueness failure cannot be mistaken for idempotent success.
  begin
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
  exception
    when unique_violation then
      if exists (
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

  if shipment.id is not null then
    for grain in
      select
        order_shipment_lots.product_id,
        order_shipment_lots.crate_id,
        order_shipment_lots.lot_id,
        sum(order_shipment_lots.shipped_cases)::integer as debit_cases
      from public.order_shipment_lots
      where order_shipment_lots.shipment_id = shipment.id
        and order_shipment_lots.shipped_cases > 0
      group by order_shipment_lots.product_id, order_shipment_lots.crate_id,
        order_shipment_lots.lot_id
      order by order_shipment_lots.crate_id, order_shipment_lots.lot_id
    loop
      debit_sql_cases := grain.debit_cases;
      insert into public.stock_ledger (
        transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
      )
      values (
        created_txn,
        grain.product_id,
        grain.crate_id,
        - debit_sql_cases,
        auth.uid(),
        pg_catalog.clock_timestamp(),
        grain.lot_id
      );

      lot_deltas := lot_deltas || jsonb_build_array(jsonb_build_object(
        'product_id', grain.product_id,
        'lot_id', grain.lot_id,
        'crate_id', grain.crate_id,
        'quantity', - debit_sql_cases
      ));
    end loop;
  else
    for grain in
      select
        stock_reservations.product_id,
        stock_reservations.crate_id,
        stock_reservations.lot_id,
        sum(stock_reservations.reserved_cases)::integer as reserved_cases
      from public.stock_reservations
      where stock_reservations.picking_request_id = picking.id
        and stock_reservations.status = 'consumed'
      group by stock_reservations.product_id, stock_reservations.crate_id,
        stock_reservations.lot_id
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
  end if;

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
      'fingerprint', fingerprint,
      'shipment_id', shipment.id
    ),
    cleaned_key
  );

  if shipment.id is not null then
    backorder := app_private.create_linked_backorder(shipment.id, selected, auth.uid());
    if exists (
      select 1
      from public.order_shipment_lines
      where order_shipment_lines.shipment_id = shipment.id
        and order_shipment_lines.ordered_cases > order_shipment_lines.approved_cases
    ) and backorder is null then
      raise exception 'linked backorder was not created for the unfulfilled remainder'
        using errcode = '23514';
    end if;

    update public.orders
    set fulfilment_status = case
      when backorder is null then 'fulfilled'
      else 'partially_fulfilled'
    end
    where id = selected.id;

    update public.order_shipments
    set
      status = 'dispatched',
      dispatch_request_id = header.id,
      backorder_id = backorder,
      dispatched_by = auth.uid(),
      dispatched_at = pg_catalog.clock_timestamp(),
      version = shipment.version + 1
    where id = shipment.id;

    perform app_private.shipment_event(
      shipment.id, 'dispatched', 'approved', 'dispatched', shipment.version + 1,
      pg_catalog.jsonb_build_object(
        'transaction_id', created_txn,
        'total_cases', total_cases,
        'backorder_id', backorder
      ),
      'sh-dispatch-' || replace(header.id::text, '-', '')
    );
  else
    update public.orders
    set fulfilment_status = 'fulfilled'
    where id = selected.id;
  end if;

  perform app_private.write_audit(
    auth.uid(), 'confirm_dispatch', 'stock_dispatch_requests', header.id,
    pg_catalog.jsonb_build_object(
      'request_number', header.request_number,
      'transaction_id', created_txn,
      'total_cases', total_cases,
      'shipment_id', shipment.id,
      'backorder_id', backorder
    )
  );

  return app_private.dispatch_payload(header.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Read payloads: shipment snapshot without claiming live cutover.
-- ---------------------------------------------------------------------------
create or replace function app_private.picking_fulfilment_snapshot(target_request uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  ordered integer := 0;
  allocated integer := 0;
  picked integer := 0;
  shortage integer := 0;
  has_shortage boolean := false;
  shipment public.order_shipments%rowtype;
begin
  select coalesce(sum(order_lines.requested_cases), 0)
    into ordered
  from public.order_lines
  join public.stock_picking_requests
    on stock_picking_requests.order_id = order_lines.order_id
  where stock_picking_requests.id = target_request;

  select coalesce(sum(stock_reservations.reserved_cases), 0)
    into allocated
  from public.stock_reservations
  where stock_reservations.picking_request_id = target_request
    and stock_reservations.status is distinct from 'released';

  select coalesce(sum(stock_reservations.picked_cases), 0)
    into picked
  from public.stock_reservations
  where stock_reservations.picking_request_id = target_request;

  select coalesce(sum(stock_picking_exceptions.quantity), 0)
    into shortage
  from public.stock_picking_exceptions
  where stock_picking_exceptions.picking_request_id = target_request
    and stock_picking_exceptions.exception_type = 'shortage';

  has_shortage := exists (
    select 1
    from public.stock_picking_exceptions
    where stock_picking_exceptions.picking_request_id = target_request
      and stock_picking_exceptions.exception_type = 'shortage'
  );

  shipment := app_private.open_shipment_for_picking(target_request);

  return pg_catalog.jsonb_build_object(
    'ordered_cases', ordered,
    'allocated_cases', allocated,
    'picked_cases', picked,
    'remaining_cases', greatest(allocated - picked, 0),
    'shortfall_cases', greatest(ordered - allocated, 0),
    'shortage_cases', coalesce(shortage, 0),
    'has_shortage', has_shortage,
    'short_shipment_operational', false,
    'short_shipment_workflow', true,
    'proposed_shipment_cases', coalesce((
      select sum(order_shipment_lines.proposed_cases)::integer
      from public.order_shipment_lines
      where order_shipment_lines.shipment_id = shipment.id
    ), 0),
    'approved_shipment_cases', coalesce((
      select sum(order_shipment_lines.approved_cases)::integer
      from public.order_shipment_lines
      where order_shipment_lines.shipment_id = shipment.id
    ), 0),
    'dispatched_cases', coalesce((
      select sum(order_shipment_lots.shipped_cases)::integer
      from public.order_shipment_lots
      where order_shipment_lots.shipment_id = shipment.id
    ), 0),
    'outstanding_cases', case
      when shipment.id is null then greatest(ordered - picked, 0)
      else coalesce((
        select sum(
          order_shipment_lines.ordered_cases - order_shipment_lines.approved_cases
        )::integer
        from public.order_shipment_lines
        where order_shipment_lines.shipment_id = shipment.id
      ), 0)
    end,
    'shipment_status', shipment.status,
    'shipment_number', shipment.shipment_number,
    'shipment_revision', shipment.revision,
    'gm_confirmed', shipment.gm_confirmed_at is not null,
    'accounts_approved', shipment.accounts_approved_at is not null
  );
end;
$$;

revoke all on function app_private.picking_fulfilment_snapshot(uuid)
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
  note public.delivery_notes%rowtype;
  shipment public.order_shipments%rowtype;
begin
  select *
    into header
  from public.stock_picking_requests
  where id = target_request;

  if not found or not app_private.picking_can_view(header) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select * into selected_order from public.orders where id = header.order_id;
  note := app_private.open_delivery_note_for_order(header.order_id);
  shipment := app_private.open_shipment_for_picking(header.id);

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
    'delivery_note_status', note.status,
    'fulfilment', app_private.picking_fulfilment_snapshot(header.id),
    -- Thin summary so assigned pickers can still load the task. Full lots
    -- stay on get_shipment / get_order for GM and Accounts.
    'open_shipment', case
      when shipment.id is null then null
      else pg_catalog.jsonb_build_object(
        'id', shipment.id,
        'shipment_number', shipment.shipment_number,
        'status', shipment.status,
        'revision', shipment.revision,
        'version', shipment.version,
        'delivery_note_id', shipment.delivery_note_id,
        'dispatch_request_id', shipment.dispatch_request_id,
        'backorder_id', shipment.backorder_id,
        'gm_confirmed_at', shipment.gm_confirmed_at,
        'accounts_approved_at', shipment.accounts_approved_at,
        'ordered_cases', coalesce((
          select sum(order_shipment_lines.ordered_cases)::integer
          from public.order_shipment_lines
          where order_shipment_lines.shipment_id = shipment.id
        ), 0),
        'picked_cases', coalesce((
          select sum(order_shipment_lines.picked_cases)::integer
          from public.order_shipment_lines
          where order_shipment_lines.shipment_id = shipment.id
        ), 0),
        'approved_cases', coalesce((
          select sum(order_shipment_lines.approved_cases)::integer
          from public.order_shipment_lines
          where order_shipment_lines.shipment_id = shipment.id
        ), 0)
      )
    end,
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

create or replace function public.get_order(target_order uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  note public.delivery_notes%rowtype;
  picking public.stock_picking_requests%rowtype;
  shipment public.order_shipments%rowtype;
  cutover text[];
  backorder public.orders%rowtype;
begin
  if target_order is null or not app_private.can_view_order(target_order) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  note := app_private.open_delivery_note_for_order(target_order);
  picking := app_private.open_picking_request_for_order(target_order);
  cutover := app_private.picking_cutover_blockers();
  if picking.id is not null then
    shipment := app_private.open_shipment_for_picking(picking.id);
  end if;

  select * into backorder
  from public.orders
  where orders.parent_order_id = target_order
    and orders.status is distinct from 'cancelled'
  order by orders.created_at desc
  limit 1;

  return pg_catalog.jsonb_build_object(
    'order',
    (select to_jsonb(orders) from public.orders where orders.id = target_order),
    'lines',
    coalesce(
      (
        select pg_catalog.jsonb_agg(to_jsonb(order_lines) order by order_lines.created_at)
        from public.order_lines
        where order_lines.order_id = target_order
      ),
      '[]'::jsonb
    ),
    'events',
    coalesce(
      (
        select pg_catalog.jsonb_agg(to_jsonb(order_events) order by order_events.created_at)
        from public.order_events
        where order_events.order_id = target_order
      ),
      '[]'::jsonb
    ),
    'open_delivery_note',
    case
      when note.id is null then null
      else pg_catalog.jsonb_build_object(
        'id', note.id,
        'delivery_note_number', note.delivery_note_number,
        'status', note.status,
        'version', note.version,
        'acknowledged_at', note.acknowledged_at,
        'acknowledged_by', note.acknowledged_by
      )
    end,
    'open_picking_request',
    case
      when picking.id is null then null
      else pg_catalog.jsonb_build_object(
        'id', picking.id,
        'request_number', picking.request_number,
        'status', picking.status,
        'version', picking.version,
        'fulfilment', app_private.picking_fulfilment_snapshot(picking.id)
      )
    end,
    'open_shipment',
    case
      when shipment.id is null then null
      else app_private.shipment_payload(shipment.id)
    end,
    'linked_backorder',
    case
      when backorder.id is null then null
      else pg_catalog.jsonb_build_object(
        'id', backorder.id,
        'order_number', backorder.order_number,
        'status', backorder.status,
        'fulfilment_status', backorder.fulfilment_status,
        'source', backorder.source
      )
    end,
    'picking_cutover',
    pg_catalog.jsonb_build_object(
      'dual_write_enabled', exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.dual_write_enabled' and value = 'true'::jsonb
      ),
      'aggregate_only_blocked', exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.aggregate_only_blocked' and value = 'true'::jsonb
      ),
      'blockers', to_jsonb(coalesce(cutover, '{}'::text[]))
    )
  );
end;
$$;

revoke all on function public.get_order(uuid)
  from public, anon, service_role;
grant execute on function public.get_order(uuid) to authenticated;

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
  shipment public.order_shipments%rowtype;
  blockers text[] := '{}';
  cutover text[];
  eligible boolean := true;
  note public.delivery_notes%rowtype;
  dispatch_cases integer := 0;
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
    shipment := app_private.open_shipment_for_picking(picking.id);
    begin
      perform app_private.assert_dispatch_handoff_ready(selected, picking);
    exception
      when sqlstate '23514' then
        eligible := false;
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

  if shipment.id is not null then
    dispatch_cases := coalesce((
      select sum(order_shipment_lines.approved_cases)::integer
      from public.order_shipment_lines
      where order_shipment_lines.shipment_id = shipment.id
    ), 0);
  else
    dispatch_cases := coalesce((
      select sum(stock_reservations.reserved_cases)::integer
      from public.stock_reservations
      where stock_reservations.picking_request_id = picking.id
        and stock_reservations.status = 'active'
    ), 0);
  end if;

  return pg_catalog.jsonb_build_object(
    'order_id', selected.id,
    'order_number', selected.order_number,
    'order_status', selected.status,
    'order_version', selected.version,
    'fulfilment_status', selected.fulfilment_status,
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
    'shipment_id', shipment.id,
    'shipment_number', shipment.shipment_number,
    'shipment_status', shipment.status,
    'shipment_revision', shipment.revision,
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
    'total_cases', dispatch_cases,
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

revoke all on function public.preview_dispatch(uuid) from public, anon, service_role;
grant execute on function public.preview_dispatch(uuid) to authenticated;

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

revoke all on function public.get_shipment(uuid)
  from public, anon, service_role;
revoke all on function public.create_short_shipment(uuid, integer, text)
  from public, anon, service_role;
revoke all on function public.confirm_short_shipment_quantities(uuid, integer, text)
  from public, anon, service_role;
revoke all on function public.approve_short_shipment(uuid, integer, jsonb, text)
  from public, anon, service_role;
revoke all on function public.cancel_short_shipment(uuid, integer, text, text)
  from public, anon, service_role;
revoke all on function public.confirm_dispatch(uuid, integer, text)
  from public, anon, service_role;

grant execute on function public.get_shipment(uuid) to authenticated;
grant execute on function public.create_short_shipment(uuid, integer, text) to authenticated;
grant execute on function public.confirm_short_shipment_quantities(uuid, integer, text)
  to authenticated;
grant execute on function public.approve_short_shipment(uuid, integer, jsonb, text)
  to authenticated;
grant execute on function public.cancel_short_shipment(uuid, integer, text, text)
  to authenticated;
grant execute on function public.confirm_dispatch(uuid, integer, text) to authenticated;

comment on function public.create_short_shipment(uuid, integer, text) is
  'M7.3B. Snapshot picked lots into a draft shipment document. Does not post stock.';

comment on function public.confirm_dispatch(uuid, integer, text) is
  'M3/M7.3B stock writer. Full path consumes reserved_cases. Approved short-shipment path deducts shipped lots only and creates a linked backorder.';

notify pgrst, 'reload schema';



