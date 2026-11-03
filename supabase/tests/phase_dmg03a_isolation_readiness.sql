-- DMG-03A stock-isolation readiness. Rolls back.
-- Temporarily enables dual-write + hold-ready inside this transaction only.
-- Restores operational flags via ROLLBACK. Does not touch cloud or UAT drafts.
-- Run:
-- Get-Content supabase/tests/phase_dmg03a_isolation_readiness.sql |
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
  ('verifier', gen_random_uuid()),
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
  fixture.name || '.dmg03a@example.com',
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
      values ((select id from fixture where name = 'admin'), 'DMG03A Admin', true)
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
  when 'verifier' then 'godown_manager'
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
  perform set_config('role', 'authenticated', true);
end;
$$;

create or replace function pg_temp.attach_photo(target uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  created jsonb;
  payload bytea := decode('ffd8ffd9', 'hex');
begin
  created := public.create_damage_photo_upload(target, 'dmg03a evidence');
  perform set_config('app.damage_write', 'on', true);
  update public.damage_evidence
  set
    mime_type = 'image/jpeg',
    file_size = octet_length(payload),
    verified_at = clock_timestamp()
  where id = (created ->> 'id')::uuid;
end;
$$;

-- T15 / operational gate: flags must start false for this disposable DB.
do $$
declare
  hold_ready text;
  dual_write text;
  aggregate_only text;
begin
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
    raise exception 'dmg03a requires disposable flags false at start: % % %',
      hold_ready, dual_write, aggregate_only;
  end if;
end $$;

-- Cutover guard: hold_ready cannot enable while dual-write is false.
do $$
begin
  update public.app_configuration
  set value = 'true'::jsonb
  where key = 'damage.stock_hold_ready';
  raise exception 'hold_ready must require dual-write';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%dual-write%'
      and sqlerrm not like '%lot dual-write%'
      and sqlerrm not like '%not ready%'
    then
      raise;
    end if;
end $$;

select pg_temp.as_user('admin');
set local role authenticated;

select set_config(
  'sherlyos.branch',
  public.create_branch('dmg03a_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8), 'DMG03A')::text,
  true
);
select set_config(
  'sherlyos.branch_b',
  public.create_branch('dmg03ab_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8), 'DMG03A B')::text,
  true
);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'verifier'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);

select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'z1', 'Z1', null)::text, true);
select set_config('sherlyos.crate', public.create_crate(current_setting('sherlyos.zone')::uuid, 'c1', 'C1', null)::text, true);
select set_config('sherlyos.zone_b', public.create_zone(current_setting('sherlyos.branch_b')::uuid, 'zb', 'ZB', null)::text, true);
select set_config('sherlyos.crate_b', public.create_crate(current_setting('sherlyos.zone_b')::uuid, 'cb', 'CB', null)::text, true);
select set_config('sherlyos.product', public.create_product('dmg03a-sku', 'DMG03A Product', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.product')::uuid, 'expiry_controlled');

reset role;

-- Fixture-only cutover inside this rolled-back transaction.
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
  current_setting('sherlyos.crate')::uuid,
  17, 'dmg03a-open', null, 'DMG03A-LOT', null, '2028-06-01'
);
select set_config('sherlyos.lot', (
  select stock_lots.id::text from public.stock_lots
  where stock_lots.product_id = current_setting('sherlyos.product')::uuid
  order by stock_lots.created_at limit 1
), true);
select set_config('sherlyos.bal_before', (
  select quantity::text from public.stock_balances
  where crate_id = current_setting('sherlyos.crate')::uuid
    and product_id = current_setting('sherlyos.product')::uuid
), true);
select set_config('sherlyos.ledger_before', (
  select count(*)::text from public.stock_ledger
  where product_id = current_setting('sherlyos.product')::uuid
), true);

-- T15 residual: with gate true in fixture we can submit; separately prove
-- apply fails when readiness is off by calling the private gate after flip-off.
-- First: T04 wrong godown crate rejected at create/update line validation.
select pg_temp.as_user('keeper');
do $$
begin
  perform public.create_damage_report(
    'storage', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'crate_id', current_setting('sherlyos.crate_b')::uuid,
      'lot_id', current_setting('sherlyos.lot')::uuid,
      'quantity_cases', 1,
      'damage_reason', 'wrong godown'
    )),
    'dmg03a-wrong-godown'
  );
  raise exception 'foreign crate must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%crate is not in this godown%' then raise; end if;
end $$;

-- T03 insufficient availability fails atomically (draft stays draft).
select set_config('sherlyos.dmg_over', (
  public.create_damage_report(
    'storage', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'crate_id', current_setting('sherlyos.crate')::uuid,
      'lot_id', current_setting('sherlyos.lot')::uuid,
      'quantity_cases', 18,
      'damage_reason', 'over avail'
    )),
    'dmg03a-over'
  ) ->> 'id'
), true);
do $$
begin
  perform public.submit_damage_report(
    current_setting('sherlyos.dmg_over')::uuid, 1, 'dmg03a-over-sub'
  );
  raise exception 'over-avail submit must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%insufficient unreserved stock%' then raise; end if;
end $$;
do $$
begin
  if (select status from public.damage_reports where id = current_setting('sherlyos.dmg_over')::uuid)
     is distinct from 'draft'
  then
    raise exception 'failed isolation must leave draft';
  end if;
  if exists (
    select 1 from public.damage_stock_holds
    where damage_report_id = current_setting('sherlyos.dmg_over')::uuid
  ) then
    raise exception 'failed isolation must not leave holds';
  end if;
end $$;

-- T01 / T02 valid isolation: physical 17, hold 1, avail 16, ledger unchanged.
select set_config('sherlyos.dmg03', (
  public.create_damage_report(
    'storage', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'crate_id', current_setting('sherlyos.crate')::uuid,
      'lot_id', current_setting('sherlyos.lot')::uuid,
      'quantity_cases', 1,
      'damage_reason', 'packaging'
    )),
    'dmg03a-ok'
  ) ->> 'id'
), true);
select pg_temp.attach_photo(current_setting('sherlyos.dmg03')::uuid);
select public.submit_damage_report(
  current_setting('sherlyos.dmg03')::uuid, 1, 'dmg03a-ok-sub'
);

reset role;
do $$
declare
  on_hand integer;
  held integer;
  avail integer;
  reserved integer;
begin
  select quantity into on_hand from public.stock_balances
  where crate_id = current_setting('sherlyos.crate')::uuid
    and product_id = current_setting('sherlyos.product')::uuid;
  if on_hand is distinct from current_setting('sherlyos.bal_before')::integer then
    raise exception 'physical on-hand changed on isolate: %', on_hand;
  end if;
  if on_hand is distinct from 17 then
    raise exception 'expected fixture on-hand 17, got %', on_hand;
  end if;

  select coalesce(sum(quantity_cases), 0) into held
  from public.damage_stock_holds
  where damage_report_id = current_setting('sherlyos.dmg03')::uuid
    and status = 'active';
  if held is distinct from 1 then
    raise exception 'expected one active hold case, got %', held;
  end if;

  reserved := app_private.active_reserved_lot_cases(
    current_setting('sherlyos.lot')::uuid,
    current_setting('sherlyos.crate')::uuid
  );
  avail := app_private.picking_available_cases(
    current_setting('sherlyos.lot')::uuid,
    current_setting('sherlyos.crate')::uuid
  );
  if avail is distinct from (on_hand - reserved - held) then
    raise exception 'avail formula mismatch: on_hand=% reserved=% held=% avail=%',
      on_hand, reserved, held, avail;
  end if;
  if avail is distinct from 16 then
    raise exception 'expected available 16 after 1-case hold, got %', avail;
  end if;

  if (select count(*) from public.stock_ledger
      where product_id = current_setting('sherlyos.product')::uuid)
     <> current_setting('sherlyos.ledger_before')::integer
  then
    raise exception 'storage isolate must not post ledger';
  end if;

  if (select status from public.damage_reports where id = current_setting('sherlyos.dmg03')::uuid)
     is distinct from 'submitted'
  then
    raise exception 'successful isolate must submit';
  end if;
end $$;

-- T06 duplicate submit is idempotent (same key).
select pg_temp.as_user('keeper');
select public.submit_damage_report(
  current_setting('sherlyos.dmg03')::uuid, 2, 'dmg03a-ok-sub'
);
reset role;
do $$
begin
  if (select count(*) from public.damage_stock_holds
      where damage_report_id = current_setting('sherlyos.dmg03')::uuid) <> 1
  then
    raise exception 'duplicate submit must not create extra holds';
  end if;
end $$;

-- T09 Store Keeper (reporter) cannot verify.
select pg_temp.as_user('keeper');
do $$
begin
  perform public.verify_damage_report(current_setting('sherlyos.dmg03')::uuid, 2);
  raise exception 'store keeper verify must fail';
exception
  when insufficient_privilege then null;
  when sqlstate '42501' then null;
end $$;

-- Self-verify: GM who submitted cannot verify their own report.
select pg_temp.as_user('godown');
select set_config('sherlyos.dmg_self', (
  public.create_damage_report(
    'storage', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'crate_id', current_setting('sherlyos.crate')::uuid,
      'lot_id', current_setting('sherlyos.lot')::uuid,
      'quantity_cases', 1,
      'damage_reason', 'self verify'
    )),
    'dmg03a-self'
  ) ->> 'id'
), true);
select pg_temp.attach_photo(current_setting('sherlyos.dmg_self')::uuid);
select public.submit_damage_report(
  current_setting('sherlyos.dmg_self')::uuid, 1, 'dmg03a-self-sub'
);
do $$
begin
  perform public.verify_damage_report(current_setting('sherlyos.dmg_self')::uuid, 2);
  raise exception 'reporter self-verify must fail';
exception
  when sqlstate '42501' then
    if sqlerrm not like '%reporter cannot verify%' then raise; end if;
end $$;

-- T10 authorized non-reporter GM verifies the Store Keeper report.
select pg_temp.as_user('verifier');
select public.verify_damage_report(current_setting('sherlyos.dmg03')::uuid, 2);
do $$
begin
  if (select status from public.damage_reports where id = current_setting('sherlyos.dmg03')::uuid)
     is distinct from 'verified'
  then
    raise exception 'authorized verifier must verify';
  end if;
end $$;

-- Prove fail-closed again: flip hold_ready off (replica) and ensure apply raises.
reset role;
set session_replication_role = replica;
update public.app_configuration set value = 'false'::jsonb
where key = 'damage.stock_hold_ready';
set session_replication_role = origin;

do $$
begin
  perform app_private.apply_damage_stock_isolation(current_setting('sherlyos.dmg03')::uuid);
  raise exception 'apply must fail when hold_ready false';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%stock isolation is not ready%' then raise; end if;
end $$;

-- Leave flags false for the rolled-back TX end assertion (already false for hold).
set session_replication_role = replica;
update public.app_configuration set value = 'false'::jsonb
where key in (
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked',
  'damage.stock_hold_ready'
);
set session_replication_role = origin;

do $$
declare
  hold_ready text;
  dual_write text;
  aggregate_only text;
begin
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
    raise exception 'dmg03a must restore flags false before rollback: % % %',
      hold_ready, dual_write, aggregate_only;
  end if;
end $$;

rollback;
