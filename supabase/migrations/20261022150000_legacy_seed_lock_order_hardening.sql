-- Phase 4.3E.1A: seeder concurrency and integrity hardening (local-first).
-- Forward-only after 20261022140000.
-- Fixes:
--   H1) Lock-order inversion — shared cutover advisory before zone/crate locks
--       in prepare_stock_locations (covers all apply_stock_delta callers).
--   M1) Reject unexpected pre-existing lot balances before legacy seed insert.
--   Freeze) Ignore dual_write_enabled until a later phase implements dual-write;
--           reject enabling that flag via trigger.

-- ---------------------------------------------------------------------------
-- 1. Reusable shared cutover lock (transaction-scoped)
-- ---------------------------------------------------------------------------

create or replace function app_private.acquire_stock_cutover_shared_lock()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Must run before zone/crate/balance row locks in stock-mutating txns.
  perform app_private.lot_seed_lock_shared();
end;
$$;

revoke all on function app_private.acquire_stock_cutover_shared_lock()
  from public, anon, authenticated, service_role;

comment on function app_private.acquire_stock_cutover_shared_lock() is
  'Phase 4.3E.1A. Acquire shared advisory (88104301,1) before location/balance locks. Called from prepare_stock_locations so opening, transfer, receiving, adjustment, and verification share one protocol with the legacy seeder.';

-- ---------------------------------------------------------------------------
-- 2. prepare_stock_locations — shared advisory BEFORE row locks
-- ---------------------------------------------------------------------------

create or replace function app_private.prepare_stock_locations(crate_ids uuid[])
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_branch uuid;
  found_count integer;
  branch_count integer;
  inactive_count integer;
begin
  if crate_ids is null or cardinality(crate_ids) < 1 then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  -- H1 fix: cutover shared lock before any zone/crate FOR UPDATE.
  perform app_private.acquire_stock_cutover_shared_lock();

  perform zones.id
  from public.zones
  where zones.id in (
    select crates.zone_id
    from public.crates
    where crates.id = any (crate_ids)
  )
  order by zones.id
  for update;

  perform crates.id
  from public.crates
  where crates.id = any (crate_ids)
  order by crates.id
  for update;

  select
    count(*),
    count(distinct zones.branch_id),
    count(*) filter (
      where not crates.is_active
        or not zones.is_active
        or not branches.is_active
    )
  into found_count, branch_count, inactive_count
  from public.crates
  join public.zones on zones.id = crates.zone_id
  join public.branches on branches.id = zones.branch_id
  where crates.id = any (crate_ids);

  if found_count is distinct from cardinality(crate_ids) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.crates
    join public.zones on zones.id = crates.zone_id
    where crates.id = any (crate_ids)
      and not app_private.can_work_at_branch(zones.branch_id)
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if branch_count <> 1 then
    raise exception 'crates must belong to the same godown' using errcode = '23514';
  end if;

  if inactive_count > 0 then
    raise exception 'location is inactive' using errcode = '23514';
  end if;

  select zones.branch_id
  into selected_branch
  from public.crates
  join public.zones on zones.id = crates.zone_id
  where crates.id = crate_ids[1];

  return selected_branch;
end;
$$;

revoke all on function app_private.prepare_stock_locations(uuid[])
  from public, anon, authenticated, service_role;

comment on function app_private.prepare_stock_locations(uuid[]) is
  'Locks cutover shared advisory, then zones and crates in id order. Callers must not hold conflicting stock row locks before invoking this function.';

-- ---------------------------------------------------------------------------
-- 3. Freeze: ignore dual_write_enabled until dual-write exists
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_aggregate_stock_mutation_allowed()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  blocked boolean := false;
begin
  select coalesce(app_configuration.value, 'false'::jsonb) = 'true'::jsonb
  into blocked
  from public.app_configuration
  where app_configuration.key = 'stock.lots.aggregate_only_blocked';

  -- dual_write_enabled is intentionally ignored here until Phase 4.3E.2
  -- replaces this guard with real lot-aware posting.
  if coalesce(blocked, false) then
    raise exception
      'aggregate-only stock posting is blocked until lot-aware dual-write is enabled'
      using errcode = '55000';
  end if;
end;
$$;

revoke all on function app_private.assert_aggregate_stock_mutation_allowed()
  from public, anon, authenticated, service_role;

create or replace function app_private.reject_premature_dual_write_enable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.key = 'stock.lots.dual_write_enabled'
    and new.value = 'true'::jsonb
  then
    raise exception
      'stock.lots.dual_write_enabled cannot be set true until lot-aware dual-write is implemented'
      using errcode = '55000';
  end if;
  return new;
end;
$$;

drop trigger if exists app_configuration_reject_premature_dual_write
  on public.app_configuration;

create trigger app_configuration_reject_premature_dual_write
  before insert or update on public.app_configuration
  for each row
  execute function app_private.reject_premature_dual_write_enable();

revoke all on function app_private.reject_premature_dual_write_enable()
  from public, anon, authenticated, service_role;

update public.app_configuration
set description = 'Phase 4.3E+. Reserved for future lot-aware dual-write. Enabling true is rejected until 4.3E.2 implements dual-write; aggregate_only_blocked freeze cannot be bypassed via this flag.'
where key = 'stock.lots.dual_write_enabled';

-- ---------------------------------------------------------------------------
-- 4. Seed RPC — M1 orphan lot-balance rejection + lock-order comment
-- ---------------------------------------------------------------------------

create or replace function public.seed_legacy_stock_lots()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  grain record;
  branch_group record;
  lot_id uuid;
  lot_qty integer;
  marker public.stock_legacy_lot_seeds%rowtype;
  branch uuid;
  orphan_count integer;
  seeded_count integer := 0;
  skipped_count integer := 0;
  examined_count integer := 0;
begin
  perform app_private.assert_permission('stock.lots.seed');
  -- Exclusive cutover lock BEFORE prepare_stock_locations / balance locks (H1).
  perform app_private.lot_seed_lock_exclusive();

  for branch_group in
    select
      zones.branch_id,
      array_agg(distinct stock_balances.crate_id) as crate_ids
    from public.stock_balances
    join public.crates on crates.id = stock_balances.crate_id
    join public.zones on zones.id = crates.zone_id
    where stock_balances.quantity > 0
    group by zones.branch_id
    order by zones.branch_id
  loop
    -- prepare acquires shared (compatible with this txn's exclusive) then crates.
    perform app_private.prepare_stock_locations(branch_group.crate_ids);
  end loop;

  for grain in
    select
      stock_balances.crate_id,
      stock_balances.product_id,
      stock_balances.quantity,
      zones.branch_id
    from public.stock_balances
    join public.crates on crates.id = stock_balances.crate_id
    join public.zones on zones.id = crates.zone_id
    where stock_balances.quantity > 0
    order by stock_balances.crate_id, stock_balances.product_id
    for update of stock_balances
  loop
    examined_count := examined_count + 1;
    branch := grain.branch_id;

    if branch is null then
      raise exception 'legacy seed cannot derive branch for crate %', grain.crate_id
        using errcode = '23514';
    end if;

    select *
    into marker
    from public.stock_legacy_lot_seeds
    where stock_legacy_lot_seeds.crate_id = grain.crate_id
      and stock_legacy_lot_seeds.product_id = grain.product_id
    for update;

    if found then
      select stock_lot_balances.quantity
      into lot_qty
      from public.stock_lot_balances
      where stock_lot_balances.lot_id = marker.lot_id
        and stock_lot_balances.crate_id = grain.crate_id;

      if not found
        or lot_qty is distinct from marker.quantity
        or marker.quantity is distinct from grain.quantity
        or lot_qty is distinct from grain.quantity
      then
        raise exception
          'legacy lot seed reconciliation failed for crate % product % (aggregate %, marker %, lot %)',
          grain.crate_id,
          grain.product_id,
          grain.quantity,
          marker.quantity,
          lot_qty
          using errcode = '23514';
      end if;

      skipped_count := skipped_count + 1;
      continue;
    end if;

    -- M1: refuse unexpected existing lot balances for this grain (incl. qty 0).
    select count(*)::integer
    into orphan_count
    from public.stock_lot_balances
    join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
    where stock_lot_balances.crate_id = grain.crate_id
      and stock_lots.product_id = grain.product_id;

    if orphan_count > 0 then
      raise exception
        'legacy lot seed refused: unexpected existing lot balances for crate % product % (count %)',
        grain.crate_id,
        grain.product_id,
        orphan_count
        using errcode = '23514';
    end if;

    insert into public.stock_lots (
      product_id,
      branch_id,
      manufacturer_lot_code,
      manufactured_on,
      expiry_date,
      received_on,
      status,
      origin,
      source_receipt_line_id,
      source_transaction_id,
      created_by
    )
    values (
      grain.product_id,
      branch,
      null,
      null,
      null,
      null,
      'legacy_unattributed',
      'legacy_reconciliation',
      null,
      null,
      actor
    )
    returning id into lot_id;

    insert into public.stock_lot_balances (lot_id, crate_id, quantity)
    values (lot_id, grain.crate_id, grain.quantity);

    insert into public.stock_legacy_lot_seeds (
      crate_id,
      product_id,
      lot_id,
      quantity,
      seeded_by
    )
    values (
      grain.crate_id,
      grain.product_id,
      lot_id,
      grain.quantity,
      actor
    );

    seeded_count := seeded_count + 1;
  end loop;

  update public.app_configuration
  set value = 'true'::jsonb
  where app_configuration.key = 'stock.lots.aggregate_only_blocked';

  if not found then
    insert into public.app_configuration (key, value, description)
    values (
      'stock.lots.aggregate_only_blocked',
      'true'::jsonb,
      'Phase 4.3E.1. Set true after successful legacy seed. Blocks aggregate-only apply_stock_delta until dual-write is implemented.'
    );
  end if;

  perform app_private.write_audit(
    actor,
    'seed_legacy_stock_lots',
    'stock_legacy_lot_seeds',
    null,
    pg_catalog.jsonb_build_object(
      'examined', examined_count,
      'seeded', seeded_count,
      'skipped_idempotent', skipped_count,
      'aggregate_only_blocked', true
    )
  );

  return pg_catalog.jsonb_build_object(
    'examined', examined_count,
    'seeded', seeded_count,
    'skipped_idempotent', skipped_count,
    'aggregate_only_blocked', true,
    'dual_write_enabled', false
  );
end;
$$;

revoke all on function public.seed_legacy_stock_lots()
  from public, anon, service_role;
grant execute on function public.seed_legacy_stock_lots()
  to authenticated;

comment on function public.seed_legacy_stock_lots() is
  'Requires stock.lots.seed (Admin). Exclusive cutover lock then location locks. Rejects orphan lot balances. Idempotent via markers. Sets aggregate_only_blocked; does not auto-run on migration apply.';
