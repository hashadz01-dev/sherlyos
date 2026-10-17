-- Shared setup for Phase 4.2C concurrency races.

drop table if exists public.phase42c_race_target cascade;
drop function if exists public.phase42c_claim(text);

create table public.phase42c_race_target (
  name text primary key,
  value text not null
);

create or replace function public.phase42c_claim(actor_email text)
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

grant execute on function public.phase42c_claim(text) to authenticated, service_role;

do $$
declare
  admin_id uuid := gen_random_uuid();
  accounts_id uuid := gen_random_uuid();
  accounts_b_id uuid := gen_random_uuid();
  godown_id uuid := gen_random_uuid();
  godown_b_id uuid := gen_random_uuid();
  branch_a uuid;
  shop_id uuid;
  product_id uuid;
  order_send uuid;
  order_ack uuid;
  order_sv uuid;
  order_av uuid;
  order_sc uuid;
  order_ac uuid;
  note_id uuid;
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  )
  values
    ('00000000-0000-0000-0000-000000000000', admin_id, 'authenticated', 'authenticated',
     'admin.phase42crace@example.com', extensions.crypt('local-only', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"admin"}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', accounts_id, 'authenticated', 'authenticated',
     'accounts.phase42crace@example.com', extensions.crypt('local-only', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"accounts"}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', accounts_b_id, 'authenticated', 'authenticated',
     'accounts_b.phase42crace@example.com', extensions.crypt('local-only', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"accounts_b"}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', godown_id, 'authenticated', 'authenticated',
     'godown.phase42crace@example.com', extensions.crypt('local-only', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"godown"}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', godown_b_id, 'authenticated', 'authenticated',
     'godown_b.phase42crace@example.com', extensions.crypt('local-only', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"godown_b"}'::jsonb, now(), now());

  insert into public.user_roles (user_id, role_id)
  select admin_id, id from public.roles where code = 'admin';
  insert into public.user_roles (user_id, role_id)
  select accounts_id, id from public.roles where code = 'accounts';
  insert into public.user_roles (user_id, role_id)
  select accounts_b_id, id from public.roles where code = 'accounts';
  insert into public.user_roles (user_id, role_id)
  select godown_id, id from public.roles where code = 'godown_manager';
  insert into public.user_roles (user_id, role_id)
  select godown_b_id, id from public.roles where code = 'godown_manager';

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  set local role authenticated;

  branch_a := public.create_branch('p42c_race_a', 'Phase 42C race A');
  perform public.assign_user_branch(accounts_id, branch_a);
  perform public.assign_user_branch(accounts_b_id, branch_a);
  perform public.assign_user_branch(godown_id, branch_a);
  perform public.assign_user_branch(godown_b_id, branch_a);
  shop_id := public.create_shop('Phase 42C race shop', null, null);
  product_id := public.create_product('p42c-race', 'Phase 42C race product', null, null);

  reset role;

  insert into public.orders (
    order_number, shop_id, branch_id, source, created_by, status, version,
    idempotency_key, submitted_at, submitted_by, verified_at, verified_by
  )
  values
    ('SO-42C-RACE-SEND', shop_id, branch_a, 'accounts', accounts_id, 'verified', 1,
     'p42c-race-order-send', now(), accounts_id, now(), accounts_id)
  returning id into order_send;

  insert into public.order_lines (order_id, product_id, requested_cases)
  values (order_send, product_id, 3);

  insert into public.orders (
    order_number, shop_id, branch_id, source, created_by, status, version,
    idempotency_key, submitted_at, submitted_by, verified_at, verified_by
  )
  values
    ('SO-42C-RACE-ACK', shop_id, branch_a, 'accounts', accounts_id, 'verified', 1,
     'p42c-race-order-ack', now(), accounts_id, now(), accounts_id)
  returning id into order_ack;

  insert into public.order_lines (order_id, product_id, requested_cases)
  values (order_ack, product_id, 3);

  insert into public.orders (
    order_number, shop_id, branch_id, source, created_by, status, version,
    idempotency_key, submitted_at, submitted_by, verified_at, verified_by
  )
  values
    ('SO-42C-RACE-SV', shop_id, branch_a, 'accounts', accounts_id, 'verified', 1,
     'p42c-race-order-sv', now(), accounts_id, now(), accounts_id)
  returning id into order_sv;

  insert into public.order_lines (order_id, product_id, requested_cases)
  values (order_sv, product_id, 3);

  insert into public.orders (
    order_number, shop_id, branch_id, source, created_by, status, version,
    idempotency_key, submitted_at, submitted_by, verified_at, verified_by
  )
  values
    ('SO-42C-RACE-AV', shop_id, branch_a, 'accounts', accounts_id, 'verified', 1,
     'p42c-race-order-av', now(), accounts_id, now(), accounts_id)
  returning id into order_av;

  insert into public.order_lines (order_id, product_id, requested_cases)
  values (order_av, product_id, 3);

  insert into public.orders (
    order_number, shop_id, branch_id, source, created_by, status, version,
    idempotency_key, submitted_at, submitted_by, verified_at, verified_by
  )
  values
    ('SO-42C-RACE-SC', shop_id, branch_a, 'accounts', accounts_id, 'verified', 1,
     'p42c-race-order-sc', now(), accounts_id, now(), accounts_id)
  returning id into order_sc;

  insert into public.order_lines (order_id, product_id, requested_cases)
  values (order_sc, product_id, 3);

  insert into public.orders (
    order_number, shop_id, branch_id, source, created_by, status, version,
    idempotency_key, submitted_at, submitted_by, verified_at, verified_by
  )
  values
    ('SO-42C-RACE-AC', shop_id, branch_a, 'accounts', accounts_id, 'verified', 1,
     'p42c-race-order-ac', now(), accounts_id, now(), accounts_id)
  returning id into order_ac;

  insert into public.order_lines (order_id, product_id, requested_cases)
  values (order_ac, product_id, 3);

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', accounts_id, 'role', 'authenticated')::text,
    true
  );

  note_id := (public.create_delivery_note(order_send, 'p42c-race-create-send') -> 'delivery_note' ->> 'id')::uuid;
  perform public.generate_delivery_note(note_id, 1, 'p42c-race-gen-send');
  insert into public.phase42c_race_target(name, value) values ('note_send', note_id::text);

  note_id := (public.create_delivery_note(order_ack, 'p42c-race-create-ack') -> 'delivery_note' ->> 'id')::uuid;
  perform public.generate_delivery_note(note_id, 1, 'p42c-race-gen-ack');
  perform public.send_delivery_note(note_id, 2, 'p42c-race-send-ack');
  insert into public.phase42c_race_target(name, value) values ('note_ack', note_id::text);

  note_id := (public.create_delivery_note(order_sv, 'p42c-race-create-sv') -> 'delivery_note' ->> 'id')::uuid;
  perform public.generate_delivery_note(note_id, 1, 'p42c-race-gen-sv');
  insert into public.phase42c_race_target(name, value) values ('note_sv', note_id::text);

  note_id := (public.create_delivery_note(order_av, 'p42c-race-create-av') -> 'delivery_note' ->> 'id')::uuid;
  perform public.generate_delivery_note(note_id, 1, 'p42c-race-gen-av');
  perform public.send_delivery_note(note_id, 2, 'p42c-race-send-av');
  insert into public.phase42c_race_target(name, value) values ('note_av', note_id::text);

  note_id := (public.create_delivery_note(order_sc, 'p42c-race-create-sc') -> 'delivery_note' ->> 'id')::uuid;
  perform public.generate_delivery_note(note_id, 1, 'p42c-race-gen-sc');
  insert into public.phase42c_race_target(name, value)
  values
    ('note_sc', note_id::text),
    ('order_sc', order_sc::text);

  note_id := (public.create_delivery_note(order_ac, 'p42c-race-create-ac') -> 'delivery_note' ->> 'id')::uuid;
  perform public.generate_delivery_note(note_id, 1, 'p42c-race-gen-ac');
  perform public.send_delivery_note(note_id, 2, 'p42c-race-send-ac');
  insert into public.phase42c_race_target(name, value)
  values
    ('note_ac', note_id::text),
    ('order_ac', order_ac::text),
    ('accounts', accounts_id::text),
    ('accounts_b', accounts_b_id::text),
    ('godown', godown_id::text),
    ('godown_b', godown_b_id::text);
end;
$$;
