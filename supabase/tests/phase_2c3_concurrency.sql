-- Disposable fixture for the overlapping-session runner.
-- The runner is supabase/tests/phase_2c3_concurrency.mjs. It commits these rows,
-- races a second session, then deletes them.

create or replace function public.phase2c3_race_claims()
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform set_config(
    'request.jwt.claims',
    (
      select json_build_object('sub', id, 'role', 'authenticated')::text
      from auth.users
      where email = 'admin.phase2c3race@example.com'
    ),
    true
  );
end;
$$;

create or replace function public.phase2c3_hold_transfer()
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform public.phase2c3_race_claims();
  perform public.post_crate_transfer(
    (select id from public.products where sku = 'p2c3-race-move'),
    (select id from public.crates where code = 'race1'),
    (select id from public.crates where code = 'race2'),
    4,
    'race-hold-transfer',
    null
  );
  perform pg_catalog.pg_sleep(3);
end;
$$;

create or replace function public.phase2c3_hold_opening()
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform public.phase2c3_race_claims();
  perform public.post_opening_stock(
    (select id from public.products where sku = 'p2c3-race-open'),
    (select id from public.crates where code = 'race3'),
    1,
    'race-open-same',
    null
  );
  perform pg_catalog.pg_sleep(3);
end;
$$;

create or replace function public.phase2c3_hold_second_opening()
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform public.phase2c3_race_claims();
  perform public.post_opening_stock(
    (select id from public.products where sku = 'p2c3-race-dup'),
    (select id from public.crates where code = 'race4'),
    1,
    'race-open-first',
    null
  );
  perform pg_catalog.pg_sleep(3);
end;
$$;

create or replace function public.phase2c3_hold_deactivate()
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform public.phase2c3_race_claims();
  perform public.set_crate_active((select id from public.crates where code = 'race5'), false);
  perform pg_catalog.pg_sleep(3);
end;
$$;

create or replace function public.phase2c3_hold_stocked_transfer()
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform public.phase2c3_race_claims();
  perform public.post_crate_transfer(
    (select id from public.products where sku = 'p2c3-race-live'),
    (select id from public.crates where code = 'race6'),
    (select id from public.crates where code = 'race7'),
    2,
    'race-live-partial',
    null
  );
  perform pg_catalog.pg_sleep(3);
end;
$$;

create or replace function public.phase2c3_hold_emptying_transfer()
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform public.phase2c3_race_claims();
  perform public.post_crate_transfer(
    (select id from public.products where sku = 'p2c3-race-live'),
    (select id from public.crates where code = 'race6'),
    (select id from public.crates where code = 'race7'),
    3,
    'race-live-empty',
    null
  );
  perform pg_catalog.pg_sleep(3);
end;
$$;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values (
  '00000000-0000-0000-0000-000000000000',
  gen_random_uuid(),
  'authenticated',
  'authenticated',
  'admin.phase2c3race@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"full_name":"Phase 2C3 Race"}'::jsonb,
  now(),
  now()
);

select app_private.bootstrap_initial_admin(
  (select id from auth.users where email = 'admin.phase2c3race@example.com'),
  'create-initial-administrator'
);

select set_config(
  'request.jwt.claims',
  (
    select json_build_object('sub', id, 'role', 'authenticated')::text
    from auth.users
    where email = 'admin.phase2c3race@example.com'
  ),
  false
);

insert into public.branches (code, name)
values ('phase2c3_race', 'Phase 2C3 Race');

insert into public.zones (branch_id, code, name)
select id, 'rz', 'Race Zone'
from public.branches
where code = 'phase2c3_race';

insert into public.crates (zone_id, code, name)
select zones.id, crate.code, crate.name
from public.zones
cross join (
  values
    ('race1', 'Race 1'),
    ('race2', 'Race 2'),
    ('race3', 'Race 3'),
    ('race4', 'Race 4'),
    ('race5', 'Race 5'),
    ('race6', 'Race 6'),
    ('race7', 'Race 7')
) as crate (code, name)
where zones.code = 'rz'
  and zones.branch_id = (select id from public.branches where code = 'phase2c3_race');

insert into public.products (sku, name)
values
  ('p2c3-race-move', 'Race Move'),
  ('p2c3-race-open', 'Race Open'),
  ('p2c3-race-dup', 'Race Duplicate'),
  ('p2c3-race-live', 'Race Live');

select public.post_opening_stock(
  (select id from public.products where sku = 'p2c3-race-move'),
  (select id from public.crates where code = 'race1'),
  5,
  'race-open-move',
  null
);

select public.post_opening_stock(
  (select id from public.products where sku = 'p2c3-race-live'),
  (select id from public.crates where code = 'race6'),
  5,
  'race-open-live',
  null
);
