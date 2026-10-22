-- Phase 4.3D: batch/lot and expiry schema foundation (local-first).
-- Prepares products.expiry_policy, stock_lots, stock_lot_balances, and nullable
-- stock_ledger.lot_id. Does NOT seed lots, change stock posting, enable cutover
-- invariants, or implement picking / FEFO / reconciliation workflows.
--
-- Future physical invariant (NOT activated here):
--   stock_balances.quantity(crate, product)
--     = sum(stock_lot_balances.quantity) for lots of that product in that crate
-- Activation requires lot-aware posting cutover and legacy representation (4.3E+).

-- ---------------------------------------------------------------------------
-- 1. Product expiry classification (existing rows stay NULL / unclassified)
-- ---------------------------------------------------------------------------

alter table public.products
  add column expiry_policy text;

alter table public.products
  add constraint products_expiry_policy_check
  check (
    expiry_policy is null
    or expiry_policy in ('expiry_controlled', 'non_expiring')
  );

comment on column public.products.expiry_policy is
  'Phase 4.3D. NULL = unclassified. Admin sets expiry_controlled or non_expiring via set_product_expiry_policy. Existing products remain NULL until classified. Unclassified products must not receive lot-aware intake or picking in later phases.';

-- ---------------------------------------------------------------------------
-- 2. Near-expiry warning configuration (90 days)
-- ---------------------------------------------------------------------------

insert into public.app_configuration (key, value, description)
values (
  'stock.near_expiry_warning_days',
  '90'::jsonb,
  'Approved Phase 4.3 rule. Warn when an expiry-controlled lot expires within this many days. UI warnings are later phases.'
)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 3. stock_lots (empty — no seed)
-- ---------------------------------------------------------------------------

create table public.stock_lots (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete restrict,
  supplier_id uuid references public.suppliers (id) on delete restrict,
  manufacturer_lot_code text,
  manufactured_on date,
  expiry_date date,
  received_on timestamptz,
  status text not null,
  origin text not null,
  source_receipt_line_id uuid references public.stock_receipt_lines (id) on delete restrict,
  source_transaction_id uuid references public.stock_transactions (id) on delete restrict,
  notes text,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  created_by uuid references public.profiles (id) on delete restrict,
  constraint stock_lots_status_check check (
    status in (
      'available',
      'quarantined',
      'expired_blocked',
      'legacy_unattributed'
    )
  ),
  constraint stock_lots_origin_check check (
    origin in (
      'receipt',
      'opening',
      'legacy_reconciliation',
      'adjustment'
    )
  ),
  constraint stock_lots_manufacturer_lot_code_shape check (
    manufacturer_lot_code is null
    or (
      char_length(btrim(manufacturer_lot_code)) between 1 and 80
      and manufacturer_lot_code = btrim(manufacturer_lot_code)
    )
  ),
  constraint stock_lots_notes_shape check (
    notes is null
    or (
      char_length(btrim(notes)) between 1 and 500
      and notes = btrim(notes)
    )
  ),
  constraint stock_lots_dates_order check (
    manufactured_on is null
    or expiry_date is null
    or manufactured_on <= expiry_date
  )
);

create index stock_lots_product_id_idx on public.stock_lots (product_id);
create index stock_lots_status_idx on public.stock_lots (status);
create index stock_lots_expiry_date_idx on public.stock_lots (expiry_date)
  where expiry_date is not null;
create index stock_lots_received_on_idx on public.stock_lots (received_on)
  where received_on is not null;
create index stock_lots_source_receipt_line_idx
  on public.stock_lots (source_receipt_line_id)
  where source_receipt_line_id is not null;

comment on table public.stock_lots is
  'Internal stock lot identity (Phase 4.3D). One row per inbound posting event in later phases — not merged solely by manufacturer lot code. Empty until 4.3E+ workflows. Manufacturer lot code is optional. Expiry/received_on rules are enforced by later posting RPCs using products.expiry_policy.';

comment on column public.stock_lots.manufacturer_lot_code is
  'Optional supplier/manufacturer batch label. Distinct from internal id. May be null when expiry is present (approved A8) once posting exists.';

comment on column public.stock_lots.received_on is
  'Inbound posting chronology for FIFO. Nullable at foundation for future legacy rows; eligible FIFO lots will require a non-null value in later phases.';

comment on column public.stock_lots.expiry_date is
  'Required for expiry_controlled products at lot creation time (later posting). Not fabricated for legacy stock.';

-- Cross-table expiry_policy compatibility cannot be a table CHECK.
-- Later lot-creating RPCs must assert:
--   expiry_controlled => expiry_date is not null
--   non_expiring => expiry_date is null (or ignored for FEFO)
--   unclassified products => reject lot creation / intake

-- ---------------------------------------------------------------------------
-- 4. stock_lot_balances (empty — no seed; not cut over)
-- ---------------------------------------------------------------------------

create table public.stock_lot_balances (
  lot_id uuid not null references public.stock_lots (id) on delete restrict,
  crate_id uuid not null references public.crates (id) on delete restrict,
  quantity integer not null,
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (lot_id, crate_id),
  constraint stock_lot_balances_quantity_check
    check (quantity >= 0 and quantity <= 1000000)
);

create index stock_lot_balances_crate_id_idx
  on public.stock_lot_balances (crate_id);

create index stock_lot_balances_lot_id_idx
  on public.stock_lot_balances (lot_id);

comment on table public.stock_lot_balances is
  'Lot×crate carton-case balances (Phase 4.3D). Authoritative grain after later cutover. Empty now. Existing stock_balances remain the operational aggregate until lot-aware posting is authorized and activated. Clients cannot write this table.';

create trigger stock_lot_balances_set_updated_at
  before update on public.stock_lot_balances
  for each row execute function app_private.set_updated_at();

-- ---------------------------------------------------------------------------
-- 5. Ledger extension — nullable lot_id, no backfill
-- ---------------------------------------------------------------------------

alter table public.stock_ledger
  add column lot_id uuid references public.stock_lots (id) on delete restrict;

create index stock_ledger_lot_id_idx
  on public.stock_ledger (lot_id)
  where lot_id is not null;

comment on column public.stock_ledger.lot_id is
  'Phase 4.3D. Nullable. Historical rows stay NULL. New lot-aware posts in later phases will set lot_id. Not mandatory globally until cutover.';

-- ---------------------------------------------------------------------------
-- 6. Classification RPC
-- ---------------------------------------------------------------------------

create or replace function public.set_product_expiry_policy(
  target_product uuid,
  new_policy text
)
returns public.products
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.products%rowtype;
  cleaned text;
  lot_count integer;
begin
  perform app_private.assert_permission('products.manage');

  cleaned := nullif(pg_catalog.btrim(coalesce(new_policy, '')), '');
  if cleaned is null or cleaned not in ('expiry_controlled', 'non_expiring') then
    raise exception 'expiry policy is invalid' using errcode = '23514';
  end if;

  select *
  into selected
  from public.products
  where products.id = target_product
  for update;

  if not found then
    raise exception 'product not found' using errcode = '42501';
  end if;

  -- Conservative: do not reinterpret existing lot inventory by changing policy.
  select count(*)::integer
  into lot_count
  from public.stock_lots
  where stock_lots.product_id = target_product;

  if lot_count > 0 and selected.expiry_policy is distinct from cleaned then
    raise exception 'expiry policy cannot change while stock lots exist for this product'
      using errcode = '23514';
  end if;

  if selected.expiry_policy is not distinct from cleaned then
    return selected;
  end if;

  update public.products
  set expiry_policy = cleaned
  where products.id = target_product
  returning * into selected;

  perform app_private.write_audit(
    auth.uid(),
    'set_product_expiry_policy',
    'products',
    target_product,
    pg_catalog.jsonb_build_object('expiry_policy', cleaned)
  );

  return selected;
end;
$$;

revoke all on function public.set_product_expiry_policy(uuid, text)
  from public, anon;
grant execute on function public.set_product_expiry_policy(uuid, text)
  to authenticated;

comment on function public.set_product_expiry_policy(uuid, text) is
  'Requires products.manage (Admin). Sets expiry_controlled or non_expiring. Idempotent when unchanged. Rejects policy changes once stock_lots exist for the product. Does not invent classifications for other products.';

-- ---------------------------------------------------------------------------
-- 7. RLS / grants — select only; no client mutations
-- ---------------------------------------------------------------------------

alter table public.stock_lots enable row level security;
alter table public.stock_lots force row level security;
alter table public.stock_lot_balances enable row level security;
alter table public.stock_lot_balances force row level security;

create policy stock_lots_select_authorized
  on public.stock_lots
  for select
  to authenticated
  using (
    (select app_private.has_permission('stock.read'))
    and (select app_private.has_permission('products.read'))
    and (
      not exists (
        select 1
        from public.stock_lot_balances
        where stock_lot_balances.lot_id = stock_lots.id
      )
      or exists (
        select 1
        from public.stock_lot_balances
        join public.crates on crates.id = stock_lot_balances.crate_id
        join public.zones on zones.id = crates.zone_id
        where stock_lot_balances.lot_id = stock_lots.id
          and (select app_private.can_work_at_branch(zones.branch_id))
      )
    )
  );

create policy stock_lot_balances_select_authorized
  on public.stock_lot_balances
  for select
  to authenticated
  using (
    (select app_private.has_permission('stock.read'))
    and exists (
      select 1
      from public.crates
      join public.zones on zones.id = crates.zone_id
      where crates.id = stock_lot_balances.crate_id
        and (select app_private.can_work_at_branch(zones.branch_id))
    )
  );

revoke all on table public.stock_lots from public, anon, authenticated, service_role;
revoke all on table public.stock_lot_balances from public, anon, authenticated, service_role;

revoke insert, update, delete, truncate on table public.stock_lots from service_role;
revoke insert, update, delete, truncate on table public.stock_lot_balances from service_role;

grant select on table public.stock_lots to authenticated;
grant select on table public.stock_lot_balances to authenticated;
