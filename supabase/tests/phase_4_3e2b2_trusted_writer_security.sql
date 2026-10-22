-- Phase 4.3E.2B.2 local disposable security + conservation checks. Rolls back.

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
  fixture.name || '.phase43e2b2@example.com',
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
      values ((select id from fixture where name = 'admin'), 'Phase 4.3E.2B.2 Admin', true)
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
    when 'keeper' then 'store_keeper'
    when 'accounts' then 'accounts'
  end
where fixture.name in ('godown', 'keeper', 'accounts')
on conflict do nothing;

do $$
begin
  if (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled')
    is distinct from 'false'::jsonb
    or (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked')
    is distinct from 'false'::jsonb
  then
    raise exception 'cutover flags must remain false';
  end if;
end $$;

select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select set_config('sherlyos.branch', public.create_branch('p43e2b2_a', 'Phase 4.3E.2B.2 A')::text, true);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select set_config(
  'sherlyos.zone',
  public.create_zone(current_setting('sherlyos.branch')::uuid, 'z43e2b2', 'Z43E2B2', null)::text,
  true
);
select set_config(
  'sherlyos.crate_a',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'c43e2b2a', 'C43E2B2A', null)::text,
  true
);
select set_config(
  'sherlyos.crate_b',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'c43e2b2b', 'C43E2B2B', null)::text,
  true
);
select set_config(
  'sherlyos.product',
  public.create_product('p43e2b2', 'Phase 4.3E.2B.2 Product', null, null)::text,
  true
);
select set_config(
  'sherlyos.product_b',
  public.create_product('p43e2b2-b', 'Phase 4.3E.2B.2 Product B', null, null)::text,
  true
);
select set_config(
  'sherlyos.product_seed',
  public.create_product('p43e2b2-seed', 'Phase 4.3E.2B.2 Seed Product', null, null)::text,
  true
);
select public.set_product_expiry_policy(current_setting('sherlyos.product')::uuid, 'expiry_controlled');
select public.set_product_expiry_policy(current_setting('sherlyos.product_b')::uuid, 'expiry_controlled');

-- Aggregate opening for seed grain (NULL-lot historical)
do $$
declare
  posted jsonb;
begin
  posted := public.post_opening_stock(
    current_setting('sherlyos.product_seed')::uuid,
    current_setting('sherlyos.crate_b')::uuid,
    7,
    'p43e2b2-seed-open-' || substr(gen_random_uuid()::text, 1, 8),
    null
  );
  if posted ->> 'id' is null then
    raise exception 'seed opening failed';
  end if;
end $$;

-- 5–6. Non-admin seed denied; admin seed + marker baseline
do $$
begin
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'keeper'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = 'keeper'), 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.seed_legacy_stock_lots();
    raise exception 'non-admin seed must fail';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

do $$
declare
  result jsonb;
  marker_lot uuid;
  baseline integer;
begin
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
    true
  );

  result := public.seed_legacy_stock_lots();
  if (result ->> 'seeded')::integer < 1 then
    raise exception 'expected seed to create lots got %', result;
  end if;

  select lot_id, quantity into marker_lot, baseline
  from public.stock_legacy_lot_seeds
  where crate_id = current_setting('sherlyos.crate_b')::uuid
    and product_id = current_setting('sherlyos.product_seed')::uuid;

  if marker_lot is null or baseline is distinct from 7 then
    raise exception 'seed marker missing';
  end if;

  set constraints all immediate;
  set constraints all deferred;
  perform set_config('sherlyos.legacy_lot', marker_lot::text, true);
  perform set_config('sherlyos.legacy_baseline', baseline::text, true);
end $$;

-- Unfreeze aggregate-only for remaining tests in this rolled-back transaction
reset role;
update public.app_configuration
set value = 'false'::jsonb
where key = 'stock.lots.aggregate_only_blocked';

-- Lots for helper / spoof tests (table-owner fixture inserts)
do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  branch uuid := current_setting('sherlyos.branch')::uuid;
  product uuid := current_setting('sherlyos.product')::uuid;
  lot_avail uuid;
begin
  insert into public.stock_lots (
    product_id, branch_id, manufacturer_lot_code, expiry_date, received_on,
    status, origin, created_by
  ) values (
    product, branch, 'AVAIL', current_date + 90, clock_timestamp(),
    'available', 'receipt', admin_id
  ) returning id into lot_avail;

  perform set_config('sherlyos.lot_avail', lot_avail::text, true);
  perform set_config('sherlyos.admin', admin_id::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 1–2. Forged GUC by authenticated; cannot call begin_lot_balance_write
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);

do $$
declare
  lot uuid := current_setting('sherlyos.lot_avail')::uuid;
  crate uuid := current_setting('sherlyos.crate_a')::uuid;
begin
  perform set_config('app.lot_balance_write', 'helper', true);
  begin
    insert into public.stock_lot_balances (lot_id, crate_id, quantity)
    values (lot, crate, 1);
    raise exception 'forged GUC must not authorize insert';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
  end;

  begin
    perform app_private.begin_lot_balance_write('helper');
    raise exception 'authenticated must not execute begin_lot_balance_write';
  exception
    when insufficient_privilege then null;
    when undefined_function then null;
    when sqlstate '42501' then null;
  end;
end $$;

reset role;

-- ---------------------------------------------------------------------------
-- 3. Direct DML denial: owner-without-permit / anon / service_role
-- ---------------------------------------------------------------------------

do $$
declare
  lot uuid := current_setting('sherlyos.lot_avail')::uuid;
  crate uuid := current_setting('sherlyos.crate_a')::uuid;
begin
  begin
    insert into public.stock_lot_balances (lot_id, crate_id, quantity)
    values (lot, crate, 1);
    raise exception 'postgres without permit must be denied by write gate';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

set local role anon;
do $$
declare
  lot uuid := current_setting('sherlyos.lot_avail')::uuid;
  crate uuid := current_setting('sherlyos.crate_a')::uuid;
begin
  begin
    insert into public.stock_lot_balances (lot_id, crate_id, quantity) values (lot, crate, 1);
    raise exception 'anon insert must fail';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
  end;
end $$;
reset role;

set local role service_role;
do $$
declare
  lot uuid := current_setting('sherlyos.lot_avail')::uuid;
  crate uuid := current_setting('sherlyos.crate_a')::uuid;
begin
  begin
    insert into public.stock_lot_balances (lot_id, crate_id, quantity) values (lot, crate, 1);
    raise exception 'service_role insert must fail';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
  end;
  begin
    update public.stock_lot_balances set quantity = quantity + 1;
    raise exception 'service_role update must fail';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
  end;
  begin
    delete from public.stock_lot_balances;
    raise exception 'service_role delete must fail';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
  end;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 4 + 6 + 7. Legitimate helper, fingerprint, attributed conservation + transfer
-- ---------------------------------------------------------------------------

do $$
declare
  admin_id uuid := current_setting('sherlyos.admin')::uuid;
  product uuid := current_setting('sherlyos.product')::uuid;
  crate_a uuid := current_setting('sherlyos.crate_a')::uuid;
  crate_b uuid := current_setting('sherlyos.crate_b')::uuid;
  lot uuid := current_setting('sherlyos.lot_avail')::uuid;
  txn uuid;
  lot_qty integer;
  ledger_fp text;
  applied_fp text;
  total integer;
begin
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    product_id, destination_crate_id, quantity
  ) values (
    'OPENING_STOCK', 'P43E2B2-OK', admin_id,
    'p43e2b2-ok-' || substr(gen_random_uuid()::text, 1, 8),
    'fp-ok', product, crate_a, 5
  ) returning id into txn;

  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
  ) values (txn, product, crate_a, 5, admin_id, clock_timestamp(), lot);

  perform app_private.apply_lot_aware_stock_deltas(
    txn,
    jsonb_build_array(jsonb_build_object(
      'product_id', product, 'lot_id', lot, 'crate_id', crate_a, 'quantity', 5
    ))
  );

  select quantity into lot_qty from public.stock_lot_balances where lot_id = lot and crate_id = crate_a;
  if lot_qty is distinct from 5 then
    raise exception 'helper write failed qty=%', lot_qty;
  end if;

  ledger_fp := app_private.ledger_lot_fingerprint(txn);
  select delta_fingerprint into applied_fp
  from public.stock_lot_aware_applications where transaction_id = txn;
  if ledger_fp is distinct from applied_fp then
    raise exception 'fingerprint mismatch';
  end if;

  perform set_config('sherlyos.txn_ok', txn::text, true);

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    product_id, source_crate_id, destination_crate_id, quantity
  ) values (
    'CRATE_TRANSFER', 'P43E2B2-XFER', admin_id,
    'p43e2b2-xf-' || substr(gen_random_uuid()::text, 1, 8),
    'fp-xf', product, crate_a, crate_b, 2
  ) returning id into txn;

  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
  ) values
    (txn, product, crate_a, -2, admin_id, clock_timestamp(), lot),
    (txn, product, crate_b, 2, admin_id, clock_timestamp(), lot);

  perform app_private.apply_lot_aware_stock_deltas(
    txn,
    jsonb_build_array(
      jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate_a, 'quantity', -2),
      jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate_b, 'quantity', 2)
    )
  );

  select coalesce(sum(quantity), 0) into total
  from public.stock_lot_balances where lot_id = lot;
  if total is distinct from 5 then
    raise exception 'attributed transfer conservation failed got %', total;
  end if;

  set constraints all immediate;
  set constraints all deferred;
end $$;

-- 9. Duplicate apply
do $$
begin
  begin
    perform app_private.apply_lot_aware_stock_deltas(
      current_setting('sherlyos.txn_ok')::uuid,
      jsonb_build_array(jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'lot_id', current_setting('sherlyos.lot_avail')::uuid,
        'crate_id', current_setting('sherlyos.crate_a')::uuid,
        'quantity', 5
      ))
    );
    raise exception 'duplicate apply must fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- 10. Failed apply then retry
do $$
declare
  admin_id uuid := current_setting('sherlyos.admin')::uuid;
  product uuid := current_setting('sherlyos.product_b')::uuid;
  crate uuid := current_setting('sherlyos.crate_b')::uuid;
  branch uuid := current_setting('sherlyos.branch')::uuid;
  lot uuid;
  txn uuid;
begin
  insert into public.stock_lots (
    product_id, branch_id, manufacturer_lot_code, expiry_date, received_on,
    status, origin, created_by
  ) values (
    product, branch, 'RETRY', current_date + 40, clock_timestamp(),
    'available', 'receipt', admin_id
  ) returning id into lot;

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    product_id, destination_crate_id, quantity
  ) values (
    'OPENING_STOCK', 'P43E2B2-RETRY', admin_id,
    'p43e2b2-rt-' || substr(gen_random_uuid()::text, 1, 8),
    'fp-rt', product, crate, 3
  ) returning id into txn;

  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
  ) values (txn, product, crate, 3, admin_id, clock_timestamp(), lot);

  begin
    perform app_private.apply_lot_aware_stock_deltas(
      txn,
      jsonb_build_array(jsonb_build_object(
        'product_id', product, 'lot_id', lot, 'crate_id', crate, 'quantity', 99
      ))
    );
    raise exception 'bad qty should fail before commit';
  exception
    when sqlstate '23514' then null;
  end;

  perform app_private.apply_lot_aware_stock_deltas(
    txn,
    jsonb_build_array(jsonb_build_object(
      'product_id', product, 'lot_id', lot, 'crate_id', crate, 'quantity', 3
    ))
  );

  if not exists (
    select 1 from public.stock_lot_balances where lot_id = lot and quantity = 3
  ) then
    raise exception 'retry apply failed';
  end if;

  set constraints all immediate;
  set constraints all deferred;
end $$;

-- Legacy conservation: lot-ledger transfer on seeded lot; NULL-lot ignored
do $$
declare
  admin_id uuid := current_setting('sherlyos.admin')::uuid;
  product uuid := current_setting('sherlyos.product_seed')::uuid;
  crate_a uuid := current_setting('sherlyos.crate_a')::uuid;
  crate_b uuid := current_setting('sherlyos.crate_b')::uuid;
  lot uuid := current_setting('sherlyos.legacy_lot')::uuid;
  baseline integer := current_setting('sherlyos.legacy_baseline')::integer;
  txn uuid;
  total integer;
begin
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    product_id, source_crate_id, destination_crate_id, quantity
  ) values (
    'CRATE_TRANSFER', 'P43E2B2-LEGXF', admin_id,
    'p43e2b2-lx-' || substr(gen_random_uuid()::text, 1, 8),
    'fp-lx', product, crate_b, crate_a, 2
  ) returning id into txn;

  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
  ) values
    (txn, product, crate_b, -2, admin_id, clock_timestamp(), lot),
    (txn, product, crate_a, 2, admin_id, clock_timestamp(), lot);

  perform app_private.apply_lot_aware_stock_deltas(
    txn,
    jsonb_build_array(
      jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate_b, 'quantity', -2),
      jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate_a, 'quantity', 2)
    )
  );

  select coalesce(sum(quantity), 0) into total
  from public.stock_lot_balances where lot_id = lot;

  if total is distinct from baseline then
    raise exception 'legacy conservation failed total=% baseline=%', total, baseline;
  end if;

  set constraints all immediate;
  set constraints all deferred;
end $$;

-- 12. Aggregate-only posting compatibility (NULL-lot opening path)
do $$
declare
  admin_id uuid := current_setting('sherlyos.admin')::uuid;
  crate uuid := current_setting('sherlyos.crate_a')::uuid;
  product uuid;
  posted jsonb;
begin
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  set local role authenticated;
  product := public.create_product('p43e2b2-agg', 'Phase 4.3E.2B.2 Aggregate Product', null, null);

  posted := public.post_opening_stock(
    product,
    crate,
    4,
    'p43e2b2-agg-open-' || substr(gen_random_uuid()::text, 1, 8),
    null
  );
  reset role;

  if posted ->> 'id' is null then
    raise exception 'aggregate-only opening failed';
  end if;
  if exists (
    select 1 from public.stock_ledger
    where stock_ledger.transaction_id = (posted ->> 'id')::uuid
      and stock_ledger.lot_id is not null
  ) then
    raise exception 'aggregate-only opening must remain NULL-lot';
  end if;
end $$;

-- 8. Wrong product/lot mapping (last: leaves orphan lot_id ledger; outer rollback discards)
do $$
declare
  admin_id uuid := current_setting('sherlyos.admin')::uuid;
  product_b uuid := current_setting('sherlyos.product_b')::uuid;
  crate uuid := current_setting('sherlyos.crate_a')::uuid;
  lot uuid := current_setting('sherlyos.lot_avail')::uuid;
  txn uuid;
begin
  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    product_id, destination_crate_id, quantity
  ) values (
    'OPENING_STOCK', 'P43E2B2-BADMAP', admin_id,
    'p43e2b2-bm-' || substr(gen_random_uuid()::text, 1, 8),
    'fp-bm', product_b, crate, 1
  ) returning id into txn;

  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
  ) values (txn, product_b, crate, 1, admin_id, clock_timestamp(), lot);

  begin
    perform app_private.apply_lot_aware_stock_deltas(
      txn,
      jsonb_build_array(jsonb_build_object(
        'product_id', product_b, 'lot_id', lot, 'crate_id', crate, 'quantity', 1
      ))
    );
    raise exception 'wrong product/lot mapping must fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

do $$ begin raise notice 'PASS phase_4_3e2b2_trusted_writer_security'; end $$;

rollback;
