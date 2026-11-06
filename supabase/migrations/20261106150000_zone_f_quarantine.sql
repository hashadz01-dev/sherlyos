-- UNAPPLIED. Review only. Do not run supabase db push.
-- Cloud history already has 20261106070237 for storage zones A–E.
-- This file does not repair or replay that history.
--
-- Adds one operational Zone F and crates F-01..F-04 on gd_1..gd_7.
-- Leaves QRN, QRN-01, uat_z1 and uat_c1 in place and does not post stock.

begin;

-- Structural preflight. Stock totals are compared again at the end so this
-- transaction cannot commit if a concurrent posting changed inventory.
do $preflight$
declare
  baseline_balances integer;
  baseline_balance_qty integer;
  baseline_lots integer;
  baseline_lot_qty integer;
  baseline_ledger integer;
  baseline_ledger_qty integer;
  baseline_transactions integer;
  baseline_holds integer;
begin
  if (
    select count(*)
    from public.branches
    where code in ('gd_1', 'gd_2', 'gd_3', 'gd_4', 'gd_5', 'gd_6', 'gd_7')
  ) <> 7 then
    raise exception 'expected the seven development godowns';
  end if;

  if exists (select 1 from public.zones where lower(code) = 'f') then
    raise exception 'zone F already exists; refusing to provision over it';
  end if;

  if not exists (
    select 1
    from public.zones
    where id = '950a8964-1b5c-4303-8e20-18669a443b80'
      and branch_id = '798bacf9-2212-43fc-9cbb-2fe1e7367a93'
      and code = 'QRN'
      and location_role = 'quarantine'
  ) or not exists (
    select 1
    from public.crates
    where id = '41375776-a323-40ed-a128-fee651fd48d8'
      and zone_id = '950a8964-1b5c-4303-8e20-18669a443b80'
      and code = 'QRN-01'
      and location_role = 'quarantine'
  ) or not exists (
    select 1
    from public.zones
    where id = '43230545-e3b2-4fef-a8c4-cd6fa93a4f34'
      and code = 'uat_z1'
  ) or not exists (
    select 1
    from public.crates
    where id = '351e1770-a537-4a90-863d-5c76d9a301c7'
      and code = 'uat_c1'
  ) then
    raise exception 'historical location ids do not match the reviewed baseline';
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'crates'
      and column_name = 'capacity_cases'
  ) then
    raise exception 'crates.capacity_cases is missing';
  end if;

  select count(*), coalesce(sum(quantity), 0)
  into baseline_balances, baseline_balance_qty
  from public.stock_balances;
  select count(*), coalesce(sum(quantity), 0)
  into baseline_lots, baseline_lot_qty
  from public.stock_lot_balances;
  select count(*), coalesce(sum(quantity), 0)
  into baseline_ledger, baseline_ledger_qty
  from public.stock_ledger;
  select count(*) into baseline_transactions from public.stock_transactions;
  select count(*) into baseline_holds from public.damage_stock_holds;

  create temporary table zone_f_baseline (
    balances integer,
    balance_qty integer,
    lots integer,
    lot_qty integer,
    ledger integer,
    ledger_qty integer,
    transactions integer,
    holds integer
  ) on commit drop;

  insert into zone_f_baseline
  values (
    baseline_balances,
    baseline_balance_qty,
    baseline_lots,
    baseline_lot_qty,
    baseline_ledger,
    baseline_ledger_qty,
    baseline_transactions,
    baseline_holds
  );
end;
$preflight$;

-- Quantity-aware selector. Callers keep their own signatures and pass the
-- whole intake quantity. One crate must hold all of it; this function does
-- not split a quantity across crates.
create or replace function app_private.select_zone_f_crate(
  target_godown uuid,
  requested_cases integer
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  crate_ids uuid[];
  candidate record;
begin
  if target_godown is null
    or not app_private.trusted_guc_active('app.damage_stock_write')
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if requested_cases is null or requested_cases < 1 then
    raise exception 'quarantine intake quantity must be positive'
      using errcode = '23514';
  end if;

  select array_agg(crates.id order by crates.id)
  into crate_ids
  from public.crates
  join public.zones on zones.id = crates.zone_id
  join public.branches on branches.id = zones.branch_id
  where zones.branch_id = target_godown
    and lower(zones.code) = 'f'
    and zones.location_role = 'quarantine'
    and zones.is_active
    and lower(crates.code) in ('f-01', 'f-02', 'f-03', 'f-04')
    and crates.location_role = 'quarantine'
    and crates.is_active
    and branches.is_active;

  if crate_ids is null or cardinality(crate_ids) <> 4 then
    raise exception 'zone F quarantine layout is incomplete'
      using errcode = '23514';
  end if;

  -- Zones by id, then crates by id, then the branch. This is the same order
  -- as prepare_stock_locations, so two intakes contend on F-01 before F-02.
  perform app_private.prepare_stock_locations(crate_ids);

  perform stock_balances.crate_id
  from public.stock_balances
  where stock_balances.crate_id = any (crate_ids)
  order by stock_balances.crate_id, stock_balances.product_id
  for update;

  for candidate in
    select
      crates.id,
      crates.capacity_cases,
      coalesce(sum(stock_balances.quantity), 0)::integer as on_hand
    from public.crates
    left join public.stock_balances on stock_balances.crate_id = crates.id
    where crates.id = any (crate_ids)
    group by crates.id, crates.code, crates.capacity_cases
    order by crates.code
  loop
    -- Reservations are not added to physical occupancy.
    if candidate.capacity_cases - candidate.on_hand >= requested_cases then
      return candidate.id;
    end if;
  end loop;

  raise exception 'no quarantine crate can accept the requested quantity'
    using errcode = '23514';
end;
$function$;

revoke all on function app_private.select_zone_f_crate(uuid, integer)
  from public, anon, authenticated, service_role;

-- The old helper has no quantity argument. Leaving it able to create QRN
-- would send new intake to the legacy crate, so it now fails closed.
create or replace function app_private.ensure_godown_quarantine_crate(target_godown uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
begin
  raise exception 'quarantine intake must use select_zone_f_crate with a quantity'
    using errcode = '23514';
end;
$function$;

-- Patch the three live callers in place. Their public signatures stay the same.
do $patch$
declare
  fn regprocedure;
  source text;
  old_call text;
  new_call text;
  targets text[][] := array[
    array[
      'app_private.isolate_shop_return_damage(public.damage_reports)',
      'q_crate := app_private.ensure_godown_quarantine_crate(header.godown_id);',
      'q_crate := app_private.select_zone_f_crate(header.godown_id, coalesce((select sum(lines.quantity_cases) from public.damage_report_lines lines where lines.damage_report_id = header.id), 0));'
    ],
    array[
      'public.transfer_verified_damage_to_quarantine(uuid,integer,text)',
      'q_crate := app_private.ensure_godown_quarantine_crate(selected.godown_id);',
      'q_crate := app_private.select_zone_f_crate(selected.godown_id, coalesce((select sum(holds.quantity_cases) from public.damage_stock_holds holds where holds.damage_report_id = selected.id and holds.status = ''active'' and holds.hold_kind = ''on_hand_deduction''), 0));'
    ],
    array[
      'public.post_delivery_return(uuid,integer,text)',
      'quarantine_crate := app_private.ensure_godown_quarantine_crate(header.branch_id);',
      'quarantine_crate := app_private.select_zone_f_crate(header.branch_id, coalesce((select sum(lots.damaged_cases + lots.uncertain_cases) from public.stock_delivery_return_lots lots where lots.return_id = header.id), 0));'
    ]
  ];
begin
  for fn, old_call, new_call in
    select targets[i][1]::regprocedure, targets[i][2], targets[i][3]
    from generate_subscripts(targets, 1) as i
  loop
    source := pg_get_functiondef(fn);
    if position(new_call in source) > 0 then
      continue;
    end if;
    if position(old_call in source) = 0 then
      raise exception 'quarantine caller % no longer contains the reviewed call', fn;
    end if;
    execute replace(source, old_call, new_call);
  end loop;
end;
$patch$;

-- The old partial indexes forbid a second quarantine zone and a second
-- quarantine crate. Code uniqueness remains. The allowlists stop arbitrary
-- quarantine codes from replacing that protection.
drop index if exists public.zones_branch_quarantine_key;
drop index if exists public.crates_zone_quarantine_key;

alter table public.zones
  drop constraint if exists zones_quarantine_code_allowlist;
alter table public.zones
  add constraint zones_quarantine_code_allowlist
  check (
    location_role <> 'quarantine'
    or lower(code) in ('f', 'qrn')
  );

alter table public.crates
  drop constraint if exists crates_quarantine_code_allowlist;
alter table public.crates
  add constraint crates_quarantine_code_allowlist
  check (
    location_role <> 'quarantine'
    or lower(code) in ('f-01', 'f-02', 'f-03', 'f-04', 'qrn-01')
  );

create unique index if not exists zones_one_operational_quarantine_zone
  on public.zones (branch_id)
  where location_role = 'quarantine' and lower(code) = 'f';

create unique index if not exists zones_one_legacy_quarantine_zone
  on public.zones (branch_id)
  where location_role = 'quarantine' and lower(code) = 'qrn';

-- Parent/child role agreement cannot be expressed by a local check.
create or replace function app_private.guard_quarantine_crate_parent()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  parent_code text;
  parent_role text;
begin
  if new.location_role is distinct from 'quarantine' then
    return new;
  end if;

  select lower(zones.code), zones.location_role
  into parent_code, parent_role
  from public.zones
  where zones.id = new.zone_id;

  if parent_role is distinct from 'quarantine' then
    raise exception 'a quarantine crate requires a quarantine zone'
      using errcode = '23514';
  end if;

  if lower(new.code) = 'qrn-01' and parent_code is distinct from 'qrn' then
    raise exception 'QRN-01 can belong only to the legacy QRN zone'
      using errcode = '23514';
  end if;

  if lower(new.code) in ('f-01', 'f-02', 'f-03', 'f-04')
    and parent_code is distinct from 'f'
  then
    raise exception 'F crates can belong only to Zone F'
      using errcode = '23514';
  end if;

  return new;
end;
$function$;

drop trigger if exists crates_quarantine_parent_guard on public.crates;
create trigger crates_quarantine_parent_guard
  before insert or update of zone_id, code, location_role
  on public.crates
  for each row
  execute function app_private.guard_quarantine_crate_parent();

-- The location-role trigger rejects a quarantine insert unless this token is set.
do $trusted$
begin
  perform app_private.enable_trusted_guc('app.quarantine_location_write');
end;
$trusted$;

insert into public.zones (branch_id, code, name, description, location_role)
select
  branches.id,
  'F',
  'Zone F',
  'Operational quarantine. Legacy QRN remains a separate historical location.',
  'quarantine'
from public.branches
where branches.code in ('gd_1', 'gd_2', 'gd_3', 'gd_4', 'gd_5', 'gd_6', 'gd_7')
  and not exists (
    select 1
    from public.zones existing
    where existing.branch_id = branches.id
      and lower(existing.code) = 'f'
  );

insert into public.crates (
  zone_id, code, name, description, location_role, capacity_cases
)
select
  zones.id,
  slot.code,
  slot.label,
  'Operational quarantine crate. Not available for normal picking.',
  'quarantine',
  50
from public.zones
join public.branches on branches.id = zones.branch_id
cross join (
  values
    ('F-01', 'Crate 01'),
    ('F-02', 'Crate 02'),
    ('F-03', 'Crate 03'),
    ('F-04', 'Crate 04')
) as slot(code, label)
where branches.code in ('gd_1', 'gd_2', 'gd_3', 'gd_4', 'gd_5', 'gd_6', 'gd_7')
  and lower(zones.code) = 'f'
  and zones.location_role = 'quarantine'
  and not exists (
    select 1
    from public.crates existing
    where existing.zone_id = zones.id
      and lower(existing.code) = lower(slot.code)
  );

do $verify$
declare
  baseline zone_f_baseline%rowtype;
begin
  if (
    select count(*)
    from public.zones
    join public.branches on branches.id = zones.branch_id
    where branches.code like 'gd_%'
      and zones.code = 'F'
      and zones.location_role = 'quarantine'
  ) <> 7 then
    raise exception 'expected seven Zone F records';
  end if;

  if (
    select count(*)
    from public.crates
    join public.zones on zones.id = crates.zone_id
    where zones.code = 'F'
      and crates.location_role = 'quarantine'
      and crates.code in ('F-01', 'F-02', 'F-03', 'F-04')
      and crates.capacity_cases = 50
  ) <> 28 then
    raise exception 'expected 28 empty Zone F crates at capacity 50';
  end if;

  if exists (
    select 1
    from public.stock_balances
    join public.crates on crates.id = stock_balances.crate_id
    join public.zones on zones.id = crates.zone_id
    where zones.code = 'F'
  ) or exists (
    select 1
    from public.stock_ledger
    join public.crates on crates.id = stock_ledger.crate_id
    join public.zones on zones.id = crates.zone_id
    where zones.code = 'F'
  ) then
    raise exception 'provisioning created stock in Zone F';
  end if;

  if exists (
    select 1
    from public.zones
    where id = '950a8964-1b5c-4303-8e20-18669a443b80'
      and (code is distinct from 'QRN' or location_role is distinct from 'quarantine')
  ) or exists (
    select 1
    from public.crates
    where id = '41375776-a323-40ed-a128-fee651fd48d8'
      and (
        code is distinct from 'QRN-01'
        or zone_id is distinct from '950a8964-1b5c-4303-8e20-18669a443b80'
      )
  ) then
    raise exception 'legacy quarantine location changed';
  end if;

  select * into baseline from zone_f_baseline;
  if (
    select count(*) from public.stock_balances
  ) is distinct from baseline.balances
  or (
    select coalesce(sum(quantity), 0) from public.stock_balances
  ) is distinct from baseline.balance_qty
  or (
    select count(*) from public.stock_lot_balances
  ) is distinct from baseline.lots
  or (
    select coalesce(sum(quantity), 0) from public.stock_lot_balances
  ) is distinct from baseline.lot_qty
  or (
    select count(*) from public.stock_ledger
  ) is distinct from baseline.ledger
  or (
    select coalesce(sum(quantity), 0) from public.stock_ledger
  ) is distinct from baseline.ledger_qty
  or (
    select count(*) from public.stock_transactions
  ) is distinct from baseline.transactions
  or (
    select count(*) from public.damage_stock_holds
  ) is distinct from baseline.holds
  then
    raise exception 'inventory changed during Zone F provisioning';
  end if;
end;
$verify$;

commit;
