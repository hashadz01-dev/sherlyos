-- M5.3 Damage holds, quarantine locations, and trusted-ledger disposition.
-- Local-first, forward-only after 20261026140000.
-- Does not flip lot cutover flags. damage.stock_hold_ready stays false.
-- Submit always calls apply_damage_stock_isolation; the flag may only fail-closed.

-- ---------------------------------------------------------------------------
-- 1. Location roles (quarantine is categorically unpickable)
-- ---------------------------------------------------------------------------

alter table public.zones
  add column if not exists location_role text not null default 'storage';

alter table public.crates
  add column if not exists location_role text not null default 'storage';

alter table public.zones
  drop constraint if exists zones_location_role_check;
alter table public.zones
  add constraint zones_location_role_check
    check (location_role in ('storage', 'quarantine'));

alter table public.crates
  drop constraint if exists crates_location_role_check;
alter table public.crates
  add constraint crates_location_role_check
    check (location_role in ('storage', 'quarantine'));

create unique index if not exists zones_branch_quarantine_key
  on public.zones (branch_id)
  where location_role = 'quarantine';

create unique index if not exists crates_zone_quarantine_key
  on public.crates (zone_id)
  where location_role = 'quarantine';

-- Session GUC spoofing is not enough. Only SECURITY DEFINER helpers may insert
-- a pid-scoped token; ordinary writers cannot guess or write that row.
create unlogged table if not exists app_private.trusted_guc_tokens (
  backend_pid integer not null,
  guc_name text not null,
  token text not null,
  primary key (backend_pid, guc_name)
);

revoke all on table app_private.trusted_guc_tokens
  from public, anon, authenticated, service_role;

create or replace function app_private.enable_trusted_guc(p_guc_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  token text := gen_random_uuid()::text;
begin
  if p_guc_name not in ('app.damage_stock_write', 'app.quarantine_location_write') then
    raise exception 'unsupported trusted guc' using errcode = '42501';
  end if;
  insert into app_private.trusted_guc_tokens (backend_pid, guc_name, token)
  values (pg_backend_pid(), p_guc_name, token)
  on conflict (backend_pid, guc_name) do update
    set token = excluded.token;
  perform set_config(p_guc_name, token, true);
end;
$$;

create or replace function app_private.trusted_guc_active(p_guc_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from app_private.trusted_guc_tokens
    where backend_pid = pg_backend_pid()
      and trusted_guc_tokens.guc_name = p_guc_name
      and token is not distinct from pg_catalog.current_setting(p_guc_name, true)
      and token ~ '^[0-9a-f-]{36}$'
  );
$$;

revoke all on function app_private.enable_trusted_guc(text)
  from public, anon, authenticated, service_role;
revoke all on function app_private.trusted_guc_active(text)
  from public, anon, service_role;
grant execute on function app_private.trusted_guc_active(text) to authenticated;

create or replace function app_private.guard_location_role()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
    and new.location_role is distinct from old.location_role
    and not app_private.trusted_guc_active('app.quarantine_location_write')
  then
    raise exception 'quarantine locations cannot be changed directly' using errcode = '42501';
  end if;
  if tg_op = 'INSERT'
    and new.location_role is distinct from 'storage'
    and not app_private.trusted_guc_active('app.quarantine_location_write')
  then
    raise exception 'quarantine locations cannot be changed directly' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists zones_location_role_guard on public.zones;
create trigger zones_location_role_guard
  before insert or update on public.zones
  for each row execute function app_private.guard_location_role();

drop trigger if exists crates_location_role_guard on public.crates;
create trigger crates_location_role_guard
  before insert or update on public.crates
  for each row execute function app_private.guard_location_role();

-- ---------------------------------------------------------------------------
-- 2. Custody + transaction linkage
-- ---------------------------------------------------------------------------

alter table public.damage_reports
  add column if not exists physical_custody_confirmed_at timestamptz,
  add column if not exists physical_custody_confirmed_by uuid
    references public.profiles (id) on delete restrict;

alter table public.stock_transactions
  add column if not exists damage_report_id uuid
    references public.damage_reports (id) on delete restrict,
  add column if not exists damage_posting_kind text;

alter table public.stock_transactions
  drop constraint if exists stock_transactions_damage_kind_check;
alter table public.stock_transactions
  add constraint stock_transactions_damage_kind_check check (
    damage_posting_kind is null
    or damage_posting_kind in (
      'quarantine_intake',
      'ordinary_writeoff',
      'exceptional_writeoff',
      'quarantine_transfer'
    )
  );

alter table public.stock_transactions
  drop constraint if exists stock_transactions_shape_check;
alter table public.stock_transactions
  add constraint stock_transactions_shape_check check (
    (
      transaction_type = 'OPENING_STOCK'
      and source_crate_id is null
      and destination_crate_id is not null
      and receipt_id is null
      and receipt_line_id is null
      and adjustment_request_id is null
      and dispatch_request_id is null
      and damage_report_id is null
    )
    or (
      transaction_type = 'CRATE_TRANSFER'
      and source_crate_id is not null
      and destination_crate_id is not null
      and source_crate_id <> destination_crate_id
      and receipt_id is null
      and receipt_line_id is null
      and adjustment_request_id is null
      and dispatch_request_id is null
    )
    or (
      transaction_type = 'RECEIPT'
      and source_crate_id is null
      and destination_crate_id is not null
      and receipt_id is not null
      and receipt_line_id is not null
      and adjustment_request_id is null
      and dispatch_request_id is null
      and damage_report_id is null
    )
    or (
      transaction_type = 'ADJUSTMENT'
      and source_crate_id is null
      and receipt_id is null
      and receipt_line_id is null
      and dispatch_request_id is null
      and (
        (
          adjustment_request_id is not null
          and damage_report_id is null
          and damage_posting_kind is null
        )
        or (
          adjustment_request_id is null
          and damage_report_id is not null
          and destination_crate_id is not null
          and damage_posting_kind in ('quarantine_intake', 'ordinary_writeoff', 'exceptional_writeoff')
        )
      )
    )
    or (
      transaction_type = 'DISPATCH'
      and destination_crate_id is null
      and receipt_id is null
      and receipt_line_id is null
      and adjustment_request_id is null
      and dispatch_request_id is not null
      and damage_report_id is null
    )
  );

create unique index if not exists stock_transactions_damage_kind_once
  on public.stock_transactions (damage_report_id, damage_posting_kind)
  where damage_report_id is not null and damage_posting_kind is not null;

-- ---------------------------------------------------------------------------
-- 3. Holds and exceptional requests
-- ---------------------------------------------------------------------------

create table if not exists public.damage_stock_holds (
  id uuid primary key default gen_random_uuid(),
  damage_report_id uuid not null
    references public.damage_reports (id) on delete restrict,
  damage_report_line_id uuid not null
    references public.damage_report_lines (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  crate_id uuid not null references public.crates (id) on delete restrict,
  lot_id uuid references public.stock_lots (id) on delete restrict,
  quantity_cases integer not null,
  hold_kind text not null,
  status text not null,
  source_reservation_id uuid
    references public.stock_reservations (id) on delete restrict,
  posted_transaction_id uuid
    references public.stock_transactions (id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint damage_stock_holds_qty_check
    check (quantity_cases >= 1 and quantity_cases <= 1000000),
  constraint damage_stock_holds_kind_check check (
    hold_kind in ('on_hand_deduction', 'reservation_conversion', 'quarantine_intake')
  ),
  constraint damage_stock_holds_status_check check (
    status in ('active', 'released', 'transferred', 'written_off', 'returned_supplier')
  )
);

comment on table public.damage_stock_holds is
  'M5.3 isolation rows. Deducted from picking availability while active. No parallel balance table.';

create unique index if not exists damage_stock_holds_active_grain_idx
  on public.damage_stock_holds (
    damage_report_line_id,
    crate_id,
    coalesce(lot_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(source_reservation_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  where status in ('active', 'transferred');

create index if not exists damage_stock_holds_grain_idx
  on public.damage_stock_holds (crate_id, product_id, lot_id)
  where status = 'active';

create index if not exists damage_stock_holds_report_idx
  on public.damage_stock_holds (damage_report_id);

drop trigger if exists damage_stock_holds_set_updated_at on public.damage_stock_holds;
create trigger damage_stock_holds_set_updated_at
  before update on public.damage_stock_holds
  for each row execute function app_private.set_updated_at();

drop trigger if exists damage_stock_holds_write_guard on public.damage_stock_holds;
create trigger damage_stock_holds_write_guard
  before insert or update or delete on public.damage_stock_holds
  for each row execute function app_private.guard_damage_write();

create table if not exists public.damage_exceptional_requests (
  id uuid primary key default gen_random_uuid(),
  damage_report_id uuid not null
    references public.damage_reports (id) on delete restrict,
  disposition_kind text not null,
  status text not null,
  version integer not null default 1,
  request_reason text not null,
  requested_by uuid not null references public.profiles (id) on delete restrict,
  requested_at timestamptz not null default pg_catalog.clock_timestamp(),
  decided_by uuid references public.profiles (id) on delete restrict,
  decided_at timestamptz,
  decision_reason text,
  posted_by uuid references public.profiles (id) on delete restrict,
  posted_at timestamptz,
  posted_transaction_id uuid
    references public.stock_transactions (id) on delete restrict,
  request_idempotency_key text not null,
  post_idempotency_key text,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint damage_exceptional_kind_check check (
    disposition_kind in ('return_supplier', 'destroy')
  ),
  constraint damage_exceptional_status_check check (
    status in ('requested', 'approved', 'rejected', 'posted')
  ),
  constraint damage_exceptional_request_key unique (request_idempotency_key),
  constraint damage_exceptional_reason_len check (
    char_length(btrim(request_reason)) between 1 and 500
    and request_reason = btrim(request_reason)
  )
);

create unique index if not exists damage_exceptional_open_report_idx
  on public.damage_exceptional_requests (damage_report_id)
  where status in ('requested', 'approved');

drop trigger if exists damage_exceptional_write_guard on public.damage_exceptional_requests;
create trigger damage_exceptional_write_guard
  before insert or update or delete on public.damage_exceptional_requests
  for each row execute function app_private.guard_damage_write();

alter table public.damage_stock_holds enable row level security;
alter table public.damage_stock_holds force row level security;
alter table public.damage_exceptional_requests enable row level security;
alter table public.damage_exceptional_requests force row level security;

revoke all on public.damage_stock_holds from public, anon, authenticated, service_role;
revoke all on public.damage_exceptional_requests from public, anon, authenticated, service_role;
grant select on public.damage_stock_holds to authenticated;
grant select on public.damage_exceptional_requests to authenticated;

drop policy if exists damage_stock_holds_select on public.damage_stock_holds;
create policy damage_stock_holds_select on public.damage_stock_holds
  for select to authenticated
  using (
    exists (
      select 1 from public.damage_reports
      where damage_reports.id = damage_stock_holds.damage_report_id
        and app_private.can_view_damage_report(
          damage_reports.godown_id,
          damage_reports.scenario,
          damage_reports.reporter_user_id,
          damage_reports.dispatch_id
        )
    )
  );

drop policy if exists damage_exceptional_select on public.damage_exceptional_requests;
create policy damage_exceptional_select on public.damage_exceptional_requests
  for select to authenticated
  using (
    exists (
      select 1 from public.damage_reports
      where damage_reports.id = damage_exceptional_requests.damage_report_id
        and app_private.can_view_damage_report(
          damage_reports.godown_id,
          damage_reports.scenario,
          damage_reports.reporter_user_id,
          damage_reports.dispatch_id
        )
    )
  );

-- ---------------------------------------------------------------------------
-- 4. Availability helpers
-- ---------------------------------------------------------------------------

create or replace function app_private.crate_is_quarantine(target_crate uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.crates
    join public.zones on zones.id = crates.zone_id
    where crates.id = target_crate
      and (
        crates.location_role = 'quarantine'
        or zones.location_role = 'quarantine'
      )
  );
$$;

create or replace function app_private.active_damage_hold_lot_cases(p_lot uuid, p_crate uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(damage_stock_holds.quantity_cases), 0)::integer
  from public.damage_stock_holds
  where damage_stock_holds.crate_id = p_crate
    and damage_stock_holds.lot_id is not distinct from p_lot
    and damage_stock_holds.status = 'active'
    and damage_stock_holds.hold_kind in ('on_hand_deduction', 'reservation_conversion');
$$;

create or replace function app_private.active_damage_hold_grain_cases(p_crate uuid, p_product uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(damage_stock_holds.quantity_cases), 0)::integer
  from public.damage_stock_holds
  where damage_stock_holds.crate_id = p_crate
    and damage_stock_holds.product_id = p_product
    and damage_stock_holds.status = 'active'
    and damage_stock_holds.hold_kind in ('on_hand_deduction', 'reservation_conversion');
$$;

create or replace function app_private.picking_available_cases(p_lot uuid, p_crate uuid)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  on_hand integer := 0;
begin
  if app_private.crate_is_quarantine(p_crate) then
    return 0;
  end if;

  select coalesce(stock_lot_balances.quantity, 0)
  into on_hand
  from public.stock_lot_balances
  where stock_lot_balances.lot_id = p_lot
    and stock_lot_balances.crate_id = p_crate;

  return greatest(
    on_hand
      - app_private.active_reserved_lot_cases(p_lot, p_crate)
      - app_private.active_damage_hold_lot_cases(p_lot, p_crate),
    0
  );
end;
$$;

create or replace function app_private.assert_lot_not_below_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  protected integer;
begin
  if app_private.trusted_guc_active('app.damage_stock_write') then
    protected := 0;
  else
    protected := app_private.active_damage_hold_lot_cases(
      coalesce(new.lot_id, old.lot_id),
      coalesce(new.crate_id, old.crate_id)
    );
  end if;

  if tg_op = 'UPDATE' and new.quantity < old.quantity then
    if new.quantity < app_private.active_reserved_lot_cases(new.lot_id, new.crate_id) + protected then
      raise exception 'insufficient unreserved lot stock' using errcode = '23514';
    end if;
  end if;
  if tg_op = 'DELETE' then
    if app_private.active_reserved_lot_cases(old.lot_id, old.crate_id) + protected > 0 then
      raise exception 'insufficient unreserved lot stock' using errcode = '23514';
    end if;
    return old;
  end if;
  return new;
end;
$$;

create or replace function app_private.assert_balance_not_below_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  protected integer;
begin
  if app_private.trusted_guc_active('app.damage_stock_write') then
    protected := 0;
  else
    protected := app_private.active_damage_hold_grain_cases(
      coalesce(new.crate_id, old.crate_id),
      coalesce(new.product_id, old.product_id)
    );
  end if;

  if tg_op = 'DELETE' then
    if app_private.active_reserved_grain_cases(old.crate_id, old.product_id) + protected > 0 then
      raise exception 'insufficient unreserved stock' using errcode = '23514';
    end if;
    return old;
  end if;
  if tg_op = 'UPDATE' and new.quantity < old.quantity then
    if new.quantity < app_private.active_reserved_grain_cases(new.crate_id, new.product_id) + protected then
      raise exception 'insufficient unreserved stock' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

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

  perform app_private.acquire_stock_cutover_shared_lock();

  perform zones.id
  from public.zones
  where zones.id in (
    select crates.zone_id from public.crates where crates.id = any (crate_ids)
  )
  order by zones.id
  for update;

  perform crates.id
  from public.crates
  where crates.id = any (crate_ids)
  order by crates.id
  for update;

  perform branches.id
  from public.branches
  where branches.id in (
    select zones.branch_id
    from public.crates
    join public.zones on zones.id = crates.zone_id
    where crates.id = any (crate_ids)
  )
  order by branches.id
  for update;

  select
    count(*),
    count(distinct zones.branch_id),
    count(*) filter (
      where not crates.is_active or not zones.is_active or not branches.is_active
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

  if not app_private.trusted_guc_active('app.damage_stock_write')
    and exists (
      select 1
      from public.crates
      join public.zones on zones.id = crates.zone_id
      where crates.id = any (crate_ids)
        and (
          crates.location_role = 'quarantine'
          or zones.location_role = 'quarantine'
        )
    )
  then
    raise exception 'quarantine locations cannot be used for ordinary stock posting'
      using errcode = '23514';
  end if;

  select zones.branch_id
  into selected_branch
  from public.crates
  join public.zones on zones.id = crates.zone_id
  where crates.id = crate_ids[1];

  return selected_branch;
end;
$$;

create or replace function app_private.damage_stock_isolation_installed()
returns boolean
language sql
immutable
security definer
set search_path = ''
as $$
  select true;
$$;

-- Picking plan excludes quarantine locations even if a lot is marked available.
create or replace function app_private.picking_line_plan(
  p_product uuid,
  p_branch uuid,
  p_requested integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  product_policy text;
  blockers text[] := '{}';
  remaining integer;
  take_qty integer;
  allocated integer := 0;
  slices jsonb := '[]'::jsonb;
  grain record;
begin
  select products.expiry_policy
  into product_policy
  from public.products
  where products.id = p_product;

  if product_policy is distinct from 'expiry_controlled'
    and product_policy is distinct from 'non_expiring'
  then
    return pg_catalog.jsonb_build_object(
      'product_id', p_product,
      'requested_cases', p_requested,
      'allocated_cases', 0,
      'shortfall_cases', p_requested,
      'eligible', false,
      'blockers', jsonb_build_array('Unclassified products cannot be allocated.'),
      'slices', '[]'::jsonb
    );
  end if;

  remaining := p_requested;

  for grain in
    select
      stock_lots.id as lot_id,
      stock_lot_balances.crate_id,
      stock_lots.expiry_date,
      stock_lots.received_on,
      stock_lots.manufacturer_lot_code,
      stock_lots.status,
      crates.code as crate_code,
      zones.code as zone_code,
      app_private.picking_available_cases(stock_lots.id, stock_lot_balances.crate_id) as available
    from public.stock_lot_balances
    join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
    join public.crates on crates.id = stock_lot_balances.crate_id
    join public.zones on zones.id = crates.zone_id
    where stock_lots.product_id = p_product
      and stock_lots.branch_id = p_branch
      and zones.branch_id = p_branch
      and stock_lots.status = 'available'
      and crates.location_role is distinct from 'quarantine'
      and zones.location_role is distinct from 'quarantine'
      and stock_lot_balances.quantity > 0
      and (
        (
          product_policy = 'expiry_controlled'
          and stock_lots.expiry_date is not null
          and stock_lots.expiry_date >= current_date
        )
        or (
          product_policy = 'non_expiring'
          and stock_lots.expiry_date is null
          and stock_lots.received_on is not null
        )
      )
    order by
      case when product_policy = 'expiry_controlled' then stock_lots.expiry_date end asc nulls last,
      stock_lots.received_on asc nulls last,
      stock_lots.id,
      stock_lot_balances.crate_id
  loop
    if grain.available < 1 or remaining < 1 then
      continue;
    end if;
    take_qty := least(remaining, grain.available);
    allocated := allocated + take_qty;
    remaining := remaining - take_qty;
    slices := slices || jsonb_build_array(pg_catalog.jsonb_build_object(
      'lot_id', grain.lot_id,
      'crate_id', grain.crate_id,
      'crate_code', grain.crate_code,
      'zone_code', grain.zone_code,
      'manufacturer_lot_code', grain.manufacturer_lot_code,
      'expiry_date', grain.expiry_date,
      'received_on', grain.received_on,
      'available_cases', grain.available,
      'reserved_cases', take_qty,
      'policy', product_policy
    ));
  end loop;

  if remaining > 0 then
    if product_policy = 'expiry_controlled' then
      blockers := array_append(
        blockers,
        'Insufficient eligible FEFO stock. Expired, unknown-expiry, and legacy-unattributed lots are excluded.'
      );
    else
      blockers := array_append(
        blockers,
        'Insufficient eligible FIFO stock. Lots without received_on and legacy-unattributed lots are excluded.'
      );
    end if;
  end if;

  return pg_catalog.jsonb_build_object(
    'product_id', p_product,
    'expiry_policy', product_policy,
    'requested_cases', p_requested,
    'allocated_cases', allocated,
    'shortfall_cases', remaining,
    'eligible', remaining = 0,
    'blockers', to_jsonb(blockers),
    'slices', slices
  );
end;
$$;

-- Loading damage converts reservations; remaining active + converted holds must
-- still cover the verified order so confirm_dispatch cannot silently ship less
-- without an isolation record, and cannot ship the damaged cartons.
create or replace function app_private.assert_dispatch_handoff_ready(
  selected public.orders,
  picking public.stock_picking_requests
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  handoff uuid;
  cutover text[];
  mismatch integer;
  blocking integer;
  unclassified integer;
  bad_lot integer;
begin
  if selected.status is distinct from 'verified' then
    raise exception 'dispatch requires a verified order' using errcode = '23514';
  end if;

  cutover := app_private.dispatch_cutover_blockers();
  if coalesce(pg_catalog.array_length(cutover, 1), 0) > 0 then
    raise exception '%', cutover[1] using errcode = '23514';
  end if;

  handoff := app_private.assert_picking_handoff_for_dispatch(selected.id);
  if handoff is distinct from picking.id then
    raise exception 'dispatch picking request does not match the ready_for_dispatch handoff'
      using errcode = '23514';
  end if;

  if picking.branch_id is distinct from selected.branch_id then
    raise exception 'picking godown does not match the order' using errcode = '23514';
  end if;

  select count(*)
  into mismatch
  from public.order_lines
  where order_lines.order_id = selected.id
    and order_lines.requested_cases is distinct from (
      select coalesce(sum(stock_reservations.reserved_cases), 0)
        + coalesce((
          select sum(damage_stock_holds.quantity_cases)
          from public.damage_stock_holds
          join public.stock_reservations converted
            on converted.id = damage_stock_holds.source_reservation_id
          where converted.order_line_id = order_lines.id
            and damage_stock_holds.hold_kind = 'reservation_conversion'
            and damage_stock_holds.status in ('active', 'transferred', 'written_off', 'returned_supplier')
        ), 0)
      from public.stock_reservations
      where stock_reservations.order_line_id = order_lines.id
        and stock_reservations.status = 'active'
    );

  if mismatch > 0 then
    raise exception 'dispatch quantities do not match the verified order'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.stock_reservations
    where stock_reservations.picking_request_id = picking.id
      and stock_reservations.status = 'active'
      and stock_reservations.picked_cases is distinct from stock_reservations.reserved_cases
  ) then
    raise exception 'dispatch requires every reserved carton to be picked'
      using errcode = '23514';
  end if;

  if not exists (
    select 1
    from public.stock_reservations
    where stock_reservations.picking_request_id = picking.id
      and stock_reservations.status = 'active'
  ) then
    raise exception 'dispatch requires active reservations' using errcode = '23514';
  end if;

  select count(*)
  into blocking
  from public.stock_picking_exceptions
  where stock_picking_exceptions.picking_request_id = picking.id
    and stock_picking_exceptions.exception_type in (
      'shortage',
      'expired_stock',
      'unknown_legacy',
      'unclassified',
      'cutover_blocked',
      'conflict'
    );

  if blocking > 0 then
    raise exception 'dispatch is blocked by unresolved picking exceptions'
      using errcode = '23514';
  end if;

  select count(*)
  into unclassified
  from public.order_lines
  join public.products on products.id = order_lines.product_id
  where order_lines.order_id = selected.id
    and products.expiry_policy is null;

  if unclassified > 0 then
    raise exception 'dispatch requires classified products' using errcode = '23514';
  end if;

  select count(*)
  into bad_lot
  from public.stock_reservations
  join public.stock_lots on stock_lots.id = stock_reservations.lot_id
  join public.products on products.id = stock_reservations.product_id
  join public.crates on crates.id = stock_reservations.crate_id
  join public.zones on zones.id = crates.zone_id
  where stock_reservations.picking_request_id = picking.id
    and stock_reservations.status = 'active'
    and (
      stock_lots.status is distinct from 'available'
      or zones.branch_id is distinct from picking.branch_id
      or stock_lots.branch_id is distinct from picking.branch_id
      or (
        products.expiry_policy = 'expiry_controlled'
        and (stock_lots.expiry_date is null or stock_lots.expiry_date < current_date)
      )
    );

  if bad_lot > 0 then
    raise exception 'dispatch reservations are not valid lot identities'
      using errcode = '23514';
  end if;
end;
$$;

create or replace function app_private.assert_lot_posting_status(
  selected_lot public.stock_lots
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if selected_lot.status = 'available' then
    return;
  elsif selected_lot.status = 'legacy_unattributed' then
    if not app_private.has_permission('stock.lots.legacy.reconcile') then
      raise exception 'legacy_unattributed lots require stock.lots.legacy.reconcile'
        using errcode = '42501';
    end if;
    return;
  elsif selected_lot.status in ('quarantined', 'expired_blocked') then
    if not app_private.trusted_guc_active('app.damage_stock_write')
      or selected_lot.status is distinct from 'quarantined'
    then
      raise exception 'lot status % cannot be mutated by normal posting', selected_lot.status
        using errcode = '23514';
    end if;
    return;
  end if;
  raise exception 'unsupported lot status %', selected_lot.status using errcode = '23514';
end;
$$;

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

  -- PostgREST sessions load safeupdate; unqualified DELETE is rejected there.
  delete from pg_temp._lot_aware_lines where true;
  delete from pg_temp._lot_aware_agg where true;

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

    perform app_private.assert_lot_posting_status(selected_lot);

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


create or replace function app_private.ensure_godown_quarantine_crate(target_godown uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  zone_id uuid;
  crate_id uuid;
begin
  if target_godown is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select crates.id
  into crate_id
  from public.crates
  join public.zones on zones.id = crates.zone_id
  where zones.branch_id = target_godown
    and crates.location_role = 'quarantine'
    and zones.location_role = 'quarantine'
  order by crates.id
  limit 1;

  if crate_id is not null then
    return crate_id;
  end if;

  perform app_private.enable_trusted_guc('app.quarantine_location_write');

  select zones.id into zone_id
  from public.zones
  where zones.branch_id = target_godown
    and zones.location_role = 'quarantine'
  limit 1;

  if zone_id is null then
    insert into public.zones (branch_id, code, name, description, location_role)
    values (target_godown, 'QRN', 'Quarantine', 'Unavailable damaged-goods custody.', 'quarantine')
    returning id into zone_id;
  end if;

  insert into public.crates (zone_id, code, name, description, location_role)
  values (zone_id, 'QRN-01', 'Quarantine crate', 'Unavailable damaged-goods custody.', 'quarantine')
  returning id into crate_id;

  return crate_id;
end;
$$;

create or replace function app_private.lock_damage_stock_grains(
  target_godown uuid,
  crate_ids uuid[],
  product_ids uuid[],
  lot_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.acquire_stock_cutover_shared_lock();
  perform app_private.assert_operational_active_branch(target_godown);

  if product_ids is not null and cardinality(product_ids) > 0 then
    perform products.id
    from public.products
    where products.id = any (product_ids)
    order by products.id
    for update;
  end if;

  if crate_ids is not null and cardinality(crate_ids) > 0 then
    perform app_private.prepare_stock_locations(crate_ids);
  end if;

  if lot_ids is not null and cardinality(lot_ids) > 0 then
    perform stock_lots.id
    from public.stock_lots
    where stock_lots.id = any (lot_ids)
    order by stock_lots.id
    for update;
  end if;
end;
$$;

-- Damage ADJUSTMENT rows have no stock_adjustment_requests id. The M3
-- completeness trigger treated that as incomplete; rollback SQL never fired
-- the deferred check. Allow tagged damage postings with matching ledger sums.
create or replace function app_private.assert_stock_transaction_complete()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  selected_type text;
  entry_count integer;
  entry_sum integer;
  linked_receipt uuid;
  linked_line uuid;
  linked_adjustment uuid;
  linked_dispatch uuid;
  linked_damage uuid;
  linked_kind text;
  header_qty integer;
  line_count integer;
  line_sum integer;
begin
  select
    stock_transactions.transaction_type,
    stock_transactions.receipt_id,
    stock_transactions.receipt_line_id,
    stock_transactions.adjustment_request_id,
    stock_transactions.dispatch_request_id,
    stock_transactions.damage_report_id,
    stock_transactions.damage_posting_kind,
    stock_transactions.quantity
  into
    selected_type, linked_receipt, linked_line, linked_adjustment, linked_dispatch,
    linked_damage, linked_kind, header_qty
  from public.stock_transactions
  where stock_transactions.id = new.transaction_id;

  select count(*), coalesce(sum(stock_ledger.quantity), 0)
  into entry_count, entry_sum
  from public.stock_ledger
  where stock_ledger.transaction_id = new.transaction_id;

  if selected_type = 'OPENING_STOCK' and (entry_count <> 1 or entry_sum <= 0) then
    raise exception 'opening stock ledger is incomplete' using errcode = '23514';
  end if;

  if selected_type = 'CRATE_TRANSFER' and (entry_count <> 2 or entry_sum <> 0) then
    raise exception 'transfer ledger must net to zero' using errcode = '23514';
  end if;

  if selected_type = 'RECEIPT' and (
    entry_count <> 1
    or entry_sum <= 0
    or linked_receipt is null
    or linked_line is null
  ) then
    raise exception 'receipt ledger is incomplete' using errcode = '23514';
  end if;

  if selected_type = 'ADJUSTMENT' then
    if linked_adjustment is not null then
      select count(*), coalesce(sum(stock_adjustment_lines.requested_cases), 0)
      into line_count, line_sum
      from public.stock_adjustment_lines
      where stock_adjustment_lines.request_id = linked_adjustment
        and not stock_adjustment_lines.released;

      if entry_count <> line_count
        or entry_sum is distinct from line_sum
        or entry_count < 1
      then
        raise exception 'adjustment ledger is incomplete' using errcode = '23514';
      end if;
    elsif linked_damage is not null
      and linked_kind = 'quarantine_intake'
    then
      if entry_count < 1 or entry_sum is distinct from header_qty or entry_sum <= 0 then
        raise exception 'adjustment ledger is incomplete' using errcode = '23514';
      end if;
    elsif linked_damage is not null
      and linked_kind in ('ordinary_writeoff', 'exceptional_writeoff')
    then
      if entry_count < 1 or entry_sum is distinct from (- header_qty) or entry_sum >= 0 then
        raise exception 'adjustment ledger is incomplete' using errcode = '23514';
      end if;
    else
      raise exception 'adjustment ledger is incomplete' using errcode = '23514';
    end if;
  end if;

  if selected_type = 'DISPATCH' then
    if linked_dispatch is null
      or entry_count < 1
      or entry_sum >= 0
      or entry_sum is distinct from (- header_qty)
    then
      raise exception 'dispatch ledger is incomplete' using errcode = '23514';
    end if;
  end if;

  if selected_type not in ('OPENING_STOCK', 'CRATE_TRANSFER', 'RECEIPT', 'ADJUSTMENT', 'DISPATCH') then
    raise exception 'stock transaction type is not supported' using errcode = '23514';
  end if;

  return null;
end;
$$;

create or replace function app_private.post_damage_adjustment(
  target_report uuid,
  posting_kind text,
  dest_crate uuid,
  signed_lines jsonb,
  notes text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.damage_reports;
  cleaned_key text;
  fingerprint text;
  replay uuid;
  created_id uuid;
  reference_number text;
  item jsonb;
  line_product uuid;
  line_crate uuid;
  line_lot uuid;
  line_qty integer;
  total_qty integer := 0;
  first_product uuid;
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
  lot_deltas jsonb := '[]'::jsonb;
  crate_ids uuid[] := '{}';
  product_ids uuid[] := '{}';
  lot_ids uuid[] := '{}';
begin
  perform app_private.enable_trusted_guc('app.damage_stock_write');
  select * into header from public.damage_reports where id = target_report;
  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  cleaned_key := app_private.clean_idempotency_key(
    'dmg-' || posting_kind || '-' || target_report::text
  );

  select stock_transactions.id
  into replay
  from public.stock_transactions
  where stock_transactions.idempotency_key = cleaned_key;
  if found then
    return replay;
  end if;

  for item in select value from jsonb_array_elements(signed_lines)
  loop
    line_product := (item ->> 'product_id')::uuid;
    line_crate := coalesce((item ->> 'crate_id')::uuid, dest_crate);
    line_lot := nullif(item ->> 'lot_id', '')::uuid;
    line_qty := (item ->> 'quantity')::integer;
    if line_product is null or line_crate is null or line_qty is null or line_qty = 0 then
      raise exception 'damage stock line is invalid' using errcode = '23514';
    end if;
    total_qty := total_qty + abs(line_qty);
    if first_product is null then
      first_product := line_product;
    end if;
    crate_ids := array_append(crate_ids, line_crate);
    product_ids := array_append(product_ids, line_product);
    if line_lot is not null then
      lot_ids := array_append(lot_ids, line_lot);
    end if;
  end loop;

  if total_qty < 1 then
    raise exception 'damage stock quantity is required' using errcode = '23514';
  end if;

  fingerprint := posting_kind || ':' || target_report::text || ':' || total_qty::text;
  perform app_private.lock_damage_stock_grains(header.godown_id, crate_ids, product_ids, lot_ids);

  select stock_transactions.id
  into replay
  from public.stock_transactions
  where stock_transactions.idempotency_key = cleaned_key;
  if found then
    return replay;
  end if;

  reference_number := 'DMG-'
    || posting_kind
    || '-'
    || to_char(pg_catalog.clock_timestamp() at time zone 'UTC', 'YYYYMMDD')
    || '-'
    || pg_catalog.lpad(pg_catalog.nextval('public.stock_reference_seq')::text, 6, '0');

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    notes, product_id, destination_crate_id, quantity, damage_report_id, damage_posting_kind
  )
  values (
    'ADJUSTMENT',
    reference_number,
    auth.uid(),
    cleaned_key,
    fingerprint,
    notes,
    first_product,
    dest_crate,
    total_qty,
    target_report,
    posting_kind
  )
  returning id into created_id;

  for item in select value from jsonb_array_elements(signed_lines)
  loop
    line_product := (item ->> 'product_id')::uuid;
    line_crate := coalesce((item ->> 'crate_id')::uuid, dest_crate);
    line_lot := nullif(item ->> 'lot_id', '')::uuid;
    line_qty := (item ->> 'quantity')::integer;

    if dual_write then
      if line_lot is null then
        insert into public.stock_lots (
          product_id, branch_id, manufacturer_lot_code, manufactured_on, expiry_date,
          received_on, status, origin, source_transaction_id, created_by, notes
        )
        values (
          line_product, header.godown_id, null, null, null,
          pg_catalog.clock_timestamp(), 'quarantined', 'adjustment', created_id, auth.uid(),
          'M5.3 damage quarantine lot'
        )
        returning id into line_lot;
      end if;
      insert into public.stock_ledger (
        transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
      )
      values (created_id, line_product, line_crate, line_qty, auth.uid(), clock_timestamp(), line_lot);
      lot_deltas := lot_deltas || jsonb_build_array(jsonb_build_object(
        'product_id', line_product,
        'lot_id', line_lot,
        'crate_id', line_crate,
        'quantity', line_qty
      ));
    else
      if line_lot is not null then
        raise exception 'lot_id is only accepted when lot-aware dual-write is enabled'
          using errcode = '23514';
      end if;
      insert into public.stock_ledger (
        transaction_id, product_id, crate_id, quantity, actor_id, posted_at
      )
      values (created_id, line_product, line_crate, line_qty, auth.uid(), clock_timestamp());
      perform app_private.apply_stock_delta(line_crate, line_product, line_qty);
    end if;
  end loop;

  if dual_write then
    perform app_private.apply_lot_aware_stock_deltas(created_id, lot_deltas);
  end if;

  return created_id;
end;
$$;

create or replace function app_private.release_damage_holds(
  target_report uuid,
  next_status text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.damage_reports;
  hold public.damage_stock_holds;
  picking uuid;
  dispatch public.stock_dispatch_requests;
  remaining integer;
  take_qty integer;
begin
  select * into header from public.damage_reports where id = target_report;
  if not found then
    return;
  end if;

  for hold in
    select * from public.damage_stock_holds
    where damage_report_id = target_report
      and status = 'active'
    order by crate_id, product_id, id
    for update
  loop
    if hold.hold_kind = 'on_hand_deduction' then
      update public.damage_stock_holds
      set status = 'released'
      where id = hold.id;
    elsif hold.hold_kind = 'reservation_conversion' then
      select * into dispatch
      from public.stock_dispatch_requests
      where stock_dispatch_requests.id = header.dispatch_id
      for update;

      picking := header.picking_request_id;
      if picking is null and dispatch.id is not null then
        picking := dispatch.picking_request_id;
      end if;

      if dispatch.id is not null and dispatch.stock_consumed then
        -- Dispatch already consumed remaining reservations; do not recreate.
        null;
      elsif picking is not null
        and exists (
          select 1 from public.stock_picking_requests
          where stock_picking_requests.id = picking
            and stock_picking_requests.status in (
              'allocated', 'picking', 'picked', 'ready_for_dispatch'
            )
        )
        and hold.source_reservation_id is not null
      then
        perform set_config('app.picking_write', 'on', true);
        perform set_config('app.dispatch_write', 'on', true);
        update public.stock_reservations
        set status = 'active'
        where id = hold.source_reservation_id
          and status = 'released';

        if not found then
          update public.stock_reservations
          set reserved_cases = reserved_cases + hold.quantity_cases
          where id = hold.source_reservation_id
            and status = 'active';
        end if;

        if dispatch.id is not null and not dispatch.stock_consumed then
          update public.stock_dispatch_requests
          set request_fingerprint = app_private.dispatch_reservation_fingerprint(picking)
          where id = dispatch.id;
        end if;
      end if;

      update public.damage_stock_holds
      set status = 'released'
      where id = hold.id;
    elsif hold.hold_kind = 'quarantine_intake' then
      -- Rejected/returned shop-return goods stay in quarantine until disposition.
      null;
    end if;
  end loop;

  perform app_private.record_damage_event(
    target_report, 'holds_released', header.status, next_status,
    jsonb_build_object('reason', 'lifecycle')
  );
end;
$$;

create or replace function app_private.isolate_storage_damage(header public.damage_reports)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  line public.damage_report_lines;
  on_hand integer;
  reserved integer;
  held integer;
  crate_ids uuid[];
  product_ids uuid[];
  lot_ids uuid[];
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
begin
  select array_agg(distinct crate_id), array_agg(distinct product_id),
         array_remove(array_agg(distinct lot_id), null)
  into crate_ids, product_ids, lot_ids
  from public.damage_report_lines
  where damage_report_id = header.id;

  if crate_ids is null or exists (
    select 1 from public.damage_report_lines
    where damage_report_id = header.id and crate_id is null
  ) then
    raise exception 'storage damage requires a crate' using errcode = '23514';
  end if;

  if dual_write and exists (
    select 1 from public.damage_report_lines
    where damage_report_id = header.id and lot_id is null
  ) then
    raise exception 'storage damage requires a lot when lot-aware dual-write is enabled'
      using errcode = '23514';
  end if;

  perform app_private.lock_damage_stock_grains(header.godown_id, crate_ids, product_ids, lot_ids);

  perform stock_lot_balances.lot_id
  from public.stock_lot_balances
  where stock_lot_balances.crate_id = any (crate_ids)
    and (lot_ids is null or stock_lot_balances.lot_id = any (lot_ids))
  order by stock_lot_balances.crate_id, stock_lot_balances.lot_id
  for update of stock_lot_balances;

  perform stock_balances.crate_id
  from public.stock_balances
  where stock_balances.crate_id = any (crate_ids)
    and stock_balances.product_id = any (product_ids)
  order by stock_balances.crate_id, stock_balances.product_id
  for update of stock_balances;

  for line in
    select * from public.damage_report_lines
    where damage_report_id = header.id
    order by crate_id, product_id, lot_id
  loop
    if app_private.crate_is_quarantine(line.crate_id) then
      raise exception 'quarantine locations cannot be used for ordinary stock posting'
        using errcode = '23514';
    end if;

    select coalesce(sum(quantity), 0) into on_hand
    from public.stock_balances
    where crate_id = line.crate_id and product_id = line.product_id;

    reserved := app_private.active_reserved_grain_cases(line.crate_id, line.product_id);
    held := app_private.active_damage_hold_grain_cases(line.crate_id, line.product_id);

    if line.lot_id is not null then
      select coalesce(quantity, 0) into on_hand
      from public.stock_lot_balances
      where lot_id = line.lot_id and crate_id = line.crate_id;
      reserved := app_private.active_reserved_lot_cases(line.lot_id, line.crate_id);
      held := app_private.active_damage_hold_lot_cases(line.lot_id, line.crate_id);
    end if;

    if line.quantity_cases > on_hand - reserved - held then
      raise exception 'insufficient unreserved stock' using errcode = '23514';
    end if;

    insert into public.damage_stock_holds (
      damage_report_id, damage_report_line_id, product_id, crate_id, lot_id,
      quantity_cases, hold_kind, status
    )
    values (
      header.id, line.id, line.product_id, line.crate_id, line.lot_id,
      line.quantity_cases, 'on_hand_deduction', 'active'
    );
  end loop;
end;
$$;

create or replace function app_private.isolate_loading_damage(header public.damage_reports)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  line public.damage_report_lines;
  picking uuid;
  dispatch public.stock_dispatch_requests;
  remaining integer;
  take_qty integer;
  reservation public.stock_reservations;
  crate_ids uuid[];
  looked_up_order uuid;
  looked_up_picking uuid;
begin
  -- Match confirm_dispatch: cutover → order → picking → dispatch → reservations.
  perform app_private.acquire_stock_cutover_shared_lock();

  picking := header.picking_request_id;
  if header.dispatch_id is not null then
    select
      stock_dispatch_requests.order_id,
      stock_dispatch_requests.picking_request_id
    into looked_up_order, looked_up_picking
    from public.stock_dispatch_requests
    where stock_dispatch_requests.id = header.dispatch_id;

    if looked_up_order is not null then
      perform orders.id
      from public.orders
      where orders.id = looked_up_order
      for update;
    end if;
    picking := coalesce(picking, looked_up_picking);
  end if;

  if picking is null then
    raise exception 'loading damage requires a picking request' using errcode = '23514';
  end if;

  perform set_config('app.picking_write', 'on', true);
  perform set_config('app.dispatch_write', 'on', true);

  perform stock_picking_requests.id
  from public.stock_picking_requests
  where id = picking
  for update;

  if header.dispatch_id is not null then
    select * into dispatch
    from public.stock_dispatch_requests
    where id = header.dispatch_id
    for update;
    if not found or dispatch.stock_consumed then
      raise exception 'loading damage requires an unconsumed dispatch' using errcode = '23514';
    end if;
    picking := coalesce(picking, dispatch.picking_request_id);
  end if;

  perform stock_reservations.id
  from public.stock_reservations
  where picking_request_id = picking and status = 'active'
  order by crate_id, lot_id, id
  for update;

  select array_agg(distinct crate_id) into crate_ids
  from public.stock_reservations
  where picking_request_id = picking and status = 'active';

  perform app_private.lock_damage_stock_grains(
    header.godown_id, crate_ids,
    array(select distinct product_id from public.damage_report_lines where damage_report_id = header.id),
    array(
      select distinct lot_id from public.damage_report_lines
      where damage_report_id = header.id and lot_id is not null
    )
  );

  for line in
    select * from public.damage_report_lines
    where damage_report_id = header.id
    order by product_id, crate_id, lot_id
  loop
    remaining := line.quantity_cases;
    for reservation in
      select * from public.stock_reservations
      where picking_request_id = picking
        and status = 'active'
        and product_id = line.product_id
        and (line.crate_id is null or crate_id = line.crate_id)
        and (line.lot_id is null or lot_id = line.lot_id)
      order by crate_id, lot_id, id
    loop
      exit when remaining < 1;
      take_qty := least(remaining, reservation.reserved_cases);
      if take_qty = reservation.reserved_cases then
        update public.stock_reservations
        set status = 'released'
        where id = reservation.id;
      else
        update public.stock_reservations
        set
          reserved_cases = reserved_cases - take_qty,
          picked_cases = least(picked_cases, reserved_cases - take_qty)
        where id = reservation.id;
      end if;

      insert into public.damage_stock_holds (
        damage_report_id, damage_report_line_id, product_id, crate_id, lot_id,
        quantity_cases, hold_kind, status, source_reservation_id
      )
      values (
        header.id, line.id, reservation.product_id, reservation.crate_id, reservation.lot_id,
        take_qty, 'reservation_conversion', 'active', reservation.id
      );
      remaining := remaining - take_qty;
    end loop;

    if remaining > 0 then
      raise exception 'loading damage exceeds identifiable reserved quantity'
        using errcode = '23514';
    end if;
  end loop;

  if dispatch.id is not null then
    update public.stock_dispatch_requests
    set request_fingerprint = app_private.dispatch_reservation_fingerprint(picking)
    where id = dispatch.id;
  end if;
end;
$$;

create or replace function app_private.isolate_shop_return_damage(header public.damage_reports)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  line public.damage_report_lines;
  q_crate uuid;
  signed jsonb := '[]'::jsonb;
  posted uuid;
  created_hold uuid;
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
  created_lot uuid;
begin
  if header.physical_custody_confirmed_at is null
    or header.physical_custody_confirmed_by is null
  then
    raise exception 'shop-return damage requires confirmed physical custody'
      using errcode = '23514';
  end if;

  perform app_private.enable_trusted_guc('app.damage_stock_write');
  q_crate := app_private.ensure_godown_quarantine_crate(header.godown_id);

  for line in
    select * from public.damage_report_lines
    where damage_report_id = header.id
    order by product_id, id
  loop
    created_lot := line.lot_id;
    signed := signed || jsonb_build_array(jsonb_build_object(
      'product_id', line.product_id,
      'crate_id', q_crate,
      'lot_id', created_lot,
      'quantity', line.quantity_cases
    ));
  end loop;

  posted := app_private.post_damage_adjustment(
    header.id, 'quarantine_intake', q_crate, signed, 'Shop-return quarantine intake'
  );

  for line in
    select * from public.damage_report_lines
    where damage_report_id = header.id
    order by product_id, id
  loop
    created_lot := line.lot_id;
    if dual_write and created_lot is null then
      select stock_ledger.lot_id
      into created_lot
      from public.stock_ledger
      where stock_ledger.transaction_id = posted
        and stock_ledger.product_id = line.product_id
        and stock_ledger.crate_id = q_crate
      order by stock_ledger.id
      limit 1;
    end if;

    insert into public.damage_stock_holds (
      damage_report_id, damage_report_line_id, product_id, crate_id, lot_id,
      quantity_cases, hold_kind, status, posted_transaction_id
    )
    values (
      header.id, line.id, line.product_id, q_crate, created_lot,
      line.quantity_cases, 'quarantine_intake', 'active', posted
    )
    returning id into created_hold;
  end loop;
end;
$$;

create or replace function app_private.apply_damage_stock_isolation(target_report uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.damage_reports;
begin
  if target_report is null then
    raise exception 'damage stock isolation is not ready' using errcode = '23514';
  end if;

  -- Always invoked. Flag may block, never skip isolation once ready.
  if not app_private.damage_stock_hold_ready() then
    raise exception 'damage stock isolation is not ready' using errcode = '23514';
  end if;

  select * into header
  from public.damage_reports
  where id = target_report
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if not app_private.damage_requires_stock_hold(header.scenario) then
    return;
  end if;

  if exists (
    select 1 from public.damage_stock_holds
    where damage_report_id = header.id
      and status in ('active', 'transferred', 'written_off', 'returned_supplier')
  ) then
    return;
  end if;

  if header.scenario = 'storage' then
    perform app_private.isolate_storage_damage(header);
  elsif header.scenario = 'loading' then
    perform app_private.isolate_loading_damage(header);
  elsif header.scenario = 'shop_return' then
    perform app_private.isolate_shop_return_damage(header);
  else
    raise exception 'damage stock isolation is not ready' using errcode = '23514';
  end if;
end;
$$;

create or replace function public.confirm_shop_return_custody(
  target_report uuid,
  expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
begin
  perform set_config('app.damage_write', 'on', true);
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_damage_create_auth(
    selected.scenario, selected.godown_id, selected.dispatch_id
  );

  if selected.scenario is distinct from 'shop_return'
    or selected.status not in ('draft', 'returned')
  then
    raise exception 'physical custody cannot be confirmed' using errcode = '42501';
  end if;

  if selected.physical_custody_confirmed_at is not null then
    return app_private.damage_report_payload(selected.id);
  end if;

  update public.damage_reports
  set
    physical_custody_confirmed_at = pg_catalog.clock_timestamp(),
    physical_custody_confirmed_by = auth.uid(),
    version = selected.version + 1
  where id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'custody_confirmed', selected.status, selected.status, '{}'::jsonb
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

create or replace function public.verify_damage_report(
  target_report uuid,
  expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_operational_active_branch(selected.godown_id);

  if selected.status is distinct from 'submitted' then
    raise exception 'damage report cannot be verified' using errcode = '42501';
  end if;

  if selected.reporter_user_id is not distinct from auth.uid() then
    raise exception 'the reporter cannot verify this damage report' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.damage_evidence
    where damage_evidence.damage_report_id = selected.id
      and damage_evidence.verified_at is not null
  ) then
    raise exception 'photographic evidence is required' using errcode = '23514';
  end if;

  if app_private.damage_requires_stock_hold(selected.scenario)
    and not exists (
      select 1 from public.damage_stock_holds
      where damage_report_id = selected.id
        and status in ('active', 'transferred')
    )
  then
    raise exception 'damage stock isolation is not ready' using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.damage_report_lines
    where damage_report_id = selected.id
      and quantity_cases is distinct from (
        select coalesce(sum(damage_stock_holds.quantity_cases), 0)
        from public.damage_stock_holds
        where damage_stock_holds.damage_report_line_id = damage_report_lines.id
          and damage_stock_holds.status in ('active', 'transferred')
      )
      and app_private.damage_requires_stock_hold(selected.scenario)
  ) then
    raise exception 'verified quantities cannot exceed isolated quantities'
      using errcode = '23514';
  end if;

  update public.damage_reports
  set
    status = 'verified',
    verifier_user_id = auth.uid(),
    verified_at = pg_catalog.clock_timestamp(),
    version = selected.version + 1
  where damage_reports.id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'verified', selected.status, 'verified', '{}'::jsonb
  );
  perform app_private.write_audit(
    auth.uid(), 'verify_damage_report', 'damage_reports', selected.id, '{}'::jsonb
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

create or replace function public.return_damage_report(
  target_report uuid,
  expected_version integer,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  cleaned_reason text;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_operational_active_branch(selected.godown_id);
  cleaned_reason := app_private.clean_verification_text(reason, true);

  if selected.status is distinct from 'submitted' then
    raise exception 'damage report cannot be returned' using errcode = '42501';
  end if;

  if selected.scenario = 'shop_return' then
    raise exception 'submitted shop-return damage cannot return to draft'
      using errcode = '23514';
  end if;

  perform app_private.release_damage_holds(selected.id, 'returned');

  update public.damage_reports
  set
    status = 'returned',
    returned_at = pg_catalog.clock_timestamp(),
    returned_by = auth.uid(),
    return_reason = cleaned_reason,
    version = selected.version + 1
  where id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'returned', selected.status, 'returned',
    jsonb_build_object('reason', cleaned_reason)
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

create or replace function public.reject_damage_report(
  target_report uuid,
  expected_version integer,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  cleaned_reason text;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_operational_active_branch(selected.godown_id);
  cleaned_reason := app_private.clean_verification_text(reason, true);

  if selected.status is distinct from 'submitted' then
    raise exception 'damage report cannot be rejected' using errcode = '42501';
  end if;

  if selected.reporter_user_id is not distinct from auth.uid() then
    raise exception 'the reporter cannot verify this damage report' using errcode = '42501';
  end if;

  perform app_private.release_damage_holds(selected.id, 'rejected');

  update public.damage_reports
  set
    status = 'rejected',
    rejected_at = pg_catalog.clock_timestamp(),
    rejected_by = auth.uid(),
    rejection_reason = cleaned_reason,
    version = selected.version + 1
  where id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'rejected', selected.status, 'rejected',
    jsonb_build_object('reason', cleaned_reason)
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

create or replace function app_private.assert_damage_disposition_ready(
  selected public.damage_reports
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if selected.scenario in ('refill_supply', 'unloading', 'transit') then
    raise exception 'this damage report has no on-hand stock to post'
      using errcode = '23514';
  end if;

  if selected.status is distinct from 'verified'
    and not (
      selected.scenario = 'shop_return'
      and selected.status = 'rejected'
    )
  then
    raise exception 'damage report is not ready for stock posting' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.damage_evidence
    where damage_report_id = selected.id and verified_at is not null
  ) then
    raise exception 'photographic evidence is required' using errcode = '23514';
  end if;
end;
$$;

create or replace function app_private.consume_damage_holds(
  target_report uuid,
  next_hold_status text,
  posting_kind text,
  notes text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.damage_reports;
  hold public.damage_stock_holds;
  signed jsonb := '[]'::jsonb;
  dest uuid;
  posted uuid;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.enable_trusted_guc('app.damage_stock_write');
  select * into header from public.damage_reports where id = target_report for update;

  for hold in
    select * from public.damage_stock_holds
    where damage_report_id = target_report
      and status in ('active', 'transferred')
    order by crate_id, product_id, id
    for update
  loop
    dest := coalesce(dest, hold.crate_id);
    signed := signed || jsonb_build_array(jsonb_build_object(
      'product_id', hold.product_id,
      'crate_id', hold.crate_id,
      'lot_id', hold.lot_id,
      'quantity', - hold.quantity_cases
    ));
  end loop;

  if dest is null then
    raise exception 'no isolated damage quantity remains' using errcode = '23514';
  end if;

  update public.damage_stock_holds
  set status = next_hold_status
  where damage_report_id = target_report
    and status in ('active', 'transferred');

  posted := app_private.post_damage_adjustment(target_report, posting_kind, dest, signed, notes);

  update public.damage_stock_holds
  set posted_transaction_id = posted
  where damage_report_id = target_report
    and status = next_hold_status
    and posted_transaction_id is null;

  return posted;
end;
$$;

create or replace function public.post_ordinary_damage_writeoff(
  target_report uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  posted uuid;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_operational_active_branch(selected.godown_id);
  perform app_private.assert_damage_disposition_ready(selected);

  if app_private.has_permission('damage.dispose')
    and not app_private.has_permission('damage.verify')
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.damage_exceptional_requests
    where damage_report_id = selected.id
      and status in ('requested', 'approved')
  ) then
    raise exception 'an exceptional disposition is already open' using errcode = '23514';
  end if;

  select stock_transactions.id into posted
  from public.stock_transactions
  where stock_transactions.damage_report_id = selected.id
    and stock_transactions.damage_posting_kind = 'ordinary_writeoff';
  if found then
    return app_private.damage_report_payload(selected.id);
  end if;

  posted := app_private.consume_damage_holds(
    selected.id, 'written_off', 'ordinary_writeoff', 'Ordinary damage write-off'
  );

  perform app_private.record_damage_event(
    selected.id, 'ordinary_writeoff', selected.status, selected.status,
    jsonb_build_object('transaction_id', posted, 'idempotency_key', idempotency_key)
  );
  perform app_private.write_audit(
    auth.uid(), 'post_ordinary_damage_writeoff', 'damage_reports', selected.id,
    jsonb_build_object('transaction_id', posted)
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

create or replace function public.request_exceptional_damage_disposition(
  target_report uuid,
  expected_version integer,
  disposition_kind text,
  request_reason text,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  cleaned_key text;
  cleaned_kind text;
  cleaned_reason text;
  existing public.damage_exceptional_requests;
  created_id uuid;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_operational_active_branch(selected.godown_id);
  perform app_private.assert_damage_disposition_ready(selected);
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_kind := pg_catalog.lower(pg_catalog.btrim(coalesce(disposition_kind, '')));
  cleaned_reason := app_private.clean_verification_text(request_reason, true);

  if cleaned_kind not in ('return_supplier', 'destroy') then
    raise exception 'exceptional disposition is invalid' using errcode = '23514';
  end if;

  select * into existing
  from public.damage_exceptional_requests
  where request_idempotency_key = cleaned_key;
  if found then
    return app_private.damage_report_payload(selected.id);
  end if;

  insert into public.damage_exceptional_requests (
    damage_report_id, disposition_kind, status, request_reason,
    requested_by, request_idempotency_key
  )
  values (
    selected.id, cleaned_kind, 'requested', cleaned_reason, auth.uid(), cleaned_key
  )
  returning id into created_id;

  perform app_private.record_damage_event(
    selected.id, 'exceptional_requested', selected.status, selected.status,
    jsonb_build_object('request_id', created_id, 'kind', cleaned_kind)
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

create or replace function public.approve_exceptional_damage_disposition(
  target_request uuid,
  expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_exceptional_requests;
  header public.damage_reports;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.dispose');

  select * into selected
  from public.damage_exceptional_requests
  where id = target_request
  for update;
  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  header := app_private.lock_damage_report(selected.damage_report_id);
  if selected.version is distinct from expected_version then
    raise exception 'changed by someone else' using errcode = 'PT409';
  end if;
  if selected.status is distinct from 'requested' then
    raise exception 'exceptional request cannot be approved' using errcode = '42501';
  end if;

  update public.damage_exceptional_requests
  set
    status = 'approved',
    decided_by = auth.uid(),
    decided_at = clock_timestamp(),
    version = selected.version + 1
  where id = selected.id;

  perform app_private.record_damage_event(
    header.id, 'exceptional_approved', header.status, header.status,
    jsonb_build_object('request_id', selected.id)
  );
  return app_private.damage_report_payload(header.id);
end;
$$;

create or replace function public.reject_exceptional_damage_disposition(
  target_request uuid,
  expected_version integer,
  decision_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_exceptional_requests;
  header public.damage_reports;
  cleaned_reason text;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.dispose');
  cleaned_reason := app_private.clean_verification_text(decision_reason, true);

  select * into selected
  from public.damage_exceptional_requests
  where id = target_request
  for update;
  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  header := app_private.lock_damage_report(selected.damage_report_id);
  if selected.version is distinct from expected_version then
    raise exception 'changed by someone else' using errcode = 'PT409';
  end if;
  if selected.status is distinct from 'requested' then
    raise exception 'exceptional request cannot be rejected' using errcode = '42501';
  end if;

  update public.damage_exceptional_requests
  set
    status = 'rejected',
    decided_by = auth.uid(),
    decided_at = clock_timestamp(),
    decision_reason = cleaned_reason,
    version = selected.version + 1
  where id = selected.id;

  perform app_private.record_damage_event(
    header.id, 'exceptional_rejected', header.status, header.status,
    jsonb_build_object('request_id', selected.id)
  );
  return app_private.damage_report_payload(header.id);
end;
$$;

create or replace function public.post_exceptional_damage_disposition(
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
  selected public.damage_exceptional_requests;
  header public.damage_reports;
  posted uuid;
  hold_status text;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');

  select * into selected
  from public.damage_exceptional_requests
  where id = target_request
  for update;
  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  header := app_private.lock_damage_report(selected.damage_report_id);
  perform app_private.assert_operational_active_branch(header.godown_id);
  if selected.version is distinct from expected_version then
    raise exception 'changed by someone else' using errcode = 'PT409';
  end if;
  if selected.status = 'posted' and selected.post_idempotency_key = app_private.clean_idempotency_key(idempotency_key) then
    return app_private.damage_report_payload(header.id);
  end if;
  if selected.status is distinct from 'approved' then
    raise exception 'exceptional request is not approved' using errcode = '42501';
  end if;

  hold_status := case
    when selected.disposition_kind = 'return_supplier' then 'returned_supplier'
    else 'written_off'
  end;

  posted := app_private.consume_damage_holds(
    header.id, hold_status, 'exceptional_writeoff',
    'Exceptional ' || selected.disposition_kind
  );

  update public.damage_exceptional_requests
  set
    status = 'posted',
    posted_by = auth.uid(),
    posted_at = clock_timestamp(),
    posted_transaction_id = posted,
    post_idempotency_key = app_private.clean_idempotency_key(idempotency_key),
    version = selected.version + 1
  where id = selected.id;

  perform app_private.record_damage_event(
    header.id, 'exceptional_posted', header.status, header.status,
    jsonb_build_object('request_id', selected.id, 'transaction_id', posted)
  );
  return app_private.damage_report_payload(header.id);
end;
$$;

create or replace function public.transfer_verified_damage_to_quarantine(
  target_report uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  hold public.damage_stock_holds;
  q_crate uuid;
  cleaned_key text;
  fingerprint text;
  created_id uuid;
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
  lot_deltas jsonb := '[]'::jsonb;
  crate_ids uuid[];
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.enable_trusted_guc('app.damage_stock_write');
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_operational_active_branch(selected.godown_id);

  if selected.status is distinct from 'verified' or selected.scenario is distinct from 'storage' then
    raise exception 'quarantine transfer requires verified storage damage' using errcode = '23514';
  end if;

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  q_crate := app_private.ensure_godown_quarantine_crate(selected.godown_id);

  select array_agg(distinct crate_id) into crate_ids
  from public.damage_stock_holds
  where damage_report_id = selected.id and status = 'active' and hold_kind = 'on_hand_deduction';
  crate_ids := array_append(crate_ids, q_crate);
  perform app_private.lock_damage_stock_grains(
    selected.godown_id, crate_ids,
    array(select distinct product_id from public.damage_stock_holds where damage_report_id = selected.id),
    array(select distinct lot_id from public.damage_stock_holds where damage_report_id = selected.id and lot_id is not null)
  );

  fingerprint := 'quarantine_transfer:' || selected.id::text;
  select stock_transactions.id
  into created_id
  from public.stock_transactions
  where stock_transactions.idempotency_key = cleaned_key;
  if found then
    return app_private.damage_report_payload(selected.id);
  end if;

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    notes, product_id, source_crate_id, destination_crate_id, quantity,
    damage_report_id, damage_posting_kind
  )
  select
    'CRATE_TRANSFER',
    'DMG-QRN-' || to_char(clock_timestamp() at time zone 'UTC', 'YYYYMMDD') || '-'
      || lpad(nextval('public.stock_reference_seq')::text, 6, '0'),
    auth.uid(), cleaned_key, fingerprint, 'Verified damage quarantine transfer',
    (array_agg(product_id))[1],
    (array_agg(crate_id order by crate_id))[1],
    q_crate,
    sum(quantity_cases)::integer,
    selected.id,
    'quarantine_transfer'
  from public.damage_stock_holds
  where damage_report_id = selected.id and status = 'active' and hold_kind = 'on_hand_deduction'
  returning id into created_id;

  if created_id is null then
    raise exception 'no isolated damage quantity remains' using errcode = '23514';
  end if;

  for hold in
    select * from public.damage_stock_holds
    where damage_report_id = selected.id and status = 'active' and hold_kind = 'on_hand_deduction'
    order by crate_id, product_id, id
    for update
  loop
    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
    )
    values (created_id, hold.product_id, hold.crate_id, -hold.quantity_cases, auth.uid(), clock_timestamp(), hold.lot_id);
    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
    )
    values (created_id, hold.product_id, q_crate, hold.quantity_cases, auth.uid(), clock_timestamp(), hold.lot_id);

    if dual_write then
      if hold.lot_id is null then
        raise exception 'storage damage requires a lot when lot-aware dual-write is enabled'
          using errcode = '23514';
      end if;
      lot_deltas := lot_deltas || jsonb_build_array(
        jsonb_build_object('product_id', hold.product_id, 'lot_id', hold.lot_id, 'crate_id', hold.crate_id, 'quantity', -hold.quantity_cases),
        jsonb_build_object('product_id', hold.product_id, 'lot_id', hold.lot_id, 'crate_id', q_crate, 'quantity', hold.quantity_cases)
      );
    else
      perform app_private.apply_stock_delta(hold.crate_id, hold.product_id, -hold.quantity_cases);
      perform app_private.apply_stock_delta(q_crate, hold.product_id, hold.quantity_cases);
    end if;

    update public.damage_stock_holds
    set status = 'transferred', crate_id = q_crate, posted_transaction_id = created_id
    where id = hold.id;
  end loop;

  if dual_write then
    perform app_private.apply_lot_aware_stock_deltas(created_id, lot_deltas);
  end if;

  perform app_private.record_damage_event(
    selected.id, 'quarantine_transferred', selected.status, selected.status,
    jsonb_build_object('transaction_id', created_id)
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

create or replace function app_private.damage_report_payload(target_report uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  header public.damage_reports;
begin
  select * into header from public.damage_reports where damage_reports.id = target_report;

  if not found
    or not app_private.can_view_damage_report(
      header.godown_id, header.scenario, header.reporter_user_id, header.dispatch_id
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'id', header.id,
    'report_number', header.report_number,
    'scenario', header.scenario,
    'godown_id', header.godown_id,
    'godown_name', (select branches.name from public.branches where branches.id = header.godown_id),
    'status', header.status,
    'version', header.version,
    'receipt_id', header.receipt_id,
    'picking_request_id', header.picking_request_id,
    'dispatch_id', header.dispatch_id,
    'order_id', header.order_id,
    'shop_id', header.shop_id,
    'notes', header.notes,
    'reporter_user_id', header.reporter_user_id,
    'physical_custody_confirmed', header.physical_custody_confirmed_at is not null,
    'reporter_name', (
      select profiles.full_name from public.profiles where profiles.id = header.reporter_user_id
    ),
    'created_at', header.created_at,
    'lines', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', damage_report_lines.id,
        'product_id', damage_report_lines.product_id,
        'product_sku', products.sku,
        'product_name', products.name,
        'crate_id', damage_report_lines.crate_id,
        'crate_code', crates.code,
        'lot_id', damage_report_lines.lot_id,
        'quantity_cases', damage_report_lines.quantity_cases,
        'damage_reason', damage_report_lines.damage_reason,
        'notes', damage_report_lines.notes,
        'receipt_line_id', damage_report_lines.receipt_line_id
      ) order by damage_report_lines.sort_order, damage_report_lines.id)
      from public.damage_report_lines
      join public.products on products.id = damage_report_lines.product_id
      left join public.crates on crates.id = damage_report_lines.crate_id
      where damage_report_lines.damage_report_id = header.id
    ), '[]'::jsonb),
    'holds', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', damage_stock_holds.id,
        'line_id', damage_stock_holds.damage_report_line_id,
        'product_id', damage_stock_holds.product_id,
        'crate_id', damage_stock_holds.crate_id,
        'lot_id', damage_stock_holds.lot_id,
        'quantity_cases', damage_stock_holds.quantity_cases,
        'hold_kind', damage_stock_holds.hold_kind,
        'status', damage_stock_holds.status
      ) order by damage_stock_holds.created_at, damage_stock_holds.id)
      from public.damage_stock_holds
      where damage_stock_holds.damage_report_id = header.id
    ), '[]'::jsonb),
    'exceptional_requests', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', damage_exceptional_requests.id,
        'kind', damage_exceptional_requests.disposition_kind,
        'status', damage_exceptional_requests.status,
        'version', damage_exceptional_requests.version
      ) order by damage_exceptional_requests.created_at)
      from public.damage_exceptional_requests
      where damage_exceptional_requests.damage_report_id = header.id
    ), '[]'::jsonb),
    'events', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'action', damage_report_events.action,
        'actor_name', profiles.full_name,
        'previous_status', damage_report_events.previous_status,
        'next_status', damage_report_events.next_status,
        'created_at', damage_report_events.created_at,
        'metadata', damage_report_events.metadata
      ) order by damage_report_events.created_at, damage_report_events.id)
      from public.damage_report_events
      join public.profiles on profiles.id = damage_report_events.actor_id
      where damage_report_events.damage_report_id = header.id
    ), '[]'::jsonb),
    'evidence', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', damage_evidence.id,
        'finalized', damage_evidence.verified_at is not null,
        'mime_type', damage_evidence.mime_type,
        'uploaded_at', damage_evidence.uploaded_at
      ) order by damage_evidence.uploaded_at, damage_evidence.id)
      from public.damage_evidence
      where damage_evidence.damage_report_id = header.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app_private.enable_trusted_guc(text) from public, anon, authenticated, service_role;
revoke all on function app_private.trusted_guc_active(text) from public, anon, service_role;
grant execute on function app_private.trusted_guc_active(text) to authenticated;

revoke all on function app_private.crate_is_quarantine(uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.active_damage_hold_lot_cases(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.active_damage_hold_grain_cases(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.guard_location_role() from public, anon, authenticated, service_role;
revoke all on function app_private.assert_lot_posting_status(public.stock_lots) from public, anon, authenticated, service_role;
revoke all on function app_private.ensure_godown_quarantine_crate(uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.lock_damage_stock_grains(uuid, uuid[], uuid[], uuid[]) from public, anon, authenticated, service_role;
revoke all on function app_private.post_damage_adjustment(uuid, text, uuid, jsonb, text) from public, anon, authenticated, service_role;
revoke all on function app_private.release_damage_holds(uuid, text) from public, anon, authenticated, service_role;
revoke all on function app_private.isolate_storage_damage(public.damage_reports) from public, anon, authenticated, service_role;
revoke all on function app_private.isolate_loading_damage(public.damage_reports) from public, anon, authenticated, service_role;
revoke all on function app_private.isolate_shop_return_damage(public.damage_reports) from public, anon, authenticated, service_role;
revoke all on function app_private.apply_damage_stock_isolation(uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.damage_stock_isolation_installed() from public, anon, authenticated, service_role;
revoke all on function app_private.assert_damage_disposition_ready(public.damage_reports) from public, anon, authenticated, service_role;
revoke all on function app_private.consume_damage_holds(uuid, text, text, text) from public, anon, authenticated, service_role;
revoke all on function app_private.damage_report_payload(uuid) from public, anon, authenticated, service_role;

revoke all on function public.confirm_shop_return_custody(uuid, integer) from public, anon, service_role;
revoke all on function public.post_ordinary_damage_writeoff(uuid, integer, text) from public, anon, service_role;
revoke all on function public.request_exceptional_damage_disposition(uuid, integer, text, text, text) from public, anon, service_role;
revoke all on function public.approve_exceptional_damage_disposition(uuid, integer) from public, anon, service_role;
revoke all on function public.reject_exceptional_damage_disposition(uuid, integer, text) from public, anon, service_role;
revoke all on function public.post_exceptional_damage_disposition(uuid, integer, text) from public, anon, service_role;
revoke all on function public.transfer_verified_damage_to_quarantine(uuid, integer, text) from public, anon, service_role;

grant execute on function public.confirm_shop_return_custody(uuid, integer) to authenticated;
grant execute on function public.post_ordinary_damage_writeoff(uuid, integer, text) to authenticated;
grant execute on function public.request_exceptional_damage_disposition(uuid, integer, text, text, text) to authenticated;
grant execute on function public.approve_exceptional_damage_disposition(uuid, integer) to authenticated;
grant execute on function public.reject_exceptional_damage_disposition(uuid, integer, text) to authenticated;
grant execute on function public.post_exceptional_damage_disposition(uuid, integer, text) to authenticated;
grant execute on function public.transfer_verified_damage_to_quarantine(uuid, integer, text) to authenticated;
