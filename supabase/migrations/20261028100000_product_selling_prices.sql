-- M7.5B stage B1: product billing conversion and selling prices.
-- Local-only additive migration. Does not post stock, issue tax invoices, or
-- consume statutory numbers. GST rates are intentionally absent.

-- ---------------------------------------------------------------------------
-- Billing conversion (stock stays in cases; invoices bill converted units)
-- ---------------------------------------------------------------------------

alter table public.products
  add column if not exists billing_unit text,
  add column if not exists billed_units_per_case numeric(12, 4);

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'products_billing_conversion_pair'
  ) then
    alter table public.products
      add constraint products_billing_conversion_pair
      check (
        (billing_unit is null and billed_units_per_case is null)
        or (
          billing_unit is not null
          and length(btrim(billing_unit)) between 1 and 16
          and billed_units_per_case is not null
          and billed_units_per_case > 0
        )
      );
  end if;
end;
$$;

comment on column public.products.billing_unit is
  'Invoice billing unit (for example nos). Null until conversion is classified. Stock remains whole cases.';
comment on column public.products.billed_units_per_case is
  'Billed units per dispatched case. Both conversion columns must be set together. Never assume 1 case = 1 nos.';

-- ---------------------------------------------------------------------------
-- Selling prices (INR only, shop-specific with default fallback)
-- ---------------------------------------------------------------------------

create table if not exists public.product_selling_prices (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id),
  shop_id uuid references public.shops (id),
  currency_code text not null default 'INR',
  unit_amount numeric(14, 4) not null,
  effective_from date not null,
  effective_to date,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id),
  constraint product_selling_prices_currency_inr check (currency_code = 'INR'),
  constraint product_selling_prices_unit_positive check (unit_amount > 0),
  constraint product_selling_prices_window check (
    effective_to is null or effective_to >= effective_from
  )
);

create index if not exists product_selling_prices_product_shop_idx
  on public.product_selling_prices (product_id, shop_id, effective_from);

create table if not exists public.product_selling_price_events (
  id uuid primary key default gen_random_uuid(),
  price_id uuid not null references public.product_selling_prices (id) on delete cascade,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id)
);

create index if not exists product_selling_price_events_price_idx
  on public.product_selling_price_events (price_id, created_at);

comment on table public.product_selling_prices is
  'Dated selling prices in INR. Shop-specific rows override the default (shop_id null) row. Overlapping active windows fail closed. No GST.';
comment on table public.product_selling_price_events is
  'Append-only price mutations. Client writes are rejected.';

-- ---------------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------------

insert into public.permissions (code, description)
values
  (
    'products.price.manage',
    'Create, update, and deactivate product selling prices.'
  ),
  (
    'products.price.read',
    'Read product selling prices without changing them.'
  )
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code in (
  'products.price.manage',
  'products.price.read'
)
where roles.code in ('admin', 'accounts')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Overlap guard (daterange; btree_gist is not in this project)
-- ---------------------------------------------------------------------------

create or replace function app_private.selling_price_window(from_date date, to_date date)
returns daterange
language sql
immutable
set search_path = ''
as $$
  select daterange(
    from_date,
    coalesce(to_date, 'infinity'::date),
    '[]'
  );
$$;

revoke all on function app_private.selling_price_window(date, date)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_selling_price_no_overlap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'selling prices cannot be deleted' using errcode = '42501';
  end if;

  if new.is_active
    and exists (
      select 1
      from public.product_selling_prices other
      where other.product_id = new.product_id
        and other.shop_id is not distinct from new.shop_id
        and other.is_active
        and other.id is distinct from new.id
        and app_private.selling_price_window(other.effective_from, other.effective_to)
          && app_private.selling_price_window(new.effective_from, new.effective_to)
    )
  then
    raise exception 'selling price window overlaps an active price for this product and shop'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function app_private.assert_selling_price_no_overlap()
  from public, anon, authenticated, service_role;

drop trigger if exists product_selling_prices_overlap on public.product_selling_prices;
create trigger product_selling_prices_overlap
  before insert or update on public.product_selling_prices
  for each row
  execute function app_private.assert_selling_price_no_overlap();

create or replace function app_private.reject_selling_price_client_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'selling prices can only change through approved procedures'
    using errcode = '42501';
end;
$$;

revoke all on function app_private.reject_selling_price_client_write()
  from public, anon, authenticated, service_role;

drop trigger if exists product_selling_prices_no_client_write on public.product_selling_prices;
create trigger product_selling_prices_no_client_write
  before insert or update or delete on public.product_selling_prices
  for each row
  when (current_setting('app.invoice_write', true) is distinct from 'on')
  execute function app_private.reject_selling_price_client_write();

drop trigger if exists product_selling_price_events_no_client_write
  on public.product_selling_price_events;
create trigger product_selling_price_events_no_client_write
  before insert or update or delete on public.product_selling_price_events
  for each row
  when (current_setting('app.invoice_write', true) is distinct from 'on')
  execute function app_private.reject_selling_price_client_write();

create or replace function app_private.assert_invoice_write()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if current_setting('app.invoice_write', true) is distinct from 'on' then
    raise exception 'invoice writes are restricted to approved procedures'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_invoice_write()
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Price resolution (shop-specific first, then default; fail closed)
-- ---------------------------------------------------------------------------

create or replace function app_private.resolve_selling_price(
  p_product uuid,
  p_shop uuid,
  p_as_of date
)
returns table (
  price_id uuid,
  unit_amount numeric,
  price_scope text,
  effective_from date,
  effective_to date
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  hit_count integer;
begin
  if p_as_of is null then
    raise exception 'price as-of date is required' using errcode = '23514';
  end if;

  select count(*)
  into hit_count
  from public.product_selling_prices
  where product_selling_prices.product_id = p_product
    and product_selling_prices.shop_id = p_shop
    and product_selling_prices.is_active
    and product_selling_prices.effective_from <= p_as_of
    and (
      product_selling_prices.effective_to is null
      or product_selling_prices.effective_to >= p_as_of
    );

  if hit_count > 1 then
    raise exception 'overlapping shop prices for this product'
      using errcode = '23514';
  end if;

  if hit_count = 1 then
    return query
    select
      product_selling_prices.id,
      product_selling_prices.unit_amount,
      'shop'::text,
      product_selling_prices.effective_from,
      product_selling_prices.effective_to
    from public.product_selling_prices
    where product_selling_prices.product_id = p_product
      and product_selling_prices.shop_id = p_shop
      and product_selling_prices.is_active
      and product_selling_prices.effective_from <= p_as_of
      and (
        product_selling_prices.effective_to is null
        or product_selling_prices.effective_to >= p_as_of
      );
    return;
  end if;

  select count(*)
  into hit_count
  from public.product_selling_prices
  where product_selling_prices.product_id = p_product
    and product_selling_prices.shop_id is null
    and product_selling_prices.is_active
    and product_selling_prices.effective_from <= p_as_of
    and (
      product_selling_prices.effective_to is null
      or product_selling_prices.effective_to >= p_as_of
    );

  if hit_count > 1 then
    raise exception 'overlapping default prices for this product'
      using errcode = '23514';
  end if;

  if hit_count = 0 then
    raise exception 'selling price is missing for this product'
      using errcode = '23514';
  end if;

  return query
  select
    product_selling_prices.id,
    product_selling_prices.unit_amount,
    'default'::text,
    product_selling_prices.effective_from,
    product_selling_prices.effective_to
  from public.product_selling_prices
  where product_selling_prices.product_id = p_product
    and product_selling_prices.shop_id is null
    and product_selling_prices.is_active
    and product_selling_prices.effective_from <= p_as_of
    and (
      product_selling_prices.effective_to is null
      or product_selling_prices.effective_to >= p_as_of
    );
end;
$$;

revoke all on function app_private.resolve_selling_price(uuid, uuid, date)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Price + conversion RPCs
-- ---------------------------------------------------------------------------

create or replace function public.set_product_billing_conversion(
  p_product_id uuid,
  p_billing_unit text,
  p_billed_units_per_case numeric
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_unit text;
  row_products public.products;
begin
  perform app_private.assert_permission('products.manage');
  perform set_config('app.invoice_write', 'on', true);

  cleaned_unit := nullif(btrim(coalesce(p_billing_unit, '')), '');
  if cleaned_unit is null or p_billed_units_per_case is null or p_billed_units_per_case <= 0 then
    raise exception 'billing unit and billed units per case must both be set'
      using errcode = '23514';
  end if;

  update public.products
  set
    billing_unit = cleaned_unit,
    billed_units_per_case = p_billed_units_per_case
  where products.id = p_product_id
  returning * into row_products;

  if not found then
    raise exception 'product not found' using errcode = 'P0002';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'set_product_billing_conversion',
    'products',
    p_product_id,
    jsonb_build_object(
      'billing_unit',
      cleaned_unit,
      'billed_units_per_case',
      p_billed_units_per_case
    )
  );

  return jsonb_build_object(
    'product_id', row_products.id,
    'billing_unit', row_products.billing_unit,
    'billed_units_per_case', row_products.billed_units_per_case
  );
end;
$$;

create or replace function public.upsert_product_selling_price(
  p_product_id uuid,
  p_shop_id uuid,
  p_unit_amount numeric,
  p_effective_from date,
  p_effective_to date default null,
  p_price_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  row_price public.product_selling_prices;
  event_name text;
begin
  perform app_private.assert_permission('products.price.manage');
  perform set_config('app.invoice_write', 'on', true);

  if p_unit_amount is null or p_unit_amount <= 0 then
    raise exception 'unit amount must be a positive INR amount' using errcode = '23514';
  end if;
  if p_effective_from is null then
    raise exception 'effective from date is required' using errcode = '23514';
  end if;
  if p_effective_to is not null and p_effective_to < p_effective_from then
    raise exception 'effective to cannot precede effective from' using errcode = '23514';
  end if;

  if not exists (select 1 from public.products where products.id = p_product_id) then
    raise exception 'product not found' using errcode = 'P0002';
  end if;

  if p_shop_id is not null
    and not exists (select 1 from public.shops where shops.id = p_shop_id) then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;

  if p_price_id is null then
    event_name := 'price_created';
    insert into public.product_selling_prices (
      product_id,
      shop_id,
      unit_amount,
      effective_from,
      effective_to,
      created_by,
      updated_by
    )
    values (
      p_product_id,
      p_shop_id,
      p_unit_amount,
      p_effective_from,
      p_effective_to,
      auth.uid(),
      auth.uid()
    )
    returning * into row_price;
  else
    event_name := 'price_updated';
    update public.product_selling_prices
    set
      product_id = p_product_id,
      shop_id = p_shop_id,
      unit_amount = p_unit_amount,
      effective_from = p_effective_from,
      effective_to = p_effective_to,
      updated_at = now(),
      updated_by = auth.uid()
    where product_selling_prices.id = p_price_id
    returning * into row_price;

    if not found then
      raise exception 'selling price not found' using errcode = 'P0002';
    end if;
  end if;

  insert into public.product_selling_price_events (
    price_id,
    event_type,
    payload,
    created_by
  )
  values (
    row_price.id,
    event_name,
    jsonb_build_object(
      'unit_amount', row_price.unit_amount,
      'shop_id', row_price.shop_id,
      'effective_from', row_price.effective_from,
      'effective_to', row_price.effective_to
    ),
    auth.uid()
  );

  perform app_private.write_audit(
    auth.uid(),
    event_name,
    'product_selling_prices',
    row_price.id,
    jsonb_build_object('product_id', row_price.product_id, 'shop_id', row_price.shop_id)
  );

  return jsonb_build_object(
    'id', row_price.id,
    'product_id', row_price.product_id,
    'shop_id', row_price.shop_id,
    'currency_code', row_price.currency_code,
    'unit_amount', row_price.unit_amount,
    'effective_from', row_price.effective_from,
    'effective_to', row_price.effective_to,
    'is_active', row_price.is_active
  );
end;
$$;

create or replace function public.deactivate_product_selling_price(
  p_price_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  row_price public.product_selling_prices;
begin
  perform app_private.assert_permission('products.price.manage');
  perform set_config('app.invoice_write', 'on', true);

  update public.product_selling_prices
  set
    is_active = false,
    updated_at = now(),
    updated_by = auth.uid()
  where product_selling_prices.id = p_price_id
    and product_selling_prices.is_active
  returning * into row_price;

  if not found then
    raise exception 'selling price not found or already inactive' using errcode = 'P0002';
  end if;

  insert into public.product_selling_price_events (
    price_id,
    event_type,
    payload,
    created_by
  )
  values (
    row_price.id,
    'price_deactivated',
    jsonb_build_object('unit_amount', row_price.unit_amount),
    auth.uid()
  );

  perform app_private.write_audit(
    auth.uid(),
    'price_deactivated',
    'product_selling_prices',
    row_price.id,
    jsonb_build_object('product_id', row_price.product_id)
  );

  return jsonb_build_object('id', row_price.id, 'is_active', false);
end;
$$;

create or replace function public.list_product_selling_prices(
  p_product_id uuid default null,
  p_shop_id uuid default null,
  p_include_inactive boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (
    app_private.has_permission('products.price.manage')
    or app_private.has_permission('products.price.read')
  ) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  return coalesce(
    (
      select jsonb_agg(row_to_json(price_rows)::jsonb order by price_rows.effective_from desc, price_rows.created_at desc)
      from (
        select
          product_selling_prices.id,
          product_selling_prices.product_id,
          products.sku,
          products.name as product_name,
          product_selling_prices.shop_id,
          shops.code as shop_code,
          shops.name as shop_name,
          product_selling_prices.currency_code,
          product_selling_prices.unit_amount,
          product_selling_prices.effective_from,
          product_selling_prices.effective_to,
          product_selling_prices.is_active
        from public.product_selling_prices
        join public.products on products.id = product_selling_prices.product_id
        left join public.shops on shops.id = product_selling_prices.shop_id
        where (p_product_id is null or product_selling_prices.product_id = p_product_id)
          and (
            p_shop_id is null
            or product_selling_prices.shop_id = p_shop_id
            or product_selling_prices.shop_id is null
          )
          and (p_include_inactive or product_selling_prices.is_active)
      ) price_rows
    ),
    '[]'::jsonb
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.product_selling_prices enable row level security;
alter table public.product_selling_prices force row level security;
alter table public.product_selling_price_events enable row level security;
alter table public.product_selling_price_events force row level security;

create policy product_selling_prices_select_priced
  on public.product_selling_prices
  for select
  to authenticated
  using (
    (select app_private.has_permission('products.price.manage'))
    or (select app_private.has_permission('products.price.read'))
  );

create policy product_selling_price_events_select_priced
  on public.product_selling_price_events
  for select
  to authenticated
  using (
    (select app_private.has_permission('products.price.manage'))
    or (select app_private.has_permission('products.price.read'))
  );

revoke all on table public.product_selling_prices
  from public, anon, authenticated, service_role;
revoke all on table public.product_selling_price_events
  from public, anon, authenticated, service_role;
grant select on table public.product_selling_prices to authenticated;
grant select on table public.product_selling_price_events to authenticated;

revoke all on function public.set_product_billing_conversion(uuid, text, numeric)
  from public, anon;
revoke all on function public.upsert_product_selling_price(uuid, uuid, numeric, date, date, uuid)
  from public, anon;
revoke all on function public.deactivate_product_selling_price(uuid)
  from public, anon;
revoke all on function public.list_product_selling_prices(uuid, uuid, boolean)
  from public, anon;

grant execute on function public.set_product_billing_conversion(uuid, text, numeric)
  to authenticated;
grant execute on function public.upsert_product_selling_price(uuid, uuid, numeric, date, date, uuid)
  to authenticated;
grant execute on function public.deactivate_product_selling_price(uuid)
  to authenticated;
grant execute on function public.list_product_selling_prices(uuid, uuid, boolean)
  to authenticated;

comment on function public.set_product_billing_conversion(uuid, text, numeric) is
  'Classify how dispatched cases convert into billed units. Stock is unchanged.';
comment on function public.upsert_product_selling_price(uuid, uuid, numeric, date, date, uuid) is
  'Create or update an INR selling price. Overlapping active windows fail closed. Null shop_id is the default price.';
comment on function public.deactivate_product_selling_price(uuid) is
  'Deactivate a selling price. History is retained.';
comment on function public.list_product_selling_prices(uuid, uuid, boolean) is
  'List selling prices. Restricted to products.price.read / manage.';
