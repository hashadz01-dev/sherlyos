-- M1-S3 concurrency fixtures. Local Docker only. Paired with cleanup.
-- Requires empty lot tables so seed does not collide with leftover inventory.

do $$
begin
  if exists (select 1 from public.stock_lots)
    or exists (select 1 from public.stock_legacy_lot_seeds)
  then
    raise exception 'M1-S3 concurrency setup requires empty local lot tables';
  end if;
end;
$$;

create table if not exists public.m1s3c_actors (
  name text primary key,
  id uuid not null
);

insert into public.m1s3c_actors (name, id)
values
  ('admin', gen_random_uuid()),
  ('admin2', gen_random_uuid()),
  ('godown', gen_random_uuid())
on conflict (name) do nothing;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  m1s3c_actors.id,
  'authenticated',
  'authenticated',
  m1s3c_actors.name || '.m1s3c@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', m1s3c_actors.name),
  now(),
  now()
from public.m1s3c_actors
on conflict (id) do nothing;

insert into public.profiles (id, full_name, is_active)
select id, name, true from public.m1s3c_actors
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select m1s3c_actors.id, roles.id, (select id from public.m1s3c_actors where name = 'admin')
from public.m1s3c_actors
join public.roles on roles.code = case
  when m1s3c_actors.name in ('admin', 'admin2') then 'admin'
  else 'godown_manager'
end
on conflict do nothing;

create or replace function public.m1s3c_claim(actor text)
returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claims',
    (select json_build_object('sub', id, 'role', 'authenticated')::text
     from public.m1s3c_actors where name = actor),
    false
  );
end;
$$;

begin;
select public.m1s3c_claim('admin');
set local role authenticated;

select public.create_branch('m1s3c_a', 'M1 S3C A')
where not exists (select 1 from public.branches where code = 'm1s3c_a');

select public.create_zone(
  (select id from public.branches where code = 'm1s3c_a'),
  'm1s3cza',
  'M1 S3C Zone',
  null
)
where not exists (select 1 from public.zones where code = 'm1s3cza');

select public.create_crate(
  (select id from public.zones where code = 'm1s3cza'),
  'm1s3cca1',
  'M1 S3C Crate 1',
  null
)
where not exists (select 1 from public.crates where code = 'm1s3cca1');

select public.create_crate(
  (select id from public.zones where code = 'm1s3cza'),
  'm1s3cca2',
  'M1 S3C Crate 2',
  null
)
where not exists (select 1 from public.crates where code = 'm1s3cca2');

select public.create_product('m1s3c-soap', 'M1 S3C Soap', null, null)
where not exists (select 1 from public.products where sku = 'm1s3c-soap');

select public.assign_user_branch(
  (select id from public.m1s3c_actors where name = 'godown'),
  (select id from public.branches where code = 'm1s3c_a')
)
where not exists (
  select 1
  from public.user_branch_assignments
  where user_id = (select id from public.m1s3c_actors where name = 'godown')
    and branch_id = (select id from public.branches where code = 'm1s3c_a')
);

select public.post_opening_stock(
  (select id from public.products where sku = 'm1s3c-soap'),
  (select id from public.crates where code = 'm1s3cca1'),
  4,
  'm1s3c-open-soap',
  null
)
where not exists (
  select 1
  from public.stock_balances
  where crate_id = (select id from public.crates where code = 'm1s3cca1')
    and product_id = (select id from public.products where sku = 'm1s3c-soap')
    and quantity > 0
);

select public.post_opening_stock(
  (select id from public.products where sku = 'm1s3c-soap'),
  (select id from public.crates where code = 'm1s3cca2'),
  2,
  'm1s3c-open-soap-2',
  null
)
where not exists (
  select 1
  from public.stock_balances
  where crate_id = (select id from public.crates where code = 'm1s3cca2')
    and product_id = (select id from public.products where sku = 'm1s3c-soap')
    and quantity > 0
);

select public.set_product_expiry_policy(
  (select id from public.products where sku = 'm1s3c-soap'),
  'expiry_controlled'
);

commit;
reset role;
