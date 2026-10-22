-- Phase 4.3E.1: legacy inventory lot seeding (local-first).
-- Forward-only after 20261022120000. Does NOT implement dual-write, FEFO/FIFO,
-- picking, fulfilment-availability cutover, or cross-godown lot moves.
--
-- Safety: after a successful seed, aggregate-only stock mutations via
-- app_private.apply_stock_delta are blocked until stock.lots.dual_write_enabled
-- is true (later phase). Seed and posting share an advisory lock so they cannot
-- race past each other.

-- ---------------------------------------------------------------------------
-- 1. Permission (Admin only)
-- ---------------------------------------------------------------------------

insert into public.permissions (code, description)
values (
  'stock.lots.seed',
  'Seed legacy_unattributed lots from existing aggregate stock balances. Admin only.'
)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'stock.lots.seed'
where roles.code = 'admin'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. Cutover configuration
-- ---------------------------------------------------------------------------

insert into public.app_configuration (key, value, description)
values
  (
    'stock.lots.dual_write_enabled',
    'false'::jsonb,
    'Phase 4.3E+. When true, lot-aware posting may update aggregate and lot balances together. Remains false in 4.3E.1.'
  ),
  (
    'stock.lots.aggregate_only_blocked',
    'false'::jsonb,
    'Phase 4.3E.1. Set true after successful legacy seed. Blocks aggregate-only apply_stock_delta until dual_write_enabled.'
  )
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 3. Durable per-grain seed marker (idempotency)
-- ---------------------------------------------------------------------------

create table public.stock_legacy_lot_seeds (
  crate_id uuid not null references public.crates (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  lot_id uuid not null references public.stock_lots (id) on delete restrict,
  quantity integer not null,
  seeded_at timestamptz not null default pg_catalog.clock_timestamp(),
  seeded_by uuid references public.profiles (id) on delete restrict,
  primary key (crate_id, product_id),
  constraint stock_legacy_lot_seeds_lot_id_key unique (lot_id),
  constraint stock_legacy_lot_seeds_quantity_check
    check (quantity > 0 and quantity <= 1000000)
);

create index stock_legacy_lot_seeds_product_id_idx
  on public.stock_legacy_lot_seeds (product_id);

comment on table public.stock_legacy_lot_seeds is
  'Phase 4.3E.1. One row per seeded (crate_id, product_id) grain. Enforces idempotent legacy seeding. Mismatch between marker, lot balance, and aggregate is a hard reconciliation error.';

alter table public.stock_legacy_lot_seeds enable row level security;
alter table public.stock_legacy_lot_seeds force row level security;

create policy stock_legacy_lot_seeds_select_authorized
  on public.stock_legacy_lot_seeds
  for select
  to authenticated
  using (
    (select app_private.has_permission('stock.read'))
    and (select app_private.has_permission('products.read'))
    and exists (
      select 1
      from public.crates
      join public.zones on zones.id = crates.zone_id
      where crates.id = stock_legacy_lot_seeds.crate_id
        and (select app_private.can_work_at_branch(zones.branch_id))
    )
  );

revoke all on table public.stock_legacy_lot_seeds
  from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate
  on table public.stock_legacy_lot_seeds from service_role;
grant select on table public.stock_legacy_lot_seeds to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Advisory lock helpers + aggregate mutation guard
-- ---------------------------------------------------------------------------

-- Lock class constants: (88104301, 1) reserved for legacy lot seed cutover.

create or replace function app_private.lot_seed_lock_shared()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_catalog.pg_advisory_xact_lock_shared(88104301, 1);
end;
$$;

create or replace function app_private.lot_seed_lock_exclusive()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(88104301, 1);
end;
$$;

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

  if coalesce(blocked, false) and not coalesce(dual_write, false) then
    raise exception
      'aggregate-only stock posting is blocked until lot-aware dual-write is enabled'
      using errcode = '55000';
  end if;
end;
$$;

revoke all on function app_private.lot_seed_lock_shared()
  from public, anon, authenticated, service_role;
revoke all on function app_private.lot_seed_lock_exclusive()
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_aggregate_stock_mutation_allowed()
  from public, anon, authenticated, service_role;

create or replace function app_private.apply_stock_delta(
  target_crate uuid,
  target_product uuid,
  delta integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_quantity integer;
begin
  -- Serialize against legacy seed (exclusive) and re-check cutover under the lock.
  perform app_private.lot_seed_lock_shared();
  perform app_private.assert_aggregate_stock_mutation_allowed();

  select stock_balances.quantity
  into current_quantity
  from public.stock_balances
  where stock_balances.crate_id = target_crate
    and stock_balances.product_id = target_product
  for update;

  if found then
    if current_quantity + delta < 0 then
      raise exception 'insufficient stock' using errcode = '23514';
    end if;

    update public.stock_balances
    set quantity = current_quantity + delta
    where stock_balances.crate_id = target_crate
      and stock_balances.product_id = target_product;
    return;
  end if;

  if delta < 1 then
    raise exception 'insufficient stock' using errcode = '23514';
  end if;

  insert into public.stock_balances (crate_id, product_id, quantity)
  values (target_crate, target_product, delta);
end;
$$;

revoke all on function app_private.apply_stock_delta(uuid, uuid, integer)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Seed RPC
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
  seeded_count integer := 0;
  skipped_count integer := 0;
  examined_count integer := 0;
begin
  perform app_private.assert_permission('stock.lots.seed');
  perform app_private.lot_seed_lock_exclusive();

  -- prepare_stock_locations requires one godown per call; seed may span godowns.
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

  -- Zero-quantity rows are intentionally skipped (not examined above).

  update public.app_configuration
  set value = 'true'::jsonb
  where app_configuration.key = 'stock.lots.aggregate_only_blocked';

  if not found then
    insert into public.app_configuration (key, value, description)
    values (
      'stock.lots.aggregate_only_blocked',
      'true'::jsonb,
      'Phase 4.3E.1. Set true after successful legacy seed. Blocks aggregate-only apply_stock_delta until dual_write_enabled.'
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
  'Requires stock.lots.seed (Admin). Creates one legacy_unattributed lot per positive stock_balances grain. Idempotent via stock_legacy_lot_seeds. Blocks aggregate-only posting until dual-write. Does not rewrite ledger or change aggregate quantities.';
