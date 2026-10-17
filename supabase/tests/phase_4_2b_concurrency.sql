-- Shared setup for Phase 4.2B concurrency races. Not rolled back by design.
-- Cleaned by phase_4_2b_concurrency_cleanup.sql

drop table if exists public.phase42b_race_target cascade;
drop function if exists public.phase42b_claim(text);

create table public.phase42b_race_target (
  name text primary key,
  value text not null
);

create or replace function public.phase42b_claim(actor_email text)
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

grant execute on function public.phase42b_claim(text) to authenticated, service_role;

do $$
declare
  admin_id uuid := gen_random_uuid();
  accounts_id uuid := gen_random_uuid();
  accounts_b_id uuid := gen_random_uuid();
  branch_a uuid;
  shop_id uuid;
  product_id uuid;
  order_a uuid;
  order_b uuid;
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  )
  values
    (
      '00000000-0000-0000-0000-000000000000', admin_id, 'authenticated', 'authenticated',
      'admin.phase42brace@example.com',
      extensions.crypt('local-only', extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"full_name":"admin"}'::jsonb, now(), now()
    ),
    (
      '00000000-0000-0000-0000-000000000000', accounts_id, 'authenticated', 'authenticated',
      'accounts.phase42brace@example.com',
      extensions.crypt('local-only', extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"full_name":"accounts"}'::jsonb, now(), now()
    ),
    (
      '00000000-0000-0000-0000-000000000000', accounts_b_id, 'authenticated', 'authenticated',
      'accounts_b.phase42brace@example.com',
      extensions.crypt('local-only', extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"full_name":"accounts_b"}'::jsonb, now(), now()
    );

  insert into public.user_roles (user_id, role_id)
  select admin_id, id from public.roles where code = 'admin';
  insert into public.user_roles (user_id, role_id)
  select accounts_id, id from public.roles where code = 'accounts';
  insert into public.user_roles (user_id, role_id)
  select accounts_b_id, id from public.roles where code = 'accounts';

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  set local role authenticated;

  branch_a := public.create_branch('p42b_race_a', 'Phase 42B race A');
  perform public.assign_user_branch(accounts_id, branch_a);
  perform public.assign_user_branch(accounts_b_id, branch_a);
  shop_id := public.create_shop('Phase 42B race shop', null, null);
  product_id := public.create_product('p42b-race', 'Phase 42B race product', null, null);

  reset role;

  insert into public.orders (
    order_number, shop_id, branch_id, source, created_by, status, version,
    idempotency_key, submitted_at, submitted_by, verified_at, verified_by
  )
  values (
    'SO-42B-RACE-001', shop_id, branch_a, 'accounts', accounts_id, 'verified', 1,
    'p42b-race-order-01', now(), accounts_id, now(), accounts_id
  )
  returning id into order_a;

  insert into public.order_lines (order_id, product_id, requested_cases)
  values (order_a, product_id, 4);

  insert into public.orders (
    order_number, shop_id, branch_id, source, created_by, status, version,
    idempotency_key, submitted_at, submitted_by, verified_at, verified_by
  )
  values (
    'SO-42B-RACE-002', shop_id, branch_a, 'accounts', accounts_id, 'verified', 1,
    'p42b-race-order-02', now(), accounts_id, now(), accounts_id
  )
  returning id into order_b;

  insert into public.order_lines (order_id, product_id, requested_cases)
  values (order_b, product_id, 2);

  insert into public.phase42b_race_target (name, value)
  values
    ('accounts', accounts_id::text),
    ('accounts_b', accounts_b_id::text),
    ('order_a', order_a::text),
    ('order_b', order_b::text),
    ('branch_a', branch_a::text),
    ('shop_id', shop_id::text),
    ('product_id', product_id::text);
end;
$$;
