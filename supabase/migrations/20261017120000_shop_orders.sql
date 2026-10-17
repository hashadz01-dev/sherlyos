-- Phase 4.1A shop-order foundation.
-- Tables, read policies, catalog grants, and read-only RPCs.
-- Does not create, edit, submit, hold, verify, or cancel orders.
-- Does not reserve stock or add a ledger transaction type.
-- Short-stock verification outcome remains undecided and is not implemented.

insert into public.permissions (code, description)
values (
  'shops.read_all',
  'View every active shop. Does not assign salespeople or edit shops.'
);

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from (
  values
    ('accounts', 'shops.read'),
    ('accounts', 'shops.read_all'),
    ('accounts', 'products.read'),
    ('salesperson', 'products.read')
) as grants (role_code, permission_code)
join public.roles on roles.code = grants.role_code
join public.permissions on permissions.code = grants.permission_code;

drop policy if exists products_select_readers on public.products;

create policy products_select_readers
  on public.products
  for select
  to authenticated
  using (
    (select app_private.has_permission('products.manage'))
    or (
      (select app_private.has_permission('products.read'))
      and is_active
    )
  );

drop policy if exists shops_select_authorized on public.shops;

create policy shops_select_authorized
  on public.shops
  for select
  to authenticated
  using (
    (select app_private.has_permission('shops.read'))
    and (
      (select app_private.has_permission('shops.assign'))
      or (
        (select app_private.has_permission('shops.read_all'))
        and is_active
      )
      or exists (
        select 1
        from public.shop_salesperson_assignments
        where shop_salesperson_assignments.shop_id = shops.id
          and shop_salesperson_assignments.salesperson_id = (select auth.uid())
          and shop_salesperson_assignments.is_active
      )
    )
  );

create sequence public.shop_order_seq;

revoke all on sequence public.shop_order_seq from public, anon, authenticated;

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null,
  shop_id uuid not null references public.shops (id) on delete restrict,
  branch_id uuid not null references public.branches (id) on delete restrict,
  source text not null,
  source_reference text,
  notes text,
  created_by uuid not null references public.profiles (id) on delete restrict,
  status text not null default 'draft',
  version integer not null default 1,
  idempotency_key text not null,
  submitted_at timestamptz,
  submitted_by uuid references public.profiles (id) on delete restrict,
  verified_at timestamptz,
  verified_by uuid references public.profiles (id) on delete restrict,
  held_at timestamptz,
  held_by uuid references public.profiles (id) on delete restrict,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id) on delete restrict,
  cancellation_reason text,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint orders_number_key unique (order_number),
  constraint orders_idempotency_key unique (idempotency_key),
  constraint orders_source_check check (
    source in ('salesperson', 'accounts', 'telecalling', 'enquiry')
  ),
  constraint orders_status_check check (
    status in ('draft', 'submitted', 'held', 'verified', 'cancelled')
  ),
  constraint orders_version_check check (version >= 1),
  constraint orders_source_reference_length check (
    source_reference is null
    or (
      char_length(btrim(source_reference)) between 1 and 80
      and source_reference = btrim(source_reference)
    )
  ),
  constraint orders_notes_length check (
    notes is null
    or (
      char_length(btrim(notes)) between 1 and 500
      and notes = btrim(notes)
    )
  ),
  constraint orders_cancellation_reason_length check (
    cancellation_reason is null
    or (
      char_length(btrim(cancellation_reason)) between 1 and 500
      and cancellation_reason = btrim(cancellation_reason)
    )
  ),
  constraint orders_submitted_shape check (
    status <> 'submitted'
    or (submitted_at is not null and submitted_by is not null)
  ),
  constraint orders_held_shape check (
    status <> 'held'
    or (held_at is not null and held_by is not null)
  ),
  constraint orders_verified_shape check (
    status <> 'verified'
    or (verified_at is not null and verified_by is not null)
  ),
  constraint orders_cancelled_shape check (
    status <> 'cancelled'
    or (cancelled_at is not null and cancelled_by is not null)
  )
);

create index orders_status_created_at_idx on public.orders (status, created_at desc);
create index orders_shop_id_idx on public.orders (shop_id);
create index orders_branch_id_idx on public.orders (branch_id);
create index orders_created_by_idx on public.orders (created_by);

create trigger orders_set_updated_at
  before update on public.orders
  for each row execute function app_private.set_updated_at();

comment on table public.orders is
  'Shop order request. Phase 4.1A stores the row only. Verification does not reserve or deduct stock.';

comment on column public.orders.created_by is
  'Original creator. Later edits do not change this column.';

comment on column public.orders.branch_id is
  'Fulfilling godown selected for this order. A shop has no home godown.';

create table public.order_lines (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  requested_cases integer not null,
  created_at timestamptz not null default pg_catalog.now(),
  constraint order_lines_order_product_key unique (order_id, product_id),
  constraint order_lines_requested_cases_check check (requested_cases between 1 and 1000000)
);

create index order_lines_order_id_idx on public.order_lines (order_id);

comment on table public.order_lines is
  'Whole carton cases requested for one product. No price, tax, or reserved quantity.';

create table public.order_events (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete restrict,
  event_type text not null,
  from_status text,
  to_status text not null,
  actor_id uuid not null,
  note text,
  version integer not null,
  idempotency_key text not null,
  line_snapshot jsonb not null default '[]'::jsonb,
  availability_snapshot jsonb,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint order_events_idempotency_key unique (idempotency_key),
  constraint order_events_type_check check (
    event_type in ('created', 'lines_revised', 'submitted', 'held', 'verified', 'cancelled')
  ),
  constraint order_events_status_check check (
    to_status in ('draft', 'submitted', 'held', 'verified', 'cancelled')
    and (
      from_status is null
      or from_status in ('draft', 'submitted', 'held', 'verified', 'cancelled')
    )
  ),
  constraint order_events_version_check check (version >= 1),
  constraint order_events_note_length check (
    note is null
    or (
      char_length(btrim(note)) between 1 and 500
      and note = btrim(note)
    )
  )
);

create index order_events_order_id_created_at_idx
  on public.order_events (order_id, created_at);

comment on table public.order_events is
  'Append-only order history. actor_id is copied and has no foreign key.';

create or replace function app_private.assign_order_number()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' and new.order_number is null then
    new.order_number := 'SO-'
      || to_char(pg_catalog.clock_timestamp() at time zone 'utc', 'YYYYMMDD')
      || '-'
      || pg_catalog.lpad(pg_catalog.nextval('public.shop_order_seq')::text, 6, '0');
  end if;

  if tg_op = 'UPDATE' and new.order_number is distinct from old.order_number then
    raise exception 'order number is immutable' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and new.created_by is distinct from old.created_by then
    raise exception 'order creator is immutable' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and new.idempotency_key is distinct from old.idempotency_key then
    raise exception 'idempotency key is immutable' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and old.status = 'cancelled' then
    raise exception 'order is cancelled' using errcode = '23514';
  end if;

  new.idempotency_key := app_private.clean_idempotency_key(new.idempotency_key);
  return new;
end;
$$;

create trigger orders_assign_number
  before insert or update on public.orders
  for each row execute function app_private.assign_order_number();

create or replace function app_private.reject_order_event_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.idempotency_key := app_private.clean_idempotency_key(new.idempotency_key);
    return new;
  end if;

  raise exception 'order history is append-only' using errcode = '42501';
end;
$$;

create trigger order_events_append_only
  before insert or update or delete on public.order_events
  for each row execute function app_private.reject_order_event_change();

revoke all on function app_private.assign_order_number() from public, anon, authenticated, service_role;
revoke all on function app_private.reject_order_event_change() from public, anon, authenticated, service_role;

create or replace function app_private.can_view_order(target_order uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.orders
    where orders.id = target_order
      and (
        (select app_private.has_permission('operations.monitor'))
        or (
          (select app_private.has_permission('orders.verify'))
          and (select app_private.can_work_at_branch(orders.branch_id))
        )
        or (
          (select app_private.has_permission('orders.capture'))
          and orders.created_by = (select auth.uid())
        )
      )
  );
$$;

revoke all on function app_private.can_view_order(uuid) from public, anon;
grant execute on function app_private.can_view_order(uuid) to authenticated;

alter table public.orders enable row level security;
alter table public.order_lines enable row level security;
alter table public.order_events enable row level security;

alter table public.orders force row level security;
alter table public.order_lines force row level security;
alter table public.order_events force row level security;

create policy orders_select_authorized
  on public.orders
  for select
  to authenticated
  using ((select app_private.can_view_order(id)));

create policy order_lines_select_authorized
  on public.order_lines
  for select
  to authenticated
  using ((select app_private.can_view_order(order_id)));

create policy order_events_select_authorized
  on public.order_events
  for select
  to authenticated
  using ((select app_private.can_view_order(order_id)));

revoke all on table public.orders from public, anon, authenticated, service_role;
revoke all on table public.order_lines from public, anon, authenticated, service_role;
revoke all on table public.order_events from public, anon, authenticated, service_role;

grant select on table public.orders to authenticated;
grant select on table public.order_lines to authenticated;
grant select on table public.order_events to authenticated;

create or replace function public.list_orders(status_filter text default null)
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
      or (select app_private.has_permission('orders.verify'))
      or (select app_private.has_permission('orders.capture'))
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if cleaned is not null
    and cleaned not in ('draft', 'submitted', 'held', 'verified', 'cancelled')
  then
    raise exception 'order status is invalid' using errcode = '23514';
  end if;

  return coalesce(
    (
      select pg_catalog.jsonb_agg(to_jsonb(orders) order by orders.created_at desc)
      from public.orders
      where (select app_private.can_view_order(orders.id))
        and (cleaned is null or orders.status = cleaned)
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.get_order(target_order uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if target_order is null or not (select app_private.can_view_order(target_order)) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

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
    )
  );
end;
$$;

create or replace function public.check_order_availability(target_order uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_branch uuid;
  selected_shop uuid;
begin
  perform app_private.assert_permission('orders.verify');

  select orders.branch_id, orders.shop_id
  into selected_branch, selected_shop
  from public.orders
  where orders.id = target_order;

  if selected_branch is null
    or not (select app_private.can_work_at_branch(selected_branch))
  then
    raise exception 'godown is not authorized' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.shops
    where shops.id = selected_shop
      and shops.is_active
  ) then
    raise exception 'shop is not active' using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.order_lines
    join public.products on products.id = order_lines.product_id
    where order_lines.order_id = target_order
      and not products.is_active
  ) then
    raise exception 'product is not active' using errcode = '23514';
  end if;

  return coalesce(
    (
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'product_id', order_lines.product_id,
          'requested_cases', order_lines.requested_cases,
          'on_hand_cases', on_hand.quantity,
          'shortfall_cases', case
            when order_lines.requested_cases > on_hand.quantity then order_lines.requested_cases - on_hand.quantity
            else 0
          end
        )
        order by order_lines.created_at
      )
      from public.order_lines
      cross join lateral (
        select coalesce(sum(stock_balances.quantity), 0)::integer as quantity
        from public.stock_balances
        join public.crates on crates.id = stock_balances.crate_id
        join public.zones on zones.id = crates.zone_id
        where stock_balances.product_id = order_lines.product_id
          and zones.branch_id = selected_branch
      ) as on_hand
      where order_lines.order_id = target_order
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function public.list_orders(text) from public, anon;
revoke all on function public.get_order(uuid) from public, anon;
revoke all on function public.check_order_availability(uuid) from public, anon;

grant execute on function public.list_orders(text) to authenticated;
grant execute on function public.get_order(uuid) to authenticated;
grant execute on function public.check_order_availability(uuid) to authenticated;

comment on function public.list_orders(text) is
  'Orders visible to the caller. Admin monitors all. Accounts sees assigned godowns. A capturer sees orders they created.';

comment on function public.get_order(uuid) is
  'One visible order with lines and events. Hidden orders are not authorized.';

comment on function public.check_order_availability(uuid) is
  'Accounts-only on-hand and shortfall for the order godown. Reads balances and writes nothing. Does not verify the order.';

-- Phase 4.1B — draft capture and edit. No submit, hold, verify, or cancel.

create or replace function app_private.clean_optional_order_text(
  raw_value text,
  max_length integer
)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  cleaned text := nullif(pg_catalog.btrim(coalesce(raw_value, '')), '');
begin
  if cleaned is null then
    return null;
  end if;

  if pg_catalog.char_length(cleaned) > max_length then
    raise exception 'text is too long' using errcode = '23514';
  end if;

  return cleaned;
end;
$$;

create or replace function app_private.assert_order_shop(target_shop uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if target_shop is null
    or not exists (
      select 1
      from public.shops
      where shops.id = target_shop
        and shops.is_active
    )
  then
    raise exception 'shop is not active' using errcode = '23514';
  end if;

  if (select app_private.has_permission('shops.read_all')) then
    return;
  end if;

  if exists (
    select 1
    from public.shop_salesperson_assignments
    where shop_salesperson_assignments.shop_id = target_shop
      and shop_salesperson_assignments.salesperson_id = (select auth.uid())
      and shop_salesperson_assignments.is_active
  ) then
    return;
  end if;

  raise exception 'not authorized' using errcode = '42501';
end;
$$;

create or replace function app_private.assert_order_branch(target_branch uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if target_branch is null
    or not exists (
      select 1
      from public.branches
      where branches.id = target_branch
        and branches.is_active
    )
    or not (select app_private.can_work_at_branch(target_branch))
  then
    raise exception 'godown is not authorized' using errcode = '42501';
  end if;
end;
$$;

create or replace function app_private.normalize_order_lines(raw_lines jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  normalized jsonb;
begin
  if raw_lines is null or pg_catalog.jsonb_typeof(raw_lines) <> 'array' then
    raise exception 'order lines are required' using errcode = '23514';
  end if;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'product_id', item.product_id,
        'requested_cases', item.requested_cases
      )
      order by item.product_id
    ),
    '[]'::jsonb
  )
  into normalized
  from (
    select
      (entry ->> 'product_id')::uuid as product_id,
      (entry ->> 'requested_cases')::integer as requested_cases
    from pg_catalog.jsonb_array_elements(raw_lines) as entry
  ) as item;

  if pg_catalog.jsonb_array_length(normalized) < 1 then
    raise exception 'order lines are required' using errcode = '23514';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(normalized) as entry
    where (entry ->> 'product_id') is null
      or (entry ->> 'requested_cases')::integer is null
      or (entry ->> 'requested_cases')::integer < 1
      or (entry ->> 'requested_cases')::integer > 1000000
  ) then
    raise exception 'order line is invalid' using errcode = '23514';
  end if;

  if (
    select count(*)
    from pg_catalog.jsonb_array_elements(normalized) as entry
  ) <> (
    select count(distinct entry ->> 'product_id')
    from pg_catalog.jsonb_array_elements(normalized) as entry
  ) then
    raise exception 'order line products must be unique' using errcode = '23514';
  end if;

  return normalized;
end;
$$;

create or replace function app_private.assert_order_line_products(normalized_lines jsonb)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(normalized_lines) as entry
    left join public.products
      on products.id = (entry ->> 'product_id')::uuid
    where products.id is null
      or not products.is_active
  ) then
    raise exception 'product is not active' using errcode = '23514';
  end if;
end;
$$;

create or replace function app_private.replace_order_lines(
  target_order uuid,
  normalized_lines jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.order_lines
  where order_lines.order_id = target_order;

  insert into public.order_lines (order_id, product_id, requested_cases)
  select
    target_order,
    (entry ->> 'product_id')::uuid,
    (entry ->> 'requested_cases')::integer
  from pg_catalog.jsonb_array_elements(normalized_lines) as entry;
end;
$$;

create or replace function app_private.order_lines_match(
  target_order uuid,
  normalized_lines jsonb
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'product_id', order_lines.product_id,
          'requested_cases', order_lines.requested_cases
        )
        order by order_lines.product_id
      )
      from public.order_lines
      where order_lines.order_id = target_order
    ),
    '[]'::jsonb
  ) = normalized_lines;
$$;

create or replace function public.create_order(
  target_shop uuid,
  target_branch uuid,
  order_source text,
  source_reference text,
  order_notes text,
  order_lines jsonb,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  cleaned_source text;
  cleaned_reference text;
  cleaned_notes text;
  normalized_lines jsonb;
  existing public.orders%rowtype;
  created_id uuid;
begin
  perform app_private.assert_permission('orders.capture');

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_source := pg_catalog.lower(pg_catalog.btrim(coalesce(order_source, '')));
  cleaned_reference := app_private.clean_optional_order_text(source_reference, 80);
  cleaned_notes := app_private.clean_optional_order_text(order_notes, 500);
  normalized_lines := app_private.normalize_order_lines(order_lines);

  if cleaned_source not in ('salesperson', 'accounts', 'telecalling', 'enquiry') then
    raise exception 'order source is invalid' using errcode = '23514';
  end if;

  select *
  into existing
  from public.orders
  where orders.idempotency_key = cleaned_key;

  if found then
    if existing.created_by is distinct from (select auth.uid())
      or not (select app_private.can_view_order(existing.id))
    then
      raise exception 'not authorized' using errcode = '42501';
    end if;

    if existing.shop_id is distinct from target_shop
      or existing.branch_id is distinct from target_branch
      or existing.source is distinct from cleaned_source
      or existing.source_reference is distinct from cleaned_reference
      or existing.notes is distinct from cleaned_notes
      or not app_private.order_lines_match(existing.id, normalized_lines)
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;

    return public.get_order(existing.id);
  end if;

  perform app_private.assert_order_shop(target_shop);
  perform app_private.assert_order_branch(target_branch);
  perform app_private.assert_order_line_products(normalized_lines);

  begin
    insert into public.orders (
      shop_id,
      branch_id,
      source,
      source_reference,
      notes,
      created_by,
      status,
      version,
      idempotency_key
    )
    values (
      target_shop,
      target_branch,
      cleaned_source,
      cleaned_reference,
      cleaned_notes,
      (select auth.uid()),
      'draft',
      1,
      cleaned_key
    )
    returning id into created_id;
  exception
    when unique_violation then
      select *
      into existing
      from public.orders
      where orders.idempotency_key = cleaned_key;

      if not found then
        raise;
      end if;

      if existing.created_by is distinct from (select auth.uid())
        or not (select app_private.can_view_order(existing.id))
      then
        raise exception 'not authorized' using errcode = '42501';
      end if;

      if existing.shop_id is distinct from target_shop
        or existing.branch_id is distinct from target_branch
        or existing.source is distinct from cleaned_source
        or existing.source_reference is distinct from cleaned_reference
        or existing.notes is distinct from cleaned_notes
        or not app_private.order_lines_match(existing.id, normalized_lines)
      then
        raise exception 'idempotency key does not match the original request'
          using errcode = '23514';
      end if;

      return public.get_order(existing.id);
  end;

  perform app_private.replace_order_lines(created_id, normalized_lines);

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
    created_id,
    'created',
    null,
    'draft',
    (select auth.uid()),
    cleaned_notes,
    1,
    cleaned_key,
    normalized_lines
  );

  return public.get_order(created_id);
end;
$$;

create or replace function public.set_order(
  target_order uuid,
  expected_version integer,
  target_shop uuid,
  target_branch uuid,
  order_source text,
  source_reference text,
  order_notes text,
  order_lines jsonb,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  cleaned_source text;
  cleaned_reference text;
  cleaned_notes text;
  normalized_lines jsonb;
  selected public.orders%rowtype;
  existing_event public.order_events%rowtype;
begin
  perform app_private.assert_permission('orders.capture');

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_source := pg_catalog.lower(pg_catalog.btrim(coalesce(order_source, '')));
  cleaned_reference := app_private.clean_optional_order_text(source_reference, 80);
  cleaned_notes := app_private.clean_optional_order_text(order_notes, 500);
  normalized_lines := app_private.normalize_order_lines(order_lines);

  if cleaned_source not in ('salesperson', 'accounts', 'telecalling', 'enquiry') then
    raise exception 'order source is invalid' using errcode = '23514';
  end if;

  select *
  into selected
  from public.orders
  where orders.id = target_order
  for update;

  if not found
    or selected.created_by is distinct from (select auth.uid())
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into existing_event
  from public.order_events
  where order_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.order_id is distinct from selected.id
      or existing_event.event_type is distinct from 'lines_revised'
      or selected.shop_id is distinct from target_shop
      or selected.branch_id is distinct from target_branch
      or selected.source is distinct from cleaned_source
      or selected.source_reference is distinct from cleaned_reference
      or selected.notes is distinct from cleaned_notes
      or existing_event.line_snapshot is distinct from normalized_lines
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;

    return public.get_order(selected.id);
  end if;

  if selected.status not in ('draft', 'held') then
    raise exception 'order cannot change from % to %', selected.status, selected.status
      using errcode = '23514';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'order was changed by someone else' using errcode = '40001';
  end if;

  perform app_private.assert_order_shop(target_shop);
  perform app_private.assert_order_branch(target_branch);
  perform app_private.assert_order_line_products(normalized_lines);

  update public.orders
  set
    shop_id = target_shop,
    branch_id = target_branch,
    source = cleaned_source,
    source_reference = cleaned_reference,
    notes = cleaned_notes,
    version = selected.version + 1
  where orders.id = selected.id;

  perform app_private.replace_order_lines(selected.id, normalized_lines);

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
    'lines_revised',
    selected.status,
    selected.status,
    (select auth.uid()),
    cleaned_notes,
    selected.version + 1,
    cleaned_key,
    normalized_lines
  );

  return public.get_order(selected.id);
end;
$$;

revoke all on function app_private.clean_optional_order_text(text, integer)
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_order_shop(uuid)
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_order_branch(uuid)
  from public, anon, authenticated, service_role;
revoke all on function app_private.normalize_order_lines(jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_order_line_products(jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app_private.replace_order_lines(uuid, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app_private.order_lines_match(uuid, jsonb)
  from public, anon, authenticated, service_role;

revoke all on function public.create_order(uuid, uuid, text, text, text, jsonb, text)
  from public, anon;
revoke all on function public.set_order(uuid, integer, uuid, uuid, text, text, text, jsonb, text)
  from public, anon;

grant execute on function public.create_order(uuid, uuid, text, text, text, jsonb, text)
  to authenticated;
grant execute on function public.set_order(uuid, integer, uuid, uuid, text, text, text, jsonb, text)
  to authenticated;

comment on function public.create_order(uuid, uuid, text, text, text, jsonb, text) is
  'Create a draft shop order. Requires orders.capture. Does not read or write stock.';

comment on function public.set_order(uuid, integer, uuid, uuid, text, text, text, jsonb, text) is
  'Replace draft or held order header and lines. Creator only. Does not change status.';

-- Phase 4.1C — submit, hold, verify (Availability Rule A), cancel.

create or replace function app_private.clean_required_order_text(
  raw_value text,
  max_length integer
)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  cleaned text := nullif(pg_catalog.btrim(coalesce(raw_value, '')), '');
begin
  if cleaned is null or pg_catalog.char_length(cleaned) < 1 then
    raise exception 'reason is required' using errcode = '23514';
  end if;

  if pg_catalog.char_length(cleaned) > max_length then
    raise exception 'text is too long' using errcode = '23514';
  end if;

  return cleaned;
end;
$$;

create or replace function app_private.order_line_availability(
  target_order uuid,
  target_branch uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'product_id', order_lines.product_id,
          'requested_cases', order_lines.requested_cases,
          'on_hand_cases', on_hand.quantity,
          'shortfall_cases', case
            when order_lines.requested_cases > on_hand.quantity
              then order_lines.requested_cases - on_hand.quantity
            else 0
          end
        )
        order by order_lines.created_at
      )
      from public.order_lines
      cross join lateral (
        select coalesce(sum(stock_balances.quantity), 0)::integer as quantity
        from public.stock_balances
        join public.crates on crates.id = stock_balances.crate_id
        join public.zones on zones.id = crates.zone_id
        where stock_balances.product_id = order_lines.product_id
          and zones.branch_id = target_branch
      ) as on_hand
      where order_lines.order_id = target_order
    ),
    '[]'::jsonb
  );
$$;

create or replace function app_private.assert_existing_order_lines(target_order uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  normalized jsonb;
begin
  select coalesce(
    (
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'product_id', order_lines.product_id,
          'requested_cases', order_lines.requested_cases
        )
        order by order_lines.product_id
      )
      from public.order_lines
      where order_lines.order_id = target_order
    ),
    '[]'::jsonb
  )
  into normalized;

  if pg_catalog.jsonb_array_length(normalized) < 1 then
    raise exception 'order lines are required' using errcode = '23514';
  end if;

  perform app_private.assert_order_line_products(normalized);
end;
$$;

create or replace function app_private.current_order_line_snapshot(target_order uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'product_id', order_lines.product_id,
          'requested_cases', order_lines.requested_cases
        )
        order by order_lines.product_id
      )
      from public.order_lines
      where order_lines.order_id = target_order
    ),
    '[]'::jsonb
  );
$$;

create or replace function public.submit_order(
  target_order uuid,
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
  selected public.orders%rowtype;
  existing_event public.order_events%rowtype;
begin
  perform app_private.assert_permission('orders.capture');
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select *
  into selected
  from public.orders
  where orders.id = target_order
  for update;

  if not found
    or selected.created_by is distinct from (select auth.uid())
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into existing_event
  from public.order_events
  where order_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.order_id is distinct from selected.id
      or existing_event.event_type is distinct from 'submitted'
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;
    return public.get_order(selected.id);
  end if;

  if selected.status not in ('draft', 'held') then
    raise exception 'order cannot change from % to submitted', selected.status
      using errcode = '23514';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'order was changed by someone else' using errcode = '40001';
  end if;

  perform app_private.assert_order_shop(selected.shop_id);
  perform app_private.assert_order_branch(selected.branch_id);
  perform app_private.assert_existing_order_lines(selected.id);

  update public.orders
  set
    status = 'submitted',
    submitted_at = pg_catalog.clock_timestamp(),
    submitted_by = (select auth.uid()),
    version = selected.version + 1
  where orders.id = selected.id;

  insert into public.order_events (
    order_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    version,
    idempotency_key,
    line_snapshot
  )
  values (
    selected.id,
    'submitted',
    selected.status,
    'submitted',
    (select auth.uid()),
    selected.version + 1,
    cleaned_key,
    app_private.current_order_line_snapshot(selected.id)
  );

  return public.get_order(selected.id);
end;
$$;

create or replace function public.hold_order(
  target_order uuid,
  expected_version integer,
  hold_note text,
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
  selected public.orders%rowtype;
  existing_event public.order_events%rowtype;
begin
  perform app_private.assert_permission('orders.verify');
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_note := app_private.clean_required_order_text(hold_note, 500);

  select *
  into selected
  from public.orders
  where orders.id = target_order
  for update;

  if not found
    or not (select app_private.can_work_at_branch(selected.branch_id))
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into existing_event
  from public.order_events
  where order_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.order_id is distinct from selected.id
      or existing_event.event_type is distinct from 'held'
      or existing_event.note is distinct from cleaned_note
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;
    return public.get_order(selected.id);
  end if;

  if selected.status is distinct from 'submitted' then
    raise exception 'order cannot change from % to held', selected.status
      using errcode = '23514';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'order was changed by someone else' using errcode = '40001';
  end if;

  update public.orders
  set
    status = 'held',
    held_at = pg_catalog.clock_timestamp(),
    held_by = (select auth.uid()),
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
    'held',
    'submitted',
    'held',
    (select auth.uid()),
    cleaned_note,
    selected.version + 1,
    cleaned_key,
    app_private.current_order_line_snapshot(selected.id)
  );

  return public.get_order(selected.id);
end;
$$;

create or replace function public.verify_order(
  target_order uuid,
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
  selected public.orders%rowtype;
  existing_event public.order_events%rowtype;
  availability jsonb;
  shortages jsonb;
begin
  perform app_private.assert_permission('orders.verify');
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select *
  into selected
  from public.orders
  where orders.id = target_order
  for update;

  if not found
    or not (select app_private.can_work_at_branch(selected.branch_id))
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into existing_event
  from public.order_events
  where order_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.order_id is distinct from selected.id
      or existing_event.event_type is distinct from 'verified'
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;
    return public.get_order(selected.id);
  end if;

  if selected.status is distinct from 'submitted' then
    raise exception 'order cannot change from % to verified', selected.status
      using errcode = '23514';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'order was changed by someone else' using errcode = '40001';
  end if;

  if not exists (
    select 1
    from public.shops
    where shops.id = selected.shop_id
      and shops.is_active
  ) then
    raise exception 'shop is not active' using errcode = '23514';
  end if;

  perform app_private.assert_existing_order_lines(selected.id);

  availability := app_private.order_line_availability(selected.id, selected.branch_id);

  select coalesce(
    (
      select pg_catalog.jsonb_agg(entry order by entry ->> 'product_id')
      from pg_catalog.jsonb_array_elements(availability) as entry
      where (entry ->> 'shortfall_cases')::integer > 0
    ),
    '[]'::jsonb
  )
  into shortages;

  if pg_catalog.jsonb_array_length(shortages) > 0 then
    raise exception 'insufficient stock'
      using errcode = 'P0001',
            detail = shortages::text;
  end if;

  update public.orders
  set
    status = 'verified',
    verified_at = pg_catalog.clock_timestamp(),
    verified_by = (select auth.uid()),
    version = selected.version + 1
  where orders.id = selected.id;

  insert into public.order_events (
    order_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    version,
    idempotency_key,
    line_snapshot,
    availability_snapshot
  )
  values (
    selected.id,
    'verified',
    'submitted',
    'verified',
    (select auth.uid()),
    selected.version + 1,
    cleaned_key,
    app_private.current_order_line_snapshot(selected.id),
    availability
  );

  return public.get_order(selected.id);
end;
$$;

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

-- Reuse shared availability helper from the read RPC.
create or replace function public.check_order_availability(target_order uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_branch uuid;
  selected_shop uuid;
begin
  perform app_private.assert_permission('orders.verify');

  select orders.branch_id, orders.shop_id
  into selected_branch, selected_shop
  from public.orders
  where orders.id = target_order;

  if selected_branch is null
    or not (select app_private.can_work_at_branch(selected_branch))
  then
    raise exception 'godown is not authorized' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.shops
    where shops.id = selected_shop
      and shops.is_active
  ) then
    raise exception 'shop is not active' using errcode = '23514';
  end if;

  perform app_private.assert_existing_order_lines(target_order);

  return app_private.order_line_availability(target_order, selected_branch);
end;
$$;

revoke all on function app_private.clean_required_order_text(text, integer)
  from public, anon, authenticated, service_role;
revoke all on function app_private.order_line_availability(uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_existing_order_lines(uuid)
  from public, anon, authenticated, service_role;
revoke all on function app_private.current_order_line_snapshot(uuid)
  from public, anon, authenticated, service_role;

revoke all on function public.submit_order(uuid, integer, text) from public, anon;
revoke all on function public.hold_order(uuid, integer, text, text) from public, anon;
revoke all on function public.verify_order(uuid, integer, text) from public, anon;
revoke all on function public.cancel_order(uuid, integer, text, text) from public, anon;

grant execute on function public.submit_order(uuid, integer, text) to authenticated;
grant execute on function public.hold_order(uuid, integer, text, text) to authenticated;
grant execute on function public.verify_order(uuid, integer, text) to authenticated;
grant execute on function public.cancel_order(uuid, integer, text, text) to authenticated;

comment on function public.submit_order(uuid, integer, text) is
  'Creator submits a draft or held order. Does not read stock.';

comment on function public.hold_order(uuid, integer, text, text) is
  'Accounts holds a submitted order for creator correction. Does not change stock.';

comment on function public.verify_order(uuid, integer, text) is
  'Accounts verifies a submitted order. Availability Rule A rejects any shortfall without changing status.';

comment on function public.cancel_order(uuid, integer, text, text) is
  'Creator cancels draft/held. Accounts cancels submitted/verified with a required reason. Terminal.';
