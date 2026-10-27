-- M5.2 local disposable SQL. Rolls back. Does not touch development cloud.
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
  ('keeper', gen_random_uuid()),
  ('driver', gen_random_uuid()),
  ('driver2', gen_random_uuid()),
  ('sales', gen_random_uuid()),
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
  fixture.name || '.m52sql@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture;

do $$
begin
  begin
    perform app_private.bootstrap_initial_admin(
      (select id from fixture where name = 'admin'),
      'create-initial-administrator'
    );
  exception
    when sqlstate '42501' then
      insert into public.profiles (id, full_name, is_active)
      values ((select id from fixture where name = 'admin'), 'M52 Admin', true)
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
  when 'keeper' then 'store_keeper'
  when 'driver' then 'delivery_person'
  when 'driver2' then 'delivery_person'
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

create or replace function pg_temp.handshake_dn(p_order uuid, p_prefix text)
returns uuid
language plpgsql as $$
declare
  note_id uuid;
  payload jsonb;
  note_status text;
  note_version integer;
begin
  -- Reuse an open note so draft paperwork created earlier can still be acked.
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

select set_config(
  'sherlyos.branch',
  public.create_branch('m52sql_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10), 'M52SQL A')::text,
  true
);
select set_config(
  'sherlyos.branch_b',
  public.create_branch('m52sql_b_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8), 'M52SQL B')::text,
  true
);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'driver'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'driver2'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'sales'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'other'), current_setting('sherlyos.branch_b')::uuid);

select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'z1', 'Z1', null)::text, true);
select set_config('sherlyos.crate', public.create_crate(current_setting('sherlyos.zone')::uuid, 'ca', 'CA', null)::text, true);
select set_config('sherlyos.zone_b', public.create_zone(current_setting('sherlyos.branch_b')::uuid, 'zb', 'ZB', null)::text, true);
select set_config('sherlyos.crate_b', public.create_crate(current_setting('sherlyos.zone_b')::uuid, 'cb', 'CB', null)::text, true);
select set_config('sherlyos.product', public.create_product('m52-soap', 'M52 Soap', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.product')::uuid, 'expiry_controlled');
select set_config('sherlyos.shop', public.create_shop('M52 shop', null, null)::text, true);
select set_config('sherlyos.supplier', public.create_supplier('M52 supplier', null, null)::text, true);

reset role;
-- Leftover local aggregate grains (m1s2qa Playwright rows without lots) fail the
-- cutover validator. Skip that statement trigger inside this rolled-back transaction.
set session_replication_role = replica;
update public.app_configuration set value = 'true'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
set session_replication_role = origin;

select pg_temp.as_user('admin');
set local role authenticated;

select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate')::uuid,
  12, 'm52-open-a', null, 'M52-A', null, '2028-06-01'
);

-- Posted receipt with damaged cases excluded from accepted stock (DMG-01/02 source).
select pg_temp.as_user('keeper');
select set_config(
  'sherlyos.receipt',
  (
    public.create_stock_receipt(
      current_setting('sherlyos.branch')::uuid,
      current_setting('sherlyos.supplier')::uuid,
      'M52-INV-1',
      current_date,
      null,
      jsonb_build_array(jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'destination_crate_id', current_setting('sherlyos.crate')::uuid,
        'document_cases', 10,
        'counted_cases', 8,
        'damaged_cases', 4
      ))
    ) ->> 'id'
  ),
  true
);
select set_config(
  'sherlyos.receipt_line',
  (
    select stock_receipt_lines.id::text
    from public.stock_receipt_lines
    where stock_receipt_lines.receipt_id = current_setting('sherlyos.receipt')::uuid
  ),
  true
);
select public.set_stock_receipt_line_lot_attributions(
  current_setting('sherlyos.receipt_line')::uuid,
  jsonb_build_array(jsonb_build_object(
    'carton_quantity', 4,
    'manufacturer_lot_code', 'M52-R1',
    'manufactured_on', current_date - 5,
    'expiry_date', current_date + 180
  ))
);
select public.submit_stock_receipt(current_setting('sherlyos.receipt')::uuid);
select pg_temp.as_user('godown');
select public.verify_stock_receipt(current_setting('sherlyos.receipt')::uuid, 'm52-recv-1');

select pg_temp.as_user('keeper');
select set_config(
  'sherlyos.receipt2',
  (
    public.create_stock_receipt(
      current_setting('sherlyos.branch')::uuid,
      current_setting('sherlyos.supplier')::uuid,
      'M52-INV-2',
      current_date,
      null,
      jsonb_build_array(jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'destination_crate_id', current_setting('sherlyos.crate')::uuid,
        'document_cases', 5,
        'counted_cases', 3,
        'damaged_cases', 2
      ))
    ) ->> 'id'
  ),
  true
);
select set_config(
  'sherlyos.receipt_line2',
  (
    select stock_receipt_lines.id::text
    from public.stock_receipt_lines
    where stock_receipt_lines.receipt_id = current_setting('sherlyos.receipt2')::uuid
  ),
  true
);
select public.set_stock_receipt_line_lot_attributions(
  current_setting('sherlyos.receipt_line2')::uuid,
  jsonb_build_array(jsonb_build_object(
    'carton_quantity', 1,
    'manufacturer_lot_code', 'M52-R2',
    'manufactured_on', current_date - 4,
    'expiry_date', current_date + 180
  ))
);
select public.submit_stock_receipt(current_setting('sherlyos.receipt2')::uuid);
select pg_temp.as_user('godown');
select public.verify_stock_receipt(current_setting('sherlyos.receipt2')::uuid, 'm52-recv-2');

-- Consumed dispatch for DMG-05.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_live',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm52-order-live'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_live')::uuid, 1, 'm52-sub-live');
select public.verify_order(current_setting('sherlyos.order_live')::uuid, 2, 'm52-ver-live');
select pg_temp.handshake_dn(current_setting('sherlyos.order_live')::uuid, 'm52-hlive');

select pg_temp.as_user('godown');
do $$
declare
  reserved jsonb;
  header jsonb;
  res jsonb;
  prepared jsonb;
  confirmed jsonb;
begin
  reserved := public.reserve_order_allocation(
    current_setting('sherlyos.order_live')::uuid, 3, 'm52-res-live'
  );
  reserved := public.assign_picking_request(
    (reserved ->> 'id')::uuid,
    (select id from fixture where name = 'keeper'),
    (reserved ->> 'version')::integer,
    'm52-asg-live'
  );
  reserved := public.start_picking(
    (reserved ->> 'id')::uuid, (reserved ->> 'version')::integer, 'm52-start-live'
  );
  perform pg_temp.as_user('keeper');
  header := public.get_picking_request((reserved ->> 'id')::uuid);
  res := header -> 'reservations' -> 0;
  header := public.confirm_picking_quantity(
    (reserved ->> 'id')::uuid,
    (res ->> 'id')::uuid,
    (res ->> 'reserved_cases')::integer,
    (header ->> 'version')::integer,
    'm52-pick-live'
  );
  header := public.complete_picking(
    (reserved ->> 'id')::uuid, (header ->> 'version')::integer, 'm52-cmp-live'
  );
  perform pg_temp.as_user('godown');
  header := public.confirm_picking_handoff(
    (reserved ->> 'id')::uuid, (header ->> 'version')::integer, 'm52-hand-live'
  );
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_live')::uuid,
    (header ->> 'version')::integer,
    'm52-prep-live'
  );
  confirmed := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm52-cfm-live'
  );
  perform set_config('sherlyos.dispatch_live', confirmed ->> 'id', true);
  perform set_config('sherlyos.dispatch_live_version', confirmed ->> 'version', true);
end $$;

select public.assign_dispatch_delivery(
  current_setting('sherlyos.dispatch_live')::uuid,
  (select id from fixture where name = 'driver'),
  current_setting('sherlyos.dispatch_live_version')::integer,
  'm52-assign-live'
);

-- Preparing dispatch for DMG-04.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_load',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm52-order-load'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_load')::uuid, 1, 'm52-sub-load');
select public.verify_order(current_setting('sherlyos.order_load')::uuid, 2, 'm52-ver-load');
select pg_temp.handshake_dn(current_setting('sherlyos.order_load')::uuid, 'm52-hload');

select pg_temp.as_user('godown');
do $$
declare
  reserved jsonb;
  header jsonb;
  res jsonb;
  prepared jsonb;
begin
  reserved := public.reserve_order_allocation(
    current_setting('sherlyos.order_load')::uuid, 3, 'm52-res-load'
  );
  perform set_config('sherlyos.picking_load', reserved ->> 'id', true);
  reserved := public.assign_picking_request(
    (reserved ->> 'id')::uuid,
    (select id from fixture where name = 'keeper'),
    (reserved ->> 'version')::integer,
    'm52-asg-load'
  );
  reserved := public.start_picking(
    (reserved ->> 'id')::uuid, (reserved ->> 'version')::integer, 'm52-start-load'
  );
  perform pg_temp.as_user('keeper');
  header := public.get_picking_request((reserved ->> 'id')::uuid);
  res := header -> 'reservations' -> 0;
  header := public.confirm_picking_quantity(
    (reserved ->> 'id')::uuid,
    (res ->> 'id')::uuid,
    (res ->> 'reserved_cases')::integer,
    (header ->> 'version')::integer,
    'm52-pick-load'
  );
  header := public.complete_picking(
    (reserved ->> 'id')::uuid, (header ->> 'version')::integer, 'm52-cmp-load'
  );
  perform pg_temp.as_user('godown');
  header := public.confirm_picking_handoff(
    (reserved ->> 'id')::uuid, (header ->> 'version')::integer, 'm52-hand-load'
  );
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_load')::uuid,
    (header ->> 'version')::integer,
    'm52-prep-load'
  );
  perform set_config('sherlyos.dispatch_prep', prepared ->> 'id', true);
end $$;

select set_config(
  'sherlyos.ledger_before',
  (select count(*)::text from public.stock_ledger where product_id = current_setting('sherlyos.product')::uuid),
  true
);
select set_config(
  'sherlyos.txn_before',
  (select count(*)::text from public.stock_transactions where product_id = current_setting('sherlyos.product')::uuid),
  true
);
select set_config(
  'sherlyos.bal_before',
  (
    select coalesce(sum(quantity), 0)::text
    from public.stock_balances
    where product_id = current_setting('sherlyos.product')::uuid
  ),
  true
);
select set_config(
  'sherlyos.res_before',
  (
    select count(*)::text from public.stock_reservations
    where product_id = current_setting('sherlyos.product')::uuid
  ),
  true
);

-- Role denials.
select pg_temp.as_user('admin');
do $$
begin
  perform public.create_damage_report(
    'refill_supply', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 1, 'damage_reason', 'crushed',
      'receipt_line_id', current_setting('sherlyos.receipt_line')::uuid
    )),
    'm52-admin-create', null, current_setting('sherlyos.receipt')::uuid
  );
  raise exception 'admin ordinary create must fail';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('accounts');
do $$
begin
  perform public.create_damage_report(
    'refill_supply', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 1, 'damage_reason', 'crushed',
      'receipt_line_id', current_setting('sherlyos.receipt_line')::uuid
    )),
    'm52-acc-create', null, current_setting('sherlyos.receipt')::uuid
  );
  raise exception 'accounts create must fail';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('sales');
do $$
begin
  perform public.create_damage_report(
    'shop_return', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 1, 'damage_reason', 'expired'
    )),
    'm52-sales-create', null, null, null, null, null, current_setting('sherlyos.shop')::uuid
  );
  raise exception 'salesperson create must fail';
exception
  when insufficient_privilege then null;
end $$;

-- Zero / negative quantity.
select pg_temp.as_user('keeper');
do $$
begin
  perform public.create_damage_report(
    'refill_supply', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 0, 'damage_reason', 'crushed',
      'receipt_line_id', current_setting('sherlyos.receipt_line')::uuid
    )),
    'm52-zero-qty', null, current_setting('sherlyos.receipt')::uuid
  );
  raise exception 'zero quantity must fail';
exception
  when check_violation then null;
  when sqlstate '23514' then null;
end $$;

do $$
begin
  perform public.create_damage_report(
    'refill_supply', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', -1, 'damage_reason', 'crushed',
      'receipt_line_id', current_setting('sherlyos.receipt_line')::uuid
    )),
    'm52-neg-qty', null, current_setting('sherlyos.receipt')::uuid
  );
  raise exception 'negative quantity must fail';
exception
  when check_violation then null;
  when sqlstate '23514' then null;
end $$;

-- DMG-01 create, idempotent replay, different-body key, partial qty, exceed qty.
select set_config(
  'sherlyos.dmg01',
  (
    public.create_damage_report(
      'refill_supply', current_setting('sherlyos.branch')::uuid,
      jsonb_build_array(jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'quantity_cases', 2, 'damage_reason', 'crushed',
        'receipt_line_id', current_setting('sherlyos.receipt_line')::uuid
      )),
      'm52-dmg01', null, current_setting('sherlyos.receipt')::uuid
    ) ->> 'id'
  ),
  true
);

do $$
declare
  first_id uuid := current_setting('sherlyos.dmg01')::uuid;
  replay jsonb;
begin
  replay := public.create_damage_report(
    'refill_supply', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 2, 'damage_reason', 'crushed',
      'receipt_line_id', current_setting('sherlyos.receipt_line')::uuid
    )),
    'm52-dmg01', null, current_setting('sherlyos.receipt')::uuid
  );
  if (replay ->> 'id')::uuid is distinct from first_id then
    raise exception 'idempotent create must replay the same report';
  end if;
end $$;

do $$
begin
  perform public.create_damage_report(
    'refill_supply', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 1, 'damage_reason', 'crushed',
      'receipt_line_id', current_setting('sherlyos.receipt_line')::uuid
    )),
    'm52-dmg01', null, current_setting('sherlyos.receipt')::uuid
  );
  raise exception 'conflicting idempotency key must fail';
exception
  when unique_violation then null;
  when sqlstate '23505' then null;
end $$;

select public.submit_damage_report(current_setting('sherlyos.dmg01')::uuid, 1, 'm52-sub-01');

select pg_temp.as_user('keeper');
do $$
begin
  perform public.verify_damage_report(current_setting('sherlyos.dmg01')::uuid, 2);
  raise exception 'store keeper must not verify';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('godown');
do $$
begin
  perform public.verify_damage_report(current_setting('sherlyos.dmg01')::uuid, 2);
  raise exception 'verify without evidence must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%photographic evidence%' then
      raise;
    end if;
end $$;

select pg_temp.attach_photo(current_setting('sherlyos.dmg01')::uuid);
select public.verify_damage_report(current_setting('sherlyos.dmg01')::uuid, 2);

do $$
begin
  if (public.get_damage_report(current_setting('sherlyos.dmg01')::uuid) ->> 'status')
    is distinct from 'verified'
  then
    raise exception 'DMG-01 verify failed';
  end if;
end $$;

select pg_temp.as_user('keeper');
do $$
begin
  perform public.update_damage_report(
    current_setting('sherlyos.dmg01')::uuid, 3,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 2, 'damage_reason', 'crushed',
      'receipt_line_id', current_setting('sherlyos.receipt_line')::uuid
    ))
  );
  raise exception 'verified report must be immutable';
exception
  when insufficient_privilege then null;
end $$;

-- Remaining 2 of 4 damaged cases.
select set_config(
  'sherlyos.dmg01b',
  (
    public.create_damage_report(
      'refill_supply', current_setting('sherlyos.branch')::uuid,
      jsonb_build_array(jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'quantity_cases', 2, 'damage_reason', 'wet',
        'receipt_line_id', current_setting('sherlyos.receipt_line')::uuid
      )),
      'm52-dmg01b', null, current_setting('sherlyos.receipt')::uuid
    ) ->> 'id'
  ),
  true
);

do $$
begin
  perform public.create_damage_report(
    'refill_supply', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 1, 'damage_reason', 'wet',
      'receipt_line_id', current_setting('sherlyos.receipt_line')::uuid
    )),
    'm52-dmg01-over', null, current_setting('sherlyos.receipt')::uuid
  );
  raise exception 'quantity over receipt damaged_cases must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%exceeds the receipt line%' then
      raise;
    end if;
end $$;

-- DMG-02 unloading.
select set_config(
  'sherlyos.dmg02',
  (
    public.create_damage_report(
      'unloading', current_setting('sherlyos.branch')::uuid,
      jsonb_build_array(jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'quantity_cases', 2, 'damage_reason', 'dropped',
        'receipt_line_id', current_setting('sherlyos.receipt_line2')::uuid
      )),
      'm52-dmg02', null, current_setting('sherlyos.receipt2')::uuid
    ) ->> 'id'
  ),
  true
);
select public.submit_damage_report(current_setting('sherlyos.dmg02')::uuid, 1, 'm52-sub-02');

-- Cross-branch inbound denied.
select pg_temp.as_user('other');
do $$
begin
  perform public.create_damage_report(
    'unloading', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 1, 'damage_reason', 'dropped',
      'receipt_line_id', current_setting('sherlyos.receipt_line2')::uuid
    )),
    'm52-cross-in', null, current_setting('sherlyos.receipt2')::uuid
  );
  raise exception 'cross-branch inbound must fail';
exception
  when insufficient_privilege then null;
end $$;

-- DMG-03 storage draft allowed; submit blocked by hold gate.
select pg_temp.as_user('godown');
select set_config(
  'sherlyos.dmg03',
  (
    public.create_damage_report(
      'storage', current_setting('sherlyos.branch')::uuid,
      jsonb_build_array(jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'crate_id', current_setting('sherlyos.crate')::uuid,
        'quantity_cases', 1, 'damage_reason', 'rodent'
      )),
      'm52-dmg03'
    ) ->> 'id'
  ),
  true
);
do $$
begin
  perform public.submit_damage_report(current_setting('sherlyos.dmg03')::uuid, 1, 'm52-sub-03');
  raise exception 'storage submit must stay gated';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%stock isolation is not ready%' then
      raise;
    end if;
end $$;

select pg_temp.as_user('keeper');
do $$
begin
  perform public.create_damage_report(
    'storage', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'crate_id', current_setting('sherlyos.crate')::uuid,
      'quantity_cases', 1, 'damage_reason', 'rodent'
    )),
    'm52-sk-storage'
  );
  raise exception 'store keeper storage create must fail';
exception
  when insufficient_privilege then null;
end $$;

-- DMG-04 loading: source required, consumed dispatch rejected, submit gated.
select pg_temp.as_user('godown');
do $$
begin
  perform public.create_damage_report(
    'loading', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'crate_id', current_setting('sherlyos.crate')::uuid,
      'quantity_cases', 1, 'damage_reason', 'crushed'
    )),
    'm52-load-none'
  );
  raise exception 'loading without source must fail';
exception
  when sqlstate '23514' then null;
end $$;

do $$
begin
  perform public.create_damage_report(
    'loading', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'crate_id', current_setting('sherlyos.crate')::uuid,
      'quantity_cases', 1, 'damage_reason', 'crushed'
    )),
    'm52-load-consumed', null, null, null, current_setting('sherlyos.dispatch_live')::uuid
  );
  raise exception 'consumed dispatch loading must fail';
exception
  when sqlstate '23514' then null;
end $$;

select set_config(
  'sherlyos.dmg04',
  (
    public.create_damage_report(
      'loading', current_setting('sherlyos.branch')::uuid,
      jsonb_build_array(jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'crate_id', current_setting('sherlyos.crate')::uuid,
        'quantity_cases', 1, 'damage_reason', 'forklift'
      )),
      'm52-dmg04',
      null, null, current_setting('sherlyos.picking_load')::uuid,
      current_setting('sherlyos.dispatch_prep')::uuid
    ) ->> 'id'
  ),
  true
);
do $$
begin
  perform public.submit_damage_report(current_setting('sherlyos.dmg04')::uuid, 1, 'm52-sub-04');
  raise exception 'loading submit must stay gated';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%stock isolation is not ready%' then
      raise;
    end if;
end $$;

-- DMG-05 assigned driver vs unassigned vs cross-branch.
select pg_temp.as_user('driver');
select set_config(
  'sherlyos.dmg05',
  (
    public.create_damage_report(
      'transit', current_setting('sherlyos.branch')::uuid,
      jsonb_build_array(jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'quantity_cases', 1, 'damage_reason', 'road'
      )),
      'm52-dmg05', null, null, null, current_setting('sherlyos.dispatch_live')::uuid
    ) ->> 'id'
  ),
  true
);
select public.submit_damage_report(current_setting('sherlyos.dmg05')::uuid, 1, 'm52-sub-05');

select pg_temp.as_user('driver2');
do $$
begin
  perform public.create_damage_report(
    'transit', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 1, 'damage_reason', 'road'
    )),
    'm52-unassigned', null, null, null, current_setting('sherlyos.dispatch_live')::uuid
  );
  raise exception 'unassigned driver must fail';
exception
  when insufficient_privilege then null;
  when unique_violation then
    raise exception 'unassigned driver must not reach duplicate detection';
end $$;

select pg_temp.as_user('other');
do $$
begin
  perform public.create_damage_report(
    'transit', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 1, 'damage_reason', 'road'
    )),
    'm52-cross-tr', null, null, null, current_setting('sherlyos.dispatch_live')::uuid
  );
  raise exception 'cross-branch transit must fail';
exception
  when insufficient_privilege then null;
end $$;

-- Duplicate open transit source.
select pg_temp.as_user('godown');
do $$
begin
  perform public.create_damage_report(
    'transit', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'quantity_cases', 1, 'damage_reason', 'road'
    )),
    'm52-dup-tr', null, null, null, current_setting('sherlyos.dispatch_live')::uuid
  );
  raise exception 'duplicate transit source must fail';
exception
  when unique_violation then null;
end $$;

-- Stale version on the remaining inbound draft.
select pg_temp.as_user('keeper');
select public.submit_damage_report(current_setting('sherlyos.dmg01b')::uuid, 1, 'm52-sub-01b');
do $$
begin
  perform public.submit_damage_report(current_setting('sherlyos.dmg01b')::uuid, 1, 'm52-sub-01b-stale');
  raise exception 'stale version must fail';
exception
  when sqlstate 'PT409' then null;
end $$;

-- DMG-06 shop return: create allowed, submit gated, crate in other godown denied.
select pg_temp.as_user('godown');
select set_config(
  'sherlyos.dmg06',
  (
    public.create_damage_report(
      'shop_return', current_setting('sherlyos.branch')::uuid,
      jsonb_build_array(jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'quantity_cases', 1, 'damage_reason', 'expired'
      )),
      'm52-dmg06', null, null, null, null, null, current_setting('sherlyos.shop')::uuid
    ) ->> 'id'
  ),
  true
);
do $$
begin
  perform public.submit_damage_report(current_setting('sherlyos.dmg06')::uuid, 1, 'm52-sub-06');
  raise exception 'shop-return submit must stay gated';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%stock isolation is not ready%' then
      raise;
    end if;
end $$;

do $$
begin
  perform public.create_damage_report(
    'shop_return', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'crate_id', current_setting('sherlyos.crate_b')::uuid,
      'quantity_cases', 1, 'damage_reason', 'expired'
    )),
    'm52-shop-crate-b', null, null, null, null, null, current_setting('sherlyos.shop')::uuid
  );
  raise exception 'foreign crate shop return must fail';
exception
  when sqlstate '23514' then null;
end $$;

-- Spoofed Storage catalog metadata cannot finalize evidence.
select pg_temp.as_user('godown');
do $$
declare
  created jsonb;
  payload bytea := decode('ffd8ffd9', 'hex');
begin
  created := public.create_damage_photo_upload(
    current_setting('sherlyos.dmg03')::uuid, 'spoofed catalog'
  );
  insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
  values (
    'stock-damage-evidence',
    created ->> 'path',
    auth.uid(),
    auth.uid()::text,
    jsonb_build_object('size', 999, 'mimetype', 'image/png', 'eTag', 'deadbeef')
  );
  begin
    perform public.finalize_damage_photo_upload(
      (created ->> 'id')::uuid, encode(payload, 'base64')
    );
    raise exception 'spoofed storage catalog must not finalize';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%could not be verified%' then
        raise;
      end if;
  end;
end $$;

-- Authenticated clients cannot DML the hold flag.
do $$
begin
  update public.app_configuration
  set value = 'true'::jsonb
  where key = 'damage.stock_hold_ready';
  raise exception 'authenticated hold-flag write must fail';
exception
  when insufficient_privilege then null;
end $$;

-- Isolation is installed, so the flag may be enabled. M5.2 submit still
-- fail-closes while the flag is false; restore immediately.
reset role;
update public.app_configuration
set value = 'true'::jsonb
where key = 'damage.stock_hold_ready';
update public.app_configuration
set value = 'false'::jsonb
where key = 'damage.stock_hold_ready';

set local role authenticated;
select pg_temp.as_user('godown');
do $$
begin
  perform public.submit_damage_report(
    current_setting('sherlyos.dmg03')::uuid, 1, 'm52-sub-03-flag'
  );
  raise exception 'storage submit must stay gated while the hold flag is false';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%stock isolation is not ready%' then
      raise;
    end if;
end $$;

reset role;

do $$
begin
  if has_function_privilege(
    'authenticated',
    'app_private.apply_damage_stock_isolation(uuid)',
    'execute'
  ) then
    raise exception 'apply_damage_stock_isolation must stay private';
  end if;
  if has_function_privilege(
    'authenticated',
    'app_private.damage_stock_isolation_installed()',
    'execute'
  ) then
    raise exception 'damage_stock_isolation_installed must stay private';
  end if;
end $$;

set local role authenticated;

-- Inactive godown blocks new operational writes except consumed transit.
select pg_temp.as_user('admin');
select public.set_branch_active(current_setting('sherlyos.branch')::uuid, false);
select pg_temp.as_user('godown');
do $$
begin
  perform public.create_damage_report(
    'storage', current_setting('sherlyos.branch')::uuid,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'crate_id', current_setting('sherlyos.crate')::uuid,
      'quantity_cases', 1, 'damage_reason', 'rodent'
    )),
    'm52-inactive-storage'
  );
  raise exception 'inactive storage create must fail';
exception
  when insufficient_privilege then null;
  when sqlstate '23514' then
    if sqlerrm not like '%inactive%' then
      raise;
    end if;
end $$;

select pg_temp.as_user('admin');
select public.set_branch_active(current_setting('sherlyos.branch')::uuid, true);

-- Historical admin read and driver self-read.
select pg_temp.as_user('admin');
do $$
declare
  listed jsonb;
begin
  listed := public.list_damage_reports(1, 50, current_setting('sherlyos.branch')::uuid);
  if coalesce(listed ->> 'total', '0')::integer < 1 then
    raise exception 'admin historical list must include damage reports';
  end if;
end $$;

select pg_temp.as_user('driver');
do $$
declare
  payload jsonb;
begin
  payload := public.get_damage_report(current_setting('sherlyos.dmg05')::uuid);
  if payload ->> 'scenario' is distinct from 'transit' then
    raise exception 'assigned driver must read own transit report';
  end if;
end $$;

select pg_temp.as_user('driver2');
do $$
begin
  perform public.get_damage_report(current_setting('sherlyos.dmg05')::uuid);
  raise exception 'unassigned driver must not read another transit report';
exception
  when insufficient_privilege then null;
end $$;

-- FORCE RLS, no direct DML, private helper denial.
reset role;
set local role authenticated;
select pg_temp.as_user('sales');
do $$
declare
  visible integer;
begin
  select count(*) into visible from public.damage_reports;
  if visible <> 0 then
    raise exception 'salesperson must not see damage rows through RLS: %', visible;
  end if;
end $$;

do $$
begin
  insert into public.damage_reports (
    report_number, scenario, godown_id, reporter_user_id, idempotency_key, request_fingerprint
  ) values (
    'DMG-FAKE', 'storage', current_setting('sherlyos.branch')::uuid,
    (select id from fixture where name = 'sales'), 'm52-direct-dml', 'x'
  );
  raise exception 'direct authenticated insert must fail';
exception
  when insufficient_privilege then null;
end $$;

do $$
begin
  perform app_private.lock_damage_report(current_setting('sherlyos.dmg03')::uuid);
  raise exception 'private helper must not be executable';
exception
  when insufficient_privilege then null;
end $$;

-- Return / reject / cancel paths and concurrent-verify setup row.
select pg_temp.as_user('godown');
set local role authenticated;
select public.return_damage_report(current_setting('sherlyos.dmg02')::uuid, 2, 'need more photos');
select pg_temp.as_user('keeper');
select public.submit_damage_report(current_setting('sherlyos.dmg02')::uuid, 3, 'm52-sub-02b');
select pg_temp.as_user('godown');
select public.reject_damage_report(current_setting('sherlyos.dmg02')::uuid, 4, 'not damage');
select public.cancel_damage_report(current_setting('sherlyos.dmg03')::uuid, 1, 'raised in error');

-- Stock and cutover must be unchanged by damage RPCs.
do $$
declare
  ledger_after integer;
  txn_after integer;
  bal_after integer;
  res_after integer;
  dual_write text;
  aggregate_only text;
  hold_ready text;
begin
  select count(*) into ledger_after
  from public.stock_ledger
  where product_id = current_setting('sherlyos.product')::uuid;
  select count(*) into txn_after
  from public.stock_transactions
  where product_id = current_setting('sherlyos.product')::uuid;
  select coalesce(sum(quantity), 0) into bal_after
  from public.stock_balances
  where product_id = current_setting('sherlyos.product')::uuid;
  select count(*) into res_after
  from public.stock_reservations
  where product_id = current_setting('sherlyos.product')::uuid;

  if ledger_after <> current_setting('sherlyos.ledger_before')::integer
    or txn_after <> current_setting('sherlyos.txn_before')::integer
    or bal_after <> current_setting('sherlyos.bal_before')::integer
    or res_after <> current_setting('sherlyos.res_before')::integer
  then
    raise exception 'damage RPCs mutated stock (% % % %) vs (% % % %)',
      ledger_after, txn_after, bal_after, res_after,
      current_setting('sherlyos.ledger_before'),
      current_setting('sherlyos.txn_before'),
      current_setting('sherlyos.bal_before'),
      current_setting('sherlyos.res_before');
  end if;

  select value #>> '{}' into dual_write
  from public.app_configuration where key = 'stock.lots.dual_write_enabled';
  select value #>> '{}' into aggregate_only
  from public.app_configuration where key = 'stock.lots.aggregate_only_blocked';
  select value #>> '{}' into hold_ready
  from public.app_configuration where key = 'damage.stock_hold_ready';

  -- Fixture enabled dual-write; the gate itself must stay false.
  if hold_ready is distinct from 'false' then
    raise exception 'damage.stock_hold_ready must stay false';
  end if;
  if dual_write is distinct from 'true' or aggregate_only is distinct from 'true' then
    raise exception 'test fixture lost cutover flags';
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_class
    join pg_namespace on pg_namespace.oid = pg_class.relnamespace
    where pg_namespace.nspname = 'public'
      and pg_class.relname = 'damage_reports'
      and pg_class.relforcerowsecurity
  ) then
    raise exception 'damage_reports must FORCE RLS';
  end if;
end $$;

rollback;
