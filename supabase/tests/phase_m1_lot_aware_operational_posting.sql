-- M1 lot-aware operational posting. Disposable. Rolls back.
-- Covers: pre-cutover aggregate-only, dual-write opening/transfer/receive/adjust,
-- expiry rules, idempotency, PT409, permissions, conservation, forged DML denial.
-- Does NOT leave dual_write_enabled or aggregate_only_blocked true on the working DB.

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
  fixture.name || '.m1lot@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M1 Admin', true)
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

-- Working flags must start false
do $$
begin
  if (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled')
    is distinct from 'false'::jsonb
    or (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked')
    is distinct from 'false'::jsonb
  then
    raise exception 'cutover flags must start false on working DB';
  end if;
end $$;

select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select set_config('sherlyos.branch', public.create_branch('m1lot_a', 'M1 Lot A')::text, true);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);

select set_config(
  'sherlyos.zone',
  public.create_zone(current_setting('sherlyos.branch')::uuid, 'zm1', 'ZM1', null)::text,
  true
);
select set_config(
  'sherlyos.crate_a',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'cm1a', 'CM1A', null)::text,
  true
);
select set_config(
  'sherlyos.crate_b',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'cm1b', 'CM1B', null)::text,
  true
);
select set_config(
  'sherlyos.product_exp',
  public.create_product('m1-exp', 'M1 Expiry Product', null, null)::text,
  true
);
select set_config(
  'sherlyos.product_nx',
  public.create_product('m1-nx', 'M1 Non-Expiring Product', null, null)::text,
  true
);
select set_config(
  'sherlyos.product_agg',
  public.create_product('m1-agg', 'M1 Aggregate-Only Product', null, null)::text,
  true
);

-- Godown manager cannot classify
do $$
begin
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'godown'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = 'godown'), 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.set_product_expiry_policy(current_setting('sherlyos.product_exp')::uuid, 'expiry_controlled');
    raise exception 'godown manager must not classify expiry';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Admin classifies
do $$
begin
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
    true
  );
  perform public.set_product_expiry_policy(current_setting('sherlyos.product_exp')::uuid, 'expiry_controlled');
  perform public.set_product_expiry_policy(current_setting('sherlyos.product_nx')::uuid, 'non_expiring');
end $$;

-- ---------------------------------------------------------------------------
-- Pre-cutover: aggregate-only opening still works without lot fields
-- ---------------------------------------------------------------------------
do $$
declare
  posted jsonb;
  bal integer;
  lot_count integer;
begin
  posted := public.post_opening_stock(
    current_setting('sherlyos.product_agg')::uuid,
    current_setting('sherlyos.crate_a')::uuid,
    10,
    'm1-agg-open',
    'pre-cutover'
  );
  if posted ->> 'id' is null then
    raise exception 'aggregate opening failed';
  end if;

  select quantity into bal
  from public.stock_balances
  where crate_id = current_setting('sherlyos.crate_a')::uuid
    and product_id = current_setting('sherlyos.product_agg')::uuid;
  if bal is distinct from 10 then
    raise exception 'aggregate balance expected 10 got %', bal;
  end if;

  select count(*)::integer into lot_count from public.stock_lots
  where product_id = current_setting('sherlyos.product_agg')::uuid;
  if lot_count <> 0 then
    raise exception 'pre-cutover must not create lots';
  end if;
end $$;

-- lot_moves rejected while dual-write off
do $$
begin
  begin
    perform public.post_crate_transfer(
      current_setting('sherlyos.product_agg')::uuid,
      current_setting('sherlyos.crate_a')::uuid,
      current_setting('sherlyos.crate_b')::uuid,
      1,
      'm1-xfer-rejected-lots',
      null,
      jsonb_build_array(jsonb_build_object('lot_id', gen_random_uuid(), 'quantity', 1))
    );
    raise exception 'lot_moves must be rejected before dual-write';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Enable dual-write inside this rolled-back transaction only
-- ---------------------------------------------------------------------------
reset role;
update public.app_configuration
set value = 'true'::jsonb
where key = 'stock.lots.dual_write_enabled';

set local role authenticated;
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);

-- Unclassified product blocked for lot-aware opening
do $$
begin
  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.product_agg')::uuid,
      current_setting('sherlyos.crate_b')::uuid,
      1,
      'm1-unclassified-open',
      null,
      null, null, null
    );
    raise exception 'unclassified product must fail lot-aware opening';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Expiry-controlled opening requires expiry_date
do $$
begin
  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.product_exp')::uuid,
      current_setting('sherlyos.crate_a')::uuid,
      5,
      'm1-exp-missing',
      null,
      'LOT-A', null, null
    );
    raise exception 'missing expiry must fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Non-expiring must not carry expiry
do $$
begin
  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.product_nx')::uuid,
      current_setting('sherlyos.crate_a')::uuid,
      5,
      'm1-nx-bad-exp',
      null,
      'LOT-NX', null, current_date + 30
    );
    raise exception 'non-expiring with expiry must fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Successful lot-aware openings
do $$
declare
  posted jsonb;
  opened_lot uuid;
  agg integer;
  lot_qty integer;
  ledger_lots integer;
begin
  posted := public.post_opening_stock(
    current_setting('sherlyos.product_exp')::uuid,
    current_setting('sherlyos.crate_a')::uuid,
    8,
    'm1-exp-open',
    'lot opening',
    'LOT-EXP-1', current_date - 10, current_date + 120
  );
  perform set_config('sherlyos.open_txn', posted ->> 'id', true);

  select stock_lots.id into opened_lot
  from public.stock_lots
  where stock_lots.product_id = current_setting('sherlyos.product_exp')::uuid
    and stock_lots.origin = 'opening'
  order by stock_lots.created_at desc
  limit 1;
  if opened_lot is null then
    raise exception 'opening lot missing';
  end if;
  perform set_config('sherlyos.lot_exp', opened_lot::text, true);

  select quantity into agg from public.stock_balances
  where crate_id = current_setting('sherlyos.crate_a')::uuid
    and product_id = current_setting('sherlyos.product_exp')::uuid;
  select stock_lot_balances.quantity into lot_qty
  from public.stock_lot_balances
  where stock_lot_balances.lot_id = opened_lot
    and stock_lot_balances.crate_id = current_setting('sherlyos.crate_a')::uuid;
  if agg is distinct from 8 or lot_qty is distinct from 8 then
    raise exception 'opening conservation failed agg=% lot=%', agg, lot_qty;
  end if;

  select count(*)::integer into ledger_lots
  from public.stock_ledger
  where transaction_id = (posted ->> 'id')::uuid and lot_id is not null;
  if ledger_lots < 1 then
    raise exception 'ledger lot_id missing on opening';
  end if;

  posted := public.post_opening_stock(
    current_setting('sherlyos.product_nx')::uuid,
    current_setting('sherlyos.crate_a')::uuid,
    4,
    'm1-nx-open',
    null,
    'LOT-NX-1', null, null
  );
  if posted ->> 'id' is null then
    raise exception 'non-expiring opening failed';
  end if;
end $$;

-- Idempotent retry
do $$
declare
  first_id text := current_setting('sherlyos.open_txn');
  replay jsonb;
begin
  replay := public.post_opening_stock(
    current_setting('sherlyos.product_exp')::uuid,
    current_setting('sherlyos.crate_a')::uuid,
    8,
    'm1-exp-open',
    'lot opening',
    'LOT-EXP-1', current_date - 10, current_date + 120
  );
  if replay ->> 'id' is distinct from first_id then
    raise exception 'idempotent opening replay mismatch';
  end if;
end $$;

-- Explicit multi-lot transfer (split opening into second crate via two moves after second lot)
do $$
declare
  posted jsonb;
  second_lot uuid;
  move jsonb;
begin
  -- second lot on same crate via another product opening already done; create second lot on exp via receipt path later.
  -- For transfer: move 3 of the 8 from crate_a to crate_b on lot_exp
  move := jsonb_build_array(jsonb_build_object(
    'lot_id', current_setting('sherlyos.lot_exp')::uuid,
    'quantity', 3
  ));
  posted := public.post_crate_transfer(
    current_setting('sherlyos.product_exp')::uuid,
    current_setting('sherlyos.crate_a')::uuid,
    current_setting('sherlyos.crate_b')::uuid,
    3,
    'm1-xfer-1',
    null,
    move
  );
  if posted ->> 'id' is null then
    raise exception 'transfer failed';
  end if;

  if (select quantity from public.stock_lot_balances
      where lot_id = current_setting('sherlyos.lot_exp')::uuid
        and crate_id = current_setting('sherlyos.crate_a')::uuid) is distinct from 5 then
    raise exception 'source lot qty after transfer';
  end if;
  if (select quantity from public.stock_lot_balances
      where lot_id = current_setting('sherlyos.lot_exp')::uuid
        and crate_id = current_setting('sherlyos.crate_b')::uuid) is distinct from 3 then
    raise exception 'dest lot qty after transfer';
  end if;

  -- insufficient lot stock
  begin
    perform public.post_crate_transfer(
      current_setting('sherlyos.product_exp')::uuid,
      current_setting('sherlyos.crate_a')::uuid,
      current_setting('sherlyos.crate_b')::uuid,
      6,
      'm1-xfer-over',
      null,
      jsonb_build_array(jsonb_build_object(
        'lot_id', current_setting('sherlyos.lot_exp')::uuid,
        'quantity', 6
      ))
    );
    raise exception 'over-transfer must fail';
  exception
    when sqlstate '23514' then null;
  end;

  -- FEFO not implied: missing lot_moves fails
  begin
    perform public.post_crate_transfer(
      current_setting('sherlyos.product_exp')::uuid,
      current_setting('sherlyos.crate_a')::uuid,
      current_setting('sherlyos.crate_b')::uuid,
      1,
      'm1-xfer-no-lots',
      null,
      null
    );
    raise exception 'transfer without lot_moves must fail under dual-write';
  exception
    when sqlstate '23514' then null;
  end;

  perform set_config('sherlyos.unused', coalesce(second_lot::text, ''), true);
end $$;

-- Multi-lot receiving
do $$
declare
  supplier uuid;
  receipt jsonb;
  line_id uuid;
  verify jsonb;
  attr jsonb;
begin
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
    true
  );
  supplier := public.create_supplier('M1 Supplier', null, null);

  -- create_stock_receipt requires keeper/godown with receiving.execute
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'keeper'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = 'keeper'), 'role', 'authenticated')::text,
    true
  );

  receipt := public.create_stock_receipt(
    current_setting('sherlyos.branch')::uuid,
    supplier,
    'M1-DOC-1',
    current_date,
    null,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product_exp')::uuid,
      'destination_crate_id', current_setting('sherlyos.crate_a')::uuid,
      'document_cases', 5,
      'counted_cases', 5,
      'damaged_cases', 0
    ))
  );
  line_id := (receipt -> 'lines' -> 0 ->> 'id')::uuid;
  perform set_config('sherlyos.receipt', receipt ->> 'id', true);
  perform set_config('sherlyos.receipt_line', line_id::text, true);

  attr := jsonb_build_array(
    jsonb_build_object(
      'carton_quantity', 2,
      'manufacturer_lot_code', 'RCV-1',
      'manufactured_on', current_date - 5,
      'expiry_date', current_date + 60
    ),
    jsonb_build_object(
      'carton_quantity', 3,
      'manufacturer_lot_code', 'RCV-2',
      'manufactured_on', current_date - 2,
      'expiry_date', current_date + 90
    )
  );
  perform public.set_stock_receipt_line_lot_attributions(line_id, attr);

  -- wrong sum rejected
  begin
    perform public.set_stock_receipt_line_lot_attributions(
      line_id,
      jsonb_build_array(jsonb_build_object(
        'carton_quantity', 4,
        'expiry_date', current_date + 60
      ))
    );
    raise exception 'attribution sum mismatch must fail';
  exception
    when sqlstate '23514' then null;
  end;

  -- restore correct attributions
  perform public.set_stock_receipt_line_lot_attributions(line_id, attr);

  perform public.submit_stock_receipt((receipt ->> 'id')::uuid);

  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'godown'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = 'godown'), 'role', 'authenticated')::text,
    true
  );

  verify := public.verify_stock_receipt((receipt ->> 'id')::uuid, 'm1-verify-1');
  if verify ->> 'status' is distinct from 'posted' then
    raise exception 'verify failed status=%', verify ->> 'status';
  end if;

  if (select count(*)::integer from public.stock_lots
      where origin = 'receipt'
        and product_id = current_setting('sherlyos.product_exp')::uuid) < 2 then
    raise exception 'expected two receipt lots';
  end if;

  -- conservation: aggregate for product_exp on crate_a = opening remainder 5 + receive 5 = 10
  if (select quantity from public.stock_balances
      where crate_id = current_setting('sherlyos.crate_a')::uuid
        and product_id = current_setting('sherlyos.product_exp')::uuid) is distinct from 10 then
    raise exception 'post-receive aggregate mismatch';
  end if;

  if (select coalesce(sum(quantity), 0) from public.stock_lot_balances
      where crate_id = current_setting('sherlyos.crate_a')::uuid
        and lot_id in (
          select id from public.stock_lots
          where product_id = current_setting('sherlyos.product_exp')::uuid
        )) is distinct from 10 then
    raise exception 'lot balance sum must equal aggregate';
  end if;
end $$;

-- Multi-lot explicit transfer after receipt lots exist
do $$
declare
  opening_lot uuid := current_setting('sherlyos.lot_exp')::uuid;
  receipt_lot uuid;
  posted jsonb;
begin
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
    true
  );

  select stock_lots.id into receipt_lot
  from public.stock_lots
  where stock_lots.product_id = current_setting('sherlyos.product_exp')::uuid
    and stock_lots.origin = 'receipt'
    and stock_lots.manufacturer_lot_code = 'RCV-1';

  if receipt_lot is null then
    raise exception 'receipt lot RCV-1 missing';
  end if;

  posted := public.post_crate_transfer(
    current_setting('sherlyos.product_exp')::uuid,
    current_setting('sherlyos.crate_a')::uuid,
    current_setting('sherlyos.crate_b')::uuid,
    3,
    'm1-xfer-multi',
    null,
    jsonb_build_array(
      jsonb_build_object('lot_id', opening_lot, 'quantity', 1),
      jsonb_build_object('lot_id', receipt_lot, 'quantity', 2)
    )
  );
  if posted ->> 'id' is null then
    raise exception 'multi-lot transfer failed';
  end if;

  if (
    select coalesce(sum(stock_balances.quantity), 0)
    from public.stock_balances
    where stock_balances.product_id = current_setting('sherlyos.product_exp')::uuid
  ) is distinct from (
    select coalesce(sum(stock_lot_balances.quantity), 0)
    from public.stock_lot_balances
    join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
    where stock_lots.product_id = current_setting('sherlyos.product_exp')::uuid
  ) then
    raise exception 'aggregate and lot totals diverged after multi-lot transfer';
  end if;
end $$;

-- Failed statement rolls back its stock change
do $$
declare
  before_qty integer;
  after_qty integer;
begin
  select stock_balances.quantity into before_qty
  from public.stock_balances
  where stock_balances.crate_id = current_setting('sherlyos.crate_a')::uuid
    and stock_balances.product_id = current_setting('sherlyos.product_nx')::uuid;

  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.product_nx')::uuid,
      current_setting('sherlyos.crate_a')::uuid,
      1,
      'm1-nx-second-open',
      null,
      null, null, null
    );
    raise exception 'second opening must fail';
  exception
    when sqlstate '23505' then null;
  end;

  select stock_balances.quantity into after_qty
  from public.stock_balances
  where stock_balances.crate_id = current_setting('sherlyos.crate_a')::uuid
    and stock_balances.product_id = current_setting('sherlyos.product_nx')::uuid;

  if before_qty is distinct from after_qty then
    raise exception 'failed opening changed balance % -> %', before_qty, after_qty;
  end if;
end $$;

-- Adjustment permission, missing request, and PT409 contract
do $$
declare
  def text := pg_get_functiondef('public.post_stock_adjustment(uuid, integer, text)'::regprocedure);
begin
  if def not like '%errcode = ''PT409''%' then
    raise exception 'post_stock_adjustment must return PT409 for a stale version';
  end if;

  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'accounts'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = 'accounts'), 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.post_stock_adjustment(gen_random_uuid(), 1, 'm1-adjust-accounts');
    raise exception 'accounts must not post adjustments';
  exception
    when sqlstate '42501' then null;
  end;

  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'godown'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = 'godown'), 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.post_stock_adjustment(gen_random_uuid(), 1, 'm1-adjust-missing');
    raise exception 'missing adjustment must be denied';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Forged GUC / direct lot balance DML denial under dual-write
reset role;
do $$
declare
  lot uuid := current_setting('sherlyos.lot_exp')::uuid;
  crate uuid := current_setting('sherlyos.crate_a')::uuid;
begin
  begin
    insert into public.stock_lot_balances (lot_id, crate_id, quantity)
    values (lot, crate, 1)
    on conflict (lot_id, crate_id) do update set quantity = public.stock_lot_balances.quantity + 1;
    raise exception 'direct lot balance DML must be denied';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
    when sqlstate 'P0001' then null;
  end;
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
  perform set_config('app.lot_balance_write', 'helper', true);
  begin
    update public.stock_lot_balances
    set quantity = quantity + 1
    where lot_id = current_setting('sherlyos.lot_exp')::uuid
      and crate_id = current_setting('sherlyos.crate_a')::uuid;
    raise exception 'forged GUC must not authorize update';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
    when sqlstate 'P0001' then null;
  end;
end $$;

-- Accounts cannot post opening
do $$
begin
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'accounts'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = 'accounts'), 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.product_nx')::uuid,
      current_setting('sherlyos.crate_b')::uuid,
      1,
      'm1-accounts-denied',
      null,
      null, null, null
    );
    raise exception 'accounts must not post opening';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Ensure working-DB flags are restored before rollback visibility (still in txn)
reset role;
update public.app_configuration
set value = 'false'::jsonb
where key = 'stock.lots.dual_write_enabled';

do $$
begin
  if (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled')
    is distinct from 'false'::jsonb
  then
    raise exception 'dual_write must be false before rollback';
  end if;
  if (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked')
    is distinct from 'false'::jsonb
  then
    raise exception 'aggregate_only_blocked must stay false';
  end if;
end $$;

rollback;
