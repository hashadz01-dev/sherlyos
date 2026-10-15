-- Phase 2C.1 master data and the godown storage hierarchy.
-- Godown = public.branches. Hierarchy: godown -> zone -> crate. Products are separate.
-- The operational unit is one carton case. This migration stores no quantities.
-- No units table: there is no second unit and no conversion to record.
-- No product-crate assignment table: capacity, exclusivity, and permanent SKU assignment are unresolved.
-- No reorder level and no stock ledger. stock.opening.post is reserved for a later function.
-- Shop-to-godown ownership is unresolved, so shops have no branch_id.
-- New permissions are catalogued. Only Admin receives stock.opening.post.

create or replace function app_private.clean_required_name(raw_value text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  cleaned text := pg_catalog.btrim(coalesce(raw_value, ''));
begin
  if pg_catalog.char_length(cleaned) < 1 or pg_catalog.char_length(cleaned) > 160 then
    raise exception 'name is invalid' using errcode = '23514';
  end if;

  return cleaned;
end;
$$;

create or replace function app_private.clean_code(raw_value text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  cleaned text := pg_catalog.btrim(coalesce(raw_value, ''));
begin
  if pg_catalog.char_length(cleaned) < 1 or pg_catalog.char_length(cleaned) > 40 then
    raise exception 'code is invalid' using errcode = '23514';
  end if;

  return cleaned;
end;
$$;

create or replace function app_private.clean_optional_text(raw_value text, max_length integer)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  cleaned text := nullif(pg_catalog.btrim(coalesce(raw_value, '')), '');
begin
  if cleaned is not null and pg_catalog.char_length(cleaned) > max_length then
    raise exception 'text is too long' using errcode = '23514';
  end if;

  return cleaned;
end;
$$;

create or replace function app_private.clean_optional_phone(raw_value text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  cleaned text := nullif(pg_catalog.btrim(coalesce(raw_value, '')), '');
begin
  if cleaned is not null
    and (
      pg_catalog.char_length(cleaned) < 7
      or pg_catalog.char_length(cleaned) > 24
    )
  then
    raise exception 'phone is invalid' using errcode = '23514';
  end if;

  return cleaned;
end;
$$;

create or replace function app_private.clean_optional_email(raw_value text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  cleaned text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(raw_value, ''))), '');
begin
  if cleaned is not null
    and (
      pg_catalog.char_length(cleaned) < 3
      or pg_catalog.char_length(cleaned) > 320
      or pg_catalog.strpos(cleaned, '@') < 2
    )
  then
    raise exception 'email is invalid' using errcode = '23514';
  end if;

  return cleaned;
end;
$$;

create or replace function app_private.assert_permission(requested_code text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is null or not app_private.has_permission(requested_code) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.clean_required_name(text) from public, anon, authenticated, service_role;
revoke all on function app_private.clean_code(text) from public, anon, authenticated, service_role;
revoke all on function app_private.clean_optional_text(text, integer) from public, anon, authenticated, service_role;
revoke all on function app_private.clean_optional_phone(text) from public, anon, authenticated, service_role;
revoke all on function app_private.clean_optional_email(text) from public, anon, authenticated, service_role;
revoke all on function app_private.assert_permission(text) from public, anon, authenticated, service_role;

create table public.product_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint product_categories_name_length check (
    char_length(btrim(name)) between 1 and 160
    and name = btrim(name)
  ),
  constraint product_categories_description_length check (
    description is null
    or (
      char_length(btrim(description)) between 1 and 500
      and description = btrim(description)
    )
  )
);

create unique index product_categories_name_key
  on public.product_categories (lower(name));

create index product_categories_is_active_idx
  on public.product_categories (is_active);

create trigger product_categories_set_updated_at
  before update on public.product_categories
  for each row execute function app_private.set_updated_at();

comment on table public.product_categories is
  'Optional product grouping. Category assignment on a product is not mandatory. No category hierarchy.';

comment on index public.product_categories_name_key is
  'Category names are unique after trimming, compared case-insensitively.';

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  email text,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint suppliers_name_length check (
    char_length(btrim(name)) between 1 and 160
    and name = btrim(name)
  ),
  constraint suppliers_phone_shape check (
    phone is null
    or (
      char_length(phone) between 7 and 24
      and phone = btrim(phone)
    )
  ),
  constraint suppliers_email_shape check (
    email is null
    or (
      char_length(email) between 3 and 320
      and email = lower(btrim(email))
      and position('@' in email) > 1
    )
  )
);

create index suppliers_is_active_idx on public.suppliers (is_active);

create trigger suppliers_set_updated_at
  before update on public.suppliers
  for each row execute function app_private.set_updated_at();

comment on table public.suppliers is
  'One supplier company. Phone and email are optional contact fields. No tax, bank, or credit columns. Deactivate instead of deleting.';

create table public.products (
  id uuid primary key default gen_random_uuid(),
  sku text not null,
  name text not null,
  supplier_id uuid references public.suppliers (id) on delete restrict,
  category_id uuid references public.product_categories (id) on delete restrict,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint products_sku_shape check (
    char_length(btrim(sku)) between 1 and 40
    and sku = btrim(sku)
  ),
  constraint products_name_length check (
    char_length(btrim(name)) between 1 and 160
    and name = btrim(name)
  )
);

create unique index products_sku_key on public.products (lower(sku));

create index products_supplier_id_idx on public.products (supplier_id);
create index products_category_id_idx on public.products (category_id);
create index products_is_active_idx on public.products (is_active);

create trigger products_set_updated_at
  before update on public.products
  for each row execute function app_private.set_updated_at();

comment on table public.products is
  'Product master. Inventory unit is always one carton case. This row has no quantity, price, unit, or reorder level. supplier_id is the single supplier and may be null until supplier assignment is required. category_id may be null.';

comment on index public.products_sku_key is
  'SKU values are unique after trimming, compared case-insensitively.';

create table public.shops (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  address text,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint shops_name_length check (
    char_length(btrim(name)) between 1 and 160
    and name = btrim(name)
  ),
  constraint shops_phone_shape check (
    phone is null
    or (
      char_length(phone) between 7 and 24
      and phone = btrim(phone)
    )
  ),
  constraint shops_address_length check (
    address is null
    or (
      char_length(btrim(address)) between 1 and 400
      and address = btrim(address)
    )
  )
);

create index shops_is_active_idx on public.shops (is_active);

create trigger shops_set_updated_at
  before update on public.shops
  for each row execute function app_private.set_updated_at();

comment on table public.shops is
  'Customer shop. No godown column: shop-to-site ownership is unresolved. Salespersons are shop_salesperson_assignments, not a single column.';

create table public.shop_salesperson_assignments (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops (id) on delete restrict,
  salesperson_id uuid not null references public.profiles (id) on delete restrict,
  is_active boolean not null default true,
  assigned_at timestamptz not null default pg_catalog.now(),
  assigned_by uuid,
  revoked_at timestamptz,
  revoked_by uuid,
  constraint shop_salesperson_assignments_revocation_shape check (
    (is_active and revoked_at is null)
    or (not is_active and revoked_at is not null)
  )
);

create unique index shop_salesperson_assignments_active_key
  on public.shop_salesperson_assignments (shop_id, salesperson_id)
  where is_active;

create index shop_salesperson_assignments_salesperson_id_idx
  on public.shop_salesperson_assignments (salesperson_id);

create index shop_salesperson_assignments_shop_id_idx
  on public.shop_salesperson_assignments (shop_id);

comment on table public.shop_salesperson_assignments is
  'Many salespersons per shop, and many shops per salesperson. Active pairs are unique. Revocation keeps the row. assigned_by and revoked_by copy the actor id and do not reference profiles. Losing the Salesperson role or an active profile deactivates current rows and does not restore them later. Cross-godown assignment is not enforced.';

comment on index public.shop_salesperson_assignments_active_key is
  'Only one active assignment for a shop and salesperson. Inactive history may repeat.';

create table public.zones (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches (id) on delete restrict,
  code text not null,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint zones_code_shape check (
    char_length(btrim(code)) between 1 and 40
    and code = btrim(code)
  ),
  constraint zones_name_length check (
    char_length(btrim(name)) between 1 and 160
    and name = btrim(name)
  ),
  constraint zones_description_length check (
    description is null
    or (
      char_length(btrim(description)) between 1 and 500
      and description = btrim(description)
    )
  )
);

create unique index zones_branch_code_key
  on public.zones (branch_id, lower(code));

create index zones_branch_id_idx on public.zones (branch_id);
create index zones_is_active_idx on public.zones (is_active);

create trigger zones_set_updated_at
  before update on public.zones
  for each row execute function app_private.set_updated_at();

comment on table public.zones is
  'Storage area inside one operating site (godown). A zone cannot move to another godown. Deactivation while stock exists is unresolved because no stock table exists yet.';

comment on index public.zones_branch_code_key is
  'Zone codes are unique inside one godown, compared case-insensitively. Another godown may reuse the code.';

create table public.crates (
  id uuid primary key default gen_random_uuid(),
  zone_id uuid not null references public.zones (id) on delete restrict,
  code text not null,
  name text,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint crates_code_shape check (
    char_length(btrim(code)) between 1 and 40
    and code = btrim(code)
  ),
  constraint crates_name_length check (
    name is null
    or (
      char_length(btrim(name)) between 1 and 160
      and name = btrim(name)
    )
  ),
  constraint crates_description_length check (
    description is null
    or (
      char_length(btrim(description)) between 1 and 500
      and description = btrim(description)
    )
  )
);

create unique index crates_zone_code_key
  on public.crates (zone_id, lower(code));

create index crates_zone_id_idx on public.crates (zone_id);
create index crates_is_active_idx on public.crates (is_active);

create trigger crates_set_updated_at
  before update on public.crates
  for each row execute function app_private.set_updated_at();

comment on table public.crates is
  'Physical storage location inside one zone. The godown is zones.branch_id. A crate is not a product and stores no quantity. Capacity and single-product rules are unresolved. Code changes after stock exists are unresolved.';

comment on index public.crates_zone_code_key is
  'Crate codes are unique inside one zone, compared case-insensitively. Another zone may reuse the code.';

create or replace function app_private.deactivate_shop_assignments(
  target_salesperson uuid,
  reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  assignment record;
begin
  for assignment in
    select shop_salesperson_assignments.id, shop_salesperson_assignments.shop_id
    from public.shop_salesperson_assignments
    where shop_salesperson_assignments.salesperson_id = target_salesperson
      and shop_salesperson_assignments.is_active
  loop
    update public.shop_salesperson_assignments
    set
      is_active = false,
      revoked_at = pg_catalog.now(),
      revoked_by = auth.uid()
    where shop_salesperson_assignments.id = assignment.id;

    perform app_private.write_audit(
      auth.uid(),
      'revoke_shop_salesperson',
      'shop_salesperson_assignments',
      assignment.id,
      pg_catalog.jsonb_build_object(
        'shop_id', assignment.shop_id,
        'salesperson_id', target_salesperson,
        'reason', reason
      )
    );
  end loop;
end;
$$;

create or replace function app_private.revoke_assignments_when_profile_inactive()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.is_active and not new.is_active then
    perform app_private.deactivate_shop_assignments(new.id, 'profile_inactive');
  end if;

  return new;
end;
$$;

create trigger profiles_revoke_shop_assignments
  after update of is_active on public.profiles
  for each row execute function app_private.revoke_assignments_when_profile_inactive();

create or replace function app_private.revoke_assignments_when_salesperson_role_removed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.roles
    where roles.id = old.role_id
      and roles.code = 'salesperson'
  ) then
    perform app_private.deactivate_shop_assignments(old.user_id, 'salesperson_role_removed');
  end if;

  return old;
end;
$$;

create trigger user_roles_revoke_shop_assignments
  after delete on public.user_roles
  for each row execute function app_private.revoke_assignments_when_salesperson_role_removed();

revoke all on function app_private.deactivate_shop_assignments(uuid, text) from public, anon, authenticated, service_role;
revoke all on function app_private.revoke_assignments_when_profile_inactive() from public, anon, authenticated, service_role;
revoke all on function app_private.revoke_assignments_when_salesperson_role_removed() from public, anon, authenticated, service_role;

create or replace function app_private.assert_zone_manager(target_branch uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('locations.manage');

  if not exists (
    select 1
    from public.branches
    where branches.id = target_branch
      and branches.is_active
  ) then
    raise exception 'godown not found or inactive' using errcode = '42501';
  end if;

  if not app_private.can_work_at_branch(target_branch) then
    raise exception 'not authorized for this godown' using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_zone_manager(uuid) from public, anon, authenticated, service_role;

create or replace function public.create_product_category(
  category_name text,
  category_description text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
begin
  perform app_private.assert_permission('products.manage');

  insert into public.product_categories (name, description)
  values (
    app_private.clean_required_name(category_name),
    app_private.clean_optional_text(category_description, 500)
  )
  returning id into created_id;

  perform app_private.write_audit(
    auth.uid(),
    'create_product_category',
    'product_categories',
    created_id,
    pg_catalog.jsonb_build_object('name', app_private.clean_required_name(category_name))
  );

  return created_id;
exception
  when unique_violation then
    raise exception 'category name already exists' using errcode = '23505';
end;
$$;

create or replace function public.update_product_category(
  target_category uuid,
  category_name text,
  category_description text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('products.manage');

  update public.product_categories
  set
    name = app_private.clean_required_name(category_name),
    description = app_private.clean_optional_text(category_description, 500)
  where product_categories.id = target_category;

  if not found then
    raise exception 'category not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'update_product_category',
    'product_categories',
    target_category,
    pg_catalog.jsonb_build_object('name', app_private.clean_required_name(category_name))
  );
exception
  when unique_violation then
    raise exception 'category name already exists' using errcode = '23505';
end;
$$;

create or replace function public.set_product_category_active(
  target_category uuid,
  active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('products.manage');

  update public.product_categories
  set is_active = active
  where product_categories.id = target_category;

  if not found then
    raise exception 'category not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'set_product_category_active',
    'product_categories',
    target_category,
    pg_catalog.jsonb_build_object('is_active', active)
  );
end;
$$;

create or replace function public.create_supplier(
  supplier_name text,
  supplier_phone text,
  supplier_email text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
begin
  perform app_private.assert_permission('suppliers.manage');

  insert into public.suppliers (name, phone, email)
  values (
    app_private.clean_required_name(supplier_name),
    app_private.clean_optional_phone(supplier_phone),
    app_private.clean_optional_email(supplier_email)
  )
  returning id into created_id;

  perform app_private.write_audit(
    auth.uid(),
    'create_supplier',
    'suppliers',
    created_id,
    pg_catalog.jsonb_build_object('name', app_private.clean_required_name(supplier_name))
  );

  return created_id;
end;
$$;

create or replace function public.update_supplier(
  target_supplier uuid,
  supplier_name text,
  supplier_phone text,
  supplier_email text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('suppliers.manage');

  update public.suppliers
  set
    name = app_private.clean_required_name(supplier_name),
    phone = app_private.clean_optional_phone(supplier_phone),
    email = app_private.clean_optional_email(supplier_email)
  where suppliers.id = target_supplier;

  if not found then
    raise exception 'supplier not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'update_supplier',
    'suppliers',
    target_supplier,
    pg_catalog.jsonb_build_object('name', app_private.clean_required_name(supplier_name))
  );
end;
$$;

create or replace function public.set_supplier_active(target_supplier uuid, active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('suppliers.manage');

  update public.suppliers
  set is_active = active
  where suppliers.id = target_supplier;

  if not found then
    raise exception 'supplier not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'set_supplier_active',
    'suppliers',
    target_supplier,
    pg_catalog.jsonb_build_object('is_active', active)
  );
end;
$$;

create or replace function app_private.assert_active_reference(
  target_supplier uuid,
  target_category uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if target_supplier is not null and not exists (
    select 1
    from public.suppliers
    where suppliers.id = target_supplier
      and suppliers.is_active
  ) then
    raise exception 'supplier not found or inactive' using errcode = '42501';
  end if;

  if target_category is not null and not exists (
    select 1
    from public.product_categories
    where product_categories.id = target_category
      and product_categories.is_active
  ) then
    raise exception 'category not found or inactive' using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_active_reference(uuid, uuid) from public, anon, authenticated, service_role;

create or replace function public.create_product(
  product_sku text,
  product_name text,
  next_supplier uuid,
  next_category uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
  cleaned_sku text;
begin
  perform app_private.assert_permission('products.manage');
  cleaned_sku := app_private.clean_code(product_sku);
  perform app_private.assert_active_reference(next_supplier, next_category);

  insert into public.products (sku, name, supplier_id, category_id)
  values (
    cleaned_sku,
    app_private.clean_required_name(product_name),
    next_supplier,
    next_category
  )
  returning id into created_id;

  perform app_private.write_audit(
    auth.uid(),
    'create_product',
    'products',
    created_id,
    pg_catalog.jsonb_build_object('sku', cleaned_sku)
  );

  return created_id;
exception
  when unique_violation then
    raise exception 'sku already exists' using errcode = '23505';
end;
$$;

create or replace function public.update_product(
  target_product uuid,
  product_sku text,
  product_name text,
  next_supplier uuid,
  next_category uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_sku text;
begin
  perform app_private.assert_permission('products.manage');
  cleaned_sku := app_private.clean_code(product_sku);
  perform app_private.assert_active_reference(next_supplier, next_category);

  update public.products
  set
    sku = cleaned_sku,
    name = app_private.clean_required_name(product_name),
    supplier_id = next_supplier,
    category_id = next_category
  where products.id = target_product;

  if not found then
    raise exception 'product not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'update_product',
    'products',
    target_product,
    pg_catalog.jsonb_build_object('sku', cleaned_sku)
  );
exception
  when unique_violation then
    raise exception 'sku already exists' using errcode = '23505';
end;
$$;

create or replace function public.set_product_active(target_product uuid, active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('products.manage');

  update public.products
  set is_active = active
  where products.id = target_product;

  if not found then
    raise exception 'product not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'set_product_active',
    'products',
    target_product,
    pg_catalog.jsonb_build_object('is_active', active)
  );
end;
$$;

create or replace function public.create_shop(
  shop_name text,
  shop_phone text,
  shop_address text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
begin
  perform app_private.assert_permission('shops.manage');

  insert into public.shops (name, phone, address)
  values (
    app_private.clean_required_name(shop_name),
    app_private.clean_optional_phone(shop_phone),
    app_private.clean_optional_text(shop_address, 400)
  )
  returning id into created_id;

  perform app_private.write_audit(
    auth.uid(),
    'create_shop',
    'shops',
    created_id,
    pg_catalog.jsonb_build_object('name', app_private.clean_required_name(shop_name))
  );

  return created_id;
end;
$$;

create or replace function public.update_shop(
  target_shop uuid,
  shop_name text,
  shop_phone text,
  shop_address text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('shops.manage');

  update public.shops
  set
    name = app_private.clean_required_name(shop_name),
    phone = app_private.clean_optional_phone(shop_phone),
    address = app_private.clean_optional_text(shop_address, 400)
  where shops.id = target_shop;

  if not found then
    raise exception 'shop not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'update_shop',
    'shops',
    target_shop,
    pg_catalog.jsonb_build_object('name', app_private.clean_required_name(shop_name))
  );
end;
$$;

create or replace function public.set_shop_active(target_shop uuid, active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('shops.manage');

  update public.shops
  set is_active = active
  where shops.id = target_shop;

  if not found then
    raise exception 'shop not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'set_shop_active',
    'shops',
    target_shop,
    pg_catalog.jsonb_build_object('is_active', active)
  );
end;
$$;

create or replace function public.assign_shop_salesperson(
  target_shop uuid,
  target_salesperson uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
begin
  -- shops.manage is not granted yet. A dedicated assignment permission is still pending.
  -- Cross-godown eligibility is not checked: shops have no godown.
  perform app_private.assert_permission('shops.manage');

  if not exists (
    select 1
    from public.shops
    where shops.id = target_shop
      and shops.is_active
  ) then
    raise exception 'shop not found or inactive' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.profiles
    join public.user_roles on user_roles.user_id = profiles.id
    join public.roles on roles.id = user_roles.role_id
    where profiles.id = target_salesperson
      and profiles.is_active
      and roles.code = 'salesperson'
  ) then
    raise exception 'an active salesperson is required' using errcode = '42501';
  end if;

  insert into public.shop_salesperson_assignments (shop_id, salesperson_id, assigned_by)
  values (target_shop, target_salesperson, auth.uid())
  returning id into created_id;

  perform app_private.write_audit(
    auth.uid(),
    'assign_shop_salesperson',
    'shop_salesperson_assignments',
    created_id,
    pg_catalog.jsonb_build_object(
      'shop_id', target_shop,
      'salesperson_id', target_salesperson
    )
  );

  return created_id;
exception
  when unique_violation then
    raise exception 'salesperson is already assigned to this shop' using errcode = '23505';
end;
$$;

create or replace function public.revoke_shop_salesperson(
  target_shop uuid,
  target_salesperson uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  assignment_id uuid;
begin
  perform app_private.assert_permission('shops.manage');

  update public.shop_salesperson_assignments
  set
    is_active = false,
    revoked_at = pg_catalog.now(),
    revoked_by = auth.uid()
  where shop_salesperson_assignments.shop_id = target_shop
    and shop_salesperson_assignments.salesperson_id = target_salesperson
    and shop_salesperson_assignments.is_active
  returning id into assignment_id;

  if assignment_id is null then
    raise exception 'assignment not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'revoke_shop_salesperson',
    'shop_salesperson_assignments',
    assignment_id,
    pg_catalog.jsonb_build_object(
      'shop_id', target_shop,
      'salesperson_id', target_salesperson,
      'reason', 'revoked'
    )
  );
end;
$$;

create or replace function public.create_zone(
  target_branch uuid,
  zone_code text,
  zone_name text,
  zone_description text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
  cleaned_code text;
begin
  perform app_private.assert_zone_manager(target_branch);
  cleaned_code := app_private.clean_code(zone_code);

  insert into public.zones (branch_id, code, name, description)
  values (
    target_branch,
    cleaned_code,
    app_private.clean_required_name(zone_name),
    app_private.clean_optional_text(zone_description, 500)
  )
  returning id into created_id;

  perform app_private.write_audit(
    auth.uid(),
    'create_zone',
    'zones',
    created_id,
    pg_catalog.jsonb_build_object('branch_id', target_branch, 'code', cleaned_code)
  );

  return created_id;
exception
  when unique_violation then
    raise exception 'zone code already exists in this godown' using errcode = '23505';
end;
$$;

create or replace function public.update_zone(
  target_zone uuid,
  zone_code text,
  zone_name text,
  zone_description text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_branch uuid;
  cleaned_code text;
begin
  perform app_private.assert_permission('locations.manage');

  select zones.branch_id
  into selected_branch
  from public.zones
  where zones.id = target_zone;

  if selected_branch is null then
    raise exception 'zone not found' using errcode = '42501';
  end if;

  perform app_private.assert_zone_manager(selected_branch);
  cleaned_code := app_private.clean_code(zone_code);

  update public.zones
  set
    code = cleaned_code,
    name = app_private.clean_required_name(zone_name),
    description = app_private.clean_optional_text(zone_description, 500)
  where zones.id = target_zone;

  perform app_private.write_audit(
    auth.uid(),
    'update_zone',
    'zones',
    target_zone,
    pg_catalog.jsonb_build_object('code', cleaned_code)
  );
exception
  when unique_violation then
    raise exception 'zone code already exists in this godown' using errcode = '23505';
end;
$$;

create or replace function public.set_zone_active(target_zone uuid, active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_branch uuid;
begin
  perform app_private.assert_permission('locations.manage');

  select zones.branch_id
  into selected_branch
  from public.zones
  where zones.id = target_zone;

  if selected_branch is null then
    raise exception 'zone not found' using errcode = '42501';
  end if;

  perform app_private.assert_zone_manager(selected_branch);

  update public.zones
  set is_active = active
  where zones.id = target_zone;

  perform app_private.write_audit(
    auth.uid(),
    'set_zone_active',
    'zones',
    target_zone,
    pg_catalog.jsonb_build_object('is_active', active)
  );
end;
$$;

create or replace function public.create_crate(
  target_zone uuid,
  crate_code text,
  crate_name text,
  crate_description text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
  selected_branch uuid;
  zone_is_active boolean;
  cleaned_code text;
begin
  perform app_private.assert_permission('locations.manage');

  select zones.branch_id, zones.is_active
  into selected_branch, zone_is_active
  from public.zones
  where zones.id = target_zone;

  if selected_branch is null or not zone_is_active then
    raise exception 'zone not found or inactive' using errcode = '42501';
  end if;

  perform app_private.assert_zone_manager(selected_branch);
  cleaned_code := app_private.clean_code(crate_code);

  insert into public.crates (zone_id, code, name, description)
  values (
    target_zone,
    cleaned_code,
    app_private.clean_optional_text(crate_name, 160),
    app_private.clean_optional_text(crate_description, 500)
  )
  returning id into created_id;

  perform app_private.write_audit(
    auth.uid(),
    'create_crate',
    'crates',
    created_id,
    pg_catalog.jsonb_build_object('zone_id', target_zone, 'code', cleaned_code)
  );

  return created_id;
exception
  when unique_violation then
    raise exception 'crate code already exists in this zone' using errcode = '23505';
end;
$$;

create or replace function public.update_crate(
  target_crate uuid,
  crate_code text,
  crate_name text,
  crate_description text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_branch uuid;
  cleaned_code text;
begin
  perform app_private.assert_permission('locations.manage');

  select zones.branch_id
  into selected_branch
  from public.crates
  join public.zones on zones.id = crates.zone_id
  where crates.id = target_crate;

  if selected_branch is null then
    raise exception 'crate not found' using errcode = '42501';
  end if;

  perform app_private.assert_zone_manager(selected_branch);
  cleaned_code := app_private.clean_code(crate_code);

  update public.crates
  set
    code = cleaned_code,
    name = app_private.clean_optional_text(crate_name, 160),
    description = app_private.clean_optional_text(crate_description, 500)
  where crates.id = target_crate;

  perform app_private.write_audit(
    auth.uid(),
    'update_crate',
    'crates',
    target_crate,
    pg_catalog.jsonb_build_object('code', cleaned_code)
  );
exception
  when unique_violation then
    raise exception 'crate code already exists in this zone' using errcode = '23505';
end;
$$;

create or replace function public.set_crate_active(target_crate uuid, active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_branch uuid;
  zone_is_active boolean;
begin
  perform app_private.assert_permission('locations.manage');

  select zones.branch_id, zones.is_active
  into selected_branch, zone_is_active
  from public.crates
  join public.zones on zones.id = crates.zone_id
  where crates.id = target_crate;

  if selected_branch is null then
    raise exception 'crate not found' using errcode = '42501';
  end if;

  if active and not zone_is_active then
    raise exception 'zone not found or inactive' using errcode = '42501';
  end if;

  perform app_private.assert_zone_manager(selected_branch);

  update public.crates
  set is_active = active
  where crates.id = target_crate;

  perform app_private.write_audit(
    auth.uid(),
    'set_crate_active',
    'crates',
    target_crate,
    pg_catalog.jsonb_build_object('is_active', active)
  );
end;
$$;

revoke all on function public.create_product_category(text, text) from public, anon;
revoke all on function public.update_product_category(uuid, text, text) from public, anon;
revoke all on function public.set_product_category_active(uuid, boolean) from public, anon;
revoke all on function public.create_supplier(text, text, text) from public, anon;
revoke all on function public.update_supplier(uuid, text, text, text) from public, anon;
revoke all on function public.set_supplier_active(uuid, boolean) from public, anon;
revoke all on function public.create_product(text, text, uuid, uuid) from public, anon;
revoke all on function public.update_product(uuid, text, text, uuid, uuid) from public, anon;
revoke all on function public.set_product_active(uuid, boolean) from public, anon;
revoke all on function public.create_shop(text, text, text) from public, anon;
revoke all on function public.update_shop(uuid, text, text, text) from public, anon;
revoke all on function public.set_shop_active(uuid, boolean) from public, anon;
revoke all on function public.assign_shop_salesperson(uuid, uuid) from public, anon;
revoke all on function public.revoke_shop_salesperson(uuid, uuid) from public, anon;
revoke all on function public.create_zone(uuid, text, text, text) from public, anon;
revoke all on function public.update_zone(uuid, text, text, text) from public, anon;
revoke all on function public.set_zone_active(uuid, boolean) from public, anon;
revoke all on function public.create_crate(uuid, text, text, text) from public, anon;
revoke all on function public.update_crate(uuid, text, text, text) from public, anon;
revoke all on function public.set_crate_active(uuid, boolean) from public, anon;

grant execute on function public.create_product_category(text, text) to authenticated;
grant execute on function public.update_product_category(uuid, text, text) to authenticated;
grant execute on function public.set_product_category_active(uuid, boolean) to authenticated;
grant execute on function public.create_supplier(text, text, text) to authenticated;
grant execute on function public.update_supplier(uuid, text, text, text) to authenticated;
grant execute on function public.set_supplier_active(uuid, boolean) to authenticated;
grant execute on function public.create_product(text, text, uuid, uuid) to authenticated;
grant execute on function public.update_product(uuid, text, text, uuid, uuid) to authenticated;
grant execute on function public.set_product_active(uuid, boolean) to authenticated;
grant execute on function public.create_shop(text, text, text) to authenticated;
grant execute on function public.update_shop(uuid, text, text, text) to authenticated;
grant execute on function public.set_shop_active(uuid, boolean) to authenticated;
grant execute on function public.assign_shop_salesperson(uuid, uuid) to authenticated;
grant execute on function public.revoke_shop_salesperson(uuid, uuid) to authenticated;
grant execute on function public.create_zone(uuid, text, text, text) to authenticated;
grant execute on function public.update_zone(uuid, text, text, text) to authenticated;
grant execute on function public.set_zone_active(uuid, boolean) to authenticated;
grant execute on function public.create_crate(uuid, text, text, text) to authenticated;
grant execute on function public.update_crate(uuid, text, text, text) to authenticated;
grant execute on function public.set_crate_active(uuid, boolean) to authenticated;

insert into public.permissions (code, description)
values
  ('products.read', 'View product categories and products.'),
  ('products.manage', 'Create, update, and deactivate product categories and products.'),
  ('suppliers.read', 'View suppliers.'),
  ('suppliers.manage', 'Create, update, and deactivate suppliers.'),
  ('shops.read', 'View shops and salesperson assignments.'),
  ('shops.manage', 'Create, update, and deactivate shops, and assign or revoke salespersons.'),
  ('locations.read', 'View zones and crates for an authorized godown.'),
  ('locations.manage', 'Create, update, and deactivate zones and crates for an authorized godown.'),
  ('stock.read', 'View crate-level stock once the ledger exists.'),
  (
    'stock.opening.post',
    'Post opening stock through a future controlled function into one crate. Does not allow direct balance edits.'
  );

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'stock.opening.post'
where roles.code = 'admin';

alter table public.product_categories enable row level security;
alter table public.suppliers enable row level security;
alter table public.products enable row level security;
alter table public.shops enable row level security;
alter table public.shop_salesperson_assignments enable row level security;
alter table public.zones enable row level security;
alter table public.crates enable row level security;

alter table public.product_categories force row level security;
alter table public.suppliers force row level security;
alter table public.products force row level security;
alter table public.shops force row level security;
alter table public.shop_salesperson_assignments force row level security;
alter table public.zones force row level security;
alter table public.crates force row level security;

create policy product_categories_select_readers
  on public.product_categories
  for select
  to authenticated
  using ((select app_private.has_permission('products.read')));

create policy suppliers_select_readers
  on public.suppliers
  for select
  to authenticated
  using ((select app_private.has_permission('suppliers.read')));

create policy products_select_readers
  on public.products
  for select
  to authenticated
  using ((select app_private.has_permission('products.read')));

create policy shops_select_readers
  on public.shops
  for select
  to authenticated
  using ((select app_private.has_permission('shops.read')));

create policy shop_salesperson_assignments_select_readers
  on public.shop_salesperson_assignments
  for select
  to authenticated
  using ((select app_private.has_permission('shops.read')));

create policy zones_select_readers
  on public.zones
  for select
  to authenticated
  using (
    (select app_private.has_permission('locations.read'))
    and (select app_private.can_work_at_branch(zones.branch_id))
  );

create policy crates_select_readers
  on public.crates
  for select
  to authenticated
  using (
    (select app_private.has_permission('locations.read'))
    and exists (
      select 1
      from public.zones
      where zones.id = crates.zone_id
        and (select app_private.can_work_at_branch(zones.branch_id))
    )
  );

revoke all on table public.product_categories from public, anon, authenticated;
revoke all on table public.suppliers from public, anon, authenticated;
revoke all on table public.products from public, anon, authenticated;
revoke all on table public.shops from public, anon, authenticated;
revoke all on table public.shop_salesperson_assignments from public, anon, authenticated;
revoke all on table public.zones from public, anon, authenticated;
revoke all on table public.crates from public, anon, authenticated;

revoke insert, update, delete, truncate on table public.product_categories from service_role;
revoke insert, update, delete, truncate on table public.suppliers from service_role;
revoke insert, update, delete, truncate on table public.products from service_role;
revoke insert, update, delete, truncate on table public.shops from service_role;
revoke insert, update, delete, truncate on table public.shop_salesperson_assignments from service_role;
revoke insert, update, delete, truncate on table public.zones from service_role;
revoke insert, update, delete, truncate on table public.crates from service_role;

grant select on table public.product_categories to authenticated;
grant select on table public.suppliers to authenticated;
grant select on table public.products to authenticated;
grant select on table public.shops to authenticated;
grant select on table public.shop_salesperson_assignments to authenticated;
grant select on table public.zones to authenticated;
grant select on table public.crates to authenticated;

comment on function public.assign_shop_salesperson(uuid, uuid) is
  'Requires shops.manage, which is not granted. The assigned profile must be an active Salesperson. Does not check a godown.';

comment on function public.create_zone(uuid, text, text, text) is
  'Requires locations.manage and app_private.can_work_at_branch. locations.manage is not granted.';

comment on function public.create_product(text, text, uuid, uuid) is
  'Requires products.manage, which is not granted. Supplier and category are optional. Both must be active when supplied. No quantity is written.';
