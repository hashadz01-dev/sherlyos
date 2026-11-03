-- Local disposable SQL. Rolls back. Store Keeper company-wide active godowns.
begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);
grant select on fixture to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('keeper_none', gen_random_uuid()),
  ('driver', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.m82j@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture;

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
      values ((select id from fixture where name = 'admin'), 'M82J Admin', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select (select id from fixture where name = 'admin'), roles.id,
        (select id from fixture where name = 'admin')
      from public.roles where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.profiles (id, full_name, is_active)
select fixture.id, 'M82J ' || fixture.name, true from fixture where name <> 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles on roles.code = case fixture.name
  when 'keeper' then 'store_keeper'
  when 'keeper_none' then 'store_keeper'
  when 'driver' then 'delivery_person'
end
where fixture.name <> 'admin'
on conflict do nothing;

create or replace function pg_temp.as_user(who text)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = who), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = who), 'role', 'authenticated')::text,
    true
  );
end;
$$;

create temp table flag_snapshot as
select key, value
from public.app_configuration
where key in (
  'damage.stock_hold_ready',
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked'
);
grant select on flag_snapshot to authenticated, anon, service_role;

do $$
begin
  if not exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'store_keeper'
      and permissions.code = 'store_keeper.godowns.all'
  ) then
    raise exception 'store_keeper.godowns.all is not granted';
  end if;
  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'store_keeper'
      and permissions.code in (
        'branches.access_all',
        'employees.read',
        'employees.manage',
        'roles.assign',
        'orders.verify',
        'delivery_notes.issue',
        'stock.opening.post'
      )
  ) then
    raise exception 'Store Keeper received Admin or Accounts-only permissions';
  end if;
end $$;

select pg_temp.as_user('admin');
set local role authenticated;
select set_config('sherlyos.g1', public.create_branch('m82j_1', 'M82J Godown 1')::text, true);
select set_config('sherlyos.g2', public.create_branch('m82j_2', 'M82J Godown 2')::text, true);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.g1')::uuid);
select public.assign_user_branch((select id from fixture where name = 'driver'), current_setting('sherlyos.g1')::uuid);
reset role;

reset role;
select pg_temp.as_user('admin');
set local role authenticated;
select set_config('sherlyos.g8', public.create_branch('m82j_8', 'M82J Godown 8')::text, true);
reset role;
select pg_temp.as_user('keeper_none');
set local role authenticated;
do $$
declare
  branch_count integer;
  foreign_assignments integer;
begin
  if not app_private.has_permission('store_keeper.godowns.all') then
    raise exception 'unassigned Store Keeper missing store_keeper.godowns.all';
  end if;
  if app_private.has_permission('branches.access_all')
    or app_private.has_permission('employees.manage')
    or app_private.has_permission('orders.verify')
    or app_private.has_permission('stock.opening.post')
    or app_private.has_permission('godown_manager.godowns.all')
  then
    raise exception 'unassigned Store Keeper received Admin, Accounts, or Godown Manager rights';
  end if;
  if not app_private.can_work_at_branch(current_setting('sherlyos.g1')::uuid)
    or not app_private.can_work_at_branch(current_setting('sherlyos.g2')::uuid)
    or not app_private.can_work_at_branch(current_setting('sherlyos.g8')::uuid)
  then
    raise exception 'unassigned Store Keeper cannot work at all active godowns';
  end if;
  select count(*) into branch_count from public.branches where code like 'm82j_%';
  if branch_count <> 3 then
    raise exception 'Store Keeper catalog missing active godowns: %', branch_count;
  end if;
  select count(*) into foreign_assignments
  from public.user_branch_assignments
  where user_id is distinct from (select id from fixture where name = 'keeper_none');
  if foreign_assignments <> 0 then
    raise exception 'Store Keeper must not read other employees'' assignments';
  end if;
  begin
    perform public.assign_user_role((select id from fixture where name = 'driver'), 'admin');
    raise exception 'Store Keeper assigned an employee role';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.list_verified_orders_without_dn();
    raise exception 'Store Keeper listed the Accounts delivery-note issue queue';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

reset role;
select pg_temp.as_user('driver');
set local role authenticated;
do $$
begin
  if app_private.has_permission('store_keeper.godowns.all') then
    raise exception 'Delivery Person received Store Keeper company-wide scope';
  end if;
  if app_private.can_work_at_branch(current_setting('sherlyos.g2')::uuid) then
    raise exception 'Delivery Person worked at Godown 2';
  end if;
  if not app_private.can_work_at_branch(current_setting('sherlyos.g1')::uuid) then
    raise exception 'Delivery Person lost Godown 1';
  end if;
end $$;

do $$
begin
  if exists (
    select 1
    from public.app_configuration
    join flag_snapshot on flag_snapshot.key = app_configuration.key
    where app_configuration.value is distinct from flag_snapshot.value
  ) then
    raise exception 'M8.2J must not change operational flags';
  end if;
end $$;

rollback;
