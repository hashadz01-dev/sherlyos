-- Phase 4.3E.2B.1 local disposable checks. Transaction rolls back.
-- Ledger match, deferred integrity, status matrix, attribution, seed compatibility.

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
  fixture.name || '.phase43e2b1@example.com',
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
      values ((select id from fixture where name = 'admin'), 'Phase 4.3E.2B.1 Admin', true)
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

-- Flags remain disabled
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

select set_config('sherlyos.branch', public.create_branch('p43e2b1_a', 'Phase 4.3E.2B.1 A')::text, true);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select set_config(
  'sherlyos.zone',
  public.create_zone(current_setting('sherlyos.branch')::uuid, 'z43e2b1', 'Z43E2B1', null)::text,
  true
);
select set_config(
  'sherlyos.crate',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'c43e2b1', 'C43E2B1', null)::text,
  true
);
select set_config(
  'sherlyos.crate_b',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'c43e2b1b', 'C43E2B1B', null)::text,
  true
);
select set_config(
  'sherlyos.product',
  public.create_product('p43e2b1', 'Phase 4.3E.2B.1 Product', null, null)::text,
  true
);
select set_config(
  'sherlyos.product_seed',
  public.create_product('p43e2b1-seed', 'Phase 4.3E.2B.1 Seed Product', null, null)::text,
  true
);
select set_config(
  'sherlyos.product_b',
  public.create_product('p43e2b1-b', 'Phase 4.3E.2B.1 Product B', null, null)::text,
  true
);
select set_config(
  'sherlyos.product_c',
  public.create_product('p43e2b1-c', 'Phase 4.3E.2B.1 Product C', null, null)::text,
  true
);
select public.set_product_expiry_policy(current_setting('sherlyos.product')::uuid, 'expiry_controlled');
select public.set_product_expiry_policy(current_setting('sherlyos.product_b')::uuid, 'expiry_controlled');
select public.set_product_expiry_policy(current_setting('sherlyos.product_c')::uuid, 'expiry_controlled');
select set_config(
  'sherlyos.supplier',
  public.create_supplier('Phase 4.3E.2B.1 Supplier', null, null)::text,
  true
);

-- Historical NULL-lot compatibility via aggregate opening
do $$
declare
  posted jsonb;
begin
  posted := public.post_opening_stock(
    current_setting('sherlyos.product_seed')::uuid,
    current_setting('sherlyos.crate')::uuid,
    12,
    'p43e2b1-null-lot-' || substr(gen_random_uuid()::text, 1, 8),
    null
  );
  if posted ->> 'id' is null then
    raise exception 'NULL-lot opening compatibility failed';
  end if;
  if exists (
    select 1 from public.stock_ledger
    where stock_ledger.transaction_id = (posted ->> 'id')::uuid
      and stock_ledger.lot_id is not null
  ) then
    raise exception 'opening must remain NULL-lot until dual-write cutover';
  end if;
end $$;

-- Dual-write enable (later) requires classified positive-stock products.
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

-- Legacy seed while grains still match historical aggregate opening
do $$
declare
  result jsonb;
  seed_product uuid := current_setting('sherlyos.product_seed')::uuid;
  crate uuid := current_setting('sherlyos.crate')::uuid;
  lot_sum integer;
  agg integer;
begin
  result := public.seed_legacy_stock_lots();
  if (result ->> 'aggregate_only_blocked')::boolean is not true then
    raise exception 'seed should set aggregate_only_blocked';
  end if;
  if (result ->> 'dual_write_enabled')::boolean is not false then
    raise exception 'seed must leave dual_write false';
  end if;

  select quantity into agg
  from public.stock_balances
  where crate_id = crate and product_id = seed_product;

  select coalesce(sum(stock_lot_balances.quantity), 0) into lot_sum
  from public.stock_lot_balances
  join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
  where stock_lot_balances.crate_id = crate
    and stock_lots.product_id = seed_product;

  if lot_sum is distinct from agg then
    raise exception 'seed conservation failed lot=% agg=%', lot_sum, agg;
  end if;
end $$;

reset role;

do $$
begin
  begin
    update public.app_configuration
    set value = 'false'::jsonb
    where key = 'stock.lots.aggregate_only_blocked';
    raise exception 'unfreeze after seed must be rejected';
  exception
    when sqlstate '55000' then
      null;
  end;
end $$;

-- Remaining posting in this file uses lot-aware verify; enable dual-write now.
update public.app_configuration
set value = 'true'::jsonb
where key = 'stock.lots.dual_write_enabled';

-- Lots for helper tests
do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  branch uuid := current_setting('sherlyos.branch')::uuid;
  product uuid := current_setting('sherlyos.product')::uuid;
  lot_avail uuid;
  lot_legacy uuid;
  lot_quar uuid;
  lot_exp uuid;
begin
  insert into public.stock_lots (
    product_id, branch_id, manufacturer_lot_code, expiry_date, received_on,
    status, origin, created_by
  ) values
    (product, branch, 'AVAIL', current_date + 90, clock_timestamp(), 'available', 'receipt', admin_id)
  returning id into lot_avail;

  insert into public.stock_lots (
    product_id, branch_id, manufacturer_lot_code, expiry_date, received_on,
    status, origin, created_by
  ) values
    (product, branch, null, null, null, 'legacy_unattributed', 'legacy_reconciliation', admin_id)
  returning id into lot_legacy;

  insert into public.stock_lots (
    product_id, branch_id, manufacturer_lot_code, expiry_date, received_on,
    status, origin, created_by
  ) values
    (product, branch, 'QUAR', current_date + 90, clock_timestamp(), 'quarantined', 'receipt', admin_id)
  returning id into lot_quar;

  insert into public.stock_lots (
    product_id, branch_id, manufacturer_lot_code, expiry_date, received_on,
    status, origin, created_by
  ) values
    (product, branch, 'EXP', current_date - 1, clock_timestamp(), 'expired_blocked', 'receipt', admin_id)
  returning id into lot_exp;

  perform set_config('sherlyos.lot_avail', lot_avail::text, true);
  perform set_config('sherlyos.lot_legacy', lot_legacy::text, true);
  perform set_config('sherlyos.lot_quar', lot_quar::text, true);
  perform set_config('sherlyos.lot_exp', lot_exp::text, true);
end $$;

-- Helper: correct ledger match
do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  product uuid := current_setting('sherlyos.product')::uuid;
  crate uuid := current_setting('sherlyos.crate')::uuid;
  lot uuid := current_setting('sherlyos.lot_avail')::uuid;
  txn uuid;
  agg integer;
  lot_qty integer;
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
    'OPENING_STOCK', 'P43E2B1-OK', admin_id,
    'p43e2b1-ok-' || substr(gen_random_uuid()::text, 1, 8),
    'fp-ok', product, crate, 5
  ) returning id into txn;

  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
  ) values (txn, product, crate, 5, admin_id, clock_timestamp(), lot);

  perform app_private.apply_lot_aware_stock_deltas(
    txn,
    jsonb_build_array(jsonb_build_object(
      'product_id', product, 'lot_id', lot, 'crate_id', crate, 'quantity', 5
    ))
  );

  select quantity into agg from public.stock_balances where crate_id = crate and product_id = product;
  select quantity into lot_qty from public.stock_lot_balances where lot_id = lot and crate_id = crate;
  if agg is distinct from 5 or lot_qty is distinct from 5 then
    raise exception 'match apply failed agg=% lot=%', agg, lot_qty;
  end if;

  perform set_config('sherlyos.txn_ok', txn::text, true);
end $$;

-- Repeated helper invocation
do $$
begin
  begin
    perform app_private.apply_lot_aware_stock_deltas(
      current_setting('sherlyos.txn_ok')::uuid,
      jsonb_build_array(jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'lot_id', current_setting('sherlyos.lot_avail')::uuid,
        'crate_id', current_setting('sherlyos.crate')::uuid,
        'quantity', 5
      ))
    );
    raise exception 'repeat apply should fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Missing lot_id on ledger
do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  product uuid := current_setting('sherlyos.product_b')::uuid;
  crate uuid := current_setting('sherlyos.crate')::uuid;
  lot uuid := current_setting('sherlyos.lot_avail')::uuid;
  txn uuid;
begin
  begin
    insert into public.stock_transactions (
      transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
      product_id, destination_crate_id, quantity
    ) values (
      'OPENING_STOCK', 'P43E2B1-NULLLOT', admin_id,
      'p43e2b1-nl-' || substr(gen_random_uuid()::text, 1, 8),
      'fp-nl', product, crate, 1
    ) returning id into txn;

    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
    ) values (txn, product, crate, 1, admin_id, clock_timestamp(), null);

    perform app_private.apply_lot_aware_stock_deltas(
      txn,
      jsonb_build_array(jsonb_build_object(
        'product_id', product, 'lot_id', lot, 'crate_id', crate, 'quantity', 1
      ))
    );
    raise exception 'null lot_id ledger should fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Wrong lot / qty mismatch
do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  product uuid := current_setting('sherlyos.product_c')::uuid;
  crate uuid := current_setting('sherlyos.crate')::uuid;
  txn uuid;
  lot_b uuid;
begin
  insert into public.stock_lots (
    product_id, branch_id, manufacturer_lot_code, expiry_date, received_on,
    status, origin, created_by
  ) values (
    product, current_setting('sherlyos.branch')::uuid, 'C-LOT', current_date + 30,
    clock_timestamp(), 'available', 'receipt', admin_id
  ) returning id into lot_b;

  begin
    insert into public.stock_transactions (
      transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
      product_id, destination_crate_id, quantity
    ) values (
      'OPENING_STOCK', 'P43E2B1-MISMATCH', admin_id,
      'p43e2b1-mm-' || substr(gen_random_uuid()::text, 1, 8),
      'fp-mm', product, crate, 2
    ) returning id into txn;

    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
    ) values (txn, product, crate, 2, admin_id, clock_timestamp(), lot_b);

    perform app_private.apply_lot_aware_stock_deltas(
      txn,
      jsonb_build_array(jsonb_build_object(
        'product_id', product, 'lot_id', lot_b, 'crate_id', crate, 'quantity', 9
      ))
    );
    raise exception 'qty mismatch should fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Duplicate delta rejection (no ledger needed — fails during normalize)
do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  product uuid := current_setting('sherlyos.product')::uuid;
  crate uuid := current_setting('sherlyos.crate')::uuid;
  lot uuid := current_setting('sherlyos.lot_avail')::uuid;
  txn uuid;
begin
  -- Reuse already-applied txn id shape: create a throwaway txn without opening uniqueness conflict
  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    product_id, source_crate_id, destination_crate_id, quantity
  ) values (
    'CRATE_TRANSFER', 'P43E2B1-DUP', admin_id,
    'p43e2b1-dup-' || substr(gen_random_uuid()::text, 1, 8),
    'fp-dup', product, crate, current_setting('sherlyos.crate_b')::uuid, 2
  ) returning id into txn;

  begin
    perform app_private.apply_lot_aware_stock_deltas(
      txn,
      jsonb_build_array(
        jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate, 'quantity', 1),
        jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate, 'quantity', 1)
      )
    );
    raise exception 'duplicate deltas should fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Zero and malformed quantities
do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  product uuid := current_setting('sherlyos.product')::uuid;
  crate uuid := current_setting('sherlyos.crate')::uuid;
  lot uuid := current_setting('sherlyos.lot_avail')::uuid;
  txn uuid;
begin
  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    product_id, source_crate_id, destination_crate_id, quantity
  ) values (
    'CRATE_TRANSFER', 'P43E2B1-ZERO', admin_id,
    'p43e2b1-z-' || substr(gen_random_uuid()::text, 1, 8),
    'fp-z', product, crate, current_setting('sherlyos.crate_b')::uuid, 1
  ) returning id into txn;

  begin
    perform app_private.apply_lot_aware_stock_deltas(
      txn,
      jsonb_build_array(jsonb_build_object(
        'product_id', product, 'lot_id', lot, 'crate_id', crate, 'quantity', 0
      ))
    );
    raise exception 'zero qty should fail';
  exception
    when sqlstate '23514' then null;
  end;

  begin
    perform app_private.apply_lot_aware_stock_deltas(
      txn,
      jsonb_build_array(jsonb_build_object(
        'product_id', product, 'lot_id', lot, 'crate_id', crate, 'quantity', 'nope'
      ))
    );
    raise exception 'malformed qty should fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Quarantined rejection (CRATE_TRANSFER ledger shape)
do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  product uuid := current_setting('sherlyos.product')::uuid;
  crate uuid := current_setting('sherlyos.crate')::uuid;
  crate_b uuid := current_setting('sherlyos.crate_b')::uuid;
  lot uuid := current_setting('sherlyos.lot_quar')::uuid;
  txn uuid;
begin
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );

  begin
    insert into public.stock_transactions (
      transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
      product_id, source_crate_id, destination_crate_id, quantity
    ) values (
      'CRATE_TRANSFER', 'P43E2B1-QUAR', admin_id,
      'p43e2b1-q-' || substr(gen_random_uuid()::text, 1, 8),
      'fp-q', product, crate, crate_b, 1
    ) returning id into txn;

    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
    ) values
      (txn, product, crate, -1, admin_id, clock_timestamp(), lot),
      (txn, product, crate_b, 1, admin_id, clock_timestamp(), lot);

    perform app_private.apply_lot_aware_stock_deltas(
      txn,
      jsonb_build_array(
        jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate, 'quantity', -1),
        jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate_b, 'quantity', 1)
      )
    );
    raise exception 'quarantined lot should fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Legacy lot without reconcile permission (godown)
do $$
declare
  godown_id uuid := (select id from fixture where name = 'godown');
  product uuid := current_setting('sherlyos.product')::uuid;
  crate uuid := current_setting('sherlyos.crate')::uuid;
  crate_b uuid := current_setting('sherlyos.crate_b')::uuid;
  lot uuid := current_setting('sherlyos.lot_legacy')::uuid;
  txn uuid;
begin
  perform set_config('request.jwt.claim.sub', godown_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', godown_id, 'role', 'authenticated')::text,
    true
  );

  begin
    insert into public.stock_transactions (
      transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
      product_id, source_crate_id, destination_crate_id, quantity
    ) values (
      'CRATE_TRANSFER', 'P43E2B1-LEG', godown_id,
      'p43e2b1-lg-' || substr(gen_random_uuid()::text, 1, 8),
      'fp-lg', product, crate, crate_b, 1
    ) returning id into txn;

    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
    ) values
      (txn, product, crate, -1, godown_id, clock_timestamp(), lot),
      (txn, product, crate_b, 1, godown_id, clock_timestamp(), lot);

    perform app_private.apply_lot_aware_stock_deltas(
      txn,
      jsonb_build_array(
        jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate, 'quantity', -1),
        jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate_b, 'quantity', 1)
      )
    );
    raise exception 'legacy without reconcile should fail';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Legacy lot with Admin reconcile: credit onto legacy lot via transfer from available lot path
-- Use inbound OPENING on a dedicated product for legacy lot credit
do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  product uuid := current_setting('sherlyos.product_b')::uuid;
  crate uuid := current_setting('sherlyos.crate_b')::uuid;
  lot uuid;
  txn uuid;
begin
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );

  insert into public.stock_lots (
    product_id, branch_id, status, origin, created_by
  ) values (
    product, current_setting('sherlyos.branch')::uuid,
    'legacy_unattributed', 'legacy_reconciliation', admin_id
  ) returning id into lot;

  -- product_b already used OPENING in null-lot failure path without applying balances;
  -- that txn may still exist. Use crate_b for a fresh opening key.
  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    product_id, destination_crate_id, quantity
  ) values (
    'OPENING_STOCK', 'P43E2B1-LEGOK', admin_id,
    'p43e2b1-lgo-' || substr(gen_random_uuid()::text, 1, 8),
    'fp-lgo', product, crate, 1
  ) returning id into txn;

  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
  ) values (txn, product, crate, 1, admin_id, clock_timestamp(), lot);

  perform app_private.apply_lot_aware_stock_deltas(
    txn,
    jsonb_build_array(jsonb_build_object(
      'product_id', product, 'lot_id', lot, 'crate_id', crate, 'quantity', 1
    ))
  );
end $$;

-- Negative stock prevention via transfer debit exceeding balance
do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  product uuid := current_setting('sherlyos.product')::uuid;
  crate uuid := current_setting('sherlyos.crate')::uuid;
  crate_b uuid := current_setting('sherlyos.crate_b')::uuid;
  lot uuid := current_setting('sherlyos.lot_avail')::uuid;
  txn uuid;
begin
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );

  begin
    insert into public.stock_transactions (
      transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
      product_id, source_crate_id, destination_crate_id, quantity
    ) values (
      'CRATE_TRANSFER', 'P43E2B1-NEG', admin_id,
      'p43e2b1-neg-' || substr(gen_random_uuid()::text, 1, 8),
      'fp-neg', product, crate, crate_b, 100
    ) returning id into txn;

    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
    ) values
      (txn, product, crate, -100, admin_id, clock_timestamp(), lot),
      (txn, product, crate_b, 100, admin_id, clock_timestamp(), lot);

    perform app_private.apply_lot_aware_stock_deltas(
      txn,
      jsonb_build_array(
        jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate, 'quantity', -100),
        jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate_b, 'quantity', 100)
      )
    );
    raise exception 'negative lot stock should fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Same-lot sequential transfers conserve total across crates
do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  product uuid := current_setting('sherlyos.product')::uuid;
  crate uuid := current_setting('sherlyos.crate')::uuid;
  crate_b uuid := current_setting('sherlyos.crate_b')::uuid;
  lot uuid := current_setting('sherlyos.lot_avail')::uuid;
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
    'CRATE_TRANSFER', 'P43E2B1-C1', admin_id,
    'p43e2b1-c1-' || substr(gen_random_uuid()::text, 1, 8),
    'fp-c1', product, crate, crate_b, 2
  ) returning id into txn;

  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
  ) values
    (txn, product, crate, -2, admin_id, clock_timestamp(), lot),
    (txn, product, crate_b, 2, admin_id, clock_timestamp(), lot);

  perform app_private.apply_lot_aware_stock_deltas(
    txn,
    jsonb_build_array(
      jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate, 'quantity', -2),
      jsonb_build_object('product_id', product, 'lot_id', lot, 'crate_id', crate_b, 'quantity', 2)
    )
  );

  select coalesce(sum(quantity), 0) into total
  from public.stock_lot_balances where lot_id = lot;

  if total is distinct from 5 then
    raise exception 'same-lot transfer conservation failed got %', total;
  end if;
end $$;

-- Deferred: lot_id ledger without helper application fails
do $$
declare
  admin_id uuid := (select id from fixture where name = 'admin');
  product uuid := current_setting('sherlyos.product_c')::uuid;
  crate uuid := current_setting('sherlyos.crate_b')::uuid;
  lot uuid;
  txn uuid;
begin
  insert into public.stock_lots (
    product_id, branch_id, manufacturer_lot_code, expiry_date, received_on,
    status, origin, created_by
  ) values (
    product, current_setting('sherlyos.branch')::uuid, 'ORPH', current_date + 10,
    clock_timestamp(), 'available', 'receipt', admin_id
  ) returning id into lot;

  begin
    insert into public.stock_transactions (
      transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
      product_id, destination_crate_id, quantity
    ) values (
      'OPENING_STOCK', 'P43E2B1-ORPHAN', admin_id,
      'p43e2b1-or-' || substr(gen_random_uuid()::text, 1, 8),
      'fp-or', product, crate, 1
    ) returning id into txn;

    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
    ) values (txn, product, crate, 1, admin_id, clock_timestamp(), lot);

    set constraints all immediate;

    raise exception 'orphan lot_id ledger should fail deferred check';
  exception
    when sqlstate '23514' then
      set constraints all deferred;
  end;
end $$;

-- Attribution: malformed qty → 23514; admin denied; fingerprint metadata change
set local role authenticated;
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'keeper'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'keeper'), 'role', 'authenticated')::text,
  true
);

do $$
declare
  receipt jsonb;
  selected_receipt uuid;
  line_id uuid;
  fp1 text;
  fp2 text;
begin
  receipt := public.create_stock_receipt(
    current_setting('sherlyos.branch')::uuid,
    current_setting('sherlyos.supplier')::uuid,
    'P43E2B1-ATTR-' || substr(gen_random_uuid()::text, 1, 8),
    current_date,
    null,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'destination_crate_id', current_setting('sherlyos.crate')::uuid,
      'document_cases', 4,
      'counted_cases', 4,
      'damaged_cases', 0
    ))
  );
  selected_receipt := (receipt ->> 'id')::uuid;
  select stock_receipt_lines.id into line_id
  from public.stock_receipt_lines
  where stock_receipt_lines.receipt_id = selected_receipt;

  perform set_config('sherlyos.receipt_b1', selected_receipt::text, true);
  perform set_config('sherlyos.line_b1', line_id::text, true);

  begin
    perform public.set_stock_receipt_line_lot_attributions(
      line_id,
      jsonb_build_array(jsonb_build_object(
        'carton_quantity', 'abc',
        'expiry_date', (current_date + 10)::text
      ))
    );
    raise exception 'malformed attribution qty should be 23514';
  exception
    when sqlstate '23514' then null;
  end;

  perform public.set_stock_receipt_line_lot_attributions(
    line_id,
    jsonb_build_array(jsonb_build_object(
      'carton_quantity', 4,
      'manufacturer_lot_code', 'M1',
      'expiry_date', (current_date + 10)::text
    ))
  );
end $$;

reset role;
do $$
declare
  line_id uuid := current_setting('sherlyos.line_b1')::uuid;
  selected_receipt uuid := current_setting('sherlyos.receipt_b1')::uuid;
  fp1 text;
  fp2 text;
begin
  fp1 := app_private.receipt_posting_fingerprint(selected_receipt);
  update public.stock_receipt_line_lot_attributions
  set manufacturer_lot_code = 'M2'
  where receipt_line_id = line_id;
  fp2 := app_private.receipt_posting_fingerprint(selected_receipt);
  if fp1 is not distinct from fp2 then
    raise exception 'fingerprint must change on metadata update';
  end if;
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);

do $$
begin
  begin
    perform public.set_stock_receipt_line_lot_attributions(
      current_setting('sherlyos.line_b1')::uuid,
      '[]'::jsonb
    );
    raise exception 'admin without receiving perms should be denied';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Attribution vs verify race serialization (lock + immutability)
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'keeper'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'keeper'), 'role', 'authenticated')::text,
  true
);
select public.submit_stock_receipt(current_setting('sherlyos.receipt_b1')::uuid);

select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'godown'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'godown'), 'role', 'authenticated')::text,
  true
);
select public.verify_stock_receipt(
  current_setting('sherlyos.receipt_b1')::uuid,
  'p43e2b1-verify-' || gen_random_uuid()::text
);

do $$
begin
  begin
    perform public.set_stock_receipt_line_lot_attributions(
      current_setting('sherlyos.line_b1')::uuid,
      jsonb_build_array(jsonb_build_object(
        'carton_quantity', 4,
        'manufacturer_lot_code', 'AFTER',
        'expiry_date', (current_date + 10)::text
      ))
    );
    raise exception 'post-verify attribution should fail';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- PT409 vs 42501 on adjustments (lock helper)
reset role;
do $$
declare
  selected public.stock_adjustment_requests;
  dummy uuid := gen_random_uuid();
begin
  begin
    selected := app_private.lock_adjustment_request(dummy, 1);
    raise exception 'missing adjustment should be 42501';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Transaction rolls back; working-DB flags stay false.
rollback;
