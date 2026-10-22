-- Phase 4.3D.1 local disposable checks. Transaction rolls back.
-- Run: docker exec -i supabase_db_sherlyos psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/phase_4_3d1_stock_lots_hardening.sql

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
  ('godown_b', gen_random_uuid()),
  ('accounts', gen_random_uuid());

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
  fixture.name || '.phase43d1@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture;

do $$
begin
  begin
    perform app_private.bootstrap_initial_admin(
      (select id from fixture where name = 'admin'),
      'create-initial-administrator'
    );
  exception
    when sqlstate '42501' then
      insert into public.profiles (id, full_name, is_active)
      values (
        (select id from fixture where name = 'admin'),
        'Phase 4.3D.1 Admin',
        true
      )
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select
        (select id from fixture where name = 'admin'),
        roles.id,
        (select id from fixture where name = 'admin')
      from public.roles
      where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.profiles (id, full_name, is_active)
select fixture.id, fixture.name, true
from fixture
where fixture.name <> 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles
  on roles.code = case fixture.name
    when 'godown' then 'godown_manager'
    when 'godown_b' then 'godown_manager'
    when 'accounts' then 'accounts'
  end
where fixture.name in ('godown', 'godown_b', 'accounts')
on conflict do nothing;

-- Permission matrix: Admin has expiry manage; GM has products.manage but not expiry manage
do $$
begin
  if not exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'admin'
      and permissions.code = 'products.expiry_policy.manage'
  ) then
    raise exception 'admin missing products.expiry_policy.manage';
  end if;

  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'godown_manager'
      and permissions.code = 'products.expiry_policy.manage'
  ) then
    raise exception 'godown_manager must not have products.expiry_policy.manage';
  end if;

  if not exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'godown_manager'
      and permissions.code = 'products.manage'
  ) then
    raise exception 'godown_manager should still have products.manage';
  end if;
end $$;

select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from fixture where name = 'admin'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'sherlyos.branch_a',
  public.create_branch('p43d1_a', 'Phase 4.3D.1 Godown A')::text,
  true
);
select set_config(
  'sherlyos.branch_b',
  public.create_branch('p43d1_b', 'Phase 4.3D.1 Godown B')::text,
  true
);
select public.assign_user_branch(
  (select id from fixture where name = 'godown'),
  current_setting('sherlyos.branch_a')::uuid
);
select public.assign_user_branch(
  (select id from fixture where name = 'godown_b'),
  current_setting('sherlyos.branch_b')::uuid
);
select set_config(
  'sherlyos.zone_a',
  public.create_zone(current_setting('sherlyos.branch_a')::uuid, 'z43d1a', 'Z43D1A', null)::text,
  true
);
select set_config(
  'sherlyos.crate_a',
  public.create_crate(current_setting('sherlyos.zone_a')::uuid, 'c43d1a', 'C43D1A', null)::text,
  true
);
select set_config(
  'sherlyos.zone_b',
  public.create_zone(current_setting('sherlyos.branch_b')::uuid, 'z43d1b', 'Z43D1B', null)::text,
  true
);
select set_config(
  'sherlyos.crate_b',
  public.create_crate(current_setting('sherlyos.zone_b')::uuid, 'c43d1b', 'C43D1B', null)::text,
  true
);
select set_config(
  'sherlyos.product',
  public.create_product('p43d1-soap', 'Phase 4.3D.1 Soap', null, null)::text,
  true
);

reset role;

-- Godown Manager: products.manage still works for catalog, but classification denied
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'godown'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from fixture where name = 'godown'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

do $$
begin
  begin
    perform public.set_product_expiry_policy(
      current_setting('sherlyos.product')::uuid,
      'expiry_controlled'
    );
    raise exception 'godown manager should not classify products';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

reset role;

-- Accounts denied
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'accounts'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from fixture where name = 'accounts'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

do $$
begin
  begin
    perform public.set_product_expiry_policy(
      current_setting('sherlyos.product')::uuid,
      'expiry_controlled'
    );
    raise exception 'accounts should not classify products';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

reset role;

-- Admin classifies successfully
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from fixture where name = 'admin'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

do $$
declare
  row public.products%rowtype;
begin
  row := public.set_product_expiry_policy(
    current_setting('sherlyos.product')::uuid,
    'expiry_controlled'
  );
  if row.expiry_policy is distinct from 'expiry_controlled' then
    raise exception 'admin classification failed';
  end if;
end $$;

reset role;

-- Seed lots as table owner: no-balance cross-branch, zero-balance same-branch
do $$
declare
  lot_a_empty uuid;
  lot_b_empty uuid;
  lot_a_zero uuid;
  branch_a uuid := current_setting('sherlyos.branch_a')::uuid;
  branch_b uuid := current_setting('sherlyos.branch_b')::uuid;
  crate_a uuid := current_setting('sherlyos.crate_a')::uuid;
  product uuid := current_setting('sherlyos.product')::uuid;
begin
  insert into public.stock_lots (
    product_id, branch_id, expiry_date, received_on, status, origin, created_by
  )
  values (
    product, branch_a, current_date + 30, clock_timestamp(),
    'available', 'opening', (select id from fixture where name = 'admin')
  )
  returning id into lot_a_empty;

  insert into public.stock_lots (
    product_id, branch_id, expiry_date, received_on, status, origin, created_by
  )
  values (
    product, branch_b, current_date + 40, clock_timestamp(),
    'available', 'opening', (select id from fixture where name = 'admin')
  )
  returning id into lot_b_empty;

  insert into public.stock_lots (
    product_id, branch_id, expiry_date, received_on, status, origin, created_by
  )
  values (
    product, branch_a, current_date + 50, clock_timestamp(),
    'available', 'opening', (select id from fixture where name = 'admin')
  )
  returning id into lot_a_zero;

  -- Legitimate zero-stock lot: balance row exists with quantity 0
  insert into public.stock_lot_balances (lot_id, crate_id, quantity)
  values (lot_a_zero, crate_a, 0);

  perform set_config('sherlyos.lot_a_empty', lot_a_empty::text, true);
  perform set_config('sherlyos.lot_b_empty', lot_b_empty::text, true);
  perform set_config('sherlyos.lot_a_zero', lot_a_zero::text, true);
end $$;

-- GM at branch A: sees A empty + A zero; must not see B empty
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'godown'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from fixture where name = 'godown'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

do $$
declare
  visible integer;
begin
  select count(*)::integer into visible
  from public.stock_lots
  where id = current_setting('sherlyos.lot_a_empty')::uuid;
  if visible <> 1 then
    raise exception 'GM A should see no-balance lot on branch A';
  end if;

  select count(*)::integer into visible
  from public.stock_lots
  where id = current_setting('sherlyos.lot_a_zero')::uuid;
  if visible <> 1 then
    raise exception 'GM A should see zero-quantity balance lot on branch A';
  end if;

  select count(*)::integer into visible
  from public.stock_lots
  where id = current_setting('sherlyos.lot_b_empty')::uuid;
  if visible <> 0 then
    raise exception 'GM A must not see no-balance lot on branch B';
  end if;

  select count(*)::integer into visible
  from public.stock_lot_balances
  where lot_id = current_setting('sherlyos.lot_a_zero')::uuid;
  if visible <> 1 then
    raise exception 'GM A should see zero-quantity balance row';
  end if;
end $$;

reset role;

-- GM at branch B: sees only B empty
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'godown_b'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from fixture where name = 'godown_b'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

do $$
declare
  visible integer;
begin
  select count(*)::integer into visible
  from public.stock_lots
  where id = current_setting('sherlyos.lot_b_empty')::uuid;
  if visible <> 1 then
    raise exception 'GM B should see no-balance lot on branch B';
  end if;

  select count(*)::integer into visible
  from public.stock_lots
  where id in (
    current_setting('sherlyos.lot_a_empty')::uuid,
    current_setting('sherlyos.lot_a_zero')::uuid
  );
  if visible <> 0 then
    raise exception 'GM B must not see branch A lots';
  end if;
end $$;

reset role;

-- Admin (branches.access_all) sees all three lots
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from fixture where name = 'admin'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

do $$
declare
  visible integer;
begin
  select count(*)::integer into visible
  from public.stock_lots
  where id in (
    current_setting('sherlyos.lot_a_empty')::uuid,
    current_setting('sherlyos.lot_b_empty')::uuid,
    current_setting('sherlyos.lot_a_zero')::uuid
  );
  if visible <> 3 then
    raise exception 'admin should see all fixture lots, got %', visible;
  end if;
end $$;

-- Opening stock still works
select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate_a')::uuid,
  2,
  'p43d1-open-' || gen_random_uuid()::text,
  'phase 4.3d.1 regression opening'
);

reset role;

-- Explicit FK probe: SQLSTATE must be 23503 (not append-only 42501)
do $$
declare
  tx uuid;
  product uuid := current_setting('sherlyos.product')::uuid;
  crate uuid := current_setting('sherlyos.crate_a')::uuid;
  actor uuid := (select id from fixture where name = 'admin');
  caught text;
begin
  select stock_transactions.id
  into tx
  from public.stock_transactions
  where stock_transactions.product_id = product
    and stock_transactions.destination_crate_id = crate
    and stock_transactions.transaction_type = 'OPENING_STOCK'
  limit 1;

  if tx is null then
    raise exception 'opening transaction missing for FK probe';
  end if;

  begin
    insert into public.stock_ledger (
      transaction_id,
      product_id,
      crate_id,
      quantity,
      actor_id,
      posted_at,
      lot_id
    )
    values (
      tx,
      product,
      crate,
      1,
      actor,
      clock_timestamp(),
      '00000000-0000-0000-0000-000000000099'::uuid
    );
    raise exception 'invalid lot_id should fail with foreign_key_violation / 23503';
  exception
    when foreign_key_violation then
      caught := sqlstate;
      if caught is distinct from '23503' then
        raise exception 'expected SQLSTATE 23503, got %', caught;
      end if;
    when others then
      raise exception 'FK probe expected 23503, got SQLSTATE %: %', sqlstate, sqlerrm;
  end;
end $$;

select 'phase_4_3d1_stock_lots_hardening ok' as result;

rollback;
