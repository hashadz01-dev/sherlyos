-- Phase 4.3E.2B: private lot-aware dual-write foundation (local-first).
-- Forward-only after 20261022150000.
-- Delivers:
--   * app_private.apply_lot_aware_stock_deltas — private helper (not wired to posting RPCs)
--   * stock_receipt_line_lot_attributions + controlled write RPC (pre-verify durable attrs)
--   * Admin-only stock.lots.legacy.reconcile permission (D1; unused by posting yet)
--   * Adjustment stale-version PT409 (D4)
-- Does NOT: enable dual_write, seed lots, rewrite opening/transfer/receive/adjust posting,
-- FEFO/picking, availability cutover, or cross-godown moves.

-- ---------------------------------------------------------------------------
-- 1. D1 permission (Admin only) — reserved for later legacy reconcile RPCs
-- ---------------------------------------------------------------------------

insert into public.permissions (code, description)
values (
  'stock.lots.legacy.reconcile',
  'Adjust or correct legacy_unattributed stock lots. Admin only.'
)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'stock.lots.legacy.reconcile'
where roles.code = 'admin'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. Durable receipt line lot attributions (D2)
-- ---------------------------------------------------------------------------

create table public.stock_receipt_line_lot_attributions (
  id uuid primary key default gen_random_uuid(),
  receipt_line_id uuid not null references public.stock_receipt_lines (id) on delete cascade,
  carton_quantity integer not null,
  manufacturer_lot_code text,
  manufactured_on date,
  expiry_date date,
  sort_order integer not null default 0,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  created_by uuid references public.profiles (id) on delete restrict,
  constraint stock_receipt_line_lot_attributions_qty_check
    check (carton_quantity > 0 and carton_quantity <= 1000000),
  constraint stock_receipt_line_lot_attributions_sort_check
    check (sort_order >= 0),
  constraint stock_receipt_line_lot_attributions_code_shape check (
    manufacturer_lot_code is null
    or (
      char_length(btrim(manufacturer_lot_code)) between 1 and 80
      and manufacturer_lot_code = btrim(manufacturer_lot_code)
    )
  ),
  constraint stock_receipt_line_lot_attributions_dates_order check (
    manufactured_on is null
    or expiry_date is null
    or manufactured_on <= expiry_date
  )
);

create index stock_receipt_line_lot_attributions_line_idx
  on public.stock_receipt_line_lot_attributions (receipt_line_id, sort_order, id);

comment on table public.stock_receipt_line_lot_attributions is
  'Phase 4.3E.2B. Durable pre-verify lot attributions for a receipt line. Multiple rows per line allowed (no unique on source_receipt_line_id). Posted receipts are immutable. Lot-aware verify posting is a later increment.';

alter table public.stock_receipt_line_lot_attributions enable row level security;
alter table public.stock_receipt_line_lot_attributions force row level security;

create policy stock_receipt_line_lot_attributions_select
  on public.stock_receipt_line_lot_attributions
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.stock_receipt_lines
      join public.stock_receipts on stock_receipts.id = stock_receipt_lines.receipt_id
      where stock_receipt_lines.id = stock_receipt_line_lot_attributions.receipt_line_id
        and (select app_private.can_view_stock_receipt(stock_receipts))
    )
  );

revoke all on table public.stock_receipt_line_lot_attributions
  from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate
  on table public.stock_receipt_line_lot_attributions from service_role;
grant select on table public.stock_receipt_line_lot_attributions to authenticated;

create or replace function app_private.reject_posted_receipt_attribution_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  receipt_status text;
  line_id uuid;
begin
  line_id := coalesce(new.receipt_line_id, old.receipt_line_id);

  select stock_receipts.status
  into receipt_status
  from public.stock_receipt_lines
  join public.stock_receipts on stock_receipts.id = stock_receipt_lines.receipt_id
  where stock_receipt_lines.id = line_id;

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

create trigger stock_receipt_line_lot_attributions_immutable_when_closed
  before insert or update or delete on public.stock_receipt_line_lot_attributions
  for each row
  execute function app_private.reject_posted_receipt_attribution_change();

revoke all on function app_private.reject_posted_receipt_attribution_change()
  from public, anon, authenticated, service_role;

-- Include attributions in posting fingerprint (for future verify idempotency).
create or replace function app_private.receipt_posting_fingerprint(target uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select stock_receipts.godown_id::text
    || '|' || stock_receipts.supplier_id::text
    || '|' || stock_receipts.normalized_document_reference
    || '|' || coalesce((
      select pg_catalog.string_agg(
        stock_receipt_lines.product_id::text
          || ':' || stock_receipt_lines.destination_crate_id::text
          || ':' || stock_receipt_lines.document_cases::text
          || ':' || stock_receipt_lines.counted_cases::text
          || ':' || stock_receipt_lines.damaged_cases::text
          || ':' || coalesce((
            select pg_catalog.string_agg(
              coalesce(attr.manufacturer_lot_code, '')
                || '/' || coalesce(attr.manufactured_on::text, '')
                || '/' || coalesce(attr.expiry_date::text, '')
                || '/' || attr.carton_quantity::text,
              ';'
              order by attr.sort_order, attr.id
            )
            from public.stock_receipt_line_lot_attributions attr
            where attr.receipt_line_id = stock_receipt_lines.id
          ), ''),
        ','
        order by stock_receipt_lines.id
      )
      from public.stock_receipt_lines
      where stock_receipt_lines.receipt_id = stock_receipts.id
    ), '')
  from public.stock_receipts
  where stock_receipts.id = target;
$$;

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

  for item in
    select value
    from jsonb_array_elements(attributions)
  loop
    qty := (item ->> 'carton_quantity')::integer;
    if qty is null or qty < 1 then
      raise exception 'attribution carton_quantity must be a positive integer'
        using errcode = '23514';
    end if;

    cleaned_code := nullif(pg_catalog.btrim(coalesce(item ->> 'manufacturer_lot_code', '')), '');
    mfg := nullif(item ->> 'manufactured_on', '')::date;
    exp := nullif(item ->> 'expiry_date', '')::date;

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
      receipt_line_id,
      carton_quantity,
      manufacturer_lot_code,
      manufactured_on,
      expiry_date,
      sort_order,
      created_by
    )
    values (
      target_receipt_line,
      qty,
      cleaned_code,
      mfg,
      exp,
      idx,
      auth.uid()
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

comment on function public.set_stock_receipt_line_lot_attributions(uuid, jsonb) is
  'Requires receiving.execute or receiving.verify and branch access. Replaces durable lot attributions for one receipt line before verify. Sum must equal accepted_cases. Does not post stock.';

-- ---------------------------------------------------------------------------
-- 3. Private lot-aware dual-write helper (not wired to posting RPCs)
-- ---------------------------------------------------------------------------

-- When dual-write is eventually active, aggregate-only apply_stock_delta stays closed.
create or replace function app_private.assert_aggregate_stock_mutation_allowed()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  blocked boolean := false;
  dual_write boolean := false;
begin
  select coalesce(app_configuration.value, 'false'::jsonb) = 'true'::jsonb
  into blocked
  from public.app_configuration
  where app_configuration.key = 'stock.lots.aggregate_only_blocked';

  select coalesce(app_configuration.value, 'false'::jsonb) = 'true'::jsonb
  into dual_write
  from public.app_configuration
  where app_configuration.key = 'stock.lots.dual_write_enabled';

  if coalesce(dual_write, false) then
    raise exception
      'aggregate-only stock posting is closed while lot-aware dual-write is active'
      using errcode = '55000';
  end if;

  if coalesce(blocked, false) then
    raise exception
      'aggregate-only stock posting is blocked until lot-aware dual-write is enabled'
      using errcode = '55000';
  end if;
end;
$$;

revoke all on function app_private.assert_aggregate_stock_mutation_allowed()
  from public, anon, authenticated, service_role;

create or replace function app_private.apply_lot_aware_stock_deltas(lot_deltas jsonb)
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
begin
  -- Always lot + aggregate together. No aggregate-only fallback path exists here.
  if lot_deltas is null or jsonb_typeof(lot_deltas) is distinct from 'array'
    or jsonb_array_length(lot_deltas) < 1
  then
    raise exception 'lot_deltas must be a non-empty json array' using errcode = '23514';
  end if;

  -- 1) Shared cutover advisory first (also taken again inside prepare_stock_locations).
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

  for item in
    select value
    from jsonb_array_elements(lot_deltas)
  loop
    target_lot := (item ->> 'lot_id')::uuid;
    target_crate := (item ->> 'crate_id')::uuid;
    target_product := (item ->> 'product_id')::uuid;
    qty_text := coalesce(item ->> 'quantity', item ->> 'carton_delta');
    line_delta := qty_text::integer;

    if target_lot is null
      or target_crate is null
      or target_product is null
      or line_delta is null
      or line_delta = 0
    then
      raise exception
        'each lot delta requires product_id, lot_id, crate_id, and non-zero quantity'
        using errcode = '23514';
    end if;

    if line_delta > 1000000 or line_delta < -1000000 then
      raise exception 'lot delta out of range' using errcode = '23514';
    end if;

    if exists (
      select 1
      from pg_temp._lot_aware_lines lines
      where lines.lot_id = target_lot
        and lines.crate_id = target_crate
        and lines.product_id is distinct from target_product
    ) then
      raise exception 'inconsistent product_id for the same lot and crate'
        using errcode = '23514';
    end if;

    insert into pg_temp._lot_aware_lines (lot_id, crate_id, product_id, delta)
    values (target_lot, target_crate, target_product, line_delta)
    on conflict (lot_id, crate_id) do update
      set delta = pg_temp._lot_aware_lines.delta + excluded.delta;
  end loop;

  delete from pg_temp._lot_aware_lines lines where lines.delta = 0;

  if not exists (select 1 from pg_temp._lot_aware_lines) then
    raise exception 'lot_deltas net to zero; nothing to apply' using errcode = '23514';
  end if;

  select array_agg(distinct lines.crate_id order by lines.crate_id)
  into crate_ids
  from pg_temp._lot_aware_lines lines;

  select array_agg(distinct lines.product_id order by lines.product_id)
  into product_ids
  from pg_temp._lot_aware_lines lines;

  select array_agg(distinct lines.lot_id order by lines.lot_id)
  into lot_ids
  from pg_temp._lot_aware_lines lines;

  -- 2) Products before location locks (compatible with receive/adjust sequences).
  perform products.id
  from public.products
  where products.id = any (product_ids)
  order by products.id
  for update;

  if (
    select count(*)
    from public.products
    where products.id = any (product_ids)
      and products.is_active
  ) is distinct from cardinality(product_ids)
  then
    raise exception 'product not found or inactive' using errcode = '23514';
  end if;

  -- 3) Zones/crates (shared advisory already held; prepare re-takes shared safely).
  perform app_private.prepare_stock_locations(crate_ids);

  -- 4) Lots in id order.
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

  -- Validate lot↔product and lot↔crate branch, then apply lot balances.
  for target_lot, target_crate, target_product, line_delta in
    select lines.lot_id, lines.crate_id, lines.product_id, lines.delta
    from pg_temp._lot_aware_lines lines
    order by lines.crate_id, lines.product_id, lines.lot_id
  loop
    select *
    into selected_lot
    from public.stock_lots
    where stock_lots.id = target_lot;

    if selected_lot.product_id is distinct from target_product then
      raise exception 'lot product does not match product_id' using errcode = '23514';
    end if;

    select zones.branch_id
    into crate_branch
    from public.crates
    join public.zones on zones.id = crates.zone_id
    where crates.id = target_crate;

    if crate_branch is null then
      raise exception 'crate not found' using errcode = '23514';
    end if;

    if selected_lot.branch_id is distinct from crate_branch then
      raise exception 'lot branch does not match crate godown' using errcode = '23514';
    end if;

    select stock_lot_balances.quantity
    into lot_qty
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

  -- 5) Aggregate balances: Σ lot deltas per product×crate (never skip when dual-write).
  for agg_crate, agg_product, aggregate_delta in
    select agg.crate_id, agg.product_id, agg.delta
    from pg_temp._lot_aware_agg agg
    order by agg.crate_id, agg.product_id
  loop
    if aggregate_delta = 0 then
      continue;
    end if;

    select stock_balances.quantity
    into current_quantity
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
end;
$$;

revoke all on function app_private.apply_lot_aware_stock_deltas(jsonb)
  from public, anon, authenticated, service_role;

comment on function app_private.apply_lot_aware_stock_deltas(jsonb) is
  'Phase 4.3E.2B private helper. Input: [{product_id, lot_id, crate_id, quantity|carton_delta}, ...]. Applies lot×crate and matching aggregate deltas under cutover shared lock → products → prepare_stock_locations → lots → balances. Caller must insert matching stock_ledger rows before balance updates. Not granted to clients. Not called by posting RPCs yet.';

-- ---------------------------------------------------------------------------
-- 4. D4 — adjustment stale version → PT409 (keep 42501 for auth/status)
-- ---------------------------------------------------------------------------

create or replace function app_private.lock_adjustment_request(
  target_request uuid,
  expected_version integer
)
returns public.stock_adjustment_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_adjustment_requests;
begin
  perform set_config('app.adjustment_write', 'on', true);

  select *
  into selected
  from public.stock_adjustment_requests
  where stock_adjustment_requests.id = target_request
  for update;

  if not found or not app_private.can_view_stock_adjustment(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'adjustment was changed by someone else' using errcode = 'PT409';
  end if;

  return selected;
end;
$$;

revoke all on function app_private.lock_adjustment_request(uuid, integer)
  from public, anon, authenticated, service_role;

-- post_stock_adjustment: split version (PT409) vs status (42501). Body otherwise unchanged.
create or replace function public.post_stock_adjustment(
  target_request uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_adjustment_requests;
  cleaned_key text;
  fingerprint text;
  replay jsonb;
  crate_ids uuid[];
  line record;
  baseline_quantity integer;
  later_count integer;
  created_id uuid;
  absolute_quantity integer;
  single_crate uuid;
begin
  perform set_config('app.adjustment_write', 'on', true);
  perform app_private.assert_permission('stock.adjustment.post');

  select *
  into selected
  from public.stock_adjustment_requests
  where stock_adjustment_requests.id = target_request
  for update;

  if not found or not app_private.can_work_at_branch(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if selected.compensates_request_id is not null then
    raise exception 'compensation is not available' using errcode = '23514';
  end if;

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  if selected.status = 'posted' then
    select pg_catalog.jsonb_build_object('id', stock_transactions.id, 'reference_number', stock_transactions.reference_number)
    into replay
    from public.stock_transactions
    where stock_transactions.adjustment_request_id = selected.id
      and stock_transactions.idempotency_key = cleaned_key;

    if replay is null then
      raise exception 'adjustment was already posted' using errcode = '23505';
    end if;
    return replay;
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'adjustment was changed by someone else' using errcode = 'PT409';
  end if;

  if selected.status <> 'approved' then
    raise exception 'adjustment cannot be posted' using errcode = '42501';
  end if;

  fingerprint := 'ADJUSTMENT:' || selected.id::text || ':' || selected.version::text;

  select coalesce(pg_catalog.array_agg(distinct stock_adjustment_lines.crate_id), '{}')
  into crate_ids
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released;

  if pg_catalog.cardinality(crate_ids) < 1 then
    raise exception 'an adjustment line is required' using errcode = '23514';
  end if;

  perform products.id
  from public.products
  where products.id in (
    select stock_adjustment_lines.product_id
    from public.stock_adjustment_lines
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
  )
  order by products.id
  for update;

  if app_private.prepare_stock_locations(crate_ids) is distinct from selected.godown_id then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform stock_balances.crate_id
  from public.stock_balances
  join public.stock_adjustment_lines
    on stock_adjustment_lines.crate_id = stock_balances.crate_id
    and stock_adjustment_lines.product_id = stock_balances.product_id
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released
  order by stock_balances.crate_id, stock_balances.product_id
  for update;

  for line in
    select
      stock_adjustment_lines.requested_cases,
      stock_adjustment_lines.crate_id,
      stock_adjustment_lines.product_id,
      stock_verification_lines.reconciled_expected_cases,
      stock_verification_lines.acknowledged_ledger_ids,
      stock_verification_lines.recount_cases,
      stock_verification_lines.final_variance_cases
    from public.stock_adjustment_lines
    join public.stock_verification_lines
      on stock_verification_lines.id = stock_adjustment_lines.verification_line_id
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
    order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id
  loop
    if line.final_variance_cases is distinct from line.requested_cases
      or line.final_variance_cases is distinct from (line.recount_cases - line.reconciled_expected_cases)
    then
      raise exception 'verification line cannot be adjusted' using errcode = '23514';
    end if;

    select count(*)
    into later_count
    from public.stock_ledger
    where stock_ledger.crate_id = line.crate_id
      and stock_ledger.product_id = line.product_id
      and not (
        stock_ledger.id = any (coalesce(line.acknowledged_ledger_ids, '{}'))
        or exists (
          select 1
          from public.stock_verification_snapshot_entries snapshot_entries
          where snapshot_entries.verification_id = selected.verification_id
            and snapshot_entries.ledger_id = stock_ledger.id
        )
      );

    if later_count > 0 then
      raise exception 'adjustment is stale and needs a new verification' using errcode = '23514';
    end if;

    select coalesce(sum(stock_ledger.quantity), 0)
    into baseline_quantity
    from public.stock_ledger
    where stock_ledger.crate_id = line.crate_id
      and stock_ledger.product_id = line.product_id;

    if baseline_quantity is distinct from line.reconciled_expected_cases then
      raise exception 'adjustment is stale and needs a new verification' using errcode = '23514';
    end if;
  end loop;

  select coalesce(sum(pg_catalog.abs(stock_adjustment_lines.requested_cases)), 0)
  into absolute_quantity
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released;

  select case when count(distinct stock_adjustment_lines.crate_id) = 1
    then (pg_catalog.array_agg(stock_adjustment_lines.crate_id))[1] else null end
  into single_crate
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released;

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    notes, product_id, destination_crate_id, quantity, adjustment_request_id
  )
  select
    'ADJUSTMENT',
    selected.request_number,
    auth.uid(),
    cleaned_key,
    fingerprint,
    selected.note,
    stock_adjustment_lines.product_id,
    single_crate,
    absolute_quantity,
    selected.id
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released
  order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id
  limit 1
  returning id into created_id;

  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at
  )
  select
    created_id,
    stock_adjustment_lines.product_id,
    stock_adjustment_lines.crate_id,
    stock_adjustment_lines.requested_cases,
    auth.uid(),
    pg_catalog.clock_timestamp()
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released
  order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id;

  for line in
    select stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id, stock_adjustment_lines.requested_cases
    from public.stock_adjustment_lines
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
    order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id
  loop
    perform app_private.apply_stock_delta(line.crate_id, line.product_id, line.requested_cases);
  end loop;

  update public.stock_adjustment_requests
  set
    status = 'posted',
    posted_by = auth.uid(),
    posted_at = pg_catalog.clock_timestamp(),
    posted_transaction_id = created_id,
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where stock_adjustment_requests.id = selected.id;

  perform app_private.adjustment_event(
    selected.id, 'posted', 'approved', 'posted', selected.version + 1, selected.note
  );
  perform app_private.write_audit(
    auth.uid(),
    'post_stock_adjustment',
    'stock_adjustment_requests',
    selected.id,
    pg_catalog.jsonb_build_object('transaction_id', created_id, 'request_number', selected.request_number)
  );

  return pg_catalog.jsonb_build_object('id', created_id, 'reference_number', selected.request_number);
end;
$$;

revoke all on function public.post_stock_adjustment(uuid, integer, text)
  from public, anon, service_role;
grant execute on function public.post_stock_adjustment(uuid, integer, text)
  to authenticated;
