-- Phase 4.3E.2B.2: trusted lot-balance writers + cumulative conservation (local-first).
-- Forward-only after 20261022170000.
--
-- Verified (PG 17.11): SET ROLE / SET LOCAL ROLE is illegal inside SECURITY DEFINER.
-- Authorization uses transaction-scoped rows in app_private.lot_balance_write_permits
-- (keyed by pg_current_xact_id). GUCs are not authorization. No client EXECUTE on
-- begin/end permit helpers. service_role / authenticated / anon remain SELECT-only
-- on stock_lot_balances (no DML grants). Does NOT seed inventory or enable dual-write.

-- ---------------------------------------------------------------------------
-- 1. Private write permits (non-spoofable by clients)
-- ---------------------------------------------------------------------------

create table app_private.lot_balance_write_permits (
  xact_id xid8 primary key default pg_catalog.pg_current_xact_id(),
  mode text not null,
  opened_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint lot_balance_write_permits_mode_check
    check (mode in ('helper', 'seed'))
);

comment on table app_private.lot_balance_write_permits is
  'Phase 4.3E.2B.2. Transaction-scoped permit for stock_lot_balances DML. Not client-writable.';

revoke all on table app_private.lot_balance_write_permits
  from public, anon, authenticated, service_role;

create or replace function app_private.begin_lot_balance_write(p_mode text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_mode is distinct from 'helper' and p_mode is distinct from 'seed' then
    raise exception 'invalid lot balance write mode' using errcode = '23514';
  end if;

  insert into app_private.lot_balance_write_permits (xact_id, mode)
  values (pg_catalog.pg_current_xact_id(), p_mode)
  on conflict (xact_id) do update
    set mode = excluded.mode,
        opened_at = pg_catalog.clock_timestamp();
end;
$$;

create or replace function app_private.end_lot_balance_write()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from app_private.lot_balance_write_permits
  where lot_balance_write_permits.xact_id = pg_catalog.pg_current_xact_id();
end;
$$;

create or replace function app_private.lot_balance_write_mode()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  active_mode text;
begin
  select lot_balance_write_permits.mode
  into active_mode
  from app_private.lot_balance_write_permits
  where lot_balance_write_permits.xact_id = pg_catalog.pg_current_xact_id();

  return active_mode;
end;
$$;

revoke all on function app_private.begin_lot_balance_write(text)
  from public, anon, authenticated, service_role;
revoke all on function app_private.end_lot_balance_write()
  from public, anon, authenticated, service_role;
revoke all on function app_private.lot_balance_write_mode()
  from public, anon, authenticated, service_role;

comment on function app_private.begin_lot_balance_write(text) is
  'Opens a transaction-scoped lot-balance write permit. Not client-callable.';
comment on function app_private.end_lot_balance_write() is
  'Clears the current transaction lot-balance write permit. Not client-callable.';

-- ---------------------------------------------------------------------------
-- 2. Write gate: permit only (no GUC, no owner bypass)
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_lot_balance_write_allowed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from app_private.lot_balance_write_permits
    where lot_balance_write_permits.xact_id = pg_catalog.pg_current_xact_id()
  ) then
    return coalesce(new, old);
  end if;

  raise exception
    'stock_lot_balances may only be written by lot-aware helper or legacy seed'
    using errcode = '42501';
end;
$$;

revoke all on function app_private.assert_lot_balance_write_allowed()
  from public, anon, authenticated, service_role;

-- Reaffirm table privileges: SELECT for authenticated only; no DML for clients.
revoke all on table public.stock_lot_balances
  from public, anon, authenticated, service_role;
grant select on table public.stock_lot_balances to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Deferred ledger integrity: drop GUC seed skip (NULL-lot path already skips)
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_lot_aware_transaction_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  txn uuid;
  has_null boolean;
  has_lot boolean;
  applied public.stock_lot_aware_applications%rowtype;
  ledger_fp text;
begin
  -- Seed writes balances without lot_id ledger; has_lot stays false and we skip.
  if app_private.lot_balance_write_mode() is not distinct from 'seed' then
    return null;
  end if;

  txn := coalesce(new.transaction_id, old.transaction_id);
  if txn is null then
    return null;
  end if;

  select
    exists (
      select 1 from public.stock_ledger
      where stock_ledger.transaction_id = txn and stock_ledger.lot_id is null
    ),
    exists (
      select 1 from public.stock_ledger
      where stock_ledger.transaction_id = txn and stock_ledger.lot_id is not null
    )
  into has_null, has_lot;

  if not has_lot then
    return null;
  end if;

  if has_null then
    raise exception
      'lot-aware stock transaction cannot mix NULL and non-NULL lot_id ledger rows'
      using errcode = '23514';
  end if;

  select *
  into applied
  from public.stock_lot_aware_applications
  where stock_lot_aware_applications.transaction_id = txn;

  if not found then
    raise exception
      'lot_id ledger rows require a matching lot-aware helper application'
      using errcode = '23514';
  end if;

  ledger_fp := app_private.ledger_lot_fingerprint(txn);
  if ledger_fp is distinct from applied.delta_fingerprint then
    raise exception
      'lot-aware ledger fingerprint does not match applied deltas'
      using errcode = '23514';
  end if;

  return null;
end;
$$;

revoke all on function app_private.assert_lot_aware_transaction_integrity()
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Cumulative lot conservation (marker baseline + lot_id ledger only)
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_lot_quantity_conservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  check_lot uuid;
  balance_total integer;
  ledger_total integer;
  baseline_total integer;
  has_marker boolean;
  has_lot_ledger boolean;
begin
  -- While seed establishes the marker baseline, skip until markers exist.
  if app_private.lot_balance_write_mode() is not distinct from 'seed' then
    return null;
  end if;

  if tg_table_name = 'stock_ledger' then
    check_lot := coalesce(new.lot_id, old.lot_id);
  else
    check_lot := coalesce(new.lot_id, old.lot_id);
  end if;

  if check_lot is null then
    return null;
  end if;

  select exists (
    select 1 from public.stock_legacy_lot_seeds
    where stock_legacy_lot_seeds.lot_id = check_lot
  )
  into has_marker;

  select exists (
    select 1 from public.stock_ledger
    where stock_ledger.lot_id = check_lot
  )
  into has_lot_ledger;

  -- Fixtures / pre-attribution balances: no marker and no lot-ledger yet.
  if not has_marker and not has_lot_ledger then
    return null;
  end if;

  select coalesce(sum(stock_lot_balances.quantity), 0)
  into balance_total
  from public.stock_lot_balances
  where stock_lot_balances.lot_id = check_lot;

  -- Never include NULL-lot ledger rows in lot conservation.
  select coalesce(sum(stock_ledger.quantity), 0)
  into ledger_total
  from public.stock_ledger
  where stock_ledger.lot_id = check_lot;

  if has_marker then
    select coalesce(sum(stock_legacy_lot_seeds.quantity), 0)
    into baseline_total
    from public.stock_legacy_lot_seeds
    where stock_legacy_lot_seeds.lot_id = check_lot;

    if balance_total is distinct from (baseline_total + ledger_total) then
      raise exception
        'legacy lot conservation failed for lot % (balances %, baseline %, lot_ledger %)',
        check_lot,
        balance_total,
        baseline_total,
        ledger_total
        using errcode = '23514';
    end if;
  else
    if balance_total is distinct from ledger_total then
      raise exception
        'attributed lot conservation failed for lot % (balances %, lot_ledger %)',
        check_lot,
        balance_total,
        ledger_total
        using errcode = '23514';
    end if;
  end if;

  return null;
end;
$$;

drop trigger if exists stock_lot_balances_quantity_conservation on public.stock_lot_balances;
create constraint trigger stock_lot_balances_quantity_conservation
  after insert or update or delete on public.stock_lot_balances
  deferrable initially deferred
  for each row
  execute function app_private.assert_lot_quantity_conservation();

drop trigger if exists stock_ledger_lot_quantity_conservation on public.stock_ledger;
create constraint trigger stock_ledger_lot_quantity_conservation
  after insert or update or delete on public.stock_ledger
  deferrable initially deferred
  for each row
  execute function app_private.assert_lot_quantity_conservation();

revoke all on function app_private.assert_lot_quantity_conservation()
  from public, anon, authenticated, service_role;

comment on function app_private.assert_lot_quantity_conservation() is
  'Deferred. Marker lots: balances = seed baseline + lot_id ledger. Attributed lots with lot-ledger: balances = lot_id ledger. Ignores NULL-lot ledger.';

-- ---------------------------------------------------------------------------
-- 5. Helper: permit instead of GUC
-- ---------------------------------------------------------------------------

create or replace function app_private.apply_lot_aware_stock_deltas(
  target_transaction uuid,
  lot_deltas jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
  target_lot uuid;
  target_crate uuid;
  target_product uuid;
  line_delta integer;
  selected_lot public.stock_lots%rowtype;
  crate_branch uuid;
  lot_qty integer;
  current_quantity integer;
  crate_ids uuid[];
  product_ids uuid[];
  lot_ids uuid[];
  aggregate_delta integer;
  agg_crate uuid;
  agg_product uuid;
  qty_text text;
  fingerprint text;
  ledger_fp text;
  ledger_null_count integer;
  ledger_lot_count integer;
  ledger_row_count integer;
  delta_row_count integer;
begin
  if target_transaction is null then
    raise exception 'transaction_id is required' using errcode = '23514';
  end if;

  if not exists (
    select 1 from public.stock_transactions where stock_transactions.id = target_transaction
  ) then
    raise exception 'stock transaction not found' using errcode = '23514';
  end if;

  if exists (
    select 1 from public.stock_lot_aware_applications
    where stock_lot_aware_applications.transaction_id = target_transaction
  ) then
    raise exception 'lot-aware deltas already applied for this transaction'
      using errcode = '23514';
  end if;

  if lot_deltas is null or jsonb_typeof(lot_deltas) is distinct from 'array'
    or jsonb_array_length(lot_deltas) < 1
  then
    raise exception 'lot_deltas must be a non-empty json array' using errcode = '23514';
  end if;

  fingerprint := app_private.lot_aware_delta_fingerprint(lot_deltas);

  perform app_private.acquire_stock_cutover_shared_lock();

  create temporary table if not exists pg_temp._lot_aware_lines (
    lot_id uuid not null,
    crate_id uuid not null,
    product_id uuid not null,
    delta integer not null,
    primary key (lot_id, crate_id)
  ) on commit drop;

  create temporary table if not exists pg_temp._lot_aware_agg (
    crate_id uuid not null,
    product_id uuid not null,
    delta integer not null,
    primary key (crate_id, product_id)
  ) on commit drop;

  delete from pg_temp._lot_aware_lines;
  delete from pg_temp._lot_aware_agg;

  for item in select value from jsonb_array_elements(lot_deltas)
  loop
    begin
      target_lot := (item ->> 'lot_id')::uuid;
      target_crate := (item ->> 'crate_id')::uuid;
      target_product := (item ->> 'product_id')::uuid;
      qty_text := coalesce(item ->> 'quantity', item ->> 'carton_delta');
      line_delta := qty_text::integer;
    exception
      when invalid_text_representation or datatype_mismatch then
        raise exception 'lot delta fields must be valid uuid/integer values'
          using errcode = '23514';
    end;

    if target_lot is null or target_crate is null or target_product is null
      or line_delta is null or line_delta = 0
    then
      raise exception
        'each lot delta requires product_id, lot_id, crate_id, and non-zero quantity'
        using errcode = '23514';
    end if;

    if line_delta > 1000000 or line_delta < -1000000 then
      raise exception 'lot delta out of range' using errcode = '23514';
    end if;

    if exists (
      select 1 from pg_temp._lot_aware_lines lines
      where lines.lot_id = target_lot and lines.crate_id = target_crate
    ) then
      raise exception 'duplicate lot_id and crate_id delta is not allowed'
        using errcode = '23514';
    end if;

    insert into pg_temp._lot_aware_lines (lot_id, crate_id, product_id, delta)
    values (target_lot, target_crate, target_product, line_delta);
  end loop;

  select count(*) into delta_row_count from pg_temp._lot_aware_lines;

  select
    count(*) filter (where stock_ledger.lot_id is null),
    count(*) filter (where stock_ledger.lot_id is not null),
    count(*)
  into ledger_null_count, ledger_lot_count, ledger_row_count
  from public.stock_ledger
  where stock_ledger.transaction_id = target_transaction;

  if ledger_row_count < 1 then
    raise exception 'lot-aware helper requires stock_ledger rows for the transaction'
      using errcode = '23514';
  end if;

  if ledger_null_count > 0 then
    raise exception 'lot-aware ledger rows must include lot_id'
      using errcode = '23514';
  end if;

  if ledger_lot_count is distinct from delta_row_count then
    raise exception 'lot-aware ledger row count does not match lot deltas'
      using errcode = '23514';
  end if;

  ledger_fp := app_private.ledger_lot_fingerprint(target_transaction);
  if ledger_fp is distinct from fingerprint then
    raise exception 'lot-aware ledger entries do not match lot deltas'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from pg_temp._lot_aware_lines lines
    where not exists (
      select 1
      from public.stock_ledger
      where stock_ledger.transaction_id = target_transaction
        and stock_ledger.lot_id = lines.lot_id
        and stock_ledger.crate_id = lines.crate_id
        and stock_ledger.product_id = lines.product_id
        and stock_ledger.quantity = lines.delta
    )
  ) then
    raise exception 'lot delta has no matching stock_ledger row' using errcode = '23514';
  end if;

  select array_agg(distinct lines.crate_id order by lines.crate_id)
  into crate_ids from pg_temp._lot_aware_lines lines;
  select array_agg(distinct lines.product_id order by lines.product_id)
  into product_ids from pg_temp._lot_aware_lines lines;
  select array_agg(distinct lines.lot_id order by lines.lot_id)
  into lot_ids from pg_temp._lot_aware_lines lines;

  perform products.id
  from public.products
  where products.id = any (product_ids)
  order by products.id
  for update;

  if (
    select count(*) from public.products
    where products.id = any (product_ids) and products.is_active
  ) is distinct from cardinality(product_ids)
  then
    raise exception 'product not found or inactive' using errcode = '23514';
  end if;

  perform app_private.prepare_stock_locations(crate_ids);

  perform stock_lots.id
  from public.stock_lots
  where stock_lots.id = any (lot_ids)
  order by stock_lots.id
  for update;

  if (
    select count(*) from public.stock_lots where stock_lots.id = any (lot_ids)
  ) is distinct from cardinality(lot_ids)
  then
    raise exception 'stock lot not found' using errcode = '23514';
  end if;

  perform app_private.begin_lot_balance_write('helper');

  for target_lot, target_crate, target_product, line_delta in
    select lines.lot_id, lines.crate_id, lines.product_id, lines.delta
    from pg_temp._lot_aware_lines lines
    order by lines.crate_id, lines.product_id, lines.lot_id
  loop
    select * into selected_lot from public.stock_lots where stock_lots.id = target_lot;

    if selected_lot.product_id is distinct from target_product then
      raise exception 'lot product does not match product_id' using errcode = '23514';
    end if;

    if selected_lot.status = 'available' then
      null;
    elsif selected_lot.status = 'legacy_unattributed' then
      if not app_private.has_permission('stock.lots.legacy.reconcile') then
        raise exception 'legacy_unattributed lots require stock.lots.legacy.reconcile'
          using errcode = '42501';
      end if;
    elsif selected_lot.status in ('quarantined', 'expired_blocked') then
      raise exception 'lot status % cannot be mutated by normal posting', selected_lot.status
        using errcode = '23514';
    else
      raise exception 'unsupported lot status %', selected_lot.status using errcode = '23514';
    end if;

    select zones.branch_id into crate_branch
    from public.crates
    join public.zones on zones.id = crates.zone_id
    where crates.id = target_crate;

    if crate_branch is null then
      raise exception 'crate not found' using errcode = '23514';
    end if;

    if selected_lot.branch_id is distinct from crate_branch then
      raise exception 'lot branch does not match crate godown' using errcode = '23514';
    end if;

    select stock_lot_balances.quantity into lot_qty
    from public.stock_lot_balances
    where stock_lot_balances.lot_id = target_lot
      and stock_lot_balances.crate_id = target_crate
    for update;

    if found then
      if lot_qty + line_delta < 0 then
        raise exception 'insufficient lot stock' using errcode = '23514';
      end if;
      update public.stock_lot_balances
      set quantity = lot_qty + line_delta
      where stock_lot_balances.lot_id = target_lot
        and stock_lot_balances.crate_id = target_crate;
    else
      if line_delta < 1 then
        raise exception 'insufficient lot stock' using errcode = '23514';
      end if;
      insert into public.stock_lot_balances (lot_id, crate_id, quantity)
      values (target_lot, target_crate, line_delta);
    end if;

    insert into pg_temp._lot_aware_agg (crate_id, product_id, delta)
    values (target_crate, target_product, line_delta)
    on conflict (crate_id, product_id)
    do update set delta = pg_temp._lot_aware_agg.delta + excluded.delta;
  end loop;

  for agg_crate, agg_product, aggregate_delta in
    select agg.crate_id, agg.product_id, agg.delta
    from pg_temp._lot_aware_agg agg
    order by agg.crate_id, agg.product_id
  loop
    if aggregate_delta = 0 then
      continue;
    end if;

    select stock_balances.quantity into current_quantity
    from public.stock_balances
    where stock_balances.crate_id = agg_crate
      and stock_balances.product_id = agg_product
    for update;

    if found then
      if current_quantity + aggregate_delta < 0 then
        raise exception 'insufficient stock' using errcode = '23514';
      end if;
      update public.stock_balances
      set quantity = current_quantity + aggregate_delta
      where stock_balances.crate_id = agg_crate
        and stock_balances.product_id = agg_product;
    else
      if aggregate_delta < 1 then
        raise exception 'insufficient stock' using errcode = '23514';
      end if;
      insert into public.stock_balances (crate_id, product_id, quantity)
      values (agg_crate, agg_product, aggregate_delta);
    end if;
  end loop;

  insert into public.stock_lot_aware_applications (transaction_id, delta_fingerprint)
  values (target_transaction, fingerprint);

  perform app_private.end_lot_balance_write();
exception
  when others then
    perform app_private.end_lot_balance_write();
    raise;
end;
$$;

revoke all on function app_private.apply_lot_aware_stock_deltas(uuid, jsonb)
  from public, anon, authenticated, service_role;

comment on function app_private.apply_lot_aware_stock_deltas(uuid, jsonb) is
  'Phase 4.3E.2B.2. Opens a private helper write permit (not GUC). Requires matching lot_id ledger. Not client-callable; not wired to posting RPCs.';

-- ---------------------------------------------------------------------------
-- 6. Legacy seed: permit instead of GUC
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
  perform app_private.lot_seed_lock_exclusive();
  perform app_private.begin_lot_balance_write('seed');

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
      product_id, branch_id, manufacturer_lot_code, manufactured_on, expiry_date,
      received_on, status, origin, source_receipt_line_id, source_transaction_id, created_by
    )
    values (
      grain.product_id, branch, null, null, null, null,
      'legacy_unattributed', 'legacy_reconciliation', null, null, actor
    )
    returning id into lot_id;

    insert into public.stock_lot_balances (lot_id, crate_id, quantity)
    values (lot_id, grain.crate_id, grain.quantity);

    insert into public.stock_legacy_lot_seeds (
      crate_id, product_id, lot_id, quantity, seeded_by
    )
    values (grain.crate_id, grain.product_id, lot_id, grain.quantity, actor);

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

  perform app_private.end_lot_balance_write();

  return pg_catalog.jsonb_build_object(
    'examined', examined_count,
    'seeded', seeded_count,
    'skipped_idempotent', skipped_count,
    'aggregate_only_blocked', true,
    'dual_write_enabled', false
  );
exception
  when others then
    perform app_private.end_lot_balance_write();
    raise;
end;
$$;

revoke all on function public.seed_legacy_stock_lots()
  from public, anon, service_role;
grant execute on function public.seed_legacy_stock_lots()
  to authenticated;

comment on function public.seed_legacy_stock_lots() is
  'Requires stock.lots.seed (Admin). Opens a private seed write permit (not GUC). Exclusive cutover lock. Idempotent. Sets aggregate_only_blocked; does not auto-run on migration apply.';
