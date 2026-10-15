-- Local disposable checks for Phase 2C.2. The transaction rolls back.
-- Run with: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f supabase/tests/phase_2c2_master_data_access.sql

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);

grant select on fixture to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('accounts', gen_random_uuid()),
  ('salesperson', gen_random_uuid()),
  ('delivery', gen_random_uuid()),
  ('keeper', gen_random_uuid());

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
  fixture.name || '.phase2c2@example.com',
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

do $$
begin
  if not exists (
    select 1
    from public.roles
    join public.role_permissions on role_permissions.role_id = roles.id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'admin'
      and permissions.code = 'stock.opening.post'
  ) then
    raise exception 'admin lost stock.opening.post';
  end if;

  if exists (
    select 1
    from public.roles
    join public.role_permissions on role_permissions.role_id = roles.id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code <> 'admin'
      and permissions.code in ('stock.opening.post', 'shops.assign')
  ) then
    raise exception 'a non-admin received a restricted permission';
  end if;

  if (
    select count(*)
    from public.roles
    join public.role_permissions on role_permissions.role_id = roles.id
    join public.permissions on permissions.id = role_permissions.permission_id
    where (roles.code, permissions.code) in (
      ('admin', 'products.manage'),
      ('admin', 'suppliers.manage'),
      ('admin', 'shops.assign'),
      ('admin', 'locations.manage'),
      ('godown_manager', 'products.manage'),
      ('godown_manager', 'suppliers.read'),
      ('godown_manager', 'locations.manage'),
      ('accounts', 'suppliers.manage'),
      ('salesperson', 'shops.manage')
    )
  ) <> 9 then
    raise exception 'approved master-data grants are incomplete';
  end if;

  if exists (
    select 1
    from public.roles
    join public.role_permissions on role_permissions.role_id = roles.id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'godown_manager'
      and permissions.code = 'suppliers.manage'
  ) or exists (
    select 1
    from public.roles
    join public.role_permissions on role_permissions.role_id = roles.id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code in ('delivery_person', 'store_keeper', 'accounts', 'salesperson')
      and permissions.code in ('products.manage', 'locations.manage')
  ) then
    raise exception 'an unapproved management grant exists';
  end if;
end;
$$;

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
select public.assign_user_role((select id from fixture where name = 'accounts'), 'accounts');
select public.assign_user_role((select id from fixture where name = 'salesperson'), 'salesperson');
select public.assign_user_role((select id from fixture where name = 'delivery'), 'delivery_person');
select public.assign_user_role((select id from fixture where name = 'keeper'), 'store_keeper');
select public.assign_user_branch(
  (select id from fixture where name = 'godown'),
  current_setting('sherlyos.branch_a')::uuid
);

select set_config('sherlyos.product', public.create_product('sku-1', 'Soap', null, null)::text, true);
select set_config('sherlyos.shop', public.create_shop('Assigned Shop', null, null)::text, true);
select set_config('sherlyos.shop_two', public.create_shop('Other Shop', null, null)::text, true);
select public.assign_shop_salesperson(
  current_setting('sherlyos.shop')::uuid,
  (select id from fixture where name = 'salesperson')
);

do $$
begin
  perform public.create_product('sku-1', 'Duplicate', null, null);
  raise exception 'duplicate sku was accepted';
exception
  when unique_violation then
    null;
end;
$$;

do $$
begin
  perform public.assign_shop_salesperson(
    current_setting('sherlyos.shop')::uuid,
    (select id from fixture where name = 'salesperson')
  );
  raise exception 'duplicate assignment was accepted';
exception
  when unique_violation then
    null;
end;
$$;

do $$
begin
  perform public.assign_shop_salesperson(
    current_setting('sherlyos.shop')::uuid,
    (select id from fixture where name = 'accounts')
  );
  raise exception 'non-salesperson assignment was accepted';
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
    where name = 'godown'
  ),
  true
);
set local role authenticated;

select set_config(
  'sherlyos.zone',
  public.create_zone(
    current_setting('sherlyos.branch_a')::uuid,
    'z1',
    'Zone One',
    null
  )::text,
  true
);
select public.create_product('sku-gm', 'Godown Soap', null, null);

do $$
begin
  perform public.create_zone(
    current_setting('sherlyos.branch_b')::uuid,
    'z9',
    'Other Zone',
    null
  );
  raise exception 'cross-godown zone was accepted';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.create_zone(
    current_setting('sherlyos.branch_a')::uuid,
    'z1',
    'Duplicate Zone',
    null
  );
  raise exception 'duplicate zone code was accepted';
exception
  when unique_violation then
    null;
end;
$$;

select set_config(
  'sherlyos.crate',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'c1', null, null)::text,
  true
);

do $$
begin
  perform public.create_crate(current_setting('sherlyos.zone')::uuid, 'c1', null, null);
  raise exception 'duplicate crate code was accepted';
exception
  when unique_violation then
    null;
end;
$$;

do $$
begin
  perform public.create_supplier('Blocked Supplier', null, null);
  raise exception 'godown manager created a supplier';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.create_shop('Blocked Shop', null, null);
  raise exception 'godown manager created a shop';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
declare
  seen integer;
begin
  select count(*) into seen from public.zones;
  if seen <> 1 then
    raise exception 'godown manager saw % zones', seen;
  end if;
end;
$$;

reset role;

select set_config(
  'request.jwt.claims',
  (
    select json_build_object('sub', id, 'role', 'authenticated')::text
    from fixture
    where name = 'accounts'
  ),
  true
);
set local role authenticated;

select public.create_supplier('Accounts Supplier', null, null);

do $$
begin
  perform public.create_product('sku-accounts', 'Blocked', null, null);
  raise exception 'accounts created a product';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.create_zone(
    current_setting('sherlyos.branch_a')::uuid,
    'za',
    'Accounts Zone',
    null
  );
  raise exception 'accounts created a zone';
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
declare
  seen integer;
begin
  select count(*) into seen from public.shops;
  if seen <> 1 then
    raise exception 'salesperson saw % shops', seen;
  end if;
  select count(*) into seen from public.shop_salesperson_assignments;
  if seen <> 1 then
    raise exception 'salesperson saw % assignments', seen;
  end if;
end;
$$;

select public.update_shop(
  current_setting('sherlyos.shop')::uuid,
  'Assigned Shop Edited',
  null,
  null
);

do $$
begin
  perform public.update_shop(
    current_setting('sherlyos.shop_two')::uuid,
    'Stolen Shop',
    null,
    null
  );
  raise exception 'salesperson edited an unrelated shop';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.create_shop('Self Owned', null, null);
  raise exception 'salesperson created a shop';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.assign_shop_salesperson(
    current_setting('sherlyos.shop')::uuid,
    (select id from fixture where name = 'salesperson')
  );
  raise exception 'salesperson assigned a shop';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  perform public.create_zone(
    current_setting('sherlyos.branch_a')::uuid,
    'zs',
    'Sales Zone',
    null
  );
  raise exception 'salesperson created a zone';
exception
  when insufficient_privilege then
    null;
end;
$$;

do $$
begin
  insert into public.products (sku, name) values ('direct', 'Direct');
  raise exception 'direct product insert was accepted';
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
    where name = 'admin'
  ),
  true
);
set local role authenticated;
select public.revoke_shop_salesperson(
  current_setting('sherlyos.shop')::uuid,
  (select id from fixture where name = 'salesperson')
);

do $$
begin
  if (select count(*) from public.shops) < 2 then
    raise exception 'admin lost shop visibility after revocation';
  end if;
  if not exists (
    select 1
    from public.shop_salesperson_assignments
    where salesperson_id = (select id from fixture where name = 'salesperson')
      and shop_id = current_setting('sherlyos.shop')::uuid
      and is_active = false
  ) then
    raise exception 'admin cannot see revoked assignment history';
  end if;
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
declare
  seen integer;
begin
  select count(*) into seen from public.shops;
  if seen <> 0 then
    raise exception 'revoked salesperson still saw % shops', seen;
  end if;
  select count(*) into seen from public.shop_salesperson_assignments;
  if seen <> 0 then
    raise exception 'revoked salesperson still saw % assignments', seen;
  end if;
end;
$$;

do $$
begin
  perform public.update_shop(
    current_setting('sherlyos.shop')::uuid,
    'After Revoke',
    null,
    null
  );
  raise exception 'revoked salesperson still edited the shop';
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
    where name = 'delivery'
  ),
  true
);
set local role authenticated;

do $$
begin
  perform public.create_product('sku-delivery', 'Blocked', null, null);
  raise exception 'delivery person created a product';
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
    where name = 'keeper'
  ),
  true
);
set local role authenticated;

do $$
begin
  perform public.create_supplier('Keeper Supplier', null, null);
  raise exception 'store keeper created a supplier';
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
    where name = 'admin'
  ),
  true
);
set local role authenticated;
select public.set_employee_active((select id from fixture where name = 'godown'), false);
reset role;

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

do $$
begin
  perform public.create_product('sku-inactive', 'Blocked', null, null);
  raise exception 'inactive godown manager created a product';
exception
  when insufficient_privilege then
    null;
end;
$$;

reset role;

do $$
begin
  if not exists (
    select 1
    from public.audit_logs
    where action = 'create_product'
      and actor_id = (select id from fixture where name = 'admin')
  ) then
    raise exception 'product creation was not audited';
  end if;

  if not exists (
    select 1
    from public.audit_logs
    where action = 'assign_shop_salesperson'
  ) or not exists (
    select 1
    from public.audit_logs
    where action = 'revoke_shop_salesperson'
  ) or not exists (
    select 1
    from public.audit_logs
    where action = 'create_zone'
  ) then
    raise exception 'assignment or location changes were not audited';
  end if;
end;
$$;

rollback;
