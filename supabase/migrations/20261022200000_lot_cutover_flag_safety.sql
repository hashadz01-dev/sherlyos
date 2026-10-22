-- M1-S1.1: Fail-closed lot cutover configuration guards (local-first).
-- Forward-only after 20261022190000. Does not flip flags or seed on apply.
-- Dual-write enable requires blocked aggregate posting, grain reconciliation,
-- and an explicit expiry_policy on every product with positive stock.

-- ---------------------------------------------------------------------------
-- 0. Posting reads dual-write only after the shared cutover lock
-- ---------------------------------------------------------------------------

-- VOLATILE: takes the same shared advisory lock as prepare_stock_locations so
-- a concurrent flag UPDATE (exclusive) cannot flip the path after this read.
create or replace function app_private.stock_lots_dual_write_enabled()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  dual_write boolean := false;
begin
  perform app_private.acquire_stock_cutover_shared_lock();

  select coalesce(app_configuration.value, 'false'::jsonb) = 'true'::jsonb
  into dual_write
  from public.app_configuration
  where app_configuration.key = 'stock.lots.dual_write_enabled';

  return coalesce(dual_write, false);
end;
$$;

revoke all on function app_private.stock_lots_dual_write_enabled()
  from public, anon, authenticated, service_role;

comment on function app_private.stock_lots_dual_write_enabled() is
  'M1-S1.1. Shared lock (88104301,1) then read dual-write. Posting RPCs call this before path selection so flag transitions cannot interleave mid-statement.';

-- ---------------------------------------------------------------------------
-- 1. Inventory grain reconciliation (crate_id, product_id)
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_lot_inventory_grains_reconciled()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  mismatch_count integer := 0;
  orphan_count integer := 0;
begin
  select count(*)
  into mismatch_count
  from public.stock_balances sb
  left join (
    select
      stock_lot_balances.crate_id,
      stock_lots.product_id,
      sum(stock_lot_balances.quantity)::integer as lot_quantity
    from public.stock_lot_balances
    join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
    group by stock_lot_balances.crate_id, stock_lots.product_id
  ) lot_totals
    on lot_totals.crate_id = sb.crate_id
   and lot_totals.product_id = sb.product_id
  where sb.quantity > 0
    and coalesce(lot_totals.lot_quantity, 0) is distinct from sb.quantity;

  if mismatch_count > 0 then
    raise exception
      'positive aggregate stock grain lacks matching lot quantity (mismatches=%)',
      mismatch_count
      using errcode = '55000';
  end if;

  select count(*)
  into orphan_count
  from (
    select
      stock_lot_balances.crate_id,
      stock_lots.product_id,
      sum(stock_lot_balances.quantity)::integer as lot_quantity
    from public.stock_lot_balances
    join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
    group by stock_lot_balances.crate_id, stock_lots.product_id
    having sum(stock_lot_balances.quantity) <> 0
  ) lot_grains
  left join public.stock_balances sb
    on sb.crate_id = lot_grains.crate_id
   and sb.product_id = lot_grains.product_id
  where sb.crate_id is null
     or sb.quantity = 0
     or lot_grains.lot_quantity is distinct from sb.quantity;

  if orphan_count > 0 then
    raise exception
      'lot balance exists without matching positive aggregate grain (orphans=%)',
      orphan_count
      using errcode = '55000';
  end if;

  -- Table CHECK already requires quantity >= 0. Keep an explicit reject if a
  -- replica/superuser session ever bypasses that constraint.
  if exists (
    select 1 from public.stock_lot_balances where stock_lot_balances.quantity < 0
  ) then
    raise exception 'negative lot balance cannot satisfy cutover reconciliation'
      using errcode = '55000';
  end if;
end;
$$;

revoke all on function app_private.assert_lot_inventory_grains_reconciled()
  from public, anon, authenticated, service_role;

comment on function app_private.assert_lot_inventory_grains_reconciled() is
  'M1-S1. Every positive (crate_id, product_id) aggregate grain must equal the sum of lot balances for that grain; no non-zero lot grain may exceed or fall short of aggregate.';

-- ---------------------------------------------------------------------------
-- 1b. Dual-write enable: positive stock must already be classified
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_positive_stock_products_classified()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  unclassified_count integer := 0;
begin
  -- Fail-closed. Do not invent expiry_controlled vs non_expiring here.
  select count(distinct stock_balances.product_id)
  into unclassified_count
  from public.stock_balances
  join public.products on products.id = stock_balances.product_id
  where stock_balances.quantity > 0
    and products.expiry_policy is distinct from 'expiry_controlled'
    and products.expiry_policy is distinct from 'non_expiring';

  if unclassified_count > 0 then
    raise exception
      'stock.lots.dual_write_enabled requires expiry_policy expiry_controlled or non_expiring on every product with positive stock (unclassified=%)',
      unclassified_count
      using errcode = '55000';
  end if;
end;
$$;

revoke all on function app_private.assert_positive_stock_products_classified()
  from public, anon, authenticated, service_role;

comment on function app_private.assert_positive_stock_products_classified() is
  'M1-S1.1. Dual-write activation is rejected while any positive stock_balances product has NULL or invalid expiry_policy. Classification remains Admin-only via set_product_expiry_policy.';

-- ---------------------------------------------------------------------------
-- 2. Configuration pair validation (all privileged update paths)
-- ---------------------------------------------------------------------------

drop function if exists app_private.validate_lot_cutover_configuration();

create or replace function app_private.validate_lot_cutover_configuration(
  pending_dual jsonb default null,
  pending_blocked jsonb default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  dual_write boolean := false;
  blocked boolean := false;
  lot_activity boolean := false;
begin
  -- Serialize against posting (shared) and seed (exclusive) on (88104301, 1).
  perform app_private.lot_seed_lock_exclusive();

  -- Ordered row locks match posting grains (crate, product) then lots (crate, lot).
  perform 1
  from public.stock_balances
  order by stock_balances.crate_id, stock_balances.product_id
  for update;

  perform 1
  from public.stock_lot_balances
  order by stock_lot_balances.crate_id, stock_lot_balances.lot_id
  for update;

  perform 1
  from public.products
  where products.id in (
    select distinct stock_balances.product_id
    from public.stock_balances
    where stock_balances.quantity > 0
  )
  order by products.id
  for update;

  perform 1
  from public.app_configuration
  where app_configuration.key in (
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked'
  )
  order by app_configuration.key
  for update;

  if pending_dual is not null then
    dual_write := pending_dual = 'true'::jsonb;
  else
    select coalesce(app_configuration.value, 'false'::jsonb) = 'true'::jsonb
    into dual_write
    from public.app_configuration
    where app_configuration.key = 'stock.lots.dual_write_enabled';
  end if;

  if pending_blocked is not null then
    blocked := pending_blocked = 'true'::jsonb;
  else
    select coalesce(app_configuration.value, 'false'::jsonb) = 'true'::jsonb
    into blocked
    from public.app_configuration
    where app_configuration.key = 'stock.lots.aggregate_only_blocked';
  end if;

  select exists (
    select 1 from public.stock_lots
  )
  or exists (
    select 1 from public.stock_lot_balances where stock_lot_balances.quantity <> 0
  )
  or exists (
    select 1 from public.stock_ledger where stock_ledger.lot_id is not null
  )
  into lot_activity;

  -- Rule B: do not reopen aggregate-only while lot-aware inventory exists.
  if not blocked and lot_activity then
    raise exception
      'stock.lots.aggregate_only_blocked cannot be false while lot inventory or lot-attributed ledger rows exist'
      using errcode = '55000';
  end if;

  -- Recovery guard: aggregate + dual-write off with lot data reopens unsafe aggregate posting.
  if not dual_write and not blocked and lot_activity then
    raise exception
      'lot inventory exists but both cutover flags are false; enable dual-write or block aggregate-only posting'
      using errcode = '55000';
  end if;

  -- Rule A: dual-write requires blocked aggregate path, grain match, and classification.
  if dual_write then
    if not blocked then
      raise exception
        'stock.lots.dual_write_enabled requires stock.lots.aggregate_only_blocked=true'
        using errcode = '55000';
    end if;

    perform app_private.assert_lot_inventory_grains_reconciled();
    perform app_private.assert_positive_stock_products_classified();
  end if;

  -- Rule C: no safe return to aggregate-only after lot-attributed ledger posting.
  if not dual_write and exists (
    select 1 from public.stock_ledger where stock_ledger.lot_id is not null
  ) then
    raise exception
      'stock.lots.dual_write_enabled cannot be false while lot-attributed ledger rows exist'
      using errcode = '55000';
  end if;
end;
$$;

revoke all on function app_private.validate_lot_cutover_configuration(jsonb, jsonb)
  from public, anon, authenticated, service_role;

comment on function app_private.validate_lot_cutover_configuration(jsonb, jsonb) is
  'M1-S1.1. Validates the final cutover flag pair under exclusive advisory lock (88104301,1). Invoked from AFTER STATEMENT so a single UPDATE of both flags is judged atomically.';

-- ---------------------------------------------------------------------------
-- 3. Triggers on app_configuration
-- ---------------------------------------------------------------------------

-- BEFORE ROW: type-check only. Full validation waits until AFTER STATEMENT so
-- a multi-row UPDATE of both flags is not rejected on an intermediate row.
create or replace function app_private.enforce_lot_cutover_configuration_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.key not in (
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked'
  ) then
    return new;
  end if;

  if new.value is distinct from 'true'::jsonb
     and new.value is distinct from 'false'::jsonb
  then
    raise exception 'lot cutover flags must be json boolean true or false'
      using errcode = '23514';
  end if;

  -- Description-only updates must not re-evaluate cutover invariants.
  if tg_op = 'UPDATE' and new.value is not distinct from old.value then
    return new;
  end if;

  perform set_config('app_private.lot_cutover_flags_pending', '1', true);
  return new;
end;
$$;

revoke all on function app_private.enforce_lot_cutover_configuration_row()
  from public, anon, authenticated, service_role;

create or replace function app_private.enforce_lot_cutover_configuration_statement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Skip non-flag app_configuration statements (and description-only flag edits).
  if current_setting('app_private.lot_cutover_flags_pending', true) is distinct from '1' then
    return null;
  end if;

  perform set_config('app_private.lot_cutover_flags_pending', '0', true);
  perform app_private.validate_lot_cutover_configuration(null, null);
  return null;
end;
$$;

revoke all on function app_private.enforce_lot_cutover_configuration_statement()
  from public, anon, authenticated, service_role;

drop trigger if exists app_configuration_reject_premature_dual_write
  on public.app_configuration;
drop trigger if exists app_configuration_lot_cutover_row_guard
  on public.app_configuration;
drop trigger if exists app_configuration_lot_cutover_statement_guard
  on public.app_configuration;
drop trigger if exists app_configuration_lot_cutover_validate
  on public.app_configuration;
drop function if exists app_private.enforce_lot_cutover_configuration_deferred();

create trigger app_configuration_lot_cutover_row_guard
  before insert or update on public.app_configuration
  for each row
  execute function app_private.enforce_lot_cutover_configuration_row();

-- AFTER STATEMENT (not deferred): SET CONSTRAINTS ALL IMMEDIATE used by lot
-- posting must not re-run this. It fires only when app_configuration is written.
create trigger app_configuration_lot_cutover_statement_guard
  after insert or update on public.app_configuration
  for each statement
  execute function app_private.enforce_lot_cutover_configuration_statement();

update public.app_configuration
set description = 'M1-S1.1. When true, requires aggregate_only_blocked=true, full (crate_id, product_id) lot reconciliation, and expiry_policy on every product with positive stock.'
where key = 'stock.lots.dual_write_enabled';

update public.app_configuration
set description = 'M1-S1.1. When false, rejected if lot balances, stock_lots, or lot-attributed ledger rows exist.'
where key = 'stock.lots.aggregate_only_blocked';
