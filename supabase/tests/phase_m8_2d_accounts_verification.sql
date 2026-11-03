-- M8.2D local disposable SQL. Rolls back. Does not touch development cloud.
-- Covers Accounts verification without godown assignment, ATP fail-closed,
-- and unauthorized verify_order. Dual-write stays false.
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
  ('accounts_other', gen_random_uuid()),
  ('salesperson', gen_random_uuid()),
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
  fixture.name || '.m82d@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M82D Admin', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select (select id from fixture where name = 'admin'), roles.id,
        (select id from fixture where name = 'admin')
      from public.roles where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.profiles (id, full_name, is_active)
select fixture.id, 'M82D ' || fixture.name, true from fixture where name <> 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles on roles.code = case fixture.name
  when 'accounts' then 'accounts'
  when 'accounts_none' then 'accounts'
  when 'accounts_other' then 'accounts'
  when 'salesperson' then 'salesperson'
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
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked'
);
grant select on flag_snapshot to authenticated, anon, service_role;

select pg_temp.as_user('admin');
set local role authenticated;
select set_config('sherlyos.branch', public.create_branch('m82d_a', 'M82D Godown A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('m82d_b', 'M82D Godown B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'salesperson'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'accounts_other'), current_setting('sherlyos.branch_b')::uuid);
select set_config('sherlyos.sku', public.create_product('m82d-milk', 'M82D milk', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.sku')::uuid, 'non_expiring');
select set_config('sherlyos.shop', public.create_shop('M82D shop', null, null)::text, true);
select public.assign_shop_salesperson(
  current_setting('sherlyos.shop')::uuid,
  (select id from fixture where name = 'salesperson')
);

select pg_temp.as_user('salesperson');
select set_config(
  'sherlyos.order_sp',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'salesperson', null, 'm82d notes',
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.sku')::uuid, 'requested_cases', 2)
      ),
      'm82d-ord-sp01'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_sp')::uuid, 1, 'm82d-sub-sp01');

-- Unassigned Accounts can read salesperson submitted orders. Verify stays ATP-gated.
select pg_temp.as_user('accounts_none');
do $$
declare
  payload jsonb;
  dash jsonb;
  detail text;
begin
  payload := public.list_orders('submitted');
  if not exists (
    select 1
    from jsonb_array_elements(payload) as row
    where row ->> 'id' = current_setting('sherlyos.order_sp')
      and row ->> 'status' = 'submitted'
  ) then
    raise exception 'unassigned accounts missing submitted order: %', payload;
  end if;

  perform public.get_order(current_setting('sherlyos.order_sp')::uuid);

  begin
    perform public.verify_order(current_setting('sherlyos.order_sp')::uuid, 2, 'm82d-ver-none');
    raise exception 'unassigned accounts verify must stay ATP fail-closed';
  exception
    when sqlstate 'P0001' then
      get stacked diagnostics detail = pg_exception_detail;
      if detail is null or detail not like '%shortfall_cases%' then
        raise exception 'shortage detail missing: %', detail;
      end if;
  end;

  if (select status from public.orders where id = current_setting('sherlyos.order_sp')::uuid)
    is distinct from 'submitted'
  then
    raise exception 'failed verify must leave submitted';
  end if;

  dash := public.get_operations_dashboard(null);
  if (dash -> 'orders' ->> 'submitted')::int < 1 then
    raise exception 'unassigned accounts dashboard submitted must include the order: %', dash -> 'orders';
  end if;
end $$;

-- Other-godown Accounts can also read the submitted order for verification.
select pg_temp.as_user('accounts_other');
do $$
declare
  payload jsonb;
begin
  payload := public.list_orders('submitted');
  if not exists (
    select 1
    from jsonb_array_elements(payload) as row
    where row ->> 'id' = current_setting('sherlyos.order_sp')
  ) then
    raise exception 'other-godown accounts missing Godown A submitted order';
  end if;
end $$;

-- Store keeper cannot call verification RPCs.
select pg_temp.as_user('keeper');
do $$
begin
  begin
    perform public.list_orders('submitted');
    raise exception 'store keeper listed orders';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.verify_order(current_setting('sherlyos.order_sp')::uuid, 2, 'm82d-ver-keeper');
    raise exception 'store keeper verified an order';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Assigned Accounts can read the submitted order and stay fail-closed on ATP.
select pg_temp.as_user('accounts');
do $$
declare
  payload jsonb;
  snapshot jsonb;
  detail text;
  dash jsonb;
begin
  payload := public.list_orders('submitted');
  if not exists (
    select 1
    from jsonb_array_elements(payload) as row
    where row ->> 'id' = current_setting('sherlyos.order_sp')
      and row ->> 'status' = 'submitted'
  ) then
    raise exception 'assigned accounts missing submitted order: %', payload;
  end if;

  dash := public.get_operations_dashboard(null);
  if (dash -> 'orders' ->> 'submitted')::int < 1 then
    raise exception 'assigned accounts dashboard submitted must include the order: %', dash -> 'orders';
  end if;

  snapshot := public.check_order_availability(current_setting('sherlyos.order_sp')::uuid);
  if snapshot ->> 'reserves_stock' is distinct from 'false' then
    raise exception 'availability must remain non-reserving: %', snapshot;
  end if;

  begin
    perform public.verify_order(current_setting('sherlyos.order_sp')::uuid, 2, 'm82d-ver-atp');
    raise exception 'verify_order must fail closed without eligible lots';
  exception
    when sqlstate 'P0001' then
      get stacked diagnostics detail = pg_exception_detail;
      if detail is null or detail not like '%shortfall_cases%' then
        raise exception 'shortage detail missing: %', detail;
      end if;
  end;

  if (select status from public.orders where id = current_setting('sherlyos.order_sp')::uuid)
    is distinct from 'submitted'
  then
    raise exception 'failed verify must leave submitted';
  end if;

  begin
    perform public.create_delivery_note(current_setting('sherlyos.order_sp')::uuid, 'm82d-dn-early');
    raise exception 'delivery note must still require verified';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Salesperson cannot verify even as creator.
select pg_temp.as_user('salesperson');
do $$
begin
  begin
    perform public.verify_order(current_setting('sherlyos.order_sp')::uuid, 2, 'm82d-ver-sales');
    raise exception 'salesperson verified an order';
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
    raise exception 'cutover flags changed during M8.2D SQL';
  end if;
end $$;

rollback;
