-- M1-S2.2 concurrency fixtures. Local Docker only. Paired with cleanup.

create table if not exists public.m1s2c_actors (
  name text primary key,
  id uuid not null
);

insert into public.m1s2c_actors (name, id)
values
  ('admin', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('godown2', gen_random_uuid())
on conflict (name) do nothing;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  m1s2c_actors.id,
  'authenticated',
  'authenticated',
  m1s2c_actors.name || '.m1s2c@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', m1s2c_actors.name),
  now(),
  now()
from public.m1s2c_actors
on conflict (id) do nothing;

insert into public.profiles (id, full_name, is_active)
select id, name, true from public.m1s2c_actors
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select m1s2c_actors.id, roles.id, (select id from public.m1s2c_actors where name = 'admin')
from public.m1s2c_actors
join public.roles on roles.code = case m1s2c_actors.name
  when 'admin' then 'admin'
  else 'godown_manager'
end
on conflict do nothing;

create or replace function public.m1s2c_claim(actor text)
returns void
language plpgsql
as $$
begin
  -- Session-level claims: concurrency scripts are not always one transaction.
  perform set_config(
    'request.jwt.claims',
    (select json_build_object('sub', id, 'role', 'authenticated')::text
     from public.m1s2c_actors where name = actor),
    false
  );
end;
$$;

begin;
select public.m1s2c_claim('admin');
set local role authenticated;

select public.create_branch('m1s2c_a', 'M1 S2C A')
where not exists (select 1 from public.branches where code = 'm1s2c_a');

select public.create_zone(
  (select id from public.branches where code = 'm1s2c_a'),
  'm1s2cza',
  'M1 S2C Zone',
  null
)
where not exists (select 1 from public.zones where code = 'm1s2cza');

select public.create_crate(
  (select id from public.zones where code = 'm1s2cza'),
  'm1s2cca1',
  'M1 S2C Crate 1',
  null
)
where not exists (select 1 from public.crates where code = 'm1s2cca1');

select public.create_crate(
  (select id from public.zones where code = 'm1s2cza'),
  'm1s2cca2',
  'M1 S2C Crate 2',
  null
)
where not exists (select 1 from public.crates where code = 'm1s2cca2');

select public.create_product('m1s2c-soap', 'M1 S2C Soap', null, null)
where not exists (select 1 from public.products where sku = 'm1s2c-soap');

select public.assign_user_branch(
  (select id from public.m1s2c_actors where name = 'godown'),
  (select id from public.branches where code = 'm1s2c_a')
)
where not exists (
  select 1
  from public.user_branch_assignments
  where user_id = (select id from public.m1s2c_actors where name = 'godown')
    and branch_id = (select id from public.branches where code = 'm1s2c_a')
);

select public.assign_user_branch(
  (select id from public.m1s2c_actors where name = 'godown2'),
  (select id from public.branches where code = 'm1s2c_a')
)
where not exists (
  select 1
  from public.user_branch_assignments
  where user_id = (select id from public.m1s2c_actors where name = 'godown2')
    and branch_id = (select id from public.branches where code = 'm1s2c_a')
);

select public.post_opening_stock(
  (select id from public.products where sku = 'm1s2c-soap'),
  (select id from public.crates where code = 'm1s2cca1'),
  4,
  'm1s2c-open-1',
  null
)
where not exists (
  select 1
  from public.stock_balances
  where crate_id = (select id from public.crates where code = 'm1s2cca1')
    and product_id = (select id from public.products where sku = 'm1s2c-soap')
    and quantity > 0
);

select public.post_opening_stock(
  (select id from public.products where sku = 'm1s2c-soap'),
  (select id from public.crates where code = 'm1s2cca2'),
  4,
  'm1s2c-open-2',
  null
)
where not exists (
  select 1
  from public.stock_balances
  where crate_id = (select id from public.crates where code = 'm1s2cca2')
    and product_id = (select id from public.products where sku = 'm1s2c-soap')
    and quantity > 0
);

select public.set_product_expiry_policy(
  (select id from public.products where sku = 'm1s2c-soap'),
  'non_expiring'
);

commit;
reset role;
