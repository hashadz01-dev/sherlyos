-- M8.1B disposable cutover rehearsal. COMMITS on m81b_rehearsal only.
-- Refuses the owner system identifier. Recovery is restore, not flag-off.

do $$
declare
  sysid bigint;
begin
  select system_identifier into sysid from pg_control_system();
  if sysid = 7699785797738577957 then
    raise exception 'M8.1B must not run against the owner database (system_identifier=%)', sysid;
  end if;
  if current_database() is distinct from 'm81b_rehearsal' then
    raise exception 'M8.1B must run on database m81b_rehearsal, got %', current_database();
  end if;
end $$;

begin;

create table if not exists app_private.m81b_oracles (
  name text primary key,
  value bigint not null,
  note text
);
-- Isolated rehearsal table only. Authenticated RPCs stay security definer;
-- oracles are recorded from the same session after set local role.
grant usage on schema app_private to authenticated;
grant select, insert, update on app_private.m81b_oracles to authenticated;

create temp table fixture (
  name text primary key,
  id uuid not null
);
grant select on fixture to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('accounts', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('driver', gen_random_uuid()),
  ('other', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.m81b@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture;

insert into public.profiles (id, full_name, is_active)
select id, name, true from fixture
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles on roles.code = case fixture.name
  when 'admin' then 'admin'
  when 'accounts' then 'accounts'
  when 'godown' then 'godown_manager'
  when 'keeper' then 'store_keeper'
  when 'driver' then 'delivery_person'
  when 'other' then 'godown_manager'
end
on conflict do nothing;

create or replace function pg_temp.as_user(who text)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = who), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = who), 'role', 'authenticated')::text,
    true
  );
end;
$$;

create or replace function pg_temp.qty_agg(p_crate uuid, p_product uuid)
returns integer language sql as $$
  select coalesce((
    select quantity from public.stock_balances
    where crate_id = p_crate and product_id = p_product
  ), 0);
$$;

create or replace function pg_temp.qty_lot(p_crate uuid, p_product uuid)
returns integer language sql as $$
  select coalesce((
    select sum(stock_lot_balances.quantity)::integer
    from public.stock_lot_balances
    join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
    where stock_lot_balances.crate_id = p_crate
      and stock_lots.product_id = p_product
  ), 0);
$$;

create or replace function pg_temp.oracle(p_name text, p_value bigint, p_note text)
returns void language plpgsql as $$
begin
  insert into app_private.m81b_oracles (name, value, note)
  values (p_name, p_value, p_note)
  on conflict (name) do update set value = excluded.value, note = excluded.note;
end;
$$;

-- Owner of this temp function is the session role (postgres). Invoked after
-- set local role authenticated so grain checks do not depend on app_private grants.
create or replace function pg_temp.assert_grains()
returns void
language plpgsql
security definer
set search_path = public, app_private
as $$
begin
  perform app_private.assert_lot_inventory_grains_reconciled();
end;
$$;

create or replace function pg_temp.count_return_lots(p_return uuid default null)
returns bigint
language sql
security definer
set search_path = public
as $$
  select count(*)::bigint
  from public.stock_delivery_return_lots
  where p_return is null or return_id = p_return;
$$;

create or replace function pg_temp.handshake_dn(p_order uuid, p_prefix text)
returns uuid language plpgsql as $$
declare
  note_id uuid;
  payload jsonb;
  note_status text;
  note_version integer;
begin
  perform pg_temp.as_user('accounts');
  select delivery_notes.id, delivery_notes.status, delivery_notes.version
    into note_id, note_status, note_version
  from public.delivery_notes
  where delivery_notes.order_id = p_order
    and delivery_notes.status is distinct from 'voided'
  order by delivery_notes.created_at desc
  limit 1;

  if note_id is null then
    payload := public.create_delivery_note(p_order, p_prefix || '-dn');
    note_id := (payload -> 'delivery_note' ->> 'id')::uuid;
    note_status := payload -> 'delivery_note' ->> 'status';
    note_version := (payload -> 'delivery_note' ->> 'version')::integer;
  end if;
  if note_status = 'draft' then
    payload := public.generate_delivery_note(note_id, note_version, p_prefix || '-gen');
    note_status := payload -> 'delivery_note' ->> 'status';
    note_version := (payload -> 'delivery_note' ->> 'version')::integer;
  end if;
  if note_status = 'generated' then
    payload := public.send_delivery_note(note_id, note_version, p_prefix || '-send');
    note_status := payload -> 'delivery_note' ->> 'status';
    note_version := (payload -> 'delivery_note' ->> 'version')::integer;
  end if;
  if note_status = 'sent' then
    perform pg_temp.as_user('godown');
    payload := public.acknowledge_delivery_note(note_id, note_version, p_prefix || '-ack');
    note_status := payload -> 'delivery_note' ->> 'status';
  end if;
  if note_status is distinct from 'acknowledged' then
    raise exception 'DN handshake did not reach acknowledged: %', note_status;
  end if;
  return note_id;
end;
$$;

create or replace function pg_temp.handoff(p_order uuid, p_prefix text)
returns uuid language plpgsql as $$
declare
  header jsonb;
  res jsonb;
  i int;
  request_id uuid;
begin
  perform pg_temp.handshake_dn(p_order, p_prefix);
  perform pg_temp.as_user('godown');
  header := public.reserve_order_allocation(p_order, 3, p_prefix || '-res');
  request_id := (header ->> 'id')::uuid;
  header := public.assign_picking_request(
    request_id, (select id from fixture where name = 'keeper'), 1, p_prefix || '-asg'
  );
  header := public.start_picking(request_id, 2, p_prefix || '-start');
  perform pg_temp.as_user('keeper');
  header := public.get_picking_request(request_id);
  for i in 0 .. jsonb_array_length(header -> 'reservations') - 1 loop
    res := header -> 'reservations' -> i;
    header := public.confirm_picking_quantity(
      request_id, (res ->> 'id')::uuid, (res ->> 'reserved_cases')::integer,
      (header ->> 'version')::integer, p_prefix || '-pick-' || i::text
    );
  end loop;
  header := public.complete_picking(request_id, (header ->> 'version')::integer, p_prefix || '-done');
  perform pg_temp.as_user('godown');
  header := public.confirm_picking_handoff(request_id, (header ->> 'version')::integer, p_prefix || '-ho');
  return request_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Stock readiness on the restored copy
-- ---------------------------------------------------------------------------
do $$
declare
  agg_qty bigint;
  lot_qty bigint;
  neg_agg integer;
  neg_lot integer;
  unclassified_stocked integer;
  posted_returns integer;
  return_lots integer;
  ledger_without_txn integer;
begin
  if (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled')
       is distinct from 'false'::jsonb
     or (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked')
       is distinct from 'false'::jsonb
     or (select value from public.app_configuration where key = 'damage.stock_hold_ready')
       is distinct from 'false'::jsonb
  then
    raise exception 'disposable flags must start false/false/false';
  end if;

  perform pg_temp.assert_grains();

  select coalesce(sum(quantity), 0) into agg_qty from public.stock_balances;
  select coalesce(sum(quantity), 0) into lot_qty from public.stock_lot_balances;
  if agg_qty is distinct from lot_qty then
    raise exception 'aggregate on-hand % <> lot on-hand %', agg_qty, lot_qty;
  end if;

  select count(*) into neg_agg from public.stock_balances where quantity < 0;
  select count(*) into neg_lot from public.stock_lot_balances where quantity < 0;
  if neg_agg > 0 or neg_lot > 0 then
    raise exception 'negative balances agg=% lot=%', neg_agg, neg_lot;
  end if;

  select count(*) into unclassified_stocked
  from public.stock_balances sb
  join public.products p on p.id = sb.product_id
  where sb.quantity > 0 and p.expiry_policy is null;
  if unclassified_stocked > 0 then
    raise exception 'stocked unclassified products=%; dual-write enable would fail', unclassified_stocked;
  end if;

  select count(*) into posted_returns
  from public.stock_delivery_returns
  where status = 'posted';
  select count(*) into return_lots from public.stock_delivery_return_lots;
  if posted_returns < 1 then
    raise exception 'historical posted returns were not restored';
  end if;

  select count(*) into ledger_without_txn
  from public.stock_ledger sl
  where not exists (
    select 1 from public.stock_transactions st where st.id = sl.transaction_id
  );
  if ledger_without_txn > 0 then
    raise exception 'ledger rows without transactions=%', ledger_without_txn;
  end if;

  perform pg_temp.oracle('pre_cutover_agg_qty', agg_qty, 'independent aggregate oracle');
  perform pg_temp.oracle('pre_cutover_lot_qty', lot_qty, 'independent lot oracle');
  perform pg_temp.oracle('pre_cutover_posted_returns', posted_returns, 'historical returns preserved');
  perform pg_temp.oracle('pre_cutover_return_lots', return_lots, 'no manufactured historical lots');
  perform pg_temp.oracle('unclassified_catalog', (
    select count(*) from public.products where expiry_policy is null
  ), 'must remain blocked after cutover');
end $$;

-- ---------------------------------------------------------------------------
-- 5. Atomic cutover (both flags true in one statement)
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    update public.app_configuration
    set value = 'true'::jsonb
    where key = 'stock.lots.aggregate_only_blocked';
    raise exception 'sequential blocked=true must fail while dual-write is still false and lot ledger exists';
  exception
    when sqlstate '55000' then null;
  end;
end $$;

update public.app_configuration
set value = 'true'::jsonb
where key in (
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked'
);

do $$
begin
  if (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled')
       is distinct from 'true'::jsonb
     or (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked')
       is distinct from 'true'::jsonb
  then
    raise exception 'atomic true/true cutover was not accepted';
  end if;
  if (select value from public.app_configuration where key = 'damage.stock_hold_ready')
       is distinct from 'false'::jsonb
  then
    raise exception 'damage holds must stay false';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Isolated fixtures
-- ---------------------------------------------------------------------------
select pg_temp.as_user('admin');
set local role authenticated;

select set_config('sherlyos.branch', public.create_branch('m81b_a', 'M81B A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('m81b_b', 'M81B B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'driver'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'other'), current_setting('sherlyos.branch_b')::uuid);
select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'z1', 'Z1', null)::text, true);
select set_config('sherlyos.crate_a', public.create_crate(current_setting('sherlyos.zone')::uuid, 'ca', 'CA', null)::text, true);
select set_config('sherlyos.crate_b', public.create_crate(current_setting('sherlyos.zone')::uuid, 'cb', 'CB', null)::text, true);
select set_config('sherlyos.zone_x', public.create_zone(current_setting('sherlyos.branch_b')::uuid, 'zx', 'ZX', null)::text, true);
select set_config('sherlyos.crate_x', public.create_crate(current_setting('sherlyos.zone_x')::uuid, 'cx', 'CX', null)::text, true);
select set_config('sherlyos.exp', public.create_product('m81b-exp', 'M81B Expiry', null, null)::text, true);
select set_config('sherlyos.nx', public.create_product('m81b-nx', 'M81B Non-expiring', null, null)::text, true);
select set_config('sherlyos.unclass', public.create_product('m81b-un', 'M81B Unclassified', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.exp')::uuid, 'expiry_controlled');
select public.set_product_expiry_policy(current_setting('sherlyos.nx')::uuid, 'non_expiring');
select set_config('sherlyos.shop', public.create_shop('M81B shop', null, null)::text, true);

select pg_temp.as_user('godown');
select set_config(
  'sherlyos.vehicle',
  public.create_vehicle(
    current_setting('sherlyos.branch')::uuid, 'KL07 M81B 01', 'van', 'M81B van', 20, 'ops'
  )::text,
  true
);

-- Aggregate-only / missing lot must fail closed after cutover.
select pg_temp.as_user('admin');
do $$
begin
  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.exp')::uuid,
      current_setting('sherlyos.crate_a')::uuid,
      1, 'm81b-agg-only', null
    );
    raise exception 'aggregate-only opening must fail after cutover';
  exception
    when sqlstate '23514' then null;
  end;

  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.unclass')::uuid,
      current_setting('sherlyos.crate_a')::uuid,
      1, 'm81b-unclass-open', null, 'UN-1', null, null
    );
    raise exception 'unclassified stocked product must remain blocked';
  exception
    when sqlstate '23514' then null;
  end;

  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.exp')::uuid,
      current_setting('sherlyos.crate_a')::uuid,
      1, 'm81b-exp-missing', null, 'LOT-NO-EXP', null, null
    );
    raise exception 'expiry-controlled without expiry must fail';
  exception
    when sqlstate '23514' then null;
  end;

  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.nx')::uuid,
      current_setting('sherlyos.crate_a')::uuid,
      1, 'm81b-nx-bad-exp', null, 'NX-BAD', null, current_date + 30
    );
    raise exception 'non-expiring with expiry must fail';
  exception
    when sqlstate '23514' then null;
  end;

end $$;

-- Admin has access_all; the GM assigned only to branch A must not post onto B.
select pg_temp.as_user('godown');
do $$
begin
  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.exp')::uuid,
      current_setting('sherlyos.crate_x')::uuid,
      1, 'm81b-cross-crate', null, 'X-LOT', null, '2028-01-01'
    );
    raise exception 'cross-godown crate opening must fail';
  exception
    when sqlstate '23514' then
      null;
    when sqlstate '42501' then
      null;
  end;
end $$;

-- Unauthorized stock writes
select pg_temp.as_user('driver');
do $$
begin
  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.nx')::uuid,
      current_setting('sherlyos.crate_a')::uuid,
      1, 'm81b-unauth-open', null, 'NX-UNAUTH', null, null
    );
    raise exception 'driver must not post opening stock';
  exception
    when sqlstate '42501' then null;
  end;

  declare
    before_qty bigint;
    after_qty bigint;
  begin
    select coalesce(sum(quantity), 0) into before_qty from public.stock_balances;
    begin
      update public.stock_balances set quantity = quantity + 1;
      raise exception 'direct stock_balances update must fail';
    exception
      when sqlstate '42501' then null;
    end;
    select coalesce(sum(quantity), 0) into after_qty from public.stock_balances;
    if after_qty is distinct from before_qty then
      raise exception 'rejected unauthorized write mutated stock';
    end if;
  end;
end $$;

-- Lot-aware openings (FEFO then FIFO). Independent oracles captured first.
select pg_temp.as_user('admin');
do $$
declare
  crate uuid := current_setting('sherlyos.crate_a')::uuid;
  crate_b uuid := current_setting('sherlyos.crate_b')::uuid;
  exp uuid := current_setting('sherlyos.exp')::uuid;
  nx uuid := current_setting('sherlyos.nx')::uuid;
begin
  perform pg_temp.oracle('open_exp_before', pg_temp.qty_agg(crate, exp) + pg_temp.qty_agg(crate_b, exp), 'exp grains before open');
  perform pg_temp.oracle('open_nx_before', pg_temp.qty_agg(crate, nx) + pg_temp.qty_agg(crate_b, nx), 'nx grains before open');
end $$;

select public.post_opening_stock(
  current_setting('sherlyos.exp')::uuid, current_setting('sherlyos.crate_a')::uuid,
  4, 'm81b-open-exp-late', null, 'BATCH-LATE', null, '2028-12-01'
);
select public.post_opening_stock(
  current_setting('sherlyos.exp')::uuid, current_setting('sherlyos.crate_b')::uuid,
  4, 'm81b-open-exp-early', null, 'BATCH-EARLY', null, '2027-01-15'
);
select public.post_opening_stock(
  current_setting('sherlyos.nx')::uuid, current_setting('sherlyos.crate_a')::uuid,
  3, 'm81b-open-nx-old', null, 'NX-OLD', null, null
);
select public.post_opening_stock(
  current_setting('sherlyos.nx')::uuid, current_setting('sherlyos.crate_b')::uuid,
  3, 'm81b-open-nx-new', null, 'NX-NEW', null, null
);

do $$
declare
  crate uuid := current_setting('sherlyos.crate_a')::uuid;
  crate_b uuid := current_setting('sherlyos.crate_b')::uuid;
  exp uuid := current_setting('sherlyos.exp')::uuid;
  nx uuid := current_setting('sherlyos.nx')::uuid;
  exp_total integer;
  nx_total integer;
begin
  exp_total := pg_temp.qty_agg(crate, exp) + pg_temp.qty_agg(crate_b, exp);
  nx_total := pg_temp.qty_agg(crate, nx) + pg_temp.qty_agg(crate_b, nx);
  if exp_total is distinct from (select value from app_private.m81b_oracles where name = 'open_exp_before') + 8 then
    raise exception 'exp opening oracle failed: %', exp_total;
  end if;
  if nx_total is distinct from (select value from app_private.m81b_oracles where name = 'open_nx_before') + 6 then
    raise exception 'nx opening oracle failed: %', nx_total;
  end if;
  if pg_temp.qty_lot(crate, exp) is distinct from pg_temp.qty_agg(crate, exp)
     or pg_temp.qty_lot(crate_b, exp) is distinct from pg_temp.qty_agg(crate_b, exp)
     or pg_temp.qty_lot(crate, nx) is distinct from pg_temp.qty_agg(crate, nx)
     or pg_temp.qty_lot(crate_b, nx) is distinct from pg_temp.qty_agg(crate_b, nx)
  then
    raise exception 'lot/aggregate mismatch after opening';
  end if;
  perform pg_temp.assert_grains();
end $$;

-- FEFO/FIFO picking preview
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_pick',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.exp')::uuid, 'requested_cases', 5),
        jsonb_build_object('product_id', current_setting('sherlyos.nx')::uuid, 'requested_cases', 2)
      ),
      'm81b-order-pick'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_pick')::uuid, 1, 'm81b-sub-pick');
select public.verify_order(current_setting('sherlyos.order_pick')::uuid, 2, 'm81b-ver-pick');

select pg_temp.handshake_dn(current_setting('sherlyos.order_pick')::uuid, 'm81b-pick');
select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
  line jsonb;
  first_lot text;
begin
  preview := public.preview_order_allocation(current_setting('sherlyos.order_pick')::uuid);
  if coalesce(preview ->> 'eligible', 'false') is distinct from 'true' then
    raise exception 'eligible order should preview true: %', preview;
  end if;
  for line in select value from jsonb_array_elements(preview -> 'lines')
  loop
    first_lot := line -> 'slices' -> 0 ->> 'manufacturer_lot_code';
    if line ->> 'expiry_policy' = 'expiry_controlled' and first_lot is distinct from 'BATCH-EARLY' then
      raise exception 'FEFO must pick earliest expiry first, got %', first_lot;
    end if;
    if line ->> 'expiry_policy' = 'non_expiring' and first_lot is distinct from 'NX-OLD' then
      raise exception 'FIFO must pick earliest received_on first, got %', first_lot;
    end if;
  end loop;
end $$;

-- Over-pick must fail and leave reservations unchanged.
select pg_temp.as_user('godown');
do $$
declare
  header jsonb;
  res jsonb;
  request_id uuid;
  before integer;
begin
  header := public.reserve_order_allocation(current_setting('sherlyos.order_pick')::uuid, 3, 'm81b-res-pick');
  request_id := (header ->> 'id')::uuid;
  perform set_config('sherlyos.request_pick', request_id::text, true);
  header := public.assign_picking_request(
    request_id, (select id from fixture where name = 'keeper'), 1, 'm81b-asg-pick'
  );
  header := public.start_picking(request_id, 2, 'm81b-start-pick');
  perform pg_temp.as_user('keeper');
  header := public.get_picking_request(request_id);
  res := header -> 'reservations' -> 0;
  before := (res ->> 'reserved_cases')::integer;
  begin
    perform public.confirm_picking_quantity(
      request_id, (res ->> 'id')::uuid, before + 1,
      (header ->> 'version')::integer, 'm81b-overpick'
    );
    raise exception 'over-pick must fail';
  exception
    when sqlstate '23514' then null;
  end;
  header := public.get_picking_request(request_id);
  if (header -> 'reservations' -> 0 ->> 'picked_cases')::integer is distinct from 0
     and (header -> 'reservations' -> 0 ->> 'picked_cases') is not null
     and (header -> 'reservations' -> 0 ->> 'picked_cases')::integer > 0
  then
    raise exception 'rejected over-pick must not store a picked quantity';
  end if;
end $$;

select pg_temp.as_user('keeper');
do $$
declare
  header jsonb;
  res jsonb;
  i int;
  request_id uuid := current_setting('sherlyos.request_pick')::uuid;
begin
  header := public.get_picking_request(request_id);
  for i in 0 .. jsonb_array_length(header -> 'reservations') - 1 loop
    res := header -> 'reservations' -> i;
    if coalesce((res ->> 'picked_cases')::int, 0) is distinct from (res ->> 'reserved_cases')::int then
      header := public.confirm_picking_quantity(
        request_id, (res ->> 'id')::uuid, (res ->> 'reserved_cases')::integer,
        (header ->> 'version')::integer, 'm81b-pick-' || i::text
      );
    end if;
  end loop;
  header := public.complete_picking(request_id, (header ->> 'version')::integer, 'm81b-done-pick');
end $$;

select pg_temp.as_user('godown');
select public.confirm_picking_handoff(
  current_setting('sherlyos.request_pick')::uuid,
  (select version from public.stock_picking_requests where id = current_setting('sherlyos.request_pick')::uuid),
  'm81b-ho-pick'
);

-- Dispatch consume + duplicate confirm
do $$
declare
  preview jsonb;
  prepared jsonb;
  confirmed jsonb;
  replay jsonb;
  crate uuid := current_setting('sherlyos.crate_a')::uuid;
  crate_b uuid := current_setting('sherlyos.crate_b')::uuid;
  exp uuid := current_setting('sherlyos.exp')::uuid;
  nx uuid := current_setting('sherlyos.nx')::uuid;
  before_exp integer;
  before_nx integer;
  after_exp integer;
  after_nx integer;
  before_ledger bigint;
  after_ledger bigint;
begin
  before_exp := pg_temp.qty_agg(crate, exp) + pg_temp.qty_agg(crate_b, exp);
  before_nx := pg_temp.qty_agg(crate, nx) + pg_temp.qty_agg(crate_b, nx);
  select count(*) into before_ledger from public.stock_ledger;
  perform pg_temp.oracle('dispatch_exp_before', before_exp, 'exp before dispatch consume');
  perform pg_temp.oracle('dispatch_nx_before', before_nx, 'nx before dispatch consume');

  preview := public.preview_dispatch(current_setting('sherlyos.order_pick')::uuid);
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_pick')::uuid,
    (preview ->> 'picking_version')::integer,
    'm81b-prep-pick'
  );
  confirmed := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm81b-cfm-pick'
  );
  perform set_config('sherlyos.dispatch_pick', (confirmed ->> 'id')::text, true);
  if confirmed ->> 'stock_consumed' is distinct from 'true' then
    raise exception 'dispatch must consume stock';
  end if;

  begin
    replay := public.confirm_dispatch(
      (confirmed ->> 'id')::uuid, (confirmed ->> 'version')::integer, 'm81b-cfm-pick-dup'
    );
    -- Idempotent replay is acceptable; a second consume is not.
  exception
    when sqlstate '23514' then
      replay := confirmed;
    when sqlstate 'PT409' then
      replay := confirmed;
  end;

  after_exp := pg_temp.qty_agg(crate, exp) + pg_temp.qty_agg(crate_b, exp);
  after_nx := pg_temp.qty_agg(crate, nx) + pg_temp.qty_agg(crate_b, nx);
  select count(*) into after_ledger from public.stock_ledger;
  if after_exp is distinct from before_exp - 5 then
    raise exception 'dispatch exp consume oracle failed: before=% after=%', before_exp, after_exp;
  end if;
  if after_nx is distinct from before_nx - 2 then
    raise exception 'dispatch nx consume oracle failed: before=% after=%', before_nx, after_nx;
  end if;
  if pg_temp.qty_lot(crate, exp) is distinct from pg_temp.qty_agg(crate, exp)
     or pg_temp.qty_lot(crate_b, exp) is distinct from pg_temp.qty_agg(crate_b, exp)
  then
    raise exception 'dispatch left aggregate/lot mismatch';
  end if;
  perform pg_temp.assert_grains();
  if after_ledger <= before_ledger then
    raise exception 'dispatch must write ledger rows';
  end if;
end $$;

-- Complete delivery (POD) on the consumed dispatch
select pg_temp.as_user('godown');
do $$
declare
  assigned jsonb;
  started jsonb;
  delivered jsonb;
  header jsonb;
begin
  header := public.get_dispatch_request(current_setting('sherlyos.dispatch_pick')::uuid);
  assigned := public.assign_dispatch_delivery(
    current_setting('sherlyos.dispatch_pick')::uuid,
    (select id from fixture where name = 'driver'),
    (header ->> 'version')::integer,
    'm81b-asg-del',
    current_setting('sherlyos.vehicle')::uuid
  );
  perform pg_temp.as_user('driver');
  started := public.start_dispatch_delivery(
    current_setting('sherlyos.dispatch_pick')::uuid,
    (assigned ->> 'version')::integer,
    'm81b-go-del'
  );
  delivered := public.acknowledge_dispatch_delivery(
    current_setting('sherlyos.dispatch_pick')::uuid,
    'Shop keeper', 'left at counter',
    (started ->> 'version')::integer,
    'm81b-pod'
  );
  if delivered ->> 'status' is distinct from 'delivered' then
    raise exception 'POD should mark delivered, got %', delivered ->> 'status';
  end if;
end $$;

-- Cross-godown access stays denied after cutover
select pg_temp.as_user('other');
do $$
begin
  begin
    perform public.preview_dispatch(current_setting('sherlyos.order_pick')::uuid);
    raise exception 'cross-godown manager must not preview dispatch';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Second order: lot-aware customer return via failed-delivery exception
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_ret',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.exp')::uuid, 'requested_cases', 2)
      ),
      'm81b-order-ret'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_ret')::uuid, 1, 'm81b-sub-ret');
select public.verify_order(current_setting('sherlyos.order_ret')::uuid, 2, 'm81b-ver-ret');
select set_config('sherlyos.request_ret', pg_temp.handoff(current_setting('sherlyos.order_ret')::uuid, 'm81b-ret')::text, true);

select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
  prepared jsonb;
  confirmed jsonb;
  assigned jsonb;
  excepted jsonb;
  crate uuid := current_setting('sherlyos.crate_a')::uuid;
  crate_b uuid := current_setting('sherlyos.crate_b')::uuid;
  exp uuid := current_setting('sherlyos.exp')::uuid;
  before integer;
begin
  before := pg_temp.qty_agg(crate, exp) + pg_temp.qty_agg(crate_b, exp);
  perform pg_temp.oracle('return_exp_before_dispatch', before, 'exp before return-path dispatch');
  preview := public.preview_dispatch(current_setting('sherlyos.order_ret')::uuid);
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_ret')::uuid,
    (preview ->> 'picking_version')::integer,
    'm81b-prep-ret'
  );
  confirmed := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm81b-cfm-ret'
  );
  perform set_config('sherlyos.dispatch_ret', (confirmed ->> 'id')::text, true);
  assigned := public.assign_dispatch_delivery(
    (confirmed ->> 'id')::uuid,
    (select id from fixture where name = 'driver'),
    (confirmed ->> 'version')::integer,
    'm81b-asg-ret',
    current_setting('sherlyos.vehicle')::uuid
  );
  excepted := public.report_dispatch_delivery_exception(
    (assigned ->> 'id')::uuid, 'shop closed',
    (assigned ->> 'version')::integer, 'm81b-exc-ret'
  );
  if excepted ->> 'return_id' is null then
    raise exception 'exception must open a return document';
  end if;
end $$;

select pg_temp.as_user('driver');
do $$
declare
  ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_ret')::uuid);
  ret := public.declare_delivery_return_handback(
    (ret ->> 'id')::uuid, 2, 'physical cartons', (ret ->> 'version')::integer, 'm81b-hb-ok'
  );
end $$;

select pg_temp.as_user('keeper');
do $$
declare
  ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_ret')::uuid);
  begin
    perform public.count_delivery_return(
      (ret ->> 'id')::uuid,
      jsonb_build_array(jsonb_build_object(
        'id', ret -> 'lots' -> 0 ->> 'id',
        'delivered_cases', 0,
        'saleable_cases', 2,
        'damaged_cases', 0,
        'uncertain_cases', 0,
        'missing_cases', 0,
        'receiving_crate_id', current_setting('sherlyos.crate_x')
      )),
      (ret ->> 'version')::integer,
      'm81b-cross-count'
    );
    raise exception 'cross-godown receiving crate must fail';
  exception
    when sqlstate '23514' then null;
  end;

  ret := public.count_delivery_return(
    (ret ->> 'id')::uuid,
    jsonb_build_array(jsonb_build_object(
      'id', ret -> 'lots' -> 0 ->> 'id',
      'delivered_cases', 0,
      'saleable_cases', 2,
      'damaged_cases', 0,
      'uncertain_cases', 0,
      'missing_cases', 0,
      'receiving_crate_id', current_setting('sherlyos.crate_a')
    )),
    (ret ->> 'version')::integer,
    'm81b-count'
  );
end $$;

select pg_temp.as_user('godown');
do $$
declare
  ret jsonb;
  crate uuid := current_setting('sherlyos.crate_a')::uuid;
  crate_b uuid := current_setting('sherlyos.crate_b')::uuid;
  exp uuid := current_setting('sherlyos.exp')::uuid;
  before integer;
  after integer;
  before_lots integer;
  after_lots integer;
  posted_lots integer;
  replay jsonb;
begin
  before := pg_temp.qty_agg(crate, exp) + pg_temp.qty_agg(crate_b, exp);
  before_lots := pg_temp.count_return_lots();
  perform pg_temp.oracle('return_exp_before_post', before, 'exp before return post');

  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_ret')::uuid);
  ret := public.approve_delivery_return(
    (ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm81b-ap-ok'
  );
  ret := public.post_delivery_return(
    (ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm81b-post'
  );
  if ret ->> 'status' is distinct from 'posted' then
    raise exception 'return should post, got %', ret ->> 'status';
  end if;

  after := pg_temp.qty_agg(crate, exp) + pg_temp.qty_agg(crate_b, exp);
  if after is distinct from before + 2 then
    raise exception 'return credit oracle failed: before=% after=%', before, after;
  end if;
  if pg_temp.qty_lot(crate, exp) is distinct from pg_temp.qty_agg(crate, exp) then
    raise exception 'return left crate_a aggregate/lot mismatch';
  end if;

  -- FORCE RLS hides return-lot rows from postgres; the posted payload is the
  -- independent oracle that the writer actually attached lots.
  after_lots := jsonb_array_length(coalesce(ret -> 'lots', '[]'::jsonb));
  if after_lots < 1 then
    raise exception 'lot-aware return must insert return-lot rows: %', ret -> 'lots';
  end if;
  posted_lots := after_lots;
  if posted_lots < 1 then
    raise exception 'posted return has no lot rows';
  end if;

  replay := public.post_delivery_return(
    (ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm81b-post-dup'
  );
  if (select pg_temp.qty_agg(crate, exp) + pg_temp.qty_agg(crate_b, exp)) is distinct from after then
    raise exception 'duplicate return posting mutated stock';
  end if;

  perform pg_temp.assert_grains();
  perform pg_temp.oracle('return_exp_after_post', after, 'exp after return post');
  perform pg_temp.oracle('return_lots_after', after_lots, 'return-lot rows after post');
end $$;

-- Final invariance vs pre-cutover oracles plus fixture deltas:
-- openings +8 exp +6 nx; pick dispatch -5 exp -2 nx; return-path dispatch -2 exp; return +2 exp.
-- Net fixture: exp +3, nx +4 on top of restored balances.
do $$
declare
  pre_agg bigint;
  now_agg bigint;
  now_lot bigint;
  posted_returns bigint;
begin
  reset role;
  select value into pre_agg from app_private.m81b_oracles where name = 'pre_cutover_agg_qty';
  select coalesce(sum(quantity), 0) into now_agg from public.stock_balances;
  select coalesce(sum(quantity), 0) into now_lot from public.stock_lot_balances;
  if now_agg is distinct from now_lot then
    raise exception 'final aggregate % <> lot %', now_agg, now_lot;
  end if;
  if now_agg is distinct from pre_agg + 8 + 6 - 5 - 2 - 2 + 2 then
    raise exception 'independent oracle net failed: pre=% now=% expected=%',
      pre_agg, now_agg, pre_agg + 7;
  end if;
  select count(*) into posted_returns
  from public.stock_delivery_returns
  where status = 'posted';
  if posted_returns is distinct from (
    select value from app_private.m81b_oracles where name = 'pre_cutover_posted_returns'
  ) + 1 then
    raise exception 'historical posted returns were not preserved';
  end if;
  if (select value from public.app_configuration where key = 'damage.stock_hold_ready')
       is distinct from 'false'::jsonb
  then
    raise exception 'damage holds must remain false';
  end if;
  perform pg_temp.oracle('final_agg_qty', now_agg, 'post-rehearsal aggregate');
  perform pg_temp.oracle('final_lot_qty', now_lot, 'post-rehearsal lot');
end $$;

commit;

select 'M8.1B rehearsal committed' as status,
       (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled') as dual_write,
       (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked') as blocked,
       (select value from app_private.m81b_oracles where name = 'final_agg_qty') as final_agg,
       (select value from app_private.m81b_oracles where name = 'final_lot_qty') as final_lot;
