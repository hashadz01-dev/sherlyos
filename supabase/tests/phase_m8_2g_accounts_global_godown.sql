-- M8.2G local disposable SQL. Rolls back. Does not touch development cloud.
-- Accounts company-wide active-godown scope without Admin or warehouse grants.
begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);
grant select on fixture to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('accounts', gen_random_uuid()),
  ('accounts_none', gen_random_uuid()),
  ('inactive', gen_random_uuid()),
  ('salesperson', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('keeper', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.m82g@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M82G Admin', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select (select id from fixture where name = 'admin'), roles.id,
        (select id from fixture where name = 'admin')
      from public.roles where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.profiles (id, full_name, is_active)
select fixture.id, 'M82G ' || fixture.name, true from fixture where name <> 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles on roles.code = case fixture.name
  when 'accounts' then 'accounts'
  when 'accounts_none' then 'accounts'
  when 'inactive' then 'accounts'
  when 'salesperson' then 'salesperson'
  when 'godown' then 'godown_manager'
  when 'keeper' then 'store_keeper'
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

-- Catalog: Accounts has company-wide godown scope and not Admin access_all.
do $$
begin
  if not exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'accounts'
      and permissions.code = 'accounts.godowns.all'
  ) then
    raise exception 'accounts.godowns.all is not granted to Accounts';
  end if;
  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'accounts'
      and permissions.code in (
        'branches.access_all',
        'employees.read',
        'employees.manage',
        'roles.assign',
        'picking.execute',
        'dispatch.confirm',
        'stock.opening.post',
        'stock.adjustment.post',
        'stock.adjustment.approve_exceptional'
      )
  ) then
    raise exception 'Accounts received an Admin or warehouse permission';
  end if;
end $$;

select pg_temp.as_user('admin');
set local role authenticated;
select set_config('sherlyos.g1', public.create_branch('m82g_1', 'M82G Godown 1')::text, true);
select set_config('sherlyos.g2', public.create_branch('m82g_2', 'M82G Godown 2')::text, true);
select set_config('sherlyos.g3', public.create_branch('m82g_3', 'M82G Godown 3')::text, true);
select set_config('sherlyos.g4', public.create_branch('m82g_4', 'M82G Godown 4')::text, true);
select set_config('sherlyos.g5', public.create_branch('m82g_5', 'M82G Godown 5')::text, true);
select set_config('sherlyos.g6', public.create_branch('m82g_6', 'M82G Godown 6')::text, true);
select set_config('sherlyos.g7', public.create_branch('m82g_7', 'M82G Godown 7')::text, true);
select public.assign_user_branch((select id from fixture where name = 'salesperson'), current_setting('sherlyos.g1')::uuid);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.g1')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.g1')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.g1')::uuid);
select set_config('sherlyos.sku', public.create_product('m82g-milk', 'M82G milk', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.sku')::uuid, 'non_expiring');
select set_config('sherlyos.shop', public.create_shop('M82G shop', null, null)::text, true);
select public.assign_shop_salesperson(
  current_setting('sherlyos.shop')::uuid,
  (select id from fixture where name = 'salesperson')
);
reset role;

insert into public.orders (
  order_number, shop_id, branch_id, source, created_by, status, version,
  idempotency_key, submitted_at, submitted_by, verified_at, verified_by
)
select
  'SO-M82G-' || n,
  current_setting('sherlyos.shop')::uuid,
  current_setting('sherlyos.g' || n)::uuid,
  'salesperson',
  (select id from fixture where name = 'salesperson'),
  case when n = 1 then 'verified' else 'submitted' end,
  case when n = 1 then 3 else 2 end,
  'm82g-ord-' || n,
  now(),
  (select id from fixture where name = 'salesperson'),
  case when n = 1 then now() else null end,
  case when n = 1 then (select id from fixture where name = 'accounts') else null end
from generate_series(1, 7) as n;

insert into public.order_lines (order_id, product_id, requested_cases)
select orders.id, current_setting('sherlyos.sku')::uuid, 2
from public.orders
where orders.idempotency_key like 'm82g-ord-%';

select set_config('sherlyos.order_v', (select id::text from public.orders where idempotency_key = 'm82g-ord-1'), true);
select set_config('sherlyos.order_s2', (select id::text from public.orders where idempotency_key = 'm82g-ord-2'), true);

-- ACC-01 / ACC-02 / ACC-03 / ACC-06 / ACC-16 / ACC-20: unassigned Accounts
select pg_temp.as_user('accounts_none');
set local role authenticated;
do $$
declare
  listed jsonb;
  queue jsonb;
  dash jsonb;
  branch_count integer;
  foreign_assignments integer;
  ledger_before bigint;
  created jsonb;
begin
  if not app_private.has_permission('accounts.godowns.all') then
    raise exception 'unassigned Accounts missing accounts.godowns.all';
  end if;
  if app_private.has_permission('branches.access_all')
    or app_private.has_permission('employees.read')
    or app_private.has_permission('picking.execute')
    or app_private.has_permission('dispatch.confirm')
    or app_private.has_permission('stock.opening.post')
  then
    raise exception 'unassigned Accounts received Admin or warehouse rights';
  end if;

  listed := public.list_orders('submitted');
  if not exists (
    select 1 from jsonb_array_elements(listed) as row
    where row ->> 'id' = current_setting('sherlyos.order_s2')
  ) then
    raise exception 'ACC-02 missing Godown-2 submitted order';
  end if;
  if (
    select count(*) from jsonb_array_elements(listed) as row
    where row ->> 'id' in (
      select id::text from public.orders where idempotency_key like 'm82g-ord-%' and status = 'submitted'
    )
  ) <> 6 then
    raise exception 'ACC-03 Accounts did not see all submitted godown orders: %', listed;
  end if;

  select count(*) into branch_count
  from public.branches
  where code in ('m82g_1', 'm82g_2', 'm82g_3', 'm82g_4', 'm82g_5', 'm82g_6', 'm82g_7');
  if branch_count <> 7 then
    raise exception 'ACC-03 Accounts catalog missing seven godowns: %', branch_count;
  end if;

  select count(*) into foreign_assignments
  from public.user_branch_assignments
  where user_id is distinct from (select id from fixture where name = 'accounts_none');
  if foreign_assignments <> 0 then
    raise exception 'Accounts must not read other employees'' assignments';
  end if;

  queue := public.list_verified_orders_without_dn();
  if not exists (
    select 1 from jsonb_array_elements(queue) as row
    where row ->> 'id' = current_setting('sherlyos.order_v')
  ) then
    raise exception 'ACC-06 unassigned Accounts missing verified queue row';
  end if;

  dash := public.get_operations_dashboard(null);
  if (dash -> 'orders' ->> 'submitted')::int < 6 then
    raise exception 'ACC-16 dashboard submitted under-counted: %', dash -> 'orders';
  end if;
  if (dash -> 'orders' ->> 'verified')::int < 1 then
    raise exception 'ACC-16 dashboard verified under-counted: %', dash -> 'orders';
  end if;

  begin
    perform public.verify_order(current_setting('sherlyos.order_s2')::uuid, 2, 'm82g-ver-s2');
    raise exception 'ACC-05 verify must stay ATP fail-closed';
  exception
    when sqlstate 'P0001' then null;
    when sqlstate '42501' then
      raise exception 'ACC-05 unassigned Accounts was not authorized to verify';
  end;

  select count(*) into ledger_before from public.stock_ledger;
  created := public.create_delivery_note(current_setting('sherlyos.order_v')::uuid, 'm82g-dn-none');
  if created -> 'delivery_note' ->> 'status' is distinct from 'draft' then
    raise exception 'ACC-07 create did not land in draft';
  end if;
  if created -> 'delivery_note' ->> 'order_id' is distinct from current_setting('sherlyos.order_v') then
    raise exception 'ACC-07 draft linked to the wrong order';
  end if;
  if (select count(*) from public.stock_ledger) <> ledger_before then
    raise exception 'ACC-19 draft creation wrote stock_ledger';
  end if;

  begin
    perform public.start_picking('00000000-0000-0000-0000-000000000001'::uuid, 1, 'm82g-pick');
    raise exception 'ACC-08 Accounts started picking';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.confirm_dispatch('00000000-0000-0000-0000-000000000001'::uuid, 1, 'm82g-disp');
    raise exception 'ACC-09 Accounts confirmed dispatch';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.sku')::uuid,
      '00000000-0000-0000-0000-000000000001'::uuid,
      1,
      'm82g-open',
      null
    );
    raise exception 'ACC-10 Accounts posted opening stock';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.assign_user_role((select id from fixture where name = 'keeper'), 'admin');
    raise exception 'ACC-11 Accounts assigned a role';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.create_stock_adjustment(
      '00000000-0000-0000-0000-000000000001'::uuid,
      'shortage',
      'no',
      array[]::uuid[],
      'm82g-adj'
    );
    raise exception 'ACC-12 Accounts created an adjustment';
  exception
    when sqlstate '42501' then null;
  end;

  if to_regprocedure('public.finalize_statutory_invoice(uuid)') is not null
    or to_regprocedure('public.issue_tax_invoice(uuid)') is not null
  then
    raise exception 'ACC-18 legal GST issuance RPC became available';
  end if;
end $$;

-- ACC-04 newly created godown, no assignment row
reset role;
select pg_temp.as_user('admin');
set local role authenticated;
select set_config('sherlyos.g8', public.create_branch('m82g_8', 'M82G Godown 8')::text, true);
reset role;
select pg_temp.as_user('accounts_none');
set local role authenticated;
do $$
begin
  if not exists (
    select 1 from public.branches where id = current_setting('sherlyos.g8')::uuid
  ) then
    raise exception 'ACC-04 Accounts cannot see the new godown';
  end if;
  if not app_private.can_work_at_branch(current_setting('sherlyos.g8')::uuid) then
    raise exception 'ACC-04 Accounts cannot work at the new godown';
  end if;
end $$;

-- ACC-14 Store Keeper cannot use Accounts issue RPCs. Site scope is
-- store_keeper.godowns.all (M8.2J), not Accounts or Admin grants.
reset role;
select pg_temp.as_user('keeper');
set local role authenticated;
do $$
begin
  if app_private.has_permission('accounts.godowns.all')
    or app_private.has_permission('branches.access_all')
  then
    raise exception 'ACC-14 store keeper received Accounts or Admin godown grants';
  end if;
  begin
    perform public.list_verified_orders_without_dn();
    raise exception 'ACC-14 store keeper listed the Accounts queue';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

reset role;
select pg_temp.as_user('godown');
set local role authenticated;
do $$
begin
  if not app_private.has_permission('godown_manager.godowns.all') then
    raise exception 'ACC-14 godown manager missing company-wide godown permission';
  end if;
  if app_private.has_permission('branches.access_all')
    or app_private.has_permission('employees.manage')
    or app_private.has_permission('orders.verify')
  then
    raise exception 'ACC-14 godown manager received Admin or Accounts rights';
  end if;
  if not app_private.can_work_at_branch(current_setting('sherlyos.g2')::uuid) then
    raise exception 'ACC-14 godown manager cannot work at Godown 2';
  end if;
  if not app_private.can_work_at_branch(current_setting('sherlyos.g1')::uuid) then
    raise exception 'ACC-14 godown manager lost Godown 1';
  end if;
end $$;

-- ACC-13 inactive Accounts
reset role;
update public.profiles
set is_active = false
where id = (select id from fixture where name = 'inactive');
select pg_temp.as_user('inactive');
set local role authenticated;
do $$
begin
  if app_private.has_permission('accounts.godowns.all') then
    raise exception 'ACC-13 inactive Accounts kept company-wide godown access';
  end if;
  begin
    perform public.list_verified_orders_without_dn();
    raise exception 'ACC-13 inactive Accounts listed the queue';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

do $$
begin
  if exists (
    select 1
    from public.app_configuration
    join flag_snapshot on flag_snapshot.key = app_configuration.key
    where app_configuration.value is distinct from flag_snapshot.value
  ) then
    raise exception 'M8.2G must not change operational flags';
  end if;
end $$;

rollback;
