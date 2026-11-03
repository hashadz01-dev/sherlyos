-- DMG-03B: transfer pre-check rejects moves that would consume damage holds.
-- Disposable. Temporarily enables dual-write + hold-ready; restores via ROLLBACK.
-- Run:
-- Get-Content supabase/tests/phase_dmg03b_transfer_holds_precheck.sql |
--   docker exec -i supabase_db_sherlyos psql -U postgres -d postgres -v ON_ERROR_STOP=1

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
  ('keeper', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id, 'authenticated', 'authenticated',
  fixture.name || '.dmg03b@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name), now(), now()
from fixture;

do $$
begin
  begin
    perform app_private.bootstrap_initial_admin(
      (select id from fixture where name = 'admin'), 'create-initial-administrator'
    );
  exception
    when sqlstate '42501' then
      insert into public.profiles (id, full_name, is_active)
      values ((select id from fixture where name = 'admin'), 'DMG03B Admin', true)
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
end
where fixture.name <> 'admin'
on conflict do nothing;

-- Grant transfer post to godown manager via existing permission if present.
-- Admin posts opening and transfer in this fixture.

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

select pg_temp.as_user('admin');
set local role authenticated;
select set_config(
  'sherlyos.branch',
  public.create_branch('dmg03b_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8), 'DMG03B')::text,
  true
);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'z1', 'Z1', null)::text, true);
select set_config('sherlyos.crate_a', public.create_crate(current_setting('sherlyos.zone')::uuid, 'ca', 'CA', null)::text, true);
select set_config('sherlyos.crate_b', public.create_crate(current_setting('sherlyos.zone')::uuid, 'cb', 'CB', null)::text, true);
select set_config('sherlyos.product', public.create_product('dmg03b-sku', 'DMG03B Product', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.product')::uuid, 'expiry_controlled');

reset role;
set session_replication_role = replica;
update public.app_configuration set value = 'true'::jsonb
where key in (
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked',
  'damage.stock_hold_ready'
);
set session_replication_role = origin;

select pg_temp.as_user('admin');
set local role authenticated;
select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate_a')::uuid,
  5, 'dmg03b-open', null, 'DMG03B-LOT', null, '2028-06-01'
);
select set_config('sherlyos.lot', (
  select stock_lots.id::text from public.stock_lots
  where stock_lots.product_id = current_setting('sherlyos.product')::uuid
  order by stock_lots.created_at limit 1
), true);

select pg_temp.as_user('keeper');
select set_config('sherlyos.dmg', (
  public.create_damage_report(
    'storage', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'crate_id', current_setting('sherlyos.crate_a')::uuid,
      'lot_id', current_setting('sherlyos.lot')::uuid,
      'quantity_cases', 2,
      'damage_reason', 'held'
    )),
    'dmg03b-hold'
  ) ->> 'id'
), true);
select public.submit_damage_report(current_setting('sherlyos.dmg')::uuid, 1, 'dmg03b-sub');

-- Physical 5, hold 2 → unreserved 3. Transfer of 4 must fail pre-check.
select pg_temp.as_user('admin');
do $$
begin
  perform public.post_crate_transfer(
    current_setting('sherlyos.product')::uuid,
    current_setting('sherlyos.crate_a')::uuid,
    current_setting('sherlyos.crate_b')::uuid,
    4,
    'dmg03b-xfer-fail',
    'must fail',
    jsonb_build_array(jsonb_build_object(
      'lot_id', current_setting('sherlyos.lot')::uuid,
      'quantity', 4
    ))
  );
  raise exception 'transfer of held stock must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%insufficient unreserved%' then raise; end if;
end $$;

-- Transfer of 3 unreserved cases must succeed.
select public.post_crate_transfer(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate_a')::uuid,
  current_setting('sherlyos.crate_b')::uuid,
  3,
  'dmg03b-xfer-ok',
  'ok',
  jsonb_build_array(jsonb_build_object(
    'lot_id', current_setting('sherlyos.lot')::uuid,
    'quantity', 3
  ))
);

reset role;
do $$
declare
  held integer;
  qty_a integer;
  qty_b integer;
begin
  select coalesce(sum(quantity_cases), 0) into held
  from public.damage_stock_holds
  where damage_report_id = current_setting('sherlyos.dmg')::uuid
    and status = 'active';
  if held is distinct from 2 then
    raise exception 'hold must remain 2, got %', held;
  end if;
  select quantity into qty_a from public.stock_balances
  where crate_id = current_setting('sherlyos.crate_a')::uuid
    and product_id = current_setting('sherlyos.product')::uuid;
  select coalesce(quantity, 0) into qty_b from public.stock_balances
  where crate_id = current_setting('sherlyos.crate_b')::uuid
    and product_id = current_setting('sherlyos.product')::uuid;
  if qty_a is distinct from 2 or qty_b is distinct from 3 then
    raise exception 'unexpected balances a=% b=%', qty_a, qty_b;
  end if;
end $$;

set session_replication_role = replica;
update public.app_configuration set value = 'false'::jsonb
where key in (
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked',
  'damage.stock_hold_ready'
);
set session_replication_role = origin;

rollback;
