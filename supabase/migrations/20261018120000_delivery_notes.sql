-- Phase 4.2A delivery-note foundation.
-- Tables, permissions, forced RLS, numbering, and read-only RPCs.
-- Does not create, generate, send, acknowledge, or void delivery notes via RPCs.
-- Does not change order status, stock balances, or the deployed Phase 4.1 migration.
-- Lifecycle designed for: draft → generated → sent → acknowledged (void from eligible pre-ack states).

insert into public.permissions (code, description)
values (
  'delivery_notes.acknowledge',
  'Acknowledge receipt of a delivery note sent to an authorized fulfilling godown.'
)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'delivery_notes.acknowledge'
where roles.code = 'godown_manager'
on conflict do nothing;

create sequence public.delivery_note_seq;

revoke all on sequence public.delivery_note_seq from public, anon, authenticated;

create table public.delivery_notes (
  id uuid primary key default gen_random_uuid(),
  delivery_note_number text not null,
  order_id uuid not null references public.orders (id) on delete restrict,
  shop_id uuid not null references public.shops (id) on delete restrict,
  branch_id uuid not null references public.branches (id) on delete restrict,
  status text not null default 'draft',
  version integer not null default 1,
  idempotency_key text not null,
  created_by uuid not null references public.profiles (id) on delete restrict,
  generated_at timestamptz,
  generated_by uuid references public.profiles (id) on delete restrict,
  sent_at timestamptz,
  sent_by uuid references public.profiles (id) on delete restrict,
  acknowledged_at timestamptz,
  acknowledged_by uuid references public.profiles (id) on delete restrict,
  voided_at timestamptz,
  voided_by uuid references public.profiles (id) on delete restrict,
  void_reason text,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint delivery_notes_number_key unique (delivery_note_number),
  constraint delivery_notes_idempotency_key unique (idempotency_key),
  constraint delivery_notes_status_check check (
    status in ('draft', 'generated', 'sent', 'acknowledged', 'voided')
  ),
  constraint delivery_notes_version_check check (version >= 1),
  constraint delivery_notes_void_reason_length check (
    void_reason is null
    or (
      char_length(btrim(void_reason)) between 1 and 500
      and void_reason = btrim(void_reason)
    )
  ),
  constraint delivery_notes_draft_shape check (
    status <> 'draft'
    or (
      generated_at is null
      and generated_by is null
      and sent_at is null
      and sent_by is null
      and acknowledged_at is null
      and acknowledged_by is null
      and voided_at is null
      and voided_by is null
      and void_reason is null
    )
  ),
  constraint delivery_notes_generated_shape check (
    status <> 'generated'
    or (
      generated_at is not null
      and generated_by is not null
      and sent_at is null
      and sent_by is null
      and acknowledged_at is null
      and acknowledged_by is null
      and voided_at is null
      and voided_by is null
      and void_reason is null
    )
  ),
  constraint delivery_notes_sent_shape check (
    status <> 'sent'
    or (
      generated_at is not null
      and generated_by is not null
      and sent_at is not null
      and sent_by is not null
      and acknowledged_at is null
      and acknowledged_by is null
      and voided_at is null
      and voided_by is null
      and void_reason is null
    )
  ),
  constraint delivery_notes_acknowledged_shape check (
    status <> 'acknowledged'
    or (
      generated_at is not null
      and generated_by is not null
      and sent_at is not null
      and sent_by is not null
      and acknowledged_at is not null
      and acknowledged_by is not null
      and voided_at is null
      and voided_by is null
      and void_reason is null
    )
  ),
  constraint delivery_notes_voided_shape check (
    status <> 'voided'
    or (
      voided_at is not null
      and voided_by is not null
      and void_reason is not null
      and acknowledged_at is null
      and acknowledged_by is null
    )
  )
);

comment on table public.delivery_notes is
  'Delivery note for a verified shop order (ORD-03/04). Phase 4.2A stores rows and read APIs only. No stock reservation or deduction.';

comment on column public.delivery_notes.branch_id is
  'Fulfilling godown copied from orders.branch_id at create time.';

comment on column public.delivery_notes.created_by is
  'Original Accounts creator. Later transitions do not change this column.';

create unique index delivery_notes_open_order_key
  on public.delivery_notes (order_id)
  where status <> 'voided';

create index delivery_notes_status_created_at_idx
  on public.delivery_notes (status, created_at desc);

create index delivery_notes_shop_id_idx on public.delivery_notes (shop_id);
create index delivery_notes_branch_id_idx on public.delivery_notes (branch_id);
create index delivery_notes_created_by_idx on public.delivery_notes (created_by);
create index delivery_notes_order_id_idx on public.delivery_notes (order_id);

create trigger delivery_notes_set_updated_at
  before update on public.delivery_notes
  for each row execute function app_private.set_updated_at();

create table public.delivery_note_lines (
  id uuid primary key default gen_random_uuid(),
  delivery_note_id uuid not null references public.delivery_notes (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  requested_cases integer not null,
  created_at timestamptz not null default pg_catalog.now(),
  constraint delivery_note_lines_note_product_key unique (delivery_note_id, product_id),
  constraint delivery_note_lines_requested_cases_check check (
    requested_cases between 1 and 1000000
  )
);

create index delivery_note_lines_delivery_note_id_idx
  on public.delivery_note_lines (delivery_note_id);

comment on table public.delivery_note_lines is
  'Whole carton cases copied from a verified order. Immutable after insert. No price or reserved quantity.';

create table public.delivery_note_events (
  id uuid primary key default gen_random_uuid(),
  delivery_note_id uuid not null references public.delivery_notes (id) on delete restrict,
  event_type text not null,
  from_status text,
  to_status text not null,
  actor_id uuid not null,
  note text,
  version integer not null,
  idempotency_key text not null,
  line_snapshot jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint delivery_note_events_idempotency_key unique (idempotency_key),
  constraint delivery_note_events_type_check check (
    event_type in ('created', 'generated', 'sent', 'acknowledged', 'voided')
  ),
  constraint delivery_note_events_status_check check (
    to_status in ('draft', 'generated', 'sent', 'acknowledged', 'voided')
    and (
      from_status is null
      or from_status in ('draft', 'generated', 'sent', 'acknowledged', 'voided')
    )
  ),
  constraint delivery_note_events_version_check check (version >= 1),
  constraint delivery_note_events_note_length check (
    note is null
    or (
      char_length(btrim(note)) between 1 and 500
      and note = btrim(note)
    )
  )
);

create index delivery_note_events_note_id_created_at_idx
  on public.delivery_note_events (delivery_note_id, created_at);

comment on table public.delivery_note_events is
  'Append-only delivery-note history. actor_id is copied and has no foreign key.';

create or replace function app_private.assign_delivery_note_number()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' and new.delivery_note_number is null then
    new.delivery_note_number := 'DN-'
      || to_char(pg_catalog.clock_timestamp() at time zone 'utc', 'YYYYMMDD')
      || '-'
      || pg_catalog.lpad(pg_catalog.nextval('public.delivery_note_seq')::text, 6, '0');
  end if;

  if tg_op = 'UPDATE' and new.delivery_note_number is distinct from old.delivery_note_number then
    raise exception 'delivery note number is immutable' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and new.created_by is distinct from old.created_by then
    raise exception 'delivery note creator is immutable' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and new.idempotency_key is distinct from old.idempotency_key then
    raise exception 'idempotency key is immutable' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and new.order_id is distinct from old.order_id then
    raise exception 'delivery note order is immutable' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and old.status in ('acknowledged', 'voided') then
    raise exception 'delivery note is terminal' using errcode = '23514';
  end if;

  new.idempotency_key := app_private.clean_idempotency_key(new.idempotency_key);
  return new;
end;
$$;

create trigger delivery_notes_assign_number
  before insert or update on public.delivery_notes
  for each row execute function app_private.assign_delivery_note_number();

create or replace function app_private.reject_delivery_note_event_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.idempotency_key := app_private.clean_idempotency_key(new.idempotency_key);
    return new;
  end if;

  raise exception 'delivery note history is append-only' using errcode = '42501';
end;
$$;

create trigger delivery_note_events_append_only
  before insert or update or delete on public.delivery_note_events
  for each row execute function app_private.reject_delivery_note_event_change();

create or replace function app_private.reject_delivery_note_line_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    return new;
  end if;

  raise exception 'delivery note lines are immutable' using errcode = '42501';
end;
$$;

create trigger delivery_note_lines_immutable
  before update or delete on public.delivery_note_lines
  for each row execute function app_private.reject_delivery_note_line_change();

revoke all on function app_private.assign_delivery_note_number()
  from public, anon, authenticated, service_role;
revoke all on function app_private.reject_delivery_note_event_change()
  from public, anon, authenticated, service_role;
revoke all on function app_private.reject_delivery_note_line_change()
  from public, anon, authenticated, service_role;

create or replace function app_private.can_view_delivery_note(target_note uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.delivery_notes
    where delivery_notes.id = target_note
      and (
        (select app_private.has_permission('operations.monitor'))
        or (
          (select app_private.has_permission('delivery_notes.issue'))
          and (select app_private.can_work_at_branch(delivery_notes.branch_id))
        )
        or (
          (select app_private.has_permission('delivery_notes.acknowledge'))
          and (select app_private.can_work_at_branch(delivery_notes.branch_id))
        )
      )
  );
$$;

revoke all on function app_private.can_view_delivery_note(uuid) from public, anon;
grant execute on function app_private.can_view_delivery_note(uuid) to authenticated;

alter table public.delivery_notes enable row level security;
alter table public.delivery_note_lines enable row level security;
alter table public.delivery_note_events enable row level security;

alter table public.delivery_notes force row level security;
alter table public.delivery_note_lines force row level security;
alter table public.delivery_note_events force row level security;

create policy delivery_notes_select_authorized
  on public.delivery_notes
  for select
  to authenticated
  using ((select app_private.can_view_delivery_note(id)));

create policy delivery_note_lines_select_authorized
  on public.delivery_note_lines
  for select
  to authenticated
  using ((select app_private.can_view_delivery_note(delivery_note_id)));

create policy delivery_note_events_select_authorized
  on public.delivery_note_events
  for select
  to authenticated
  using ((select app_private.can_view_delivery_note(delivery_note_id)));

revoke all on table public.delivery_notes from public, anon, authenticated, service_role;
revoke all on table public.delivery_note_lines from public, anon, authenticated, service_role;
revoke all on table public.delivery_note_events from public, anon, authenticated, service_role;

grant select on table public.delivery_notes to authenticated;
grant select on table public.delivery_note_lines to authenticated;
grant select on table public.delivery_note_events to authenticated;

create or replace function public.list_delivery_notes(
  status_filter text default null,
  shop_filter uuid default null,
  branch_filter uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cleaned text := nullif(pg_catalog.btrim(coalesce(status_filter, '')), '');
begin
  if (select auth.uid()) is null
    or not (
      (select app_private.has_permission('operations.monitor'))
      or (select app_private.has_permission('delivery_notes.issue'))
      or (select app_private.has_permission('delivery_notes.acknowledge'))
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if cleaned is not null
    and cleaned not in ('draft', 'generated', 'sent', 'acknowledged', 'voided')
  then
    raise exception 'delivery note status is invalid' using errcode = '23514';
  end if;

  if branch_filter is not null
    and not (
      (select app_private.has_permission('operations.monitor'))
      or (select app_private.can_work_at_branch(branch_filter))
    )
  then
    raise exception 'godown is not authorized' using errcode = '42501';
  end if;

  return coalesce(
    (
      select pg_catalog.jsonb_agg(to_jsonb(delivery_notes) order by delivery_notes.created_at desc)
      from public.delivery_notes
      where (select app_private.can_view_delivery_note(delivery_notes.id))
        and (cleaned is null or delivery_notes.status = cleaned)
        and (shop_filter is null or delivery_notes.shop_id = shop_filter)
        and (branch_filter is null or delivery_notes.branch_id = branch_filter)
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.get_delivery_note(target_note uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected public.delivery_notes%rowtype;
begin
  if target_note is null or not (select app_private.can_view_delivery_note(target_note)) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into selected
  from public.delivery_notes
  where delivery_notes.id = target_note;

  return pg_catalog.jsonb_build_object(
    'delivery_note',
    to_jsonb(selected),
    'order',
    (
      select pg_catalog.jsonb_build_object(
        'id', orders.id,
        'order_number', orders.order_number,
        'status', orders.status,
        'shop_id', orders.shop_id,
        'branch_id', orders.branch_id
      )
      from public.orders
      where orders.id = selected.order_id
    ),
    'shop',
    (
      select pg_catalog.jsonb_build_object(
        'id', shops.id,
        'name', shops.name,
        'phone', shops.phone,
        'address', shops.address
      )
      from public.shops
      where shops.id = selected.shop_id
    ),
    'godown',
    (
      select pg_catalog.jsonb_build_object(
        'id', branches.id,
        'code', branches.code,
        'name', branches.name
      )
      from public.branches
      where branches.id = selected.branch_id
    ),
    'lines',
    coalesce(
      (
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'id', delivery_note_lines.id,
            'product_id', delivery_note_lines.product_id,
            'requested_cases', delivery_note_lines.requested_cases,
            'sku', products.sku,
            'product_name', products.name,
            'created_at', delivery_note_lines.created_at
          )
          order by delivery_note_lines.created_at
        )
        from public.delivery_note_lines
        join public.products on products.id = delivery_note_lines.product_id
        where delivery_note_lines.delivery_note_id = target_note
      ),
      '[]'::jsonb
    ),
    'events',
    coalesce(
      (
        select pg_catalog.jsonb_agg(to_jsonb(delivery_note_events) order by delivery_note_events.created_at)
        from public.delivery_note_events
        where delivery_note_events.delivery_note_id = target_note
      ),
      '[]'::jsonb
    )
  );
end;
$$;

create or replace function public.list_verified_orders_without_dn()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null
    or not (select app_private.has_permission('delivery_notes.issue'))
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return coalesce(
    (
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', orders.id,
          'order_number', orders.order_number,
          'shop_id', orders.shop_id,
          'branch_id', orders.branch_id,
          'status', orders.status,
          'verified_at', orders.verified_at,
          'created_at', orders.created_at
        )
        order by orders.verified_at desc nulls last, orders.created_at desc
      )
      from public.orders
      where orders.status = 'verified'
        and (select app_private.can_work_at_branch(orders.branch_id))
        and not exists (
          select 1
          from public.delivery_notes
          where delivery_notes.order_id = orders.id
            and delivery_notes.status <> 'voided'
        )
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function public.list_delivery_notes(text, uuid, uuid) from public, anon;
revoke all on function public.get_delivery_note(uuid) from public, anon;
revoke all on function public.list_verified_orders_without_dn() from public, anon;

grant execute on function public.list_delivery_notes(text, uuid, uuid) to authenticated;
grant execute on function public.get_delivery_note(uuid) to authenticated;
grant execute on function public.list_verified_orders_without_dn() to authenticated;

comment on function public.list_delivery_notes(text, uuid, uuid) is
  'Delivery notes visible to the caller. Admin monitors all. Accounts and Godown Manager see authorized godowns only.';

comment on function public.get_delivery_note(uuid) is
  'One visible delivery note with lines, source order reference, shop, godown, and events.';

comment on function public.list_verified_orders_without_dn() is
  'Accounts queue of verified orders with no open (non-voided) delivery note. Branch-scoped.';

-- Phase 4.2A cancellation consistency (design only — cancel_order is not replaced here).
-- Future forward-only migration must guard cancel_order:
--   * verified + no open DN → cancel allowed (Phase 4.1)
--   * open DN in draft/generated/sent → require void first (conservative; no auto-void in 4.2A)
--   * acknowledged DN → cancel blocked; acknowledged DN cannot be voided
-- Lock order for future mutations: FOR UPDATE order, then FOR UPDATE delivery_note (same order always).
comment on column public.delivery_notes.status is
  'draft → generated → sent → acknowledged. voided is terminal. Acknowledged cannot be voided. Order cancel guards are deferred to a later forward-only migration.';
