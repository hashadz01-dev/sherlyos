-- Phase 4.3E.2B.1: ledger / lot integrity hardening (local-first).
-- Forward-only after 20261022160000.
-- Delivers:
--   * apply_lot_aware_stock_deltas(transaction_id, lot_deltas) with ledger match + once-only apply
--   * Reject duplicate (lot_id, crate_id) deltas (H1)
--   * Lot-status eligibility (H4)
--   * GUC-gated lot_balance writes + deferred txn integrity for lot_id ledger (H3)
--   * Receipt attribution receipt-row lock + 23514 numeric casts
-- Does NOT: enable dual_write, seed working DB, wire posting RPCs, rewrite history.

-- ---------------------------------------------------------------------------
-- 1. Application marker (prevents double-apply per stock transaction)
-- ---------------------------------------------------------------------------

create table public.stock_lot_aware_applications (
  transaction_id uuid primary key
    references public.stock_transactions (id) on delete restrict,
  delta_fingerprint text not null,
  applied_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint stock_lot_aware_applications_fp_check
    check (char_length(delta_fingerprint) between 1 and 4000)
);

comment on table public.stock_lot_aware_applications is
  'Phase 4.3E.2B.1. One row per stock transaction that applied lot-aware dual-write deltas. Prevents double-apply.';

alter table public.stock_lot_aware_applications enable row level security;
alter table public.stock_lot_aware_applications force row level security;

revoke all on table public.stock_lot_aware_applications
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Lot-balance write gate (helper | seed only) — distinguishes seed from ops
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_lot_balance_write_allowed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  mode text := pg_catalog.current_setting('app.lot_balance_write', true);
begin
  if mode is not distinct from 'helper' or mode is not distinct from 'seed' then
    return coalesce(new, old);
  end if;

  -- Local/migration table-owner fixtures (never a client role).
  if current_user in ('postgres', 'supabase_admin') then
    return coalesce(new, old);
  end if;

  raise exception
    'stock_lot_balances may only be written by lot-aware helper or legacy seed'
    using errcode = '42501';
end;
$$;

create trigger stock_lot_balances_write_gate
  before insert or update or delete on public.stock_lot_balances
  for each row
  execute function app_private.assert_lot_balance_write_allowed();

revoke all on function app_private.assert_lot_balance_write_allowed()
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Deferred integrity: lot_id ledger requires matching helper application
-- ---------------------------------------------------------------------------

create or replace function app_private.lot_aware_delta_fingerprint(lot_deltas jsonb)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  item jsonb;
  target_lot uuid;
  target_crate uuid;
  target_product uuid;
  line_delta integer;
  qty_text text;
  fp text;
begin
  create temporary table if not exists pg_temp._lot_fp_lines (
    lot_id uuid not null,
    crate_id uuid not null,
    product_id uuid not null,
    delta integer not null,
    primary key (lot_id, crate_id)
  ) on commit drop;

  delete from pg_temp._lot_fp_lines;

  if lot_deltas is null or jsonb_typeof(lot_deltas) is distinct from 'array' then
    raise exception 'lot_deltas must be a json array' using errcode = '23514';
  end if;

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

    if exists (
      select 1 from pg_temp._lot_fp_lines lines
      where lines.lot_id = target_lot and lines.crate_id = target_crate
    ) then
      raise exception 'duplicate lot_id and crate_id delta is not allowed'
        using errcode = '23514';
    end if;

    insert into pg_temp._lot_fp_lines (lot_id, crate_id, product_id, delta)
    values (target_lot, target_crate, target_product, line_delta);
  end loop;

  select string_agg(
    lines.lot_id::text || ':' || lines.crate_id::text || ':' || lines.product_id::text || ':' || lines.delta::text,
    ','
    order by lines.lot_id, lines.crate_id
  )
  into fp
  from pg_temp._lot_fp_lines lines;

  if fp is null then
    raise exception 'lot_deltas must be a non-empty json array' using errcode = '23514';
  end if;

  return fp;
end;
$$;

revoke all on function app_private.lot_aware_delta_fingerprint(jsonb)
  from public, anon, authenticated, service_role;

create or replace function app_private.ledger_lot_fingerprint(target_transaction uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select string_agg(
    stock_ledger.lot_id::text
      || ':' || stock_ledger.crate_id::text
      || ':' || stock_ledger.product_id::text
      || ':' || stock_ledger.quantity::text,
    ','
    order by stock_ledger.lot_id, stock_ledger.crate_id, stock_ledger.id
  )
  from public.stock_ledger
  where stock_ledger.transaction_id = target_transaction
    and stock_ledger.lot_id is not null;
$$;

revoke all on function app_private.ledger_lot_fingerprint(uuid)
  from public, anon, authenticated, service_role;

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
  mode text := pg_catalog.current_setting('app.lot_balance_write', true);
begin
  -- Seed path mutates lot balances without lot_id ledger; skip deferred ops checks.
  if mode is not distinct from 'seed' then
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

  -- Aggregate-only / historical NULL-lot transactions: no lot-aware requirements.
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

-- Deferred: fires at commit after all ledger rows for the statement/txn are visible.
create constraint trigger stock_ledger_lot_aware_integrity
  after insert on public.stock_ledger
  deferrable initially deferred
  for each row
  execute function app_private.assert_lot_aware_transaction_integrity();

revoke all on function app_private.assert_lot_aware_transaction_integrity()
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Replace private helper: (transaction_id, lot_deltas)
-- ---------------------------------------------------------------------------

drop function if exists app_private.apply_lot_aware_stock_deltas(jsonb);

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

  -- Ledger must already exist and exactly match normalized deltas.
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

  -- Reject extra / wrong lot movements not present in deltas (covered by fingerprint),
  -- and reject deltas whose (lot,crate,product,qty) is missing from ledger.
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

  perform set_config('app.lot_balance_write', 'helper', true);

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

  perform set_config('app.lot_balance_write', '', true);
exception
  when others then
    perform set_config('app.lot_balance_write', '', true);
    raise;
end;
$$;

revoke all on function app_private.apply_lot_aware_stock_deltas(uuid, jsonb)
  from public, anon, authenticated, service_role;

comment on function app_private.apply_lot_aware_stock_deltas(uuid, jsonb) is
  'Phase 4.3E.2B.1. Requires transaction_id + lot_deltas matching stock_ledger (lot_id required). Rejects duplicate (lot_id,crate_id). Applies once per transaction. Lot status: available; legacy_unattributed needs stock.lots.legacy.reconcile; quarantined/expired_blocked rejected. Not client-callable; not wired to posting RPCs.';

-- ---------------------------------------------------------------------------
-- 5. Legacy seed: allow lot_balance writes via GUC (H3 compatibility)
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
  perform set_config('app.lot_balance_write', 'seed', true);

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

  perform set_config('app.lot_balance_write', '', true);

  return pg_catalog.jsonb_build_object(
    'examined', examined_count,
    'seeded', seeded_count,
    'skipped_idempotent', skipped_count,
    'aggregate_only_blocked', true,
    'dual_write_enabled', false
  );
exception
  when others then
    perform set_config('app.lot_balance_write', '', true);
    raise;
end;
$$;

revoke all on function public.seed_legacy_stock_lots()
  from public, anon, service_role;
grant execute on function public.seed_legacy_stock_lots()
  to authenticated;

comment on function public.seed_legacy_stock_lots() is
  'Requires stock.lots.seed (Admin). Sets app.lot_balance_write=seed for lot balance inserts. Exclusive cutover lock. Idempotent. Sets aggregate_only_blocked; does not auto-run on migration apply.';

-- ---------------------------------------------------------------------------
-- 6. Receipt attribution: receipt FOR UPDATE + 23514 numeric casts
-- ---------------------------------------------------------------------------

create or replace function app_private.reject_posted_receipt_attribution_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  receipt_status text;
  line_id uuid;
  receipt_id uuid;
begin
  line_id := coalesce(new.receipt_line_id, old.receipt_line_id);

  select stock_receipt_lines.receipt_id
  into receipt_id
  from public.stock_receipt_lines
  where stock_receipt_lines.id = line_id;

  if receipt_id is null then
    raise exception 'receipt line not found' using errcode = '42501';
  end if;

  -- Serialize with verify/submit that lock the receipt row.
  select stock_receipts.status
  into receipt_status
  from public.stock_receipts
  where stock_receipts.id = receipt_id
  for update;

  if receipt_status in ('posted', 'cancelled') then
    raise exception 'receipt lot attributions cannot change after verification or cancellation'
      using errcode = '42501';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function app_private.reject_posted_receipt_attribution_change()
  from public, anon, authenticated, service_role;

create or replace function public.set_stock_receipt_line_lot_attributions(
  target_receipt_line uuid,
  attributions jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_line public.stock_receipt_lines%rowtype;
  selected_receipt public.stock_receipts%rowtype;
  product_policy text;
  item jsonb;
  idx integer := 0;
  total_qty integer := 0;
  cleaned_code text;
  mfg date;
  exp date;
  qty integer;
begin
  if not (
    app_private.has_permission('receiving.execute')
    or app_private.has_permission('receiving.verify')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if attributions is null or jsonb_typeof(attributions) is distinct from 'array' then
    raise exception 'attributions must be a json array' using errcode = '23514';
  end if;

  select *
  into selected_line
  from public.stock_receipt_lines
  where stock_receipt_lines.id = target_receipt_line
  for update;

  if not found then
    raise exception 'receipt line not found' using errcode = '42501';
  end if;

  select *
  into selected_receipt
  from public.stock_receipts
  where stock_receipts.id = selected_line.receipt_id
  for update;

  if not app_private.can_work_at_branch(selected_receipt.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if selected_receipt.status not in ('draft', 'submitted', 'held') then
    raise exception 'receipt lot attributions cannot change in status %', selected_receipt.status
      using errcode = '42501';
  end if;

  select products.expiry_policy
  into product_policy
  from public.products
  where products.id = selected_line.product_id
  for update;

  if not found then
    raise exception 'product not found' using errcode = '23514';
  end if;

  if product_policy is null then
    raise exception 'product expiry policy is unclassified' using errcode = '23514';
  end if;

  delete from public.stock_receipt_line_lot_attributions
  where stock_receipt_line_lot_attributions.receipt_line_id = target_receipt_line;

  for item in select value from jsonb_array_elements(attributions)
  loop
    begin
      qty := (item ->> 'carton_quantity')::integer;
    exception
      when invalid_text_representation or datatype_mismatch then
        raise exception 'attribution carton_quantity must be a positive integer'
          using errcode = '23514';
    end;

    if qty is null or qty < 1 then
      raise exception 'attribution carton_quantity must be a positive integer'
        using errcode = '23514';
    end if;

    begin
      cleaned_code := nullif(pg_catalog.btrim(coalesce(item ->> 'manufacturer_lot_code', '')), '');
      mfg := nullif(item ->> 'manufactured_on', '')::date;
      exp := nullif(item ->> 'expiry_date', '')::date;
    exception
      when invalid_text_representation or datatype_mismatch then
        raise exception 'attribution date fields must be valid dates'
          using errcode = '23514';
    end;

    if product_policy = 'expiry_controlled' and exp is null then
      raise exception 'expiry_date is required for expiry_controlled products'
        using errcode = '23514';
    end if;

    if product_policy = 'non_expiring' and exp is not null then
      raise exception 'expiry_date must be null for non_expiring products'
        using errcode = '23514';
    end if;

    if mfg is not null and exp is not null and mfg > exp then
      raise exception 'manufactured_on cannot be after expiry_date' using errcode = '23514';
    end if;

    insert into public.stock_receipt_line_lot_attributions (
      receipt_line_id, carton_quantity, manufacturer_lot_code,
      manufactured_on, expiry_date, sort_order, created_by
    )
    values (
      target_receipt_line, qty, cleaned_code, mfg, exp, idx, auth.uid()
    );

    total_qty := total_qty + qty;
    idx := idx + 1;
  end loop;

  if selected_line.accepted_cases = 0 then
    if idx <> 0 then
      raise exception 'zero-accepted lines cannot have lot attributions'
        using errcode = '23514';
    end if;
  elsif total_qty is distinct from selected_line.accepted_cases then
    raise exception 'attribution quantities (%) must equal accepted_cases (%)',
      total_qty, selected_line.accepted_cases
      using errcode = '23514';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'set_stock_receipt_line_lot_attributions',
    'stock_receipt_lines',
    target_receipt_line,
    pg_catalog.jsonb_build_object(
      'attribution_count', idx,
      'total_quantity', total_qty
    )
  );

  return (
    select coalesce(pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', attr.id,
        'carton_quantity', attr.carton_quantity,
        'manufacturer_lot_code', attr.manufacturer_lot_code,
        'manufactured_on', attr.manufactured_on,
        'expiry_date', attr.expiry_date,
        'sort_order', attr.sort_order
      )
      order by attr.sort_order, attr.id
    ), '[]'::jsonb)
    from public.stock_receipt_line_lot_attributions attr
    where attr.receipt_line_id = target_receipt_line
  );
end;
$$;

revoke all on function public.set_stock_receipt_line_lot_attributions(uuid, jsonb)
  from public, anon, service_role;
grant execute on function public.set_stock_receipt_line_lot_attributions(uuid, jsonb)
  to authenticated;
