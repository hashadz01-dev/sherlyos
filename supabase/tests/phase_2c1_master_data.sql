-- Local disposable checks for Phase 2C.1. The transaction rolls back.
-- Run with: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f supabase/tests/phase_2c1_master_data.sql

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);

grant select on fixture to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('inactive_admin', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('salesperson', gen_random_uuid()),
  ('salesperson_two', gen_random_uuid());

insert into auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.phase2c1@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture;

select app_private.bootstrap_initial_admin(
  (select id from fixture where name = 'admin'),
  'create-initial-administrator'
);

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles on roles.code = 'admin'
where fixture.name = 'inactive_admin';

select set_config(
  'request.jwt.claims',
  (
    select json_build_object('sub', id, 'role', 'authenticated')::text
    from fixture
    where name = 'admin'
  ),
  true
);

set local role authenticated;

select set_config('sherlyos.branch_a', public.create_branch('godown_a', 'Godown A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('godown_b', 'Godown B')::text, true);

select public.assign_user_role((select id from fixture where name = 'godown'), 'godown_manager');
select public.assign_user_role((select id from fixture where name = 'salesperson'), 'salesperson');
select public.assign_user_role((select id from fixture where name = 'salesperson_two'), 'salesperson');
select public.assign_user_branch(
  (select id from fixture where name = 'godown'),
  current_setting('sherlyos.branch_a')::uuid
);

do $$
begin
  perform public.assign_user_role(
    (select id from fixture where name = 'admin'),
    'salesperson'
  );
  raise exception 'self role change was accepted';
exception
  when insufficient_privilege then
    null;
end;
$$;

reset role;

do $$
begin
  if to_regclass('public.stock_movements') is not null
    or to_regclass('public.units_of_measure') is not null
    or to_regclass('public.product_site_settings') is not null
    or to_regclass('public.product_crate_assignments') is not null
  then
    raise exception 'an unapproved table was created';
  end if;

  if to_regclass('public.stock_transactions') is null
    or to_regclass('public.stock_ledger') is null
    or to_regclass('public.stock_balances') is null
  then
    raise exception 'the inventory ledger tables are missing';
  end if;

  if to_regclass('public.product_categories') is null
    or to_regclass('public.suppliers') is null
    or to_regclass('public.products') is null
    or to_regclass('public.shops') is null
    or to_regclass('public.shop_salesperson_assignments') is null
    or to_regclass('public.zones') is null
    or to_regclass('public.crates') is null
  then
    raise exception 'a master table is missing';
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name in (
        'product_categories',
        'suppliers',
        'products',
        'shops',
        'zones',
        'crates'
      )
      and column_name ~ 'quantity|reorder|price|unit|salesperson_id|branch_id'
      and not (table_name = 'zones' and column_name = 'branch_id')
  ) then
    raise exception 'an unapproved column was created';
  end if;
end;
$$;

insert into public.products (sku, name)
values ('sku-1', 'Product One');

do $$
begin
  insert into public.products (sku, name)
  values ('SKU-1', 'Product Two');
  raise exception 'duplicate sku was accepted';
exception
  when unique_violation then
    null;
end;
$$;

insert into public.zones (branch_id, code, name)
values (current_setting('sherlyos.branch_a')::uuid, 'A', 'Zone A');

do $$
begin
  insert into public.zones (branch_id, code, name)
  values (current_setting('sherlyos.branch_a')::uuid, 'a', 'Zone A folded');
  raise exception 'duplicate zone code was accepted';
exception
  when unique_violation then
    null;
end;
$$;

insert into public.zones (branch_id, code, name)
values (current_setting('sherlyos.branch_b')::uuid, 'A', 'Zone A other godown');

insert into public.crates (zone_id, code)
select zones.id, 'A01'
from public.zones
where zones.branch_id = current_setting('sherlyos.branch_a')::uuid
  and zones.code = 'A';

do $$
begin
  insert into public.crates (zone_id, code)
  select zones.id, 'a01'
  from public.zones
  where zones.branch_id = current_setting('sherlyos.branch_a')::uuid
    and zones.code = 'A';
  raise exception 'duplicate crate code was accepted';
exception
  when unique_violation then
    null;
end;
$$;

insert into public.crates (zone_id, code)
select zones.id, 'A01'
from public.zones
where zones.branch_id = current_setting('sherlyos.branch_b')::uuid
  and zones.code = 'A';

do $$
begin
  insert into public.crates (zone_id, code)
  values (gen_random_uuid(), 'Z9');
  raise exception 'crate accepted a missing zone';
exception
  when foreign_key_violation then
    null;
end;
$$;

do $$
begin
  insert into public.zones (branch_id, code, name)
  values (gen_random_uuid(), 'Z', 'Missing godown');
  raise exception 'zone accepted a missing godown';
exception
  when foreign_key_violation then
    null;
end;
$$;

insert into public.suppliers (name)
values ('Supplier One')
returning id;

do $$
declare
  selected_supplier uuid;
begin
  select suppliers.id
  into selected_supplier
  from public.suppliers
  where suppliers.name = 'Supplier One';

  update public.products
  set supplier_id = selected_supplier
  where products.sku = 'sku-1';

  delete from public.suppliers
  where suppliers.id = selected_supplier;

  raise exception 'referenced supplier was deleted';
exception
  when foreign_key_violation then
    null;
end;
$$;

select set_config(
  'request.jwt.claims',
  (
    select json_build_object('sub', id, 'role', 'authenticated')::text
    from fixture
    where name = 'salesperson'
  ),
  true
);

set local role authenticated;

do $$
begin
  insert into public.products (sku, name) values ('direct', 'Direct');
  raise exception 'direct product insert was accepted';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.create_zone(
    current_setting('sherlyos.branch_a')::uuid,
    'B',
    'Zone B',
    null
  );
  raise exception 'unauthorized zone create was accepted';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.create_product('sku-9', 'Nine', null, null);
  raise exception 'unauthorized product create was accepted';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  if (select count(*) from public.products) <> 0 then
    raise exception 'products were visible without products.read';
  end if;
  if (select count(*) from public.zones) <> 0 then
    raise exception 'zones were visible without locations.read';
  end if;
end;
$$;

reset role;

set local role anon;

do $$
begin
  perform count(*) from public.products;
  raise exception 'anon could read products';
exception
  when insufficient_privilege then
    null;
end;
$$;

reset role;

set local role service_role;

do $$
begin
  insert into public.products (sku, name) values ('service', 'Service');
  raise exception 'service role insert was accepted';
exception
  when insufficient_privilege then
    null;
end;
$$;

reset role;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions
  on permissions.code in ('locations.read', 'locations.manage')
where roles.code = 'godown_manager'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions
  on permissions.code in (
    'products.manage',
    'products.read',
    'suppliers.manage',
    'shops.manage',
    'shops.read'
  )
where roles.code = 'admin'
on conflict do nothing;

select set_config(
  'request.jwt.claims',
  (
    select json_build_object('sub', id, 'role', 'authenticated')::text
    from fixture
    where name = 'godown'
  ),
  true
);

set local role authenticated;

select set_config(
  'sherlyos.zone_a',
  public.create_zone(
    current_setting('sherlyos.branch_a')::uuid,
    'B',
    'Zone B',
    null
  )::text,
  true
);

do $$
begin
  perform public.create_zone(
    current_setting('sherlyos.branch_b')::uuid,
    'B',
    'Other godown',
    null
  );
  raise exception 'cross-godown zone create was accepted';
exception
  when insufficient_privilege then
    null;
end;
$$;

select set_config(
  'sherlyos.crate_b',
  public.create_crate(current_setting('sherlyos.zone_a')::uuid, 'B01', null, null)::text,
  true
);

do $$
begin
  perform public.create_crate(current_setting('sherlyos.zone_a')::uuid, 'b01', null, null);
  raise exception 'duplicate crate create was accepted';
exception
  when unique_violation then
    null;
end;
$$;

do $$
begin
  if exists (
    select 1
    from public.zones
    where zones.branch_id = current_setting('sherlyos.branch_b')::uuid
  ) then
    raise exception 'godown manager saw the other godown';
  end if;
  if (select count(*) from public.zones) <> 2 then
    raise exception 'godown manager did not see both zones in the assigned godown';
  end if;
  if (select count(*) from public.crates) <> 2 then
    raise exception 'godown manager did not see both crates in the assigned godown';
  end if;
end;
$$;

reset role;

select set_config(
  'request.jwt.claims',
  (
    select json_build_object('sub', id, 'role', 'authenticated')::text
    from fixture
    where name = 'admin'
  ),
  true
);

set local role authenticated;

select set_config(
  'sherlyos.supplier',
  public.create_supplier('Supplier Two', '+91 9000000001', 'supplier.two@example.com')::text,
  true
);
select public.set_supplier_active(current_setting('sherlyos.supplier')::uuid, false);

do $$
begin
  perform public.create_product(
    'sku-2',
    'Product Two',
    current_setting('sherlyos.supplier')::uuid,
    null
  );
  raise exception 'inactive supplier was accepted';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.set_supplier_active(current_setting('sherlyos.supplier')::uuid, true);
select set_config(
  'sherlyos.product',
  public.create_product(
    'sku-2',
    'Product Two',
    null,
    null
  )::text,
  true
);
select public.update_product(
  current_setting('sherlyos.product')::uuid,
  'sku-2',
  'Product Two',
  current_setting('sherlyos.supplier')::uuid,
  null
);

do $$
begin
  perform public.create_product('sku-2', 'Again', null, null);
  raise exception 'duplicate sku function was accepted';
exception
  when unique_violation then
    null;
end;
$$;

select set_config('sherlyos.shop', public.create_shop('Shop One', null, null)::text, true);
select set_config('sherlyos.shop_two', public.create_shop('Shop Two', null, null)::text, true);

select public.assign_shop_salesperson(
  current_setting('sherlyos.shop')::uuid,
  (select id from fixture where name = 'salesperson')
);
select public.assign_shop_salesperson(
  current_setting('sherlyos.shop')::uuid,
  (select id from fixture where name = 'salesperson_two')
);
select public.assign_shop_salesperson(
  current_setting('sherlyos.shop_two')::uuid,
  (select id from fixture where name = 'salesperson')
);

do $$
begin
  perform public.assign_shop_salesperson(
    current_setting('sherlyos.shop')::uuid,
    (select id from fixture where name = 'salesperson')
  );
  raise exception 'duplicate active assignment was accepted';
exception
  when unique_violation then
    null;
end;
$$;

do $$
begin
  perform public.assign_shop_salesperson(
    current_setting('sherlyos.shop')::uuid,
    (select id from fixture where name = 'godown')
  );
  raise exception 'non-salesperson assignment was accepted';
exception
  when insufficient_privilege then
    null;
end;
$$;

select public.revoke_shop_salesperson(
  current_setting('sherlyos.shop')::uuid,
  (select id from fixture where name = 'salesperson')
);
select public.assign_shop_salesperson(
  current_setting('sherlyos.shop')::uuid,
  (select id from fixture where name = 'salesperson')
);

select public.revoke_user_role(
  (select id from fixture where name = 'salesperson_two'),
  'salesperson'
);

select public.set_employee_active((select id from fixture where name = 'inactive_admin'), false);

do $$
begin
  perform public.set_employee_active((select id from fixture where name = 'admin'), false);
  raise exception 'self deactivation was accepted';
exception
  when insufficient_privilege then
    null;
end;
$$;

reset role;

do $$
begin
  if exists (
    select 1
    from public.shop_salesperson_assignments
    where salesperson_id = (select id from fixture where name = 'salesperson_two')
      and is_active
  ) then
    raise exception 'role removal left an active shop assignment';
  end if;

  if (
    select count(*)
    from public.shop_salesperson_assignments
    where shop_id = current_setting('sherlyos.shop')::uuid
      and salesperson_id = (select id from fixture where name = 'salesperson')
  ) <> 2 then
    raise exception 'reassignment did not keep history';
  end if;

  if (
    select count(*)
    from public.shop_salesperson_assignments
    where shop_id = current_setting('sherlyos.shop')::uuid
      and salesperson_id = (select id from fixture where name = 'salesperson')
      and is_active
  ) <> 1 then
    raise exception 'shop does not have one active salesperson row';
  end if;
end;
$$;

select set_config(
  'request.jwt.claims',
  (
    select json_build_object('sub', id, 'role', 'authenticated')::text
    from fixture
    where name = 'inactive_admin'
  ),
  true
);

set local role authenticated;

do $$
begin
  if app_private.has_permission('branches.manage') then
    raise exception 'inactive user kept a permission';
  end if;
  perform public.create_branch('inactive_site', 'Inactive Site');
  raise exception 'inactive user created a godown';
exception
  when insufficient_privilege then
    null;
end;
$$;

reset role;

select set_config(
  'request.jwt.claims',
  (
    select json_build_object('sub', id, 'role', 'authenticated')::text
    from fixture
    where name = 'salesperson'
  ),
  true
);

set local role authenticated;

do $$
begin
  perform public.assign_user_role(
    (select id from fixture where name = 'godown'),
    'admin'
  );
  raise exception 'salesperson granted a role';
exception
  when insufficient_privilege then
    null;
end;
$$;

reset role;

-- Phase 2C.2 grants the master-data permissions this script used to remove.
-- Phase 2C.3 grants stock.read and stock.transfer.post to the approved roles.
-- stock.opening.post stays Admin-only. Receiving and adjustment posting stay absent.

do $$
begin
  if (
    select count(*)
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where (roles.code, permissions.code) in (
      ('admin', 'stock.read'),
      ('accounts', 'stock.read'),
      ('godown_manager', 'stock.read'),
      ('store_keeper', 'stock.read'),
      ('admin', 'stock.transfer.post'),
      ('godown_manager', 'stock.transfer.post')
    )
  ) <> 6 then
    raise exception 'approved stock grants are incomplete';
  end if;

  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where permissions.code in ('stock.read', 'stock.transfer.post', 'stock.opening.post')
      and roles.code in ('salesperson', 'delivery_person')
  ) then
    raise exception 'salesperson or delivery person received a stock grant';
  end if;

  if (
    select count(*)
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where permissions.code = 'stock.opening.post'
      and roles.code = 'admin'
  ) <> 1 then
    raise exception 'admin opening-stock permission is missing';
  end if;

  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where permissions.code = 'stock.opening.post'
      and roles.code <> 'admin'
  ) then
    raise exception 'opening-stock permission was granted outside admin';
  end if;

  if exists (
    select 1
    from pg_proc
    join pg_namespace on pg_namespace.oid = pg_proc.pronamespace
    where pg_namespace.nspname = 'public'
      and pg_proc.proname ~ 'receipt|stock_adjustment'
  ) then
    raise exception 'an unapproved stock posting function was created';
  end if;

  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'delivery_person'
      and permissions.code = 'damage.record'
  ) then
    raise exception 'delivery person received damage.record';
  end if;

  if not exists (
    select 1
    from public.audit_logs
    where action = 'assign_shop_salesperson'
  ) then
    raise exception 'shop assignment was not audited';
  end if;
end;
$$;

rollback;
