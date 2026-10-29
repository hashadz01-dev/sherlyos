-- M1-S1 cutover flag safety. Disposable. Rolls back.
-- Admin posts opening (stock.opening.post + branches.access_all).

begin;

create temp table s1_fixture (
  name text primary key,
  id uuid not null
);

grant select on s1_fixture to authenticated;

insert into s1_fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('godown', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  s1_fixture.id,
  'authenticated',
  'authenticated',
  s1_fixture.name || '.m1s1@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', s1_fixture.name),
  now(),
  now()
from s1_fixture;

insert into public.profiles (id, full_name, is_active)
select id, name, true from s1_fixture
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select s1_fixture.id, roles.id, s1_fixture.id
from s1_fixture
join public.roles on roles.code = 'admin'
where s1_fixture.name = 'admin'
on conflict do nothing;

insert into public.user_roles (user_id, role_id, assigned_by)
select s1_fixture.id, roles.id, (select id from s1_fixture where name = 'admin')
from s1_fixture
join public.roles on roles.code = 'godown_manager'
where s1_fixture.name = 'godown'
on conflict do nothing;

do $$
begin
  if (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled')
       is distinct from 'false'::jsonb
     or (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked')
       is distinct from 'false'::jsonb
  then
    raise exception 'working DB flags must start false/false';
  end if;
end $$;

-- 8) Unauthorized authenticated config update (before privileged tests)
select set_config('request.jwt.claim.sub', (select id::text from s1_fixture where name = 'godown'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from s1_fixture where name = 'godown'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;
do $$
begin
  begin
    update public.app_configuration
    set value = 'true'::jsonb
    where key = 'stock.lots.dual_write_enabled';
    raise exception 'expected authenticated config update denial';
  exception
    when insufficient_privilege then
      null;
  end;
end $$;
reset role;

-- 1) Premature dual-write activation
do $$
begin
  begin
    update public.app_configuration
    set value = 'true'::jsonb
    where key = 'stock.lots.dual_write_enabled';
    raise exception 'expected dual-write enable rejection';
  exception
    when sqlstate '55000' then
      null;
  end;

  if (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled')
    is distinct from 'false'::jsonb
  then
    raise exception 'premature dual-write must roll back the flag value';
  end if;
end $$;

-- Same-statement pair from false/false is judged on the final pair.
-- Greenfield true/true then false/false is legal only when this database has
-- no lot rows. A populated working DB with leftover lots must not restore
-- aggregate_only_blocked=false: Rule B is the production safety trigger.
-- Fail-closed unclassified/mismatch cases stay covered after opening/seed.
do $$
declare
  lot_activity boolean := false;
begin
  select exists (select 1 from public.stock_lots)
      or exists (select 1 from public.stock_lot_balances where quantity <> 0)
      or exists (select 1 from public.stock_ledger where lot_id is not null)
    into lot_activity;
  perform set_config('sherlyos.lot_activity_at_start', lot_activity::text, true);

  if lot_activity then
    -- No-op: a same-value UPDATE would skip the statement trigger, and a
    -- true/true enable cannot be restored to false/false while lots exist.
    -- Rule B is proven after seed below. Keep working flags false/false.
    raise notice 'skipping greenfield flag restore; lot activity already present';
  else
    update public.app_configuration
    set value = 'true'::jsonb
    where key in (
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    );

    if (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled')
         is distinct from 'true'::jsonb
       or (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked')
         is distinct from 'true'::jsonb
    then
      raise exception 'empty inventory must allow dual-write+blocked greenfield enable';
    end if;

    update public.app_configuration
    set value = 'false'::jsonb
    where key in (
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    );

    if (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled')
         is distinct from 'false'::jsonb
       or (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked')
         is distinct from 'false'::jsonb
    then
      raise exception 'greenfield enable must restore false/false for the rest of the suite';
    end if;
  end if;
end $$;

do $$
begin
  begin
    update public.app_configuration
    set value = '1'::jsonb
    where key = 'stock.lots.dual_write_enabled';
    raise exception 'expected non-boolean flag rejection';
  exception
    when sqlstate '23514' then
      null;
  end;
end $$;

select set_config('request.jwt.claim.sub', (select id::text from s1_fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from s1_fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select set_config('sherlyos.branch', public.create_branch('m1s1', 'M1 S1')::text, true);
select public.assign_user_branch((select id from s1_fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select set_config(
  'sherlyos.zone',
  public.create_zone(current_setting('sherlyos.branch')::uuid, 'zs1', 'ZS1', null)::text,
  true
);
select set_config(
  'sherlyos.crate',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'cs1', 'CS1', null)::text,
  true
);
select set_config(
  'sherlyos.crate_b',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'cs1b', 'CS1B', null)::text,
  true
);
select set_config('sherlyos.product', public.create_product('M1S1-SKU', 'M1 S1 Product', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.product')::uuid, 'non_expiring');

-- Working-DB leftovers with positive stock must be classified before seed;
-- policy cannot change once lots exist. Test-only; ROLLBACK restores NULL.
do $$
declare
  rec record;
begin
  for rec in
    select distinct stock_balances.product_id
    from public.stock_balances
    join public.products on products.id = stock_balances.product_id
    where stock_balances.quantity > 0
      and products.expiry_policy is null
  loop
    perform public.set_product_expiry_policy(rec.product_id, 'non_expiring');
  end loop;
end $$;

select set_config(
  'sherlyos.product_unclass',
  public.create_product('M1S1-UNCLASS', 'M1 S1 Unclassified', null, null)::text,
  true
);

-- 9) Flags-off aggregate opening still works
select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate')::uuid,
  5,
  'm1s1-opening-1',
  null
);

-- Unclassified product with positive stock (classification guard target)
select public.post_opening_stock(
  current_setting('sherlyos.product_unclass')::uuid,
  current_setting('sherlyos.crate')::uuid,
  3,
  'm1s1-opening-unclass',
  null
);

-- 2) blocked true but unmatched aggregate still rejects dual-write.
-- Sequential blocked=true with dual-write false is illegal once lot-attributed
-- ledger rows exist (Rule C). Prove that rejection on populated DBs instead.
reset role;
do $$
begin
  if exists (select 1 from public.stock_ledger where lot_id is not null) then
    begin
      update public.app_configuration
      set value = 'true'::jsonb
      where key = 'stock.lots.aggregate_only_blocked';
      raise exception 'expected Rule C rejection while lot-attributed ledger exists';
    exception
      when sqlstate '55000' then
        null;
    end;
  else
    update public.app_configuration
    set value = 'true'::jsonb
    where key = 'stock.lots.aggregate_only_blocked';

    begin
      update public.app_configuration
      set value = 'true'::jsonb
      where key = 'stock.lots.dual_write_enabled';
      raise exception 'expected dual-write rejection without reconciled lots';
    exception
      when sqlstate '55000' then
        null;
    end;
  end if;
end $$;

-- 3) Seed legacy lots (matching grains; dual-write still false).
-- Global seed refuses when owner grains already have lots. Attribute only
-- this fixture's unmatched openings so later enable proofs stay local.
select set_config('request.jwt.claim.sub', (select id::text from s1_fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from s1_fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;
do $$
declare
  seeded boolean := false;
begin
  begin
    perform public.seed_legacy_stock_lots();
    seeded := true;
  exception
    when others then
      if sqlerrm not like 'legacy lot seed refused%' then
        raise;
      end if;
  end;

  if not seeded then
    reset role;
    set local session_replication_role = replica;
    insert into public.stock_lots (
      product_id, branch_id, status, origin, expiry_date, received_on, created_by
    )
    select
      sb.product_id,
      current_setting('sherlyos.branch')::uuid,
      'available',
      'opening',
      null,
      clock_timestamp(),
      (select id from s1_fixture where name = 'admin')
    from public.stock_balances sb
    where sb.crate_id in (
      current_setting('sherlyos.crate')::uuid,
      current_setting('sherlyos.crate_b')::uuid
    )
      and sb.quantity > 0
      and not exists (
        select 1
        from public.stock_lot_balances lb
        join public.stock_lots sl on sl.id = lb.lot_id
        where lb.crate_id = sb.crate_id
          and sl.product_id = sb.product_id
      );

    insert into public.stock_lot_balances (lot_id, crate_id, quantity)
    select sl.id, sb.crate_id, sb.quantity
    from public.stock_balances sb
    join public.stock_lots sl
      on sl.product_id = sb.product_id
     and sl.branch_id = current_setting('sherlyos.branch')::uuid
    where sb.crate_id in (
      current_setting('sherlyos.crate')::uuid,
      current_setting('sherlyos.crate_b')::uuid
    )
      and sb.quantity > 0
      and not exists (
        select 1 from public.stock_lot_balances lb where lb.lot_id = sl.id
      );
    set local session_replication_role = origin;
    perform set_config('request.jwt.claim.sub', (select id::text from s1_fixture where name = 'admin'), true);
    perform set_config(
      'request.jwt.claims',
      jsonb_build_object('sub', (select id from s1_fixture where name = 'admin'), 'role', 'authenticated')::text,
      true
    );
    execute 'set local role authenticated';
  end if;
end $$;
reset role;

-- 3a) Dual-write enable is rejected while an unclassified product still has stock
do $$
begin
  begin
    update public.app_configuration
    set value = 'true'::jsonb
    where key = 'stock.lots.dual_write_enabled';
    raise exception 'expected unclassified positive-stock rejection';
  exception
    when sqlstate '55000' then
      null;
  end;

  if (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled')
    is distinct from 'false'::jsonb
  then
    raise exception 'classification rejection must leave dual-write false';
  end if;
end $$;

-- Strip the unclassified grain (replica) so the rest of the suite can enable dual-write.
-- Policy cannot be set after lots exist; removing the grain is the fail-closed recovery.
set local session_replication_role = replica;
delete from public.stock_lot_balances
where lot_id in (
  select stock_lots.id
  from public.stock_lots
  where stock_lots.product_id = current_setting('sherlyos.product_unclass')::uuid
);
delete from public.stock_legacy_lot_seeds
where product_id = current_setting('sherlyos.product_unclass')::uuid;
delete from public.stock_lots
where product_id = current_setting('sherlyos.product_unclass')::uuid;
update public.stock_balances
set quantity = 0
where product_id = current_setting('sherlyos.product_unclass')::uuid;
set local session_replication_role = origin;

-- 3b) Orphan lot grain (lot qty on a crate with no positive aggregate) rejects dual-write
set local session_replication_role = replica;
insert into public.stock_lot_balances (lot_id, crate_id, quantity)
select
  (select stock_lots.id from public.stock_lots order by stock_lots.created_at desc limit 1),
  current_setting('sherlyos.crate_b')::uuid,
  1;
set local session_replication_role = origin;

do $$
begin
  begin
    update public.app_configuration
    set value = 'true'::jsonb
    where key = 'stock.lots.dual_write_enabled';
    raise exception 'expected orphan lot grain rejection';
  exception
    when sqlstate '55000' then
      null;
  end;
end $$;

set local session_replication_role = replica;
delete from public.stock_lot_balances
where crate_id = current_setting('sherlyos.crate_b')::uuid;
set local session_replication_role = origin;

-- 4) Successful dual-write enable after seed (atomic pair and sequential)
update public.app_configuration
set value = 'true'::jsonb
where key in (
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked'
);

do $$
begin
  if (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled')
    is distinct from 'true'::jsonb
  then
    raise exception 'dual-write should enable after reconciled seed';
  end if;
end $$;

-- 5) Grain mismatch (lot exceeds aggregate) rejects a re-validation.
-- Replica role skips the trusted-writer gate for this disposable imbalance only.
set local session_replication_role = replica;
update public.stock_lot_balances
set quantity = quantity + 1
where lot_id = (
  select stock_lots.id
  from public.stock_lots
  join public.stock_lot_balances on stock_lot_balances.lot_id = stock_lots.id
  order by stock_lots.created_at desc
  limit 1
);
set local session_replication_role = origin;

-- true -> true would skip the value-change trigger; disable then re-enable.
-- Populated DBs with lot-attributed ledger cannot disable dual-write (Rule C).
do $$
begin
  if current_setting('sherlyos.lot_activity_at_start', true) = 'true' then
    raise notice 'skipping dual-write bounce; Rule C forbids disable while lot ledger exists';
  else
    update public.app_configuration
    set value = 'false'::jsonb
    where key = 'stock.lots.dual_write_enabled';

    begin
      update public.app_configuration
      set value = 'true'::jsonb
      where key = 'stock.lots.dual_write_enabled';
      raise exception 'expected grain mismatch rejection';
    exception
      when sqlstate '55000' then
        null;
    end;
  end if;
end $$;

set local session_replication_role = replica;
update public.stock_lot_balances
set quantity = quantity - 1
where lot_id = (
  select stock_lots.id
  from public.stock_lots
  join public.stock_lot_balances on stock_lot_balances.lot_id = stock_lots.id
  order by stock_lots.created_at desc
  limit 1
);
set local session_replication_role = origin;

do $$
begin
  if current_setting('sherlyos.lot_activity_at_start', true) is distinct from 'true' then
    update public.app_configuration
    set value = 'true'::jsonb
    where key = 'stock.lots.dual_write_enabled';
  end if;
end $$;

-- 6) Rule B: cannot clear aggregate_only_blocked while lots exist
do $$
begin
  begin
    update public.app_configuration
    set value = 'false'::jsonb
    where key = 'stock.lots.aggregate_only_blocked';
    raise exception 'expected aggregate_only_blocked clear rejection';
  exception
    when sqlstate '55000' then
      null;
  end;
end $$;

-- Lot-attributed posting (needed for Rule C)
select set_config('request.jwt.claim.sub', (select id::text from s1_fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from s1_fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate_b')::uuid,
  2,
  'm1s1-opening-lot',
  null,
  'LOT-S1',
  null,
  null
);
reset role;

-- 7) Rule C: cannot disable dual-write after lot-attributed ledger exists
do $$
begin
  begin
    update public.app_configuration
    set value = 'false'::jsonb
    where key = 'stock.lots.dual_write_enabled';
    raise exception 'expected dual-write deactivation rejection';
  exception
    when sqlstate '55000' then
      null;
  end;
end $$;

do $$
begin
  raise notice 'PASS phase_m1_s1_cutover_flag_safety';
end $$;

rollback;
