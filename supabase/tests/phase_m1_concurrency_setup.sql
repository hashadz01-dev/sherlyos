-- M1 disposable parallel-posting fixture. Commits. Cleanup script removes it.
-- Enables dual-write only for this fixture and must be cleaned up afterward.
--
-- M1-S1.1: do not run against the working local database. Dual-write enable now
-- requires aggregate_only_blocked, grain reconciliation, and classified
-- positive-stock products. Meeting those guards here would seed working
-- inventory and leave cutover flags changed. Use an isolated database, or the
-- rollback-only proofs in phase_m1_s1_concurrency.mjs.

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  gen_random_uuid(),
  'authenticated',
  'authenticated',
  'admin.m1race@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', 'M1 Race Admin'),
  now(),
  now()
where not exists (
  select 1 from auth.users where email = 'admin.m1race@example.com'
);

do $$
declare
  admin_id uuid;
begin
  select id into admin_id from auth.users where email = 'admin.m1race@example.com';
  begin
    perform app_private.bootstrap_initial_admin(admin_id, 'create-initial-administrator');
  exception
    when sqlstate '42501' then
      insert into public.profiles (id, full_name, is_active)
      values (admin_id, 'M1 Race Admin', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select admin_id, roles.id, admin_id
      from public.roles
      where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

begin;

select set_config('request.jwt.claim.sub', (select id::text from auth.users where email = 'admin.m1race@example.com'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from auth.users where email = 'admin.m1race@example.com'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config('sherlyos.branch', public.create_branch('m1race', 'M1 Race')::text, true);
select set_config(
  'sherlyos.zone',
  public.create_zone(current_setting('sherlyos.branch')::uuid, 'zm1r', 'ZM1R', null)::text,
  true
);
select set_config(
  'sherlyos.crate_a',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'cm1ra', 'CM1RA', null)::text,
  true
);
select set_config(
  'sherlyos.crate_b',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'cm1rb', 'CM1RB', null)::text,
  true
);
select set_config(
  'sherlyos.product',
  public.create_product('m1-race-exp', 'M1 Race Product', null, null)::text,
  true
);
select public.set_product_expiry_policy(current_setting('sherlyos.product')::uuid, 'non_expiring');

reset role;
update public.app_configuration
set value = 'true'::jsonb
where key = 'stock.lots.dual_write_enabled';

select set_config('request.jwt.claim.sub', (select id::text from auth.users where email = 'admin.m1race@example.com'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from auth.users where email = 'admin.m1race@example.com'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate_a')::uuid,
  8,
  'm1-race-open',
  null,
  'RACE-1',
  null,
  null
);

reset role;

drop table if exists public.phase_m1_race_target;
create table public.phase_m1_race_target (
  name text primary key,
  value text not null
);
grant select on public.phase_m1_race_target to authenticated, anon, service_role;

insert into public.phase_m1_race_target (name, value)
select 'admin', id::text from auth.users where email = 'admin.m1race@example.com'
union all
select 'product', id::text from public.products where sku = 'm1-race-exp'
union all
select 'crate_a', id::text from public.crates where code = 'cm1ra'
union all
select 'crate_b', id::text from public.crates where code = 'cm1rb'
union all
select 'lot', stock_lots.id::text
from public.stock_lots
join public.products on products.id = stock_lots.product_id
where products.sku = 'm1-race-exp'
  and stock_lots.manufacturer_lot_code = 'RACE-1';

commit;
