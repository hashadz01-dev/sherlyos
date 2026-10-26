-- M5.3 local disposable SQL. Rolls back. Does not touch development cloud.
begin;

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
  ('verifier', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('driver', gen_random_uuid()),
  ('sales', gen_random_uuid()),
  ('other', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id, 'authenticated', 'authenticated',
  fixture.name || '.m53sql@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name), now(), now()
from fixture;

do $$
begin
  begin
    perform app_private.bootstrap_initial_admin(
      (select id from fixture where name = 'admin'), 'create-initial-administrator'
    );
  exception
    when sqlstate '42501' then
      insert into public.profiles (id, full_name, is_active)
      values ((select id from fixture where name = 'admin'), 'M53 Admin', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select (select id from fixture where name = 'admin'), roles.id,
        (select id from fixture where name = 'admin')
      from public.roles where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.profiles (id, full_name, is_active)
select fixture.id, fixture.name, true from fixture where name <> 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles on roles.code = case fixture.name
  when 'accounts' then 'accounts'
  when 'godown' then 'godown_manager'
  when 'verifier' then 'godown_manager'
  when 'keeper' then 'store_keeper'
  when 'driver' then 'delivery_person'
  when 'sales' then 'salesperson'
  when 'other' then 'godown_manager'
end
where fixture.name <> 'admin'
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

create or replace function pg_temp.attach_photo(target uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  created jsonb;
  payload bytea := decode('ffd8ffd9', 'hex');
begin
  created := public.create_damage_photo_upload(target, 'count sheet');
  -- SQL sessions have no caller JWT, so production finalize cannot fetch
  -- Storage bytes here. Stamp verified_at as a fixture only.
  perform set_config('app.damage_write', 'on', true);
  update public.damage_evidence
  set
    mime_type = 'image/jpeg',
    file_size = octet_length(payload),
    verified_at = clock_timestamp()
  where id = (created ->> 'id')::uuid;
end;
$$;

select pg_temp.as_user('admin');
set local role authenticated;

select set_config('sherlyos.branch', public.create_branch(
  'm53sql_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10), 'M53SQL A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch(
  'm53sql_b_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8), 'M53SQL B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'verifier'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'driver'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'sales'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'other'), current_setting('sherlyos.branch_b')::uuid);

select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'z1', 'Z1', null)::text, true);
select set_config('sherlyos.crate', public.create_crate(current_setting('sherlyos.zone')::uuid, 'ca', 'CA', null)::text, true);
select set_config('sherlyos.product', public.create_product('m53-soap', 'M53 Soap', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.product')::uuid, 'expiry_controlled');
select set_config('sherlyos.shop', public.create_shop('M53 shop', null, null)::text, true);
select set_config('sherlyos.supplier', public.create_supplier('M53 supplier', null, null)::text, true);

reset role;
set session_replication_role = replica;
update public.app_configuration set value = 'true'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked', 'damage.stock_hold_ready');
set session_replication_role = origin;

select pg_temp.as_user('admin');
set local role authenticated;
select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate')::uuid,
  20, 'm53-open-a', null, 'M53-A', null, '2028-06-01'
);
select set_config('sherlyos.lot', (
  select stock_lots.id::text from public.stock_lots
  where stock_lots.product_id = current_setting('sherlyos.product')::uuid
  order by stock_lots.created_at limit 1
), true);

select pg_temp.as_user('keeper');
select set_config('sherlyos.receipt', (
  public.create_stock_receipt(
    current_setting('sherlyos.branch')::uuid,
    current_setting('sherlyos.supplier')::uuid,
    'M53-INV-1', current_date, null,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'destination_crate_id', current_setting('sherlyos.crate')::uuid,
      'document_cases', 6, 'counted_cases', 5, 'damaged_cases', 2
    ))
  ) ->> 'id'
), true);
select set_config('sherlyos.receipt_line', (
  select stock_receipt_lines.id::text from public.stock_receipt_lines
  where receipt_id = current_setting('sherlyos.receipt')::uuid
), true);
select public.set_stock_receipt_line_lot_attributions(
  current_setting('sherlyos.receipt_line')::uuid,
  jsonb_build_array(jsonb_build_object(
    'carton_quantity', 3, 'manufacturer_lot_code', 'M53-R1',
    'manufactured_on', current_date - 5, 'expiry_date', current_date + 180
  ))
);
select public.submit_stock_receipt(current_setting('sherlyos.receipt')::uuid);
select pg_temp.as_user('godown');
select public.verify_stock_receipt(current_setting('sherlyos.receipt')::uuid, 'm53-recv-1');

select set_config('sherlyos.ledger_before', (
  select count(*)::text from public.stock_ledger
  where product_id = current_setting('sherlyos.product')::uuid
), true);
select set_config('sherlyos.bal_before', (
  select coalesce(sum(quantity), 0)::text from public.stock_balances
  where product_id = current_setting('sherlyos.product')::uuid
), true);

-- DMG-01 inbound: no hold, no second RECEIPT.
select pg_temp.as_user('keeper');
select set_config('sherlyos.dmg01', (
  public.create_damage_report(
    'refill_supply', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 1, 'damage_reason', 'wet',
      'receipt_line_id', current_setting('sherlyos.receipt_line')::uuid
    )),
    'm53-dmg01', null, current_setting('sherlyos.receipt')::uuid
  ) ->> 'id'
), true);
select public.submit_damage_report(current_setting('sherlyos.dmg01')::uuid, 1, 'm53-sub-01');
reset role;
do $$
begin
  if exists (select 1 from public.damage_stock_holds where damage_report_id = current_setting('sherlyos.dmg01')::uuid) then
    raise exception 'inbound damage must not create a hold';
  end if;
  if (select count(*) from public.stock_ledger where product_id = current_setting('sherlyos.product')::uuid)
     <> current_setting('sherlyos.ledger_before')::integer then
    raise exception 'inbound damage mutated ledger';
  end if;
end $$;
select pg_temp.as_user('godown');
set local role authenticated;

-- DMG-03 storage hold reduces availability without ledger write-off.
select pg_temp.as_user('godown');
select set_config('sherlyos.dmg03', (
  public.create_damage_report(
    'storage', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'crate_id', current_setting('sherlyos.crate')::uuid,
      'lot_id', current_setting('sherlyos.lot')::uuid,
      'quantity_cases', 2, 'damage_reason', 'rodent'
    )),
    'm53-dmg03'
  ) ->> 'id'
), true);
select public.submit_damage_report(current_setting('sherlyos.dmg03')::uuid, 1, 'm53-sub-03');

reset role;
do $$
declare
  on_hand integer;
  held integer;
  avail integer;
begin
  select quantity into on_hand from public.stock_lot_balances
  where lot_id = current_setting('sherlyos.lot')::uuid
    and crate_id = current_setting('sherlyos.crate')::uuid;
  select coalesce(sum(quantity_cases), 0) into held from public.damage_stock_holds
  where damage_report_id = current_setting('sherlyos.dmg03')::uuid and status = 'active';
  avail := app_private.picking_available_cases(
    current_setting('sherlyos.lot')::uuid, current_setting('sherlyos.crate')::uuid
  );
  if held <> 2 then raise exception 'storage hold missing'; end if;
  if avail <> on_hand - held - app_private.active_reserved_lot_cases(
    current_setting('sherlyos.lot')::uuid, current_setting('sherlyos.crate')::uuid
  ) then
    raise exception 'held + reserved + available must equal on-hand';
  end if;
  if (select count(*) from public.stock_ledger where product_id = current_setting('sherlyos.product')::uuid)
     <> current_setting('sherlyos.ledger_before')::integer then
    raise exception 'storage submit must not write ledger';
  end if;
end $$;

-- D1 self-verify denied; verifier GM may verify.
select pg_temp.as_user('godown');
set local role authenticated;
select pg_temp.attach_photo(current_setting('sherlyos.dmg03')::uuid);
do $$
begin
  perform public.verify_damage_report(current_setting('sherlyos.dmg03')::uuid, 2);
  raise exception 'self-verify must fail';
exception
  when insufficient_privilege then
    if sqlerrm not like '%reporter cannot verify%' then raise; end if;
end $$;

select pg_temp.as_user('verifier');
select pg_temp.attach_photo(current_setting('sherlyos.dmg03')::uuid);
select public.verify_damage_report(current_setting('sherlyos.dmg03')::uuid, 2);

select pg_temp.as_user('admin');
do $$
begin
  perform public.post_ordinary_damage_writeoff(
    current_setting('sherlyos.dmg03')::uuid, 3, 'm53-wo-admin'
  );
  raise exception 'admin ordinary write-off must fail';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('verifier');
select public.post_ordinary_damage_writeoff(
  current_setting('sherlyos.dmg03')::uuid, 3, 'm53-wo-gm'
);
select public.post_ordinary_damage_writeoff(
  current_setting('sherlyos.dmg03')::uuid, 3, 'm53-wo-gm-replay'
);
do $$
begin
  if (select count(*) from public.stock_transactions
      where damage_report_id = current_setting('sherlyos.dmg03')::uuid
        and damage_posting_kind = 'ordinary_writeoff') <> 1 then
    raise exception 'ordinary write-off must be exact-once';
  end if;
  if (
    select coalesce(sum(stock_ledger.quantity), 0)
    from public.stock_ledger
    join public.stock_transactions
      on stock_transactions.id = stock_ledger.transaction_id
    where stock_transactions.damage_report_id = current_setting('sherlyos.dmg03')::uuid
      and stock_transactions.damage_posting_kind = 'ordinary_writeoff'
  ) is distinct from (
    select - quantity from public.stock_transactions
    where damage_report_id = current_setting('sherlyos.dmg03')::uuid
      and damage_posting_kind = 'ordinary_writeoff'
  ) then
    raise exception 'ordinary write-off ledger must match header quantity';
  end if;
  if exists (
    select 1 from public.stock_balances
    where product_id = current_setting('sherlyos.product')::uuid and quantity < 0
  ) then
    raise exception 'negative balance after write-off';
  end if;
end $$;

-- DMG-06 shop-return custody + unavailable intake.
select pg_temp.as_user('godown');
select set_config('sherlyos.dmg06', (
  public.create_damage_report(
    'shop_return', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 1, 'damage_reason', 'expired'
    )),
    'm53-dmg06', null, null, null, null, null, current_setting('sherlyos.shop')::uuid
  ) ->> 'id'
), true);
do $$
begin
  perform public.submit_damage_report(current_setting('sherlyos.dmg06')::uuid, 1, 'm53-sub-06');
  raise exception 'shop-return submit without custody must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%physical custody%' then raise; end if;
end $$;
select public.confirm_shop_return_custody(current_setting('sherlyos.dmg06')::uuid, 1);
select public.submit_damage_report(current_setting('sherlyos.dmg06')::uuid, 2, 'm53-sub-06');
reset role;
do $$
declare
  q_crate uuid;
  q_qty integer;
begin
  select crate_id into q_crate from public.damage_stock_holds
  where damage_report_id = current_setting('sherlyos.dmg06')::uuid;
  if not app_private.crate_is_quarantine(q_crate) then
    raise exception 'shop-return must enter a quarantine crate';
  end if;
  select coalesce(sum(quantity), 0) into q_qty from public.stock_balances
  where crate_id = q_crate and product_id = current_setting('sherlyos.product')::uuid;
  if q_qty <> 1 then raise exception 'shop-return intake missing'; end if;
  if exists (
    select 1 from public.stock_lot_balances
    where crate_id = q_crate
      and app_private.picking_available_cases(lot_id, crate_id) > 0
  ) then
    raise exception 'quarantine stock must be unpickable';
  end if;
end $$;

select pg_temp.as_user('verifier');
set local role authenticated;
select pg_temp.attach_photo(current_setting('sherlyos.dmg06')::uuid);

-- Spoofing the stock-write GUC from an authenticated session must not
-- let ordinary crate transfer pull quarantine goods back to saleable stock.
select pg_temp.as_user('godown');
select set_config('app.damage_stock_write', 'on', true);
select set_config('app.quarantine_location_write', 'on', true);
do $$
declare
  q_crate uuid;
  q_lot uuid;
begin
  select crate_id, lot_id into q_crate, q_lot
  from public.damage_stock_holds
  where damage_report_id = current_setting('sherlyos.dmg06')::uuid;
  begin
    perform public.post_crate_transfer(
      current_setting('sherlyos.product')::uuid,
      q_crate,
      current_setting('sherlyos.crate')::uuid,
      1,
      'm53-guc-abuse',
      null,
      jsonb_build_array(jsonb_build_object('lot_id', q_lot, 'quantity', 1))
    );
    raise exception 'spoofed damage_stock_write must not move quarantine stock';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%quarantine%' then raise; end if;
    when insufficient_privilege then
      null;
  end;
end $$;

select pg_temp.as_user('verifier');
select public.reject_damage_report(current_setting('sherlyos.dmg06')::uuid, 3, 'not shop damage');
reset role;
do $$
begin
  if (select coalesce(sum(quantity), 0) from public.stock_balances
      where crate_id in (
        select crate_id from public.damage_stock_holds
        where damage_report_id = current_setting('sherlyos.dmg06')::uuid
      )
        and product_id = current_setting('sherlyos.product')::uuid) <> 1 then
    raise exception 'rejected shop-return must stay quarantined';
  end if;
end $$;

-- Authorized resolution: GM ordinary write-off of rejected shop-return
-- clears quarantine without restoring saleable stock.
select pg_temp.as_user('verifier');
set local role authenticated;
select public.post_ordinary_damage_writeoff(
  current_setting('sherlyos.dmg06')::uuid,
  (select version from public.damage_reports where id = current_setting('sherlyos.dmg06')::uuid),
  'm53-wo-shop'
);
reset role;
do $$
declare
  q_qty integer;
  saleable integer;
begin
  select coalesce(sum(quantity), 0) into q_qty
  from public.stock_balances
  where crate_id in (
    select crate_id from public.damage_stock_holds
    where damage_report_id = current_setting('sherlyos.dmg06')::uuid
  )
    and product_id = current_setting('sherlyos.product')::uuid;
  if q_qty <> 0 then
    raise exception 'rejected shop-return write-off must clear quarantine qty';
  end if;
  select coalesce(sum(sb.quantity), 0) into saleable
  from public.stock_balances sb
  join public.crates c on c.id = sb.crate_id
  where sb.product_id = current_setting('sherlyos.product')::uuid
    and c.location_role is distinct from 'quarantine';
  if saleable < 0 then
    raise exception 'negative saleable stock after shop-return write-off';
  end if;
  if (select count(*) from public.stock_transactions
      where damage_report_id = current_setting('sherlyos.dmg06')::uuid
        and damage_posting_kind = 'ordinary_writeoff') <> 1 then
    raise exception 'shop-return write-off must be exact-once';
  end if;
end $$;

-- Exceptional destroy on a second storage report.
select pg_temp.as_user('godown');
set local role authenticated;
select set_config('sherlyos.dmg03b', (
  public.create_damage_report(
    'storage', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'crate_id', current_setting('sherlyos.crate')::uuid,
      'lot_id', current_setting('sherlyos.lot')::uuid,
      'quantity_cases', 1, 'damage_reason', 'leak'
    )),
    'm53-dmg03b'
  ) ->> 'id'
), true);
select public.submit_damage_report(current_setting('sherlyos.dmg03b')::uuid, 1, 'm53-sub-03b');
select pg_temp.attach_photo(current_setting('sherlyos.dmg03b')::uuid);
select pg_temp.as_user('verifier');
select pg_temp.attach_photo(current_setting('sherlyos.dmg03b')::uuid);
select public.verify_damage_report(current_setting('sherlyos.dmg03b')::uuid, 2);
select set_config('sherlyos.exreq', (
  public.request_exceptional_damage_disposition(
    current_setting('sherlyos.dmg03b')::uuid, 3, 'destroy', 'destroy leaking oil', 'm53-ex-req'
  ) -> 'exceptional_requests' -> 0 ->> 'id'
), true);

select pg_temp.as_user('godown');
do $$
begin
  perform public.approve_exceptional_damage_disposition(current_setting('sherlyos.exreq')::uuid, 1);
  raise exception 'GM must not approve exceptional disposition';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('admin');
select public.approve_exceptional_damage_disposition(current_setting('sherlyos.exreq')::uuid, 1);
do $$
begin
  perform public.post_exceptional_damage_disposition(
    current_setting('sherlyos.exreq')::uuid, 2, 'm53-ex-post'
  );
  raise exception 'admin must not post exceptional stock';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('verifier');
select public.post_exceptional_damage_disposition(
  current_setting('sherlyos.exreq')::uuid, 2, 'm53-ex-post'
);

-- Loading conversion vs remaining dispatch.
select pg_temp.as_user('accounts');
select set_config('sherlyos.order_load', (
  public.create_order(
    current_setting('sherlyos.shop')::uuid,
    current_setting('sherlyos.branch')::uuid,
    'accounts', null, null,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 2
    )),
    'm53-order-load'
  ) -> 'order' ->> 'id'
), true);
select public.submit_order(current_setting('sherlyos.order_load')::uuid, 1, 'm53-sub-load');
select public.verify_order(current_setting('sherlyos.order_load')::uuid, 2, 'm53-ver-load');

select pg_temp.as_user('godown');
do $$
declare
  reserved jsonb;
  header jsonb;
  res jsonb;
  prepared jsonb;
begin
  reserved := public.reserve_order_allocation(
    current_setting('sherlyos.order_load')::uuid, 3, 'm53-res-load'
  );
  reserved := public.assign_picking_request(
    (reserved ->> 'id')::uuid, (select id from fixture where name = 'keeper'),
    (reserved ->> 'version')::integer, 'm53-asg-load'
  );
  reserved := public.start_picking(
    (reserved ->> 'id')::uuid, (reserved ->> 'version')::integer, 'm53-start-load'
  );
  perform pg_temp.as_user('keeper');
  header := public.get_picking_request((reserved ->> 'id')::uuid);
  res := header -> 'reservations' -> 0;
  header := public.confirm_picking_quantity(
    (reserved ->> 'id')::uuid, (res ->> 'id')::uuid,
    (res ->> 'reserved_cases')::integer, (header ->> 'version')::integer, 'm53-pick-load'
  );
  header := public.complete_picking(
    (reserved ->> 'id')::uuid, (header ->> 'version')::integer, 'm53-cmp-load'
  );
  perform pg_temp.as_user('godown');
  header := public.confirm_picking_handoff(
    (reserved ->> 'id')::uuid, (header ->> 'version')::integer, 'm53-hand-load'
  );
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_load')::uuid, (header ->> 'version')::integer, 'm53-prep-load'
  );
  perform set_config('sherlyos.picking_load', reserved ->> 'id', true);
  perform set_config('sherlyos.dispatch_load', prepared ->> 'id', true);
end $$;

select set_config('sherlyos.dmg04', (
  public.create_damage_report(
    'loading', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'crate_id', current_setting('sherlyos.crate')::uuid,
      'quantity_cases', 1, 'damage_reason', 'crush'
    )),
    'm53-dmg04', null, null, current_setting('sherlyos.picking_load')::uuid,
    current_setting('sherlyos.dispatch_load')::uuid
  ) ->> 'id'
), true);
select public.submit_damage_report(current_setting('sherlyos.dmg04')::uuid, 1, 'm53-sub-04');
select public.confirm_dispatch(current_setting('sherlyos.dispatch_load')::uuid, 1, 'm53-cfm-load');
reset role;
do $$
begin
  if (select reserved_cases from public.stock_reservations
      where picking_request_id = current_setting('sherlyos.picking_load')::uuid
        and status = 'consumed') is distinct from 1 then
    raise exception 'confirm_dispatch must consume only remaining reservations';
  end if;
  if (select count(*) from public.stock_transactions
      where dispatch_request_id = current_setting('sherlyos.dispatch_load')::uuid) <> 1 then
    raise exception 'loading damage must not create a second DISPATCH';
  end if;
end $$;

-- Transit: no second DISPATCH. Reuse remaining opening stock via another order.
select pg_temp.as_user('accounts');
set local role authenticated;
select set_config('sherlyos.order_tr', (
  public.create_order(
    current_setting('sherlyos.shop')::uuid,
    current_setting('sherlyos.branch')::uuid,
    'accounts', null, null,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1
    )),
    'm53-order-tr'
  ) -> 'order' ->> 'id'
), true);
select public.submit_order(current_setting('sherlyos.order_tr')::uuid, 1, 'm53-sub-tr');
select public.verify_order(current_setting('sherlyos.order_tr')::uuid, 2, 'm53-ver-tr');
select pg_temp.as_user('godown');
do $$
declare
  reserved jsonb;
  header jsonb;
  res jsonb;
  prepared jsonb;
  confirmed jsonb;
begin
  reserved := public.reserve_order_allocation(current_setting('sherlyos.order_tr')::uuid, 3, 'm53-res-tr');
  reserved := public.assign_picking_request(
    (reserved ->> 'id')::uuid, (select id from fixture where name = 'keeper'),
    (reserved ->> 'version')::integer, 'm53-asg-tr');
  reserved := public.start_picking((reserved ->> 'id')::uuid, (reserved ->> 'version')::integer, 'm53-start-tr');
  perform pg_temp.as_user('keeper');
  header := public.get_picking_request((reserved ->> 'id')::uuid);
  res := header -> 'reservations' -> 0;
  header := public.confirm_picking_quantity(
    (reserved ->> 'id')::uuid, (res ->> 'id')::uuid,
    (res ->> 'reserved_cases')::integer, (header ->> 'version')::integer, 'm53-pick-tr');
  header := public.complete_picking((reserved ->> 'id')::uuid, (header ->> 'version')::integer, 'm53-cmp-tr');
  perform pg_temp.as_user('godown');
  header := public.confirm_picking_handoff((reserved ->> 'id')::uuid, (header ->> 'version')::integer, 'm53-hand-tr');
  prepared := public.prepare_dispatch(current_setting('sherlyos.order_tr')::uuid, (header ->> 'version')::integer, 'm53-prep-tr');
  confirmed := public.confirm_dispatch((prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm53-cfm-tr');
  confirmed := public.assign_dispatch_delivery(
    (confirmed ->> 'id')::uuid, (select id from fixture where name = 'driver'),
    (confirmed ->> 'version')::integer, 'm53-assign-tr');
  perform set_config('sherlyos.dispatch_tr', confirmed ->> 'id', true);
end $$;
select pg_temp.as_user('driver');
select set_config('sherlyos.dmg05', (
  public.create_damage_report(
    'transit', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 1, 'damage_reason', 'road'
    )),
    'm53-dmg05', null, null, null, current_setting('sherlyos.dispatch_tr')::uuid
  ) ->> 'id'
), true);
select public.submit_damage_report(current_setting('sherlyos.dmg05')::uuid, 1, 'm53-sub-05');
reset role;
do $$
begin
  if exists (select 1 from public.damage_stock_holds where damage_report_id = current_setting('sherlyos.dmg05')::uuid) then
    raise exception 'transit must not create a hold';
  end if;
  if (select count(*) from public.stock_transactions
      where dispatch_request_id = current_setting('sherlyos.dispatch_tr')::uuid) <> 1 then
    raise exception 'transit must not create a second DISPATCH';
  end if;
end $$;

-- Inactive godown and direct DML.
select pg_temp.as_user('admin');
set local role authenticated;
select public.set_branch_active(current_setting('sherlyos.branch')::uuid, false);
select pg_temp.as_user('godown');
do $$
begin
  perform public.create_damage_report(
    'storage', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'crate_id', current_setting('sherlyos.crate')::uuid,
      'lot_id', current_setting('sherlyos.lot')::uuid,
      'quantity_cases', 1, 'damage_reason', 'rodent'
    )),
    'm53-inactive'
  );
  raise exception 'inactive storage create must fail';
exception
  when sqlstate '23514' then null;
  when insufficient_privilege then null;
end $$;

reset role;
select set_config('app.damage_write', '', true);
select set_config('app.damage_stock_write', '', true);
do $$
begin
  insert into public.damage_stock_holds (
    damage_report_id, damage_report_line_id, product_id, crate_id,
    quantity_cases, hold_kind, status
  )
  select damage_reports.id, damage_report_lines.id,
    current_setting('sherlyos.product')::uuid, current_setting('sherlyos.crate')::uuid,
    1, 'on_hand_deduction', 'active'
  from public.damage_reports
  join public.damage_report_lines
    on damage_report_lines.damage_report_id = damage_reports.id
  limit 1;
  raise exception 'direct hold insert must fail';
exception
  when insufficient_privilege then null;
  when sqlstate '42501' then null;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_class
    join pg_namespace on pg_namespace.oid = pg_class.relnamespace
    where pg_namespace.nspname = 'public'
      and pg_class.relname = 'damage_stock_holds'
      and pg_class.relforcerowsecurity
  ) then
    raise exception 'damage_stock_holds must FORCE RLS';
  end if;
end $$;

rollback;
