-- M7.4C. Proves search_products finds a row beyond the first 1,000 names.
-- Rolls back. Does not delete business data or posted stock transactions.
begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);
grant select on fixture to authenticated, anon, service_role;

insert into fixture (name, id) values ('admin', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  'admin.m74csearch@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  now(),
  now()
from fixture
where fixture.name = 'admin';

insert into public.profiles (id, full_name, is_active)
select fixture.id, 'm74c search admin', true from fixture where name = 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, fixture.id
from fixture
join public.roles on roles.code = 'admin'
where fixture.name = 'admin'
on conflict do nothing;

insert into public.products (sku, name, is_active)
select
  'm74c-pg-' || lpad(g::text, 4, '0'),
  'M74C Page ' || lpad(g::text, 4, '0'),
  true
from generate_series(1, 1001) as g;

insert into public.products (sku, name, is_active)
values ('zzz-m74c-tail', 'zzz M74C tail', true);

do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  page_n integer;
  hit_n integer;
  hit_sku text;
begin
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  perform set_config('role', 'authenticated', true);

  select count(*) into page_n from public.search_products(null, 50, 0, true, null);
  if page_n <> 50 then
    raise exception 'empty search must return one page of 50, got %', page_n;
  end if;

  if exists (
    select 1 from public.search_products(null, 50, 0, true, null)
    where sku = 'zzz-m74c-tail'
  ) then
    raise exception 'tail SKU must not appear on the first name page';
  end if;

  select count(*), min(sku) into hit_n, hit_sku
  from public.search_products('zzz-m74c-tail', 50, 0, true, null);
  if hit_n <> 1 or hit_sku is distinct from 'zzz-m74c-tail' then
    raise exception 'server-side search missed tail SKU hits=% sku=%', hit_n, hit_sku;
  end if;

  execute 'reset role';
end $$;

rollback;
