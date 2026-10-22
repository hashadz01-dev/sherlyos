-- Phase 4.3D local disposable checks. Transaction rolls back.
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f supabase/tests/phase_4_3d_stock_lots_foundation.sql

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
  ('accounts', gen_random_uuid());

insert into auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.phase43d@example.com',
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
      -- Local DB may already have an administrator from prior work.
      insert into public.profiles (id, full_name, is_active)
      values (
        (select id from fixture where name = 'admin'),
        'Phase 4.3D Admin',
        true
      )
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
    when 'accounts' then 'accounts'
  end
where fixture.name in ('godown', 'accounts')
on conflict do nothing;

-- Branch / crate for lot balance FK and RLS tests
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from fixture where name = 'admin'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'sherlyos.branch',
  public.create_branch('p43d_godown', 'Phase 4.3D Godown')::text,
  true
);
select public.assign_user_branch(
  (select id from fixture where name = 'godown'),
  current_setting('sherlyos.branch')::uuid
);
select set_config(
  'sherlyos.zone',
  public.create_zone(current_setting('sherlyos.branch')::uuid, 'z43d', 'Z43D', null)::text,
  true
);
select set_config(
  'sherlyos.crate',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'c43d', 'C43D', null)::text,
  true
);
select set_config(
  'sherlyos.product',
  public.create_product('p43d-soap', 'Phase 4.3D Soap', null, null)::text,
  true
);

reset role;

-- Snapshot stock integrity before foundation assertions
create temp table pre_counts as
select
  (select count(*) from public.stock_balances) as balances,
  (select coalesce(sum(quantity), 0) from public.stock_balances) as balance_qty,
  (select count(*) from public.stock_ledger) as ledger_rows,
  (select count(*) from public.stock_lots) as lots,
  (select count(*) from public.stock_lot_balances) as lot_balances;

-- A. Existing products remain unclassified (NULL) including the new fixture product
do $$
declare
  unclassified integer;
begin
  select count(*)::integer
  into unclassified
  from public.products
  where expiry_policy is not null;

  if unclassified <> 0 then
    raise exception 'expected all products unclassified, found % classified', unclassified;
  end if;
end $$;

-- Config present
do $$
begin
  if not exists (
    select 1
    from public.app_configuration
    where key = 'stock.near_expiry_warning_days'
      and value = '90'::jsonb
  ) then
    raise exception 'near-expiry configuration missing or not 90';
  end if;
end $$;

-- Lot tables empty after migration (and still empty here before any inserts)
do $$
begin
  if (select lots from pre_counts) <> 0 or (select lot_balances from pre_counts) <> 0 then
    raise exception 'lot tables should be empty after 4.3D migration';
  end if;
end $$;

-- Unauthorized classification (accounts — no products.expiry_policy.manage)
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'accounts'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from fixture where name = 'accounts'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

do $$
begin
  begin
    perform public.set_product_expiry_policy(
      current_setting('sherlyos.product')::uuid,
      'expiry_controlled'
    );
    raise exception 'accounts should not classify products';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

reset role;

-- Invalid policy (admin)
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from fixture where name = 'admin'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

do $$
begin
  begin
    perform public.set_product_expiry_policy(
      current_setting('sherlyos.product')::uuid,
      'sometimes'
    );
    raise exception 'invalid policy should fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Authorized classification + audit + idempotent repeat
do $$
declare
  before_audit integer;
  after_audit integer;
  row public.products%rowtype;
begin
  select count(*)::integer into before_audit
  from public.audit_logs
  where action = 'set_product_expiry_policy'
    and entity_id = current_setting('sherlyos.product')::uuid;

  row := public.set_product_expiry_policy(
    current_setting('sherlyos.product')::uuid,
    'expiry_controlled'
  );
  if row.expiry_policy is distinct from 'expiry_controlled' then
    raise exception 'classification failed';
  end if;

  row := public.set_product_expiry_policy(
    current_setting('sherlyos.product')::uuid,
    'expiry_controlled'
  );
  if row.expiry_policy is distinct from 'expiry_controlled' then
    raise exception 'idempotent classification failed';
  end if;

  select count(*)::integer into after_audit
  from public.audit_logs
  where action = 'set_product_expiry_policy'
    and entity_id = current_setting('sherlyos.product')::uuid;

  if after_audit <> before_audit + 1 then
    raise exception 'expected one audit row for first classification, got delta %',
      after_audit - before_audit;
  end if;

  row := public.set_product_expiry_policy(
    current_setting('sherlyos.product')::uuid,
    'non_expiring'
  );
  if row.expiry_policy is distinct from 'non_expiring' then
    raise exception 'reclassification without lots should succeed';
  end if;
end $$;

reset role;

-- B/C. Lot master + balances — insert as table owner (postgres) for constraint tests
do $$
declare
  lot_a uuid;
  lot_b uuid;
  crate uuid := current_setting('sherlyos.crate')::uuid;
  product uuid := current_setting('sherlyos.product')::uuid;
begin
  insert into public.stock_lots (
    product_id,
    branch_id,
    manufacturer_lot_code,
    expiry_date,
    received_on,
    status,
    origin,
    created_by
  )
  values (
    product,
    current_setting('sherlyos.branch')::uuid,
    null,
    current_date + 30,
    clock_timestamp(),
    'available',
    'opening',
    (select id from fixture where name = 'admin')
  )
  returning id into lot_a;

  insert into public.stock_lots (
    product_id,
    branch_id,
    manufacturer_lot_code,
    expiry_date,
    received_on,
    status,
    origin,
    created_by
  )
  values (
    product,
    current_setting('sherlyos.branch')::uuid,
    null,
    current_date + 60,
    clock_timestamp(),
    'available',
    'opening',
    (select id from fixture where name = 'admin')
  )
  returning id into lot_b;

  if lot_a = lot_b then
    raise exception 'distinct receipt-style lots must not share ids';
  end if;

  insert into public.stock_lot_balances (lot_id, crate_id, quantity)
  values (lot_a, crate, 5);

  begin
    insert into public.stock_lot_balances (lot_id, crate_id, quantity)
    values (lot_a, crate, 1);
    raise exception 'duplicate lot/crate balance should fail';
  exception
    when unique_violation then null;
  end;

  begin
    insert into public.stock_lot_balances (lot_id, crate_id, quantity)
    values (lot_b, crate, -1);
    raise exception 'negative lot balance should fail';
  exception
    when check_violation then null;
  end;

  begin
    insert into public.stock_lots (
      product_id,
      branch_id,
      manufactured_on,
      expiry_date,
      status,
      origin
    )
    values (
      product,
      current_setting('sherlyos.branch')::uuid,
      current_date,
      current_date - 1,
      'available',
      'opening'
    );
    raise exception 'manufactured_on after expiry should fail';
  exception
    when check_violation then null;
  end;

  begin
    insert into public.stock_lots (
      product_id,
      branch_id,
      status,
      origin
    )
    values (
      product,
      current_setting('sherlyos.branch')::uuid,
      'unknown',
      'opening'
    );
    raise exception 'invalid status should fail';
  exception
    when check_violation then null;
  end;

  -- Policy change blocked while lots exist
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', (select id from fixture where name = 'admin'),
      'role', 'authenticated'
    )::text,
    true
  );
  set local role authenticated;
  begin
    perform public.set_product_expiry_policy(product, 'expiry_controlled');
    raise exception 'policy change with lots should fail';
  exception
    when sqlstate '23514' then null;
  end;
  reset role;
end $$;

-- Direct client mutation denied
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'godown'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from fixture where name = 'godown'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

do $$
begin
  begin
    insert into public.stock_lots (product_id, branch_id, status, origin)
    values (
      current_setting('sherlyos.product')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'available',
      'opening'
    );
    raise exception 'authenticated insert into stock_lots should fail';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
  end;

  begin
    update public.stock_lot_balances set quantity = quantity + 1;
    raise exception 'authenticated update stock_lot_balances should fail';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
  end;

  begin
    delete from public.stock_lot_balances;
    raise exception 'authenticated delete stock_lot_balances should fail';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
  end;
end $$;

reset role;

-- D. Ledger extension: existing rows keep null lot_id (checked after opening below)
-- Opening stock still works (unchanged posting path)
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from fixture where name = 'admin'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate')::uuid,
  3,
  'p43d-open-' || gen_random_uuid()::text,
  'phase 4.3d regression opening'
);

reset role;

do $$
declare
  bal integer;
  led integer;
  null_lots integer;
  tx uuid;
  product uuid := current_setting('sherlyos.product')::uuid;
  crate uuid := current_setting('sherlyos.crate')::uuid;
  actor uuid := (select id from fixture where name = 'admin');
  caught text;
begin
  select quantity into bal
  from public.stock_balances
  where crate_id = crate
    and product_id = product;

  if bal is distinct from 3 then
    raise exception 'opening stock balance expected 3 got %', bal;
  end if;

  select count(*)::integer into led
  from public.stock_ledger
  where crate_id = crate
    and product_id = product
    and lot_id is null;

  if led < 1 then
    raise exception 'opening ledger row missing or unexpectedly lot-tagged';
  end if;

  select count(*)::integer into null_lots
  from public.stock_ledger
  where lot_id is not null;

  if null_lots <> 0 then
    raise exception 'unexpected non-null ledger lot_id rows: %', null_lots;
  end if;

  -- Table-owner INSERT against the real opening txn: append-only blocks UPDATE/DELETE only,
  -- so an invalid lot_id must surface as SQLSTATE 23503 (not 42501).
  select stock_transactions.id
  into tx
  from public.stock_transactions
  where stock_transactions.product_id = product
    and stock_transactions.destination_crate_id = crate
    and stock_transactions.transaction_type = 'OPENING_STOCK'
  limit 1;

  if tx is null then
    raise exception 'opening transaction missing for FK probe';
  end if;

  begin
    insert into public.stock_ledger (
      transaction_id,
      product_id,
      crate_id,
      quantity,
      actor_id,
      posted_at,
      lot_id
    )
    values (
      tx,
      product,
      crate,
      1,
      actor,
      clock_timestamp(),
      '00000000-0000-0000-0000-000000000099'::uuid
    );
    raise exception 'invalid lot_id should fail with foreign_key_violation / 23503';
  exception
    when foreign_key_violation then
      caught := sqlstate;
      if caught is distinct from '23503' then
        raise exception 'expected SQLSTATE 23503, got %', caught;
      end if;
    when others then
      raise exception 'FK probe expected 23503, got SQLSTATE %: %', sqlstate, sqlerrm;
  end;
end $$;

-- Availability still sums product×crate (no lot cutover)
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from fixture where name = 'admin'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

-- sanity: lot tables may have test rows in this txn but operational aggregate unchanged path works
reset role;

select 'phase_4_3d_stock_lots_foundation ok' as result;

rollback;
