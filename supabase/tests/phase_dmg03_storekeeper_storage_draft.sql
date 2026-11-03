-- DMG-03 Store Keeper storage draft auth. Rolls back.
-- Does not flip damage.stock_hold_ready or lot cutover flags.
-- Run: Get-Content supabase/tests/phase_dmg03_storekeeper_storage_draft.sql | docker exec -i supabase_db_sherlyos psql -U postgres -d postgres -v ON_ERROR_STOP=1

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);
grant select on fixture to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('sales', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.dmg03sk@example.com',
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
      values ((select id from fixture where name = 'admin'), 'DMG03 SK Admin', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select (select id from fixture where name = 'admin'), roles.id,
        (select id from fixture where name = 'admin')
      from public.roles where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.profiles (id, full_name, is_active)
select fixture.id, fixture.name, true from fixture where name <> 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles on roles.code = case fixture.name
  when 'godown' then 'godown_manager'
  when 'keeper' then 'store_keeper'
  when 'sales' then 'salesperson'
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
  perform set_config('role', 'authenticated', true);
end;
$$;

set session_replication_role = replica;

insert into public.branches (code, name, is_active)
values
  ('dmg03_gd', 'DMG03 Home', true),
  ('dmg03_other', 'DMG03 Other', true);

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code = 'dmg03_gd'
  and fixture.name in ('admin', 'godown', 'keeper');

insert into public.zones (branch_id, code, name, is_active)
select id, 'dmg03_z', 'DMG03 Zone', true from public.branches where code = 'dmg03_gd';

insert into public.crates (zone_id, code, name, is_active)
select id, 'dmg03_c', 'DMG03 Crate', true from public.zones where code = 'dmg03_z';

insert into public.products (sku, name, is_active)
values ('dmg03_sku', 'DMG03 Product', true);

insert into public.stock_balances (crate_id, product_id, quantity)
select crates.id, products.id, 4
from public.crates, public.products
where crates.code = 'dmg03_c'
  and products.sku = 'dmg03_sku';

set session_replication_role = origin;

-- Capture fixture keys as postgres before JWT role switch. Store Keeper RLS
-- hides products without products.read, which would null the line product_id.
select set_config(
  'sherlyos.dmg03_branch',
  (select id::text from public.branches where code = 'dmg03_gd'),
  true
);
select set_config(
  'sherlyos.dmg03_other',
  (select id::text from public.branches where code = 'dmg03_other'),
  true
);
select set_config(
  'sherlyos.dmg03_product',
  (select id::text from public.products where sku = 'dmg03_sku'),
  true
);
select set_config(
  'sherlyos.dmg03_crate',
  (select id::text from public.crates where code = 'dmg03_c'),
  true
);

select pg_temp.as_user('keeper');
do $$
declare
  created jsonb;
  branch uuid := current_setting('sherlyos.dmg03_branch')::uuid;
  other uuid := current_setting('sherlyos.dmg03_other')::uuid;
  product uuid := current_setting('sherlyos.dmg03_product')::uuid;
  crate uuid := current_setting('sherlyos.dmg03_crate')::uuid;
begin
  created := public.create_damage_report(
    'storage',
    branch,
    jsonb_build_array(jsonb_build_object(
      'product_id', product,
      'crate_id', crate,
      'quantity_cases', 1,
      'damage_reason', 'torn carton'
    )),
    'dmg03-sk-home',
    'warehouse find'
  );
  if created ->> 'status' is distinct from 'draft' then
    raise exception 'home godown storage draft failed: %', created;
  end if;
  if created ->> 'id' is null then
    raise exception 'draft must return a report id';
  end if;

  -- Home crate cannot be claimed against another godown (crate scope).
  -- Store Keepers with store_keeper.godowns.all may draft at other active
  -- godowns when the crate actually belongs there.
  begin
    perform public.create_damage_report(
      'storage',
      other,
      jsonb_build_array(jsonb_build_object(
        'product_id', product,
        'crate_id', crate,
        'quantity_cases', 1,
        'damage_reason', 'torn carton'
      )),
      'dmg03-sk-other'
    );
    raise exception 'foreign-crate storage draft must fail';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%crate is not in this godown%' then
        raise;
      end if;
  end;

  begin
    perform public.list_damage_report_sources('shop_return', branch, null, 1, 20);
    raise exception 'store keeper shop-return sources must stay denied';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
  end;

  begin
    perform public.submit_damage_report(
      (created ->> 'id')::uuid,
      (created ->> 'version')::integer,
      'dmg03-sk-sub'
    );
    raise exception 'storage submit must stay gated';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%stock isolation is not ready%' then
        raise;
      end if;
  end;

  begin
    perform public.verify_damage_report((created ->> 'id')::uuid, 1);
    raise exception 'store keeper must not verify own draft';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
    when sqlstate '23514' then null;
  end;

  -- Stash draft id for post-role stock/hold asserts (RLS hides balances here).
  perform set_config('sherlyos.dmg03_draft', created ->> 'id', true);
end $$;

select pg_temp.as_user('sales');
do $$
declare
  branch uuid := current_setting('sherlyos.dmg03_branch')::uuid;
  product uuid := current_setting('sherlyos.dmg03_product')::uuid;
  crate uuid := current_setting('sherlyos.dmg03_crate')::uuid;
begin
  begin
    perform public.create_damage_report(
      'storage',
      branch,
      jsonb_build_array(jsonb_build_object(
        'product_id', product,
        'crate_id', crate,
        'quantity_cases', 1,
        'damage_reason', 'sales attempt'
      )),
      'dmg03-sales'
    );
    raise exception 'salesperson storage create must fail';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
  end;
end $$;

select pg_temp.as_user('godown');
do $$
declare
  listed jsonb;
  branch uuid := current_setting('sherlyos.dmg03_branch')::uuid;
begin
  listed := public.list_damage_report_sources('storage', branch, null, 1, 20);
  if jsonb_array_length(listed -> 'items') < 1 then
    raise exception 'godown manager must still list storage sources';
  end if;
end $$;

reset role;

do $$
declare
  on_hand integer;
  hold_ready text;
  dual_write text;
  aggregate_only text;
  draft_id uuid := current_setting('sherlyos.dmg03_draft')::uuid;
begin
  select quantity into on_hand
  from public.stock_balances
  where crate_id = current_setting('sherlyos.dmg03_crate')::uuid
    and product_id = current_setting('sherlyos.dmg03_product')::uuid;
  if on_hand is distinct from 4 then
    raise exception 'draft must not change stock: %', on_hand;
  end if;

  if exists (
    select 1 from public.damage_stock_holds
    where damage_report_id = draft_id
  ) then
    raise exception 'draft must not create damage holds';
  end if;

  if exists (
    select 1 from public.stock_ledger
    where product_id = current_setting('sherlyos.dmg03_product')::uuid
  ) then
    raise exception 'draft must not post stock ledger rows';
  end if;

  select value #>> '{}' into hold_ready
  from public.app_configuration where key = 'damage.stock_hold_ready';
  select value #>> '{}' into dual_write
  from public.app_configuration where key = 'stock.lots.dual_write_enabled';
  select value #>> '{}' into aggregate_only
  from public.app_configuration where key = 'stock.lots.aggregate_only_blocked';
  if hold_ready is distinct from 'false'
    or dual_write is distinct from 'false'
    or aggregate_only is distinct from 'false'
  then
    raise exception 'cutover flags changed: % % %', hold_ready, dual_write, aggregate_only;
  end if;
end $$;

rollback;
