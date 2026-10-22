-- M1-S3: legacy lot attribution from approved physical evidence (Approach B).
-- Forward-only after 20261022210000. Does not rewrite deployed migrations.
-- Does not seed lots, attribute cloud inventory, or flip cutover flags.

-- ---------------------------------------------------------------------------
-- 1. Additive session status + applied provenance
-- ---------------------------------------------------------------------------

alter table public.stock_lot_reconciliations
  drop constraint stock_lot_reconciliations_status_check;

alter table public.stock_lot_reconciliations
  add constraint stock_lot_reconciliations_status_check check (
    status in ('draft', 'submitted', 'approved', 'rejected', 'cancelled', 'applied')
  );

alter table public.stock_lot_reconciliations
  add column applied_by uuid references public.profiles (id) on delete restrict,
  add column applied_at timestamptz;

alter table public.stock_lot_reconciliation_events
  drop constraint stock_lot_reconciliation_events_type_check;

alter table public.stock_lot_reconciliation_events
  add constraint stock_lot_reconciliation_events_type_check check (
    event_type in (
      'created',
      'scope_assigned',
      'count_saved',
      'lots_saved',
      'found_product_added',
      'expected_refreshed',
      'submitted',
      'approved',
      'rejected',
      'reopened',
      'cancelled',
      'applied'
    )
  );

-- Seed marker may record a zero remainder after a full split. The row is kept
-- as provenance pointing at the original unattributed lot.
alter table public.stock_legacy_lot_seeds
  drop constraint stock_legacy_lot_seeds_quantity_check;

alter table public.stock_legacy_lot_seeds
  add constraint stock_legacy_lot_seeds_quantity_check
    check (quantity >= 0 and quantity <= 1000000);

-- ---------------------------------------------------------------------------
-- 2. Durable attribution evidence + conservation baselines
-- ---------------------------------------------------------------------------

create table public.stock_lot_reconciliation_attributions (
  session_id uuid not null references public.stock_lot_reconciliations (id) on delete restrict,
  crate_id uuid not null references public.crates (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  source_lot_id uuid not null references public.stock_lots (id) on delete restrict,
  remaining_unattributed integer not null,
  attributed_quantity integer not null,
  unknown_quantity integer not null,
  applied_by uuid not null references public.profiles (id) on delete restrict,
  applied_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (session_id, crate_id, product_id),
  constraint stock_lot_reconciliation_attributions_remaining_check
    check (remaining_unattributed >= 0 and remaining_unattributed <= 1000000),
  constraint stock_lot_reconciliation_attributions_attributed_check
    check (attributed_quantity >= 0 and attributed_quantity <= 1000000),
  constraint stock_lot_reconciliation_attributions_unknown_check
    check (unknown_quantity >= 0 and unknown_quantity <= 1000000),
  constraint stock_lot_reconciliation_attributions_split_check
    check (remaining_unattributed = unknown_quantity)
);

comment on table public.stock_lot_reconciliation_attributions is
  'M1-S3. One row per attributed grain. Prevents duplicate apply. Clients cannot write.';

create index stock_lot_reconciliation_attributions_source_lot_idx
  on public.stock_lot_reconciliation_attributions (source_lot_id);

alter table public.stock_lot_reconciliation_attributions enable row level security;
alter table public.stock_lot_reconciliation_attributions force row level security;

create policy stock_lot_reconciliation_attributions_select_authorized
  on public.stock_lot_reconciliation_attributions
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.stock_lot_reconciliations header
      where header.id = stock_lot_reconciliation_attributions.session_id
        and (
          app_private.has_permission('stock.lots.physical_reconcile')
          or app_private.has_permission('stock.lots.legacy.reconcile')
          or app_private.has_permission('operations.monitor')
        )
        and app_private.can_view_lot_reconciliation(header.godown_id)
    )
  );

revoke all on table public.stock_lot_reconciliation_attributions
  from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate
  on table public.stock_lot_reconciliation_attributions from service_role;
grant select on table public.stock_lot_reconciliation_attributions to authenticated;

create trigger stock_lot_reconciliation_attributions_guard
  before insert or update or delete on public.stock_lot_reconciliation_attributions
  for each row execute function app_private.guard_lot_reconciliation_write();

create table public.stock_lot_attribution_baselines (
  lot_id uuid not null references public.stock_lots (id) on delete restrict,
  crate_id uuid not null references public.crates (id) on delete restrict,
  session_id uuid not null references public.stock_lot_reconciliations (id) on delete restrict,
  quantity integer not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (lot_id, crate_id),
  constraint stock_lot_attribution_baselines_quantity_check
    check (quantity >= 0 and quantity <= 1000000)
);

comment on table public.stock_lot_attribution_baselines is
  'M1-S3. Opening attributed qty per lot×crate so later lot-id ledger can conserve without rewriting historical aggregate ledger.';

create index stock_lot_attribution_baselines_session_idx
  on public.stock_lot_attribution_baselines (session_id);

alter table public.stock_lot_attribution_baselines enable row level security;
alter table public.stock_lot_attribution_baselines force row level security;

create policy stock_lot_attribution_baselines_select_authorized
  on public.stock_lot_attribution_baselines
  for select
  to authenticated
  using (
    (select app_private.has_permission('stock.read'))
    and exists (
      select 1
      from public.crates
      join public.zones on zones.id = crates.zone_id
      where crates.id = stock_lot_attribution_baselines.crate_id
        and (select app_private.can_work_at_branch(zones.branch_id))
    )
  );

revoke all on table public.stock_lot_attribution_baselines
  from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate
  on table public.stock_lot_attribution_baselines from service_role;
grant select on table public.stock_lot_attribution_baselines to authenticated;

create trigger stock_lot_attribution_baselines_guard
  before insert or update or delete on public.stock_lot_attribution_baselines
  for each row execute function app_private.guard_lot_reconciliation_write();

-- Same manufacturer identity must not create a second legacy lot in one branch.
create unique index stock_lots_legacy_attributed_identity
  on public.stock_lots (
    product_id,
    branch_id,
    manufacturer_lot_code,
    expiry_date,
    status
  )
  nulls not distinct
  where origin = 'legacy_reconciliation'
    and manufacturer_lot_code is not null
    and status is distinct from 'legacy_unattributed';

-- ---------------------------------------------------------------------------
-- 3. Trusted writer: attribution permit (no ledger writes, conservation stays on)
-- ---------------------------------------------------------------------------

alter table app_private.lot_balance_write_permits
  drop constraint lot_balance_write_permits_mode_check;

alter table app_private.lot_balance_write_permits
  add constraint lot_balance_write_permits_mode_check
    check (mode in ('helper', 'seed', 'attribution'));

create or replace function app_private.begin_lot_balance_write(p_mode text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_mode is distinct from 'helper'
    and p_mode is distinct from 'seed'
    and p_mode is distinct from 'attribution'
  then
    raise exception 'invalid lot balance write mode' using errcode = '23514';
  end if;

  insert into app_private.lot_balance_write_permits (xact_id, mode)
  values (pg_catalog.pg_current_xact_id(), p_mode)
  on conflict (xact_id) do update
    set mode = excluded.mode,
        opened_at = pg_catalog.clock_timestamp();
end;
$$;

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
    'stock_lot_balances may only be written by lot-aware helper, legacy seed, or attribution'
    using errcode = '42501';
end;
$$;

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
  attr_baseline integer;
  has_marker boolean;
  has_attr boolean;
  has_lot_ledger boolean;
begin
  if app_private.lot_balance_write_mode() is not distinct from 'seed' then
    return null;
  end if;

  check_lot := coalesce(new.lot_id, old.lot_id);
  if check_lot is null then
    return null;
  end if;

  select exists (
    select 1 from public.stock_legacy_lot_seeds
    where stock_legacy_lot_seeds.lot_id = check_lot
  )
  into has_marker;

  select exists (
    select 1 from public.stock_lot_attribution_baselines
    where stock_lot_attribution_baselines.lot_id = check_lot
  )
  into has_attr;

  select exists (
    select 1 from public.stock_ledger
    where stock_ledger.lot_id = check_lot
  )
  into has_lot_ledger;

  if not has_marker and not has_attr and not has_lot_ledger then
    return null;
  end if;

  select coalesce(sum(stock_lot_balances.quantity), 0)
  into balance_total
  from public.stock_lot_balances
  where stock_lot_balances.lot_id = check_lot;

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
  elsif has_attr then
    select coalesce(sum(stock_lot_attribution_baselines.quantity), 0)
    into attr_baseline
    from public.stock_lot_attribution_baselines
    where stock_lot_attribution_baselines.lot_id = check_lot;

    if balance_total is distinct from (attr_baseline + ledger_total) then
      raise exception
        'attributed lot conservation failed for lot % (balances %, baseline %, lot_ledger %)',
        check_lot,
        balance_total,
        attr_baseline,
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

comment on function app_private.assert_lot_quantity_conservation() is
  'Deferred. Marker lots: balances = seed baseline + lot_id ledger. Attributed lots: balances = attribution baseline + lot_id ledger. Ignores NULL-lot ledger.';

-- ---------------------------------------------------------------------------
-- 4. Payload includes applied provenance
-- ---------------------------------------------------------------------------

create or replace function app_private.lot_reconciliation_payload(target_session uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  header public.stock_lot_reconciliations;
  unmatched integer;
  uncounted integer;
  found_count integer;
  unidentified integer;
  unclassified integer;
begin
  perform app_private.assert_lot_reconciliation_reader();

  select *
  into header
  from public.stock_lot_reconciliations
  where id = target_session;

  if not found or not app_private.can_view_lot_reconciliation(header.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select
    count(*) filter (
      where counted_quantity is not null
        and counted_quantity is distinct from expected_quantity
    ),
    count(*) filter (where counted_quantity is null),
    count(*) filter (where is_found_product)
  into unmatched, uncounted, found_count
  from public.stock_lot_reconciliation_lines
  where session_id = header.id;

  select coalesce(sum(lot_entries.quantity), 0)::integer
  into unidentified
  from public.stock_lot_reconciliation_lot_entries lot_entries
  join public.stock_lot_reconciliation_lines lines on lines.id = lot_entries.line_id
  where lines.session_id = header.id
    and lot_entries.identity_unknown;

  select count(distinct products.id)::integer
  into unclassified
  from public.stock_lot_reconciliation_lines
  join public.products on products.id = stock_lot_reconciliation_lines.product_id
  where stock_lot_reconciliation_lines.session_id = header.id
    and products.expiry_policy is distinct from 'expiry_controlled'
    and products.expiry_policy is distinct from 'non_expiring';

  return pg_catalog.jsonb_build_object(
    'id', header.id,
    'session_number', header.session_number,
    'godown_id', header.godown_id,
    'status', header.status,
    'version', header.version,
    'notes', header.notes,
    'created_by', header.created_by,
    'submitted_by', header.submitted_by,
    'submitted_at', header.submitted_at,
    'reviewed_by', header.reviewed_by,
    'reviewed_at', header.reviewed_at,
    'rejection_reason', header.rejection_reason,
    'review_notes', header.review_notes,
    'cancelled_by', header.cancelled_by,
    'cancelled_at', header.cancelled_at,
    'cancellation_reason', header.cancellation_reason,
    'applied_by', header.applied_by,
    'applied_at', header.applied_at,
    'expected_frozen_at', header.expected_frozen_at,
    'created_at', header.created_at,
    'updated_at', header.updated_at,
    'discrepancy', pg_catalog.jsonb_build_object(
      'uncounted_lines', uncounted,
      'unmatched_lines', unmatched,
      'found_product_lines', found_count,
      'unidentified_cases', unidentified,
      'unclassified_products', unclassified
    ),
    'crates', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'crate_id', crates.id,
        'crate_code', crates.code,
        'crate_name', crates.name,
        'zone_id', zones.id,
        'zone_code', zones.code,
        'holds_scope', scope_crates.holds_scope
      ) order by zones.code, crates.code)
      from public.stock_lot_reconciliation_scope_crates scope_crates
      join public.crates on crates.id = scope_crates.crate_id
      join public.zones on zones.id = crates.zone_id
      where scope_crates.session_id = header.id
    ), '[]'::jsonb),
    'lines', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', lines.id,
        'crate_id', lines.crate_id,
        'product_id', lines.product_id,
        'sku', products.sku,
        'product_name', products.name,
        'expiry_policy', products.expiry_policy,
        'expected_quantity', lines.expected_quantity,
        'counted_quantity', lines.counted_quantity,
        'is_found_product', lines.is_found_product,
        'counted_by', lines.counted_by,
        'counted_at', lines.counted_at,
        'lots', coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'id', lot_entries.id,
            'manufacturer_lot_code', lot_entries.manufacturer_lot_code,
            'expiry_date', lot_entries.expiry_date,
            'expiry_unknown', lot_entries.expiry_unknown,
            'identity_unknown', lot_entries.identity_unknown,
            'quantity', lot_entries.quantity,
            'condition', lot_entries.condition
          ) order by lot_entries.created_at, lot_entries.id)
          from public.stock_lot_reconciliation_lot_entries lot_entries
          where lot_entries.line_id = lines.id
        ), '[]'::jsonb)
      ) order by products.sku, lines.crate_id)
      from public.stock_lot_reconciliation_lines lines
      join public.products on products.id = lines.product_id
      where lines.session_id = header.id
    ), '[]'::jsonb),
    'attributions', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'crate_id', attributions.crate_id,
        'product_id', attributions.product_id,
        'source_lot_id', attributions.source_lot_id,
        'remaining_unattributed', attributions.remaining_unattributed,
        'attributed_quantity', attributions.attributed_quantity,
        'unknown_quantity', attributions.unknown_quantity
      ) order by attributions.crate_id, attributions.product_id)
      from public.stock_lot_reconciliation_attributions attributions
      where attributions.session_id = header.id
    ), '[]'::jsonb),
    'events', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', events.id,
        'event_type', events.event_type,
        'actor_id', events.actor_id,
        'from_status', events.from_status,
        'to_status', events.to_status,
        'session_version', events.session_version,
        'payload', events.payload,
        'created_at', events.created_at
      ) order by events.created_at, events.id)
      from public.stock_lot_reconciliation_events events
      where events.session_id = header.id
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Readiness + apply helpers
-- ---------------------------------------------------------------------------

create or replace function app_private.lot_attribution_stays_unattributed(
  identity_unknown boolean,
  expiry_unknown boolean,
  product_policy text
)
returns boolean
language sql
immutable
as $$
  select identity_unknown
    or (
      product_policy is not distinct from 'expiry_controlled'
      and expiry_unknown
    );
$$;

revoke all on function app_private.lot_attribution_stays_unattributed(boolean, boolean, text)
  from public, anon, authenticated, service_role;

create or replace function app_private.lot_attribution_status(lot_condition text)
returns text
language plpgsql
immutable
security definer
set search_path = ''
as $$
begin
  if lot_condition is not distinct from 'expired' then
    return 'expired_blocked';
  end if;
  if lot_condition is not distinct from 'quarantined' then
    return 'quarantined';
  end if;
  if lot_condition is not distinct from 'available' then
    return 'available';
  end if;
  raise exception 'lot condition is invalid' using errcode = '23514';
end;
$$;

revoke all on function app_private.lot_attribution_status(text)
  from public, anon, authenticated, service_role;

create or replace function app_private.lot_attribution_cutover_blockers()
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  dual_write boolean := false;
  blocked boolean := false;
  blockers text[] := '{}';
begin
  select coalesce(app_configuration.value, 'false'::jsonb) = 'true'::jsonb
  into dual_write
  from public.app_configuration
  where app_configuration.key = 'stock.lots.dual_write_enabled';

  select coalesce(app_configuration.value, 'false'::jsonb) = 'true'::jsonb
  into blocked
  from public.app_configuration
  where app_configuration.key = 'stock.lots.aggregate_only_blocked';

  if not coalesce(blocked, false) then
    blockers := array_append(blockers, 'Legacy lot seed must complete before attribution.');
  end if;
  if coalesce(dual_write, false) then
    blockers := array_append(blockers, 'Lot-aware dual-write is already enabled; attribution must run in the post-seed cutover window.');
  end if;
  return blockers;
end;
$$;

revoke all on function app_private.lot_attribution_cutover_blockers()
  from public, anon, authenticated, service_role;

create or replace function app_private.lot_attribution_session_blockers(target_session uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  header public.stock_lot_reconciliations;
  blockers text[] := '{}';
  known_qty integer := 0;
  unknown_qty integer := 0;
  unmatched integer := 0;
  uncounted integer := 0;
  found_count integer := 0;
  unclassified integer := 0;
  missing_lots integer := 0;
  grain record;
  live_qty integer;
  lot_qty integer;
  lot_count integer;
  unattributed_count integer;
  marker public.stock_legacy_lot_seeds%rowtype;
  product_policy text;
begin
  select *
  into header
  from public.stock_lot_reconciliations
  where id = target_session;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  blockers := blockers || app_private.lot_attribution_cutover_blockers();

  if header.status is not distinct from 'applied' then
    blockers := array_append(blockers, 'This session has already been applied.');
  elsif header.status is distinct from 'approved' then
    blockers := array_append(blockers, 'Attribution requires an approved reconciliation session.');
  end if;

  select
    count(*) filter (
      where counted_quantity is not null
        and counted_quantity is distinct from expected_quantity
    ),
    count(*) filter (where counted_quantity is null),
    count(*) filter (where is_found_product)
  into unmatched, uncounted, found_count
  from public.stock_lot_reconciliation_lines
  where session_id = header.id;

  select count(distinct products.id)::integer
  into unclassified
  from public.stock_lot_reconciliation_lines
  join public.products on products.id = stock_lot_reconciliation_lines.product_id
  where stock_lot_reconciliation_lines.session_id = header.id
    and products.expiry_policy is distinct from 'expiry_controlled'
    and products.expiry_policy is distinct from 'non_expiring';

  if found_count > 0 then
    blockers := array_append(blockers, 'Unexpected found-product lines block attribution.');
  end if;
  if unmatched > 0 or uncounted > 0 then
    blockers := array_append(blockers, 'Unmatched counted quantities block attribution.');
  end if;
  if unclassified > 0 then
    blockers := array_append(blockers, 'Unclassified products block attribution.');
  end if;

  select coalesce(sum(lot_entries.quantity) filter (
    where app_private.lot_attribution_stays_unattributed(
      lot_entries.identity_unknown,
      lot_entries.expiry_unknown,
      products.expiry_policy
    )
  ), 0)::integer,
  coalesce(sum(lot_entries.quantity) filter (
    where not app_private.lot_attribution_stays_unattributed(
      lot_entries.identity_unknown,
      lot_entries.expiry_unknown,
      products.expiry_policy
    )
  ), 0)::integer
  into unknown_qty, known_qty
  from public.stock_lot_reconciliation_lot_entries lot_entries
  join public.stock_lot_reconciliation_lines lines on lines.id = lot_entries.line_id
  join public.products on products.id = lines.product_id
  where lines.session_id = header.id
    and not lines.is_found_product;

  select count(*)::integer
  into missing_lots
  from public.stock_lot_reconciliation_lines lines
  where lines.session_id = header.id
    and not lines.is_found_product
    and coalesce(lines.counted_quantity, 0) > 0
    and coalesce((
      select sum(lot_entries.quantity)
      from public.stock_lot_reconciliation_lot_entries lot_entries
      where lot_entries.line_id = lines.id
    ), 0) is distinct from lines.counted_quantity;

  if missing_lots > 0 then
    blockers := array_append(blockers, 'Lot evidence is missing or does not match the counted quantity.');
  end if;

  for grain in
    select lines.*, products.expiry_policy
    from public.stock_lot_reconciliation_lines lines
    join public.products on products.id = lines.product_id
    where lines.session_id = header.id
      and not lines.is_found_product
    order by lines.crate_id, lines.product_id
  loop
    product_policy := grain.expiry_policy;
    if product_policy is distinct from 'expiry_controlled'
      and product_policy is distinct from 'non_expiring'
    then
      continue;
    end if;

    select stock_balances.quantity
    into live_qty
    from public.stock_balances
    where stock_balances.crate_id = grain.crate_id
      and stock_balances.product_id = grain.product_id;

    if not found then
      live_qty := 0;
    end if;

    if live_qty is distinct from grain.expected_quantity
      or live_qty is distinct from grain.counted_quantity
    then
      blockers := array_append(blockers, 'Live aggregate stock no longer matches the approved evidence.');
      exit;
    end if;

    select *
    into marker
    from public.stock_legacy_lot_seeds
    where stock_legacy_lot_seeds.crate_id = grain.crate_id
      and stock_legacy_lot_seeds.product_id = grain.product_id;

    if not found then
      blockers := array_append(blockers, 'Legacy stock has not been seeded for every approved grain.');
      exit;
    end if;

    select
      count(*)::integer,
      count(*) filter (where stock_lots.status = 'legacy_unattributed')::integer
    into lot_count, unattributed_count
    from public.stock_lot_balances
    join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
    where stock_lot_balances.crate_id = grain.crate_id
      and stock_lots.product_id = grain.product_id;

    if lot_count is distinct from 1 or unattributed_count is distinct from 1 then
      blockers := array_append(blockers, 'Approved grains must have exactly one live legacy-unattributed lot matching the aggregate.');
      exit;
    end if;

    select stock_lot_balances.quantity
    into lot_qty
    from public.stock_lot_balances
    where stock_lot_balances.lot_id = marker.lot_id
      and stock_lot_balances.crate_id = grain.crate_id;

    if not found
      or lot_qty is distinct from marker.quantity
      or lot_qty is distinct from live_qty
    then
      blockers := array_append(blockers, 'Approved grains must have exactly one live legacy-unattributed lot matching the aggregate.');
      exit;
    end if;
  end loop;

  return pg_catalog.jsonb_build_object(
    'session_id', header.id,
    'status', header.status,
    'already_applied', header.status is not distinct from 'applied',
    'eligible', coalesce(pg_catalog.array_length(blockers, 1), 0) = 0,
    'blockers', to_jsonb(blockers),
    'known_quantity', known_qty,
    'unknown_quantity', unknown_qty,
    'dual_write_enabled', exists (
      select 1 from public.app_configuration
      where key = 'stock.lots.dual_write_enabled' and value = 'true'::jsonb
    ),
    'aggregate_only_blocked', exists (
      select 1 from public.app_configuration
      where key = 'stock.lots.aggregate_only_blocked' and value = 'true'::jsonb
    )
  );
end;
$$;

revoke all on function app_private.lot_attribution_session_blockers(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.apply_legacy_lot_attribution_grain(
  header public.stock_lot_reconciliations,
  selected_line public.stock_lot_reconciliation_lines
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  marker public.stock_legacy_lot_seeds%rowtype;
  source_lot public.stock_lots%rowtype;
  source_qty integer;
  live_qty integer;
  extra_lots integer;
  product_policy text;
  entry public.stock_lot_reconciliation_lot_entries%rowtype;
  target_status text;
  found_lot uuid;
  remaining integer;
  attributed_qty integer := 0;
  unknown_qty integer := 0;
begin
  select products.expiry_policy
  into product_policy
  from public.products
  where products.id = selected_line.product_id
  for update;

  if product_policy is distinct from 'expiry_controlled'
    and product_policy is distinct from 'non_expiring'
  then
    raise exception 'Unclassified products block attribution.' using errcode = '23514';
  end if;

  select stock_balances.quantity
  into live_qty
  from public.stock_balances
  where stock_balances.crate_id = selected_line.crate_id
    and stock_balances.product_id = selected_line.product_id
  for update;

  if not found then
    live_qty := 0;
  end if;

  if live_qty is distinct from selected_line.expected_quantity
    or live_qty is distinct from selected_line.counted_quantity
  then
    raise exception 'Live aggregate stock no longer matches the approved evidence.'
      using errcode = '23514';
  end if;

  select *
  into marker
  from public.stock_legacy_lot_seeds
  where stock_legacy_lot_seeds.crate_id = selected_line.crate_id
    and stock_legacy_lot_seeds.product_id = selected_line.product_id
  for update;

  if not found then
    raise exception 'Legacy stock has not been seeded for every approved grain.'
      using errcode = '23514';
  end if;

  select *
  into source_lot
  from public.stock_lots
  where stock_lots.id = marker.lot_id
  for update;

  if not found or source_lot.status is distinct from 'legacy_unattributed' then
    raise exception 'Approved grains must have exactly one live legacy-unattributed lot matching the aggregate.'
      using errcode = '23514';
  end if;

  select stock_lot_balances.quantity
  into source_qty
  from public.stock_lot_balances
  where stock_lot_balances.lot_id = marker.lot_id
    and stock_lot_balances.crate_id = selected_line.crate_id
  for update;

  if not found
    or source_qty is distinct from marker.quantity
    or source_qty is distinct from live_qty
  then
    raise exception 'Approved grains must have exactly one live legacy-unattributed lot matching the aggregate.'
      using errcode = '23514';
  end if;

  select count(*)::integer
  into extra_lots
  from public.stock_lot_balances
  join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
  where stock_lot_balances.crate_id = selected_line.crate_id
    and stock_lots.product_id = selected_line.product_id
    and stock_lot_balances.lot_id is distinct from marker.lot_id;

  if extra_lots > 0 then
    raise exception 'Unexpected lot balances exist on an approved grain.'
      using errcode = '23514';
  end if;

  remaining := source_qty;

  for entry in
    select *
    from public.stock_lot_reconciliation_lot_entries
    where line_id = selected_line.id
    order by created_at, id
    for update
  loop
    if app_private.lot_attribution_stays_unattributed(
      entry.identity_unknown,
      entry.expiry_unknown,
      product_policy
    ) then
      unknown_qty := unknown_qty + entry.quantity;
      continue;
    end if;

    if product_policy = 'non_expiring' and entry.expiry_date is not null then
      raise exception 'non-expiring products cannot carry expiry dates' using errcode = '23514';
    end if;

    if product_policy = 'expiry_controlled' and entry.expiry_date is null then
      raise exception 'expiry-controlled lots need an expiry date or an explicit unknown expiry'
        using errcode = '23514';
    end if;

    target_status := app_private.lot_attribution_status(entry.condition);

    select stock_lots.id
    into found_lot
    from public.stock_lots
    where stock_lots.product_id = selected_line.product_id
      and stock_lots.branch_id = header.godown_id
      and stock_lots.manufacturer_lot_code is not distinct from entry.manufacturer_lot_code
      and stock_lots.expiry_date is not distinct from entry.expiry_date
      and stock_lots.status = target_status
      and stock_lots.origin = 'legacy_reconciliation'
    for update;

    if not found then
      insert into public.stock_lots (
        product_id,
        branch_id,
        manufacturer_lot_code,
        manufactured_on,
        expiry_date,
        received_on,
        status,
        origin,
        notes,
        created_by
      )
      values (
        selected_line.product_id,
        header.godown_id,
        entry.manufacturer_lot_code,
        null,
        entry.expiry_date,
        null,
        target_status,
        'legacy_reconciliation',
        'Attributed from ' || header.session_number,
        auth.uid()
      )
      returning id into found_lot;
    end if;

    insert into public.stock_lot_balances (lot_id, crate_id, quantity)
    values (found_lot, selected_line.crate_id, entry.quantity)
    on conflict (lot_id, crate_id) do update
      set quantity = public.stock_lot_balances.quantity + excluded.quantity;

    insert into public.stock_lot_attribution_baselines (
      lot_id, crate_id, session_id, quantity
    )
    values (found_lot, selected_line.crate_id, header.id, entry.quantity)
    on conflict (lot_id, crate_id) do update
      set quantity = public.stock_lot_attribution_baselines.quantity + excluded.quantity;

    remaining := remaining - entry.quantity;
    attributed_qty := attributed_qty + entry.quantity;
  end loop;

  if remaining is distinct from unknown_qty or remaining < 0 then
    raise exception 'Attributed quantities do not conserve the legacy lot.'
      using errcode = '23514';
  end if;

  update public.stock_lot_balances
  set quantity = remaining
  where lot_id = marker.lot_id
    and crate_id = selected_line.crate_id;

  update public.stock_legacy_lot_seeds
  set quantity = remaining
  where crate_id = selected_line.crate_id
    and product_id = selected_line.product_id;

  insert into public.stock_lot_reconciliation_attributions (
    session_id,
    crate_id,
    product_id,
    source_lot_id,
    remaining_unattributed,
    attributed_quantity,
    unknown_quantity,
    applied_by
  )
  values (
    header.id,
    selected_line.crate_id,
    selected_line.product_id,
    marker.lot_id,
    remaining,
    attributed_qty,
    unknown_qty,
    auth.uid()
  );

  return pg_catalog.jsonb_build_object(
    'crate_id', selected_line.crate_id,
    'product_id', selected_line.product_id,
    'source_lot_id', marker.lot_id,
    'attributed_quantity', attributed_qty,
    'unknown_quantity', unknown_qty,
    'remaining_unattributed', remaining
  );
end;
$$;

revoke all on function app_private.apply_legacy_lot_attribution_grain(
  public.stock_lot_reconciliations,
  public.stock_lot_reconciliation_lines
)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Public RPCs
-- ---------------------------------------------------------------------------

create or replace function public.get_lot_attribution_readiness(target_session uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  header public.stock_lot_reconciliations;
begin
  select *
  into header
  from public.stock_lot_reconciliations
  where id = target_session;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_lot_reconciliation_admin(header.godown_id);
  return app_private.lot_attribution_session_blockers(target_session);
end;
$$;

create or replace function public.apply_legacy_lot_attribution(
  target_session uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_lot_reconciliations;
  cleaned_key text;
  replay uuid;
  readiness jsonb;
  blocker text;
  selected_line public.stock_lot_reconciliation_lines;
  grain_results jsonb := '[]'::jsonb;
  grain_result jsonb;
  live_sum integer;
  lot_sum integer;
  ledger_rows integer;
  ledger_net integer;
begin
  perform app_private.assert_permission('stock.lots.legacy.reconcile');

  if idempotency_key is null then
    raise exception 'idempotency key is required' using errcode = '23514';
  end if;
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_lot_reconciliation_event(
    cleaned_key, 'applied', target_session
  );
  if replay is not null then
    return app_private.lot_reconciliation_payload(replay);
  end if;

  -- Exclusive first so this never upgrades from the shared posting/recon lock.
  perform app_private.lot_seed_lock_exclusive();
  perform app_private.begin_lot_balance_write('attribution');
  perform set_config('app.lot_reconciliation_write', 'on', true);

  select *
  into selected
  from public.stock_lot_reconciliations
  where stock_lot_reconciliations.id = target_session
  for update;

  if not found or not app_private.can_view_lot_reconciliation(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_lot_reconciliation_admin(selected.godown_id);

  if selected.status is not distinct from 'applied' then
    perform app_private.end_lot_balance_write();
    return app_private.lot_reconciliation_payload(selected.id);
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'lot reconciliation was changed by someone else' using errcode = 'PT409';
  end if;

  if selected.status is distinct from 'approved' then
    raise exception 'Attribution requires an approved reconciliation session.'
      using errcode = '23514';
  end if;

  perform app_private.lock_lot_reconciliation_inventory(selected.id);

  readiness := app_private.lot_attribution_session_blockers(selected.id);
  if coalesce(readiness ->> 'eligible', 'false') is distinct from 'true' then
    blocker := readiness -> 'blockers' ->> 0;
    raise exception '%', coalesce(blocker, 'Attribution is not eligible.')
      using errcode = '23514';
  end if;

  select count(*)::integer, coalesce(sum(quantity), 0)::integer
  into ledger_rows, ledger_net
  from public.stock_ledger;

  for selected_line in
    select *
    from public.stock_lot_reconciliation_lines
    where session_id = selected.id
      and not is_found_product
    order by crate_id, product_id
    for update
  loop
    grain_result := app_private.apply_legacy_lot_attribution_grain(selected, selected_line);
    grain_results := grain_results || jsonb_build_array(grain_result);

    select stock_balances.quantity
    into live_sum
    from public.stock_balances
    where stock_balances.crate_id = selected_line.crate_id
      and stock_balances.product_id = selected_line.product_id;

    select coalesce(sum(stock_lot_balances.quantity), 0)::integer
    into lot_sum
    from public.stock_lot_balances
    join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
    where stock_lot_balances.crate_id = selected_line.crate_id
      and stock_lots.product_id = selected_line.product_id;

    if lot_sum is distinct from live_sum then
      raise exception 'lot quantities no longer match aggregate stock'
        using errcode = '23514';
    end if;
  end loop;

  if exists (
    select 1
    from public.stock_ledger
    having count(*) is distinct from ledger_rows
      or coalesce(sum(quantity), 0) is distinct from ledger_net
  ) then
    raise exception 'attribution must not rewrite historical ledger rows'
      using errcode = '23514';
  end if;

  update public.stock_lot_reconciliations
  set
    status = 'applied',
    applied_by = auth.uid(),
    applied_at = pg_catalog.clock_timestamp(),
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where id = selected.id;

  update public.stock_lot_reconciliation_scope_crates
  set holds_scope = false
  where session_id = selected.id;

  perform app_private.lot_reconciliation_event(
    selected.id,
    'applied',
    'approved',
    'applied',
    selected.version + 1,
    pg_catalog.jsonb_build_object('grains', grain_results),
    cleaned_key
  );
  perform app_private.write_audit(
    auth.uid(),
    'apply_legacy_lot_attribution',
    'stock_lot_reconciliations',
    selected.id,
    pg_catalog.jsonb_build_object(
      'version', selected.version + 1,
      'grains', grain_results
    )
  );

  perform app_private.end_lot_balance_write();
  return app_private.lot_reconciliation_payload(selected.id);
exception
  when others then
    perform app_private.end_lot_balance_write();
    raise;
end;
$$;

revoke all on function public.get_lot_attribution_readiness(uuid)
  from public, anon, service_role;
revoke all on function public.apply_legacy_lot_attribution(uuid, integer, text)
  from public, anon, service_role;
grant execute on function public.get_lot_attribution_readiness(uuid)
  to authenticated;
grant execute on function public.apply_legacy_lot_attribution(uuid, integer, text)
  to authenticated;

comment on function public.get_lot_attribution_readiness(uuid) is
  'Admin stock.lots.legacy.reconcile. Read-only eligibility, blockers, and known/unknown quantities. Does not mutate inventory.';

comment on function public.apply_legacy_lot_attribution(uuid, integer, text) is
  'Admin stock.lots.legacy.reconcile. Exclusive cutover lock. Splits seeded legacy lots from approved evidence. Does not rewrite aggregate stock or ledger or flip flags.';
