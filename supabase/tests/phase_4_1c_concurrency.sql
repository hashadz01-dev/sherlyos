-- Shared setup for Phase 4.1C concurrency races. Not rolled back by design.
-- Cleaned by phase_4_1c_concurrency_cleanup.sql

drop table if exists public.phase41c_race_target cascade;
drop function if exists public.phase41c_claim(text);

create table public.phase41c_race_target (
  name text primary key,
  value text not null
);

create or replace function public.phase41c_claim(actor_email text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config(
    'request.jwt.claims',
    (
      select pg_catalog.json_build_object('sub', id, 'role', 'authenticated')::text
      from auth.users
      where email = actor_email
    ),
    false
  );
end;
$$;

grant execute on function public.phase41c_claim(text) to authenticated, service_role;

do $$
declare
  admin_id uuid := gen_random_uuid();
  accounts_id uuid := gen_random_uuid();
  accounts2_id uuid := gen_random_uuid();
  salesperson_id uuid := gen_random_uuid();
  godown_id uuid := gen_random_uuid();
  branch_a uuid;
  shop_id uuid;
  product_id uuid;
  zone_id uuid;
  crate_id uuid;
  order_id uuid;
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  )
  values
    ('00000000-0000-0000-0000-000000000000', admin_id, 'authenticated', 'authenticated',
     'admin.phase41crace@example.com', extensions.crypt('local-only', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"admin"}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', accounts_id, 'authenticated', 'authenticated',
     'accounts.phase41crace@example.com', extensions.crypt('local-only', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"accounts"}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', accounts2_id, 'authenticated', 'authenticated',
     'accounts2.phase41crace@example.com', extensions.crypt('local-only', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"accounts2"}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', salesperson_id, 'authenticated', 'authenticated',
     'sales.phase41crace@example.com', extensions.crypt('local-only', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"sales"}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', godown_id, 'authenticated', 'authenticated',
     'godown.phase41crace@example.com', extensions.crypt('local-only', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"godown"}'::jsonb, now(), now());

  insert into public.user_roles (user_id, role_id)
  select admin_id, id from public.roles where code = 'admin';
  insert into public.user_roles (user_id, role_id)
  select accounts_id, id from public.roles where code = 'accounts';
  insert into public.user_roles (user_id, role_id)
  select accounts2_id, id from public.roles where code = 'accounts';
  insert into public.user_roles (user_id, role_id)
  select salesperson_id, id from public.roles where code = 'salesperson';
  insert into public.user_roles (user_id, role_id)
  select godown_id, id from public.roles where code = 'godown_manager';

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  set local role authenticated;

  branch_a := public.create_branch('p41c_race_a', 'Phase 41C Race A');
  perform public.assign_user_branch(accounts_id, branch_a);
  perform public.assign_user_branch(accounts2_id, branch_a);
  perform public.assign_user_branch(salesperson_id, branch_a);
  perform public.assign_user_branch(godown_id, branch_a);
  shop_id := public.create_shop('Phase 41C Race Shop', null, null);
  perform public.assign_shop_salesperson(shop_id, salesperson_id);
  product_id := public.create_product('p41c-race-sku', 'Phase 41C Race Soap', null, null);
  perform public.set_product_expiry_policy(product_id, 'non_expiring');
  zone_id := public.create_zone(branch_a, 'R', 'Race Zone', null);
  crate_id := public.create_crate(zone_id, 'rc1', 'Race Crate', null);
  set session_replication_role = replica;
  update public.app_configuration set value = 'true'::jsonb
  where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
  set session_replication_role = origin;
  perform public.post_opening_stock(product_id, crate_id, 20, 'p41c-race-open', null, 'P41C-RACE', null, null);

  reset role;
  perform set_config('request.jwt.claims', '', true);

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', salesperson_id, 'role', 'authenticated')::text,
    true
  );
  set local role authenticated;
  order_id := (
    public.create_order(
      shop_id,
      branch_a,
      'salesperson',
      null,
      null,
      jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 5)),
      'p41c-race-create'
    ) -> 'order' ->> 'id'
  )::uuid;
  reset role;
  perform set_config('request.jwt.claims', '', true);

  insert into public.phase41c_race_target(name, value) values
    ('branch_a', branch_a::text),
    ('shop_id', shop_id::text),
    ('product_id', product_id::text),
    ('crate_id', crate_id::text),
    ('order_id', order_id::text),
    ('admin', 'admin.phase41crace@example.com'),
    ('accounts', 'accounts.phase41crace@example.com'),
    ('accounts2', 'accounts2.phase41crace@example.com'),
    ('salesperson', 'sales.phase41crace@example.com'),
    ('godown', 'godown.phase41crace@example.com');
end;
$$;
