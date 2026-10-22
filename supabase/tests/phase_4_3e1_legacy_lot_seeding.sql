-- Phase 4.3E.1 local disposable checks. Transaction rolls back.
-- Run via docker exec -i supabase_db_sherlyos psql ... < this file

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
  ('godown_b', gen_random_uuid()),
  ('accounts', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.phase43e1@example.com',
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
      values ((select id from fixture where name = 'admin'), 'Phase 4.3E.1 Admin', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select
        (select id from fixture where name = 'admin'),
        roles.id,
        (select id from fixture where name = 'admin')
      from public.roles
      where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.profiles (id, full_name, is_active)
select fixture.id, fixture.name, true
from fixture
where fixture.name <> 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles
  on roles.code = case fixture.name
    when 'godown' then 'godown_manager'
    when 'godown_b' then 'godown_manager'
    when 'accounts' then 'accounts'
  end
where fixture.name in ('godown', 'godown_b', 'accounts')
on conflict do nothing;

-- Permission matrix
do $$
begin
  if not exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'admin' and permissions.code = 'stock.lots.seed'
  ) then
    raise exception 'admin missing stock.lots.seed';
  end if;

  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'godown_manager' and permissions.code = 'stock.lots.seed'
  ) then
    raise exception 'godown_manager must not have stock.lots.seed';
  end if;
end $$;

select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select set_config('sherlyos.branch_a', public.create_branch('p43e1_a', 'Phase 4.3E.1 A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('p43e1_b', 'Phase 4.3E.1 B')::text, true);
select public.assign_user_branch(
  (select id from fixture where name = 'godown'),
  current_setting('sherlyos.branch_a')::uuid
);
select public.assign_user_branch(
  (select id from fixture where name = 'godown_b'),
  current_setting('sherlyos.branch_b')::uuid
);
select set_config(
  'sherlyos.zone_a',
  public.create_zone(current_setting('sherlyos.branch_a')::uuid, 'z43e1a', 'Z43E1A', null)::text,
  true
);
select set_config(
  'sherlyos.crate_a',
  public.create_crate(current_setting('sherlyos.zone_a')::uuid, 'c43e1a', 'C43E1A', null)::text,
  true
);
select set_config(
  'sherlyos.zone_b',
  public.create_zone(current_setting('sherlyos.branch_b')::uuid, 'z43e1b', 'Z43E1B', null)::text,
  true
);
select set_config(
  'sherlyos.crate_b',
  public.create_crate(current_setting('sherlyos.zone_b')::uuid, 'c43e1b', 'C43E1B', null)::text,
  true
);
select set_config(
  'sherlyos.product',
  public.create_product('p43e1-soap', 'Phase 4.3E.1 Soap', null, null)::text,
  true
);
select set_config(
  'sherlyos.product2',
  public.create_product('p43e1-oil', 'Phase 4.3E.1 Oil', null, null)::text,
  true
);

-- Pre-seed opening still works (aggregate-only path)
select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate_a')::uuid,
  7,
  'p43e1-open-a-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
  'pre-seed opening a'
);
select public.post_opening_stock(
  current_setting('sherlyos.product2')::uuid,
  current_setting('sherlyos.crate_b')::uuid,
  4,
  'p43e1-open-b-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
  'pre-seed opening b'
);

reset role;

-- Zero-quantity row should be skipped by seeder
insert into public.stock_balances (crate_id, product_id, quantity)
values (
  current_setting('sherlyos.crate_a')::uuid,
  current_setting('sherlyos.product2')::uuid,
  0
);

create temp table ledger_before as
select count(*)::integer as ledger_rows,
       count(*) filter (where lot_id is not null)::integer as lot_tagged
from public.stock_ledger;

create temp table balances_before as
select crate_id, product_id, quantity
from public.stock_balances
order by crate_id, product_id;

-- GM denied
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'godown'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'godown'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

do $$
begin
  begin
    perform public.seed_legacy_stock_lots();
    raise exception 'godown manager should not seed';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

reset role;

-- Admin seeds
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

do $$
declare
  result jsonb;
  fixture_lots integer;
begin
  result := public.seed_legacy_stock_lots();
  if (result ->> 'seeded')::integer < 2 then
    raise exception 'expected at least 2 seeded grains for fixture openings, got %', result;
  end if;
  if result ->> 'aggregate_only_blocked' is distinct from 'true' then
    raise exception 'seed should block aggregate-only posting';
  end if;

  select count(*)::integer into fixture_lots
  from public.stock_legacy_lot_seeds
  where (crate_id, product_id) in (
    (current_setting('sherlyos.crate_a')::uuid, current_setting('sherlyos.product')::uuid),
    (current_setting('sherlyos.crate_b')::uuid, current_setting('sherlyos.product2')::uuid)
  );

  if fixture_lots <> 2 then
    raise exception 'fixture openings were not both seeded, got %', fixture_lots;
  end if;
end $$;

-- Idempotent repeat
do $$
declare
  result jsonb;
  lots_before integer;
  lots_after integer;
  examined integer;
begin
  select count(*)::integer into lots_before from public.stock_lots;
  examined := (
    select count(*)::integer from public.stock_balances where quantity > 0
  );

  result := public.seed_legacy_stock_lots();
  if (result ->> 'seeded')::integer <> 0 then
    raise exception 'idempotent seed should create 0 new lots, got %', result;
  end if;
  if (result ->> 'skipped_idempotent')::integer <> examined then
    raise exception 'expected % idempotent skips, got %', examined, result;
  end if;

  select count(*)::integer into lots_after from public.stock_lots;
  if lots_after <> lots_before then
    raise exception 'idempotent seed changed lot count';
  end if;
end $$;

reset role;

-- Conservation, null metadata, branch ownership, zero skip
do $$
declare
  mismatched integer;
  null_bad integer;
  zero_lots integer;
  branch_bad integer;
begin
  select count(*)::integer into mismatched
  from public.stock_balances b
  where b.quantity > 0
    and b.quantity is distinct from (
      select coalesce(sum(slb.quantity), 0)
      from public.stock_lot_balances slb
      join public.stock_lots sl on sl.id = slb.lot_id
      where slb.crate_id = b.crate_id
        and sl.product_id = b.product_id
    );

  if mismatched <> 0 then
    raise exception 'conservation failed for % grains', mismatched;
  end if;

  select count(*)::integer into null_bad
  from public.stock_lots
  where status = 'legacy_unattributed'
    and (
      received_on is not null
      or manufactured_on is not null
      or expiry_date is not null
      or manufacturer_lot_code is not null
      or source_receipt_line_id is not null
      or source_transaction_id is not null
    );

  if null_bad <> 0 then
    raise exception 'legacy lots must keep metadata null';
  end if;

  select count(*)::integer into zero_lots
  from public.stock_legacy_lot_seeds
  where crate_id = current_setting('sherlyos.crate_a')::uuid
    and product_id = current_setting('sherlyos.product2')::uuid;

  if zero_lots <> 0 then
    raise exception 'zero-quantity balance must not be seeded';
  end if;

  select count(*)::integer into branch_bad
  from public.stock_lots sl
  join public.stock_lot_balances slb on slb.lot_id = sl.id
  join public.crates on crates.id = slb.crate_id
  join public.zones on zones.id = crates.zone_id
  where sl.branch_id is distinct from zones.branch_id;

  if branch_bad <> 0 then
    raise exception 'lot branch_id must match crate zone branch';
  end if;
end $$;

-- Aggregate quantities unchanged; ledger untouched / untagged
do $$
declare
  qty_drift integer;
  ledger_now integer;
  lot_tagged_now integer;
begin
  select count(*)::integer into qty_drift
  from public.stock_balances b
  join balances_before bb
    on bb.crate_id = b.crate_id and bb.product_id = b.product_id
  where b.quantity is distinct from bb.quantity;

  if qty_drift <> 0 then
    raise exception 'seed must not change aggregate quantities';
  end if;

  select count(*)::integer, count(*) filter (where lot_id is not null)::integer
  into ledger_now, lot_tagged_now
  from public.stock_ledger;

  if ledger_now <> (select ledger_rows from ledger_before)
    or lot_tagged_now <> (select lot_tagged from ledger_before)
  then
    raise exception 'seed must not alter historical ledger rows';
  end if;
end $$;

-- Branch-scoped RLS for GM A
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'godown'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'godown'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

do $$
declare
  visible_fixture integer;
  cross_branch integer;
begin
  select count(*)::integer into visible_fixture
  from public.stock_lots
  where product_id = current_setting('sherlyos.product')::uuid
    and status = 'legacy_unattributed';

  if visible_fixture <> 1 then
    raise exception 'GM A should see fixture product lot on branch A, got %', visible_fixture;
  end if;

  select count(*)::integer into cross_branch
  from public.stock_lots
  where product_id = current_setting('sherlyos.product2')::uuid
    and status = 'legacy_unattributed';

  if cross_branch <> 0 then
    raise exception 'GM A must not see branch B fixture lot';
  end if;
end $$;

reset role;

-- Post-seed aggregate-only opening blocked
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

do $$
begin
  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.product')::uuid,
      current_setting('sherlyos.crate_b')::uuid,
      1,
      'p43e1-open-blocked-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
      'should block'
    );
    raise exception 'opening after seed should be blocked';
  exception
    when sqlstate '55000' then null;
  end;
end $$;

-- Transfer also blocked (uses apply_stock_delta)
do $$
declare
  other_crate uuid;
begin
  -- create second crate in same godown A as table owner path via admin RPCs
  other_crate := public.create_crate(current_setting('sherlyos.zone_a')::uuid, 'c43e1a2', 'C43E1A2', null);

  begin
    perform public.post_crate_transfer(
      current_setting('sherlyos.product')::uuid,
      current_setting('sherlyos.crate_a')::uuid,
      other_crate,
      1,
      'p43e1-xfer-blocked-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
      'should block'
    );
    raise exception 'transfer after seed should be blocked';
  exception
    when sqlstate '55000' then null;
  end;
end $$;

reset role;

-- Conservation mismatch on retry (never silent skip)
-- Drift lot balance as table owner (aggregate + marker unchanged).
do $$
declare
  marker_crate uuid := current_setting('sherlyos.crate_a')::uuid;
  marker_product uuid := current_setting('sherlyos.product')::uuid;
  target_lot uuid;
begin
  select lot_id into target_lot
  from public.stock_legacy_lot_seeds
  where crate_id = marker_crate
    and product_id = marker_product;

  update public.stock_lot_balances
  set quantity = quantity + 1
  where lot_id = target_lot
    and crate_id = marker_crate;
end $$;

select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

do $$
begin
  begin
    perform public.seed_legacy_stock_lots();
    raise exception 'seed retry should fail on conservation mismatch';
  exception
    when sqlstate '23514' then
      if sqlerrm not ilike '%reconciliation failed%' then
        raise exception 'expected reconciliation error, got %', sqlerrm;
      end if;
  end;
end $$;

reset role;

-- Restore drifted qty so rollback cleanliness is irrelevant (txn rolls back anyway)

select 'phase_4_3e1_legacy_lot_seeding ok' as result;

rollback;
