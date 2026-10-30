-- M7.8 vehicle RPC guards. Rolls back.
-- Does not import the Sherlys fleet and does not flip operational flags.
-- Run: Get-Content supabase/tests/phase_m7_8_vehicles.sql | docker exec -i supabase_db_sherlyos psql -U postgres -d postgres -v ON_ERROR_STOP=1

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);
grant select on fixture to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('sales', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new,
  email_change_token_current, reauthentication_token, email_change
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.m78@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  now(),
  now(),
  replace(gen_random_uuid()::text, '-', '') || 'c',
  replace(gen_random_uuid()::text, '-', '') || 'r',
  replace(gen_random_uuid()::text, '-', '') || 'n',
  replace(gen_random_uuid()::text, '-', '') || 'e',
  replace(gen_random_uuid()::text, '-', '') || 'a',
  ''
from fixture;

insert into public.profiles (id, full_name, is_active)
select fixture.id, fixture.name, true from fixture
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles
  on roles.code = case fixture.name when 'admin' then 'admin' else 'salesperson' end
on conflict do nothing;

do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  sales_id uuid := (select id from fixture where name = 'sales');
  branch_id uuid;
  created_vehicle uuid;
  vehicles_before bigint;
  dispatch_before bigint;
  assignment_before bigint;
  ledger_before bigint;
  flag_before integer;
  normalized text;
begin
  select count(*) into vehicles_before from public.vehicles;
  select count(*) into dispatch_before
    from public.stock_dispatch_requests
    where stock_dispatch_requests.vehicle_id is not null;
  select count(*) into assignment_before from public.stock_dispatch_assignments;
  select count(*) into ledger_before from public.stock_ledger;
  select count(*) into flag_before
  from public.app_configuration
  where key in (
    'damage.stock_hold_ready',
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked'
  ) and value = 'true'::jsonb;
  if flag_before is distinct from 0 then
    raise exception 'operational flags must remain false';
  end if;

  normalized := app_private.normalize_vehicle_registration('KL-43-F-948');
  if normalized is distinct from 'kl43f948' then
    raise exception 'registration normalization drifted: %', normalized;
  end if;
  if app_private.normalize_vehicle_registration('KL 43 F 948') is distinct from 'kl43f948' then
    raise exception 'spaced registration did not collapse';
  end if;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );

  branch_id := public.create_branch('m78qa_godown', 'M78 QA godown');
  created_vehicle := public.create_vehicle(null, 'KL-43-M7801', 'other', 'M78 disposable van', null, 'shared fleet');
  perform app_private.lock_vehicle_for_dispatch(created_vehicle, gen_random_uuid(), branch_id);

  begin
    perform public.create_vehicle(branch_id, 'KL43M7801', 'van', 'Duplicate plate', null, null);
    raise exception 'duplicate normalized registration was accepted';
  exception
    when unique_violation then
      null;
  end;

  begin
    perform public.create_vehicle(branch_id, 'KL-43-M7802', 'lorry', 'Invented type', null, null);
    raise exception 'invalid vehicle type was accepted';
  exception
    when check_violation then
      null;
    when sqlstate '23514' then
      null;
  end;

  perform set_config('request.jwt.claim.sub', sales_id::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', sales_id, 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.create_vehicle(branch_id, 'KL-43-M7803', 'van', 'Sales van', null, null);
    raise exception 'salesperson vehicle create was accepted';
  exception
    when insufficient_privilege then
      null;
  end;

  if (select count(*) from public.stock_dispatch_requests where stock_dispatch_requests.vehicle_id is not null)
       is distinct from dispatch_before
    or (select count(*) from public.stock_dispatch_assignments) is distinct from assignment_before
    or (select count(*) from public.stock_ledger) is distinct from ledger_before
  then
    raise exception 'vehicle RPC test changed deliveries or stock';
  end if;

  if exists (
    select 1 from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    ) and value = 'true'::jsonb
  ) then
    raise exception 'operational flags changed';
  end if;

  if created_vehicle is null then
    raise exception 'disposable vehicle was not created';
  end if;
  if (select count(*) from public.vehicles) < vehicles_before then
    raise exception 'vehicle rows were deleted';
  end if;
end;
$$;

rollback;
