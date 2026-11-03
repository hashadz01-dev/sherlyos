-- Receiving first-classify for unclassified SKUs. Transaction rolls back.
-- Run: Get-Content supabase/tests/phase_receipt_first_classify.sql | docker exec -i supabase_db_sherlyos psql -U postgres -d postgres -v ON_ERROR_STOP=1

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
  ('product', gen_random_uuid()),
  ('classified', gen_random_uuid());

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
  fixture.name || '.firstclassify@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture
where fixture.name in ('admin', 'godown', 'accounts');

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
        'First classify Admin',
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
where fixture.name in ('godown', 'accounts')
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles
  on roles.code = case fixture.name
    when 'godown' then 'godown_manager'
    when 'accounts' then 'accounts'
  end
where fixture.name in ('godown', 'accounts')
on conflict do nothing;

insert into public.products (id, sku, name, is_active)
values
  ((select id from fixture where name = 'product'), 'UAT-FIRST-CLASSIFY', 'First classify fixture', true),
  ((select id from fixture where name = 'classified'), 'UAT-ALREADY-CLASSIFIED', 'Already classified fixture', true);

update public.products
set expiry_policy = 'non_expiring'
where id = (select id from fixture where name = 'classified');

-- GM still must not hold catalog classify permission.
do $$
begin
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
end $$;

-- Accounts cannot first-classify.
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
    perform public.classify_unclassified_product_for_receiving(
      (select id from fixture where name = 'product'),
      'expiry_controlled'
    );
    raise exception 'accounts must not first-classify products';
  exception
    when sqlstate '42501' then
      null;
  end;
end $$;

reset role;

-- GM first-classifies the unclassified SKU, then cannot switch policy.
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
  classified public.products%rowtype;
begin
  classified := public.classify_unclassified_product_for_receiving(
    (select id from fixture where name = 'product'),
    'expiry_controlled'
  );
  if classified.expiry_policy is distinct from 'expiry_controlled' then
    raise exception 'GM first-classify did not persist';
  end if;

  classified := public.classify_unclassified_product_for_receiving(
    (select id from fixture where name = 'product'),
    'expiry_controlled'
  );
  if classified.expiry_policy is distinct from 'expiry_controlled' then
    raise exception 'idempotent first-classify should return the same policy';
  end if;

  begin
    perform public.classify_unclassified_product_for_receiving(
      (select id from fixture where name = 'product'),
      'non_expiring'
    );
    raise exception 'GM must not reclassify an already classified product';
  exception
    when sqlstate '23514' then
      null;
  end;

  begin
    perform public.classify_unclassified_product_for_receiving(
      (select id from fixture where name = 'classified'),
      'expiry_controlled'
    );
    raise exception 'GM must not reclassify Admin-classified products';
  exception
    when sqlstate '23514' then
      null;
  end;

  begin
    perform public.set_product_expiry_policy(
      (select id from fixture where name = 'classified'),
      'expiry_controlled'
    );
    raise exception 'GM must not call set_product_expiry_policy';
  exception
    when sqlstate '42501' then
      null;
  end;
end $$;

reset role;

rollback;
