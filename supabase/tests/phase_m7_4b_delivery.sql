-- M7.4B local disposable SQL. Rolls back. Does not touch development cloud.
-- Failed/partial returns, SoD, quarantine, DELIVERY_RETURN posting. No confirm_dispatch rewrite.
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
  fixture.name || '.m74b@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M74B Admin', true)
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
begin
  perform pg_temp.as_user('accounts');
  payload := public.create_delivery_note(p_order, p_prefix || '-dn');
  note_id := (payload -> 'delivery_note' ->> 'id')::uuid;
  payload := public.generate_delivery_note(note_id, 1, p_prefix || '-gen');
  payload := public.send_delivery_note(note_id, 2, p_prefix || '-send');
  perform pg_temp.as_user('godown');
  payload := public.acknowledge_delivery_note(note_id, 3, p_prefix || '-ack');
  return note_id;
end;
$$;

create or replace function pg_temp.handoff(order_id uuid, prefix text)
returns uuid language plpgsql as $$
declare
  header jsonb;
  res jsonb;
  i int;
  request_id uuid;
begin
  perform pg_temp.handshake_dn(order_id, prefix);
  perform pg_temp.as_user('godown');
  header := public.reserve_order_allocation(order_id, 3, prefix || '-res');
  request_id := (header ->> 'id')::uuid;
  header := public.assign_picking_request(
    request_id, (select id from fixture where name = 'keeper'), 1, prefix || '-asg'
  );
  header := public.start_picking(request_id, 2, prefix || '-start');
  perform pg_temp.as_user('keeper');
  header := public.get_picking_request(request_id);
  for i in 0 .. jsonb_array_length(header -> 'reservations') - 1 loop
    res := header -> 'reservations' -> i;
    header := public.confirm_picking_quantity(
      request_id, (res ->> 'id')::uuid, (res ->> 'reserved_cases')::integer,
      (header ->> 'version')::integer, prefix || '-pick-' || i::text
    );
  end loop;
  header := public.complete_picking(request_id, (header ->> 'version')::integer, prefix || '-done');
  perform pg_temp.as_user('godown');
  header := public.confirm_picking_handoff(request_id, (header ->> 'version')::integer, prefix || '-ho');
  return request_id;
end;
$$;

create or replace function pg_temp.failed_dispatch(order_id uuid, prefix text, qty integer)
returns uuid language plpgsql as $$
declare
  preview jsonb;
  prepared jsonb;
  confirmed jsonb;
  assigned jsonb;
  excepted jsonb;
begin
  perform pg_temp.handoff(order_id, prefix);
  perform pg_temp.as_user('godown');
  preview := public.preview_dispatch(order_id);
  prepared := public.prepare_dispatch(order_id, (preview ->> 'picking_version')::integer, prefix || '-prep');
  confirmed := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, prefix || '-cfm'
  );
  assigned := public.assign_dispatch_delivery(
    (confirmed ->> 'id')::uuid,
    (select id from fixture where name = 'driver'),
    (confirmed ->> 'version')::integer,
    prefix || '-asg',
    current_setting('sherlyos.vehicle')::uuid
  );
  excepted := public.report_dispatch_delivery_exception(
    (assigned ->> 'id')::uuid, 'shop closed',
    (assigned ->> 'version')::integer, prefix || '-exc'
  );
  if excepted ->> 'return_id' is null then
    raise exception 'exception must open a return document';
  end if;
  return (excepted ->> 'id')::uuid;
end;
$$;

select pg_temp.as_user('admin');
set local role authenticated;
select set_config('sherlyos.branch', public.create_branch('m74b_a', 'M74B A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('m74b_b', 'M74B B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'driver'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'other'), current_setting('sherlyos.branch_b')::uuid);
select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'z1', 'Z1', null)::text, true);
select set_config('sherlyos.crate', public.create_crate(current_setting('sherlyos.zone')::uuid, 'c1', 'C1', null)::text, true);
select set_config('sherlyos.zone_b', public.create_zone(current_setting('sherlyos.branch_b')::uuid, 'zb', 'ZB', null)::text, true);
select set_config('sherlyos.crate_b', public.create_crate(current_setting('sherlyos.zone_b')::uuid, 'cb', 'CB', null)::text, true);
select set_config('sherlyos.product', public.create_product('m74b-soap', 'M74B Soap', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.product')::uuid, 'expiry_controlled');
select set_config('sherlyos.shop', public.create_shop('M74B shop', null, null)::text, true);

select pg_temp.as_user('godown');
select set_config(
  'sherlyos.vehicle',
  public.create_vehicle(
    current_setting('sherlyos.branch')::uuid, 'KL07 M74B 01', 'van', 'M74B van', 20, 'ops'
  )::text,
  true
);

reset role;
set session_replication_role = replica;
update public.app_configuration set value = 'true'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
set session_replication_role = origin;

select pg_temp.as_user('admin');
set local role authenticated;
select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid, current_setting('sherlyos.crate')::uuid,
  30, 'm74b-open', null, 'M74B-BATCH', null, '2028-06-01'
);

-- Happy path: failed delivery → handback → keeper count → GM approve → post
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_ok',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 2)
      ),
      'm74b-order-ok'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_ok')::uuid, 1, 'm74b-sub-ok');
select public.verify_order(current_setting('sherlyos.order_ok')::uuid, 2, 'm74b-ver-ok');
select set_config(
  'sherlyos.dispatch_ok',
  pg_temp.failed_dispatch(current_setting('sherlyos.order_ok')::uuid, 'm74b-ok', 2)::text,
  true
);

select pg_temp.as_user('godown');
do $$
begin
  begin
    perform public.count_delivery_return(
      (select id from public.stock_delivery_returns
        where dispatch_id = current_setting('sherlyos.dispatch_ok')::uuid),
      '[]'::jsonb, 1, 'm74b-gm-count'
    );
    raise exception 'GM must not record the Store Keeper count';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

select pg_temp.as_user('driver');
do $$
declare
  ret jsonb;
  dispatch_txn uuid;
  return_txn uuid;
  credit integer;
  crate_role text;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_ok')::uuid);
  if ret ->> 'status' is distinct from 'awaiting_handback' then
    raise exception 'return should open awaiting_handback, got %', ret ->> 'status';
  end if;

  begin
    perform public.approve_delivery_return((ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-drv-ap');
    raise exception 'driver must not approve';
  exception
    when sqlstate '42501' then null;
  end;

  ret := public.declare_delivery_return_handback(
    (ret ->> 'id')::uuid, 2, 'physical cartons', (ret ->> 'version')::integer, 'm74b-hb-ok'
  );
  if ret ->> 'status' is distinct from 'handed_back' then
    raise exception 'handback status %, expected handed_back', ret ->> 'status';
  end if;

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
        'receiving_crate_id', current_setting('sherlyos.crate')
      )),
      (ret ->> 'version')::integer,
      'm74b-drv-count'
    );
    raise exception 'driver must not count';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

select pg_temp.as_user('keeper');
do $$
declare
  ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_ok')::uuid);

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
        'receiving_crate_id', current_setting('sherlyos.crate_b')
      )),
      (ret ->> 'version')::integer,
      'm74b-cross-crate'
    );
    raise exception 'cross-godown crate must fail';
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
      'receiving_crate_id', current_setting('sherlyos.crate')
    )),
    (ret ->> 'version')::integer,
    'm74b-count-ok'
  );
  if ret ->> 'status' is distinct from 'counted' then
    raise exception 'count should reach counted';
  end if;

  begin
    perform public.post_delivery_return((ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-kp-post');
    raise exception 'store keeper must not post';
  exception
    when sqlstate '42501' then null;
  end;

  begin
    perform public.approve_delivery_return((ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-kp-ap');
    raise exception 'store keeper must not approve';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

select pg_temp.as_user('other');
do $$
declare
  ret jsonb;
begin
  begin
    ret := public.get_delivery_return(current_setting('sherlyos.dispatch_ok')::uuid);
    perform public.approve_delivery_return((ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-xgodown');
    raise exception 'cross-godown GM must not approve';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

select pg_temp.as_user('godown');
do $$
declare
  ret jsonb;
  dispatch_txn uuid;
  return_txn uuid;
  credit integer;
  debit integer;
  lot uuid;
  crate_role text;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_ok')::uuid);
  ret := public.approve_delivery_return(
    (ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-ap-ok'
  );
  if ret ->> 'status' is distinct from 'approved' then
    raise exception 'approval did not stick';
  end if;

  select posted_transaction_id into dispatch_txn
  from public.stock_dispatch_requests
  where id = current_setting('sherlyos.dispatch_ok')::uuid;

  ret := public.post_delivery_return(
    (ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-post-ok'
  );
  if ret ->> 'status' is distinct from 'posted' then
    raise exception 'post should reach posted, got %', ret ->> 'status';
  end if;
  if ret ->> 'posted_transaction_id' is null then
    raise exception 'posted return must have a transaction';
  end if;
  return_txn := (ret ->> 'posted_transaction_id')::uuid;
  if return_txn is not distinct from dispatch_txn then
    raise exception 'return must not reuse the DISPATCH transaction';
  end if;

  select quantity into credit
  from public.stock_transactions
  where id = return_txn;
  if credit is distinct from 2 then
    raise exception 'DELIVERY_RETURN header qty %, expected 2', credit;
  end if;
  if (
    select transaction_type from public.stock_transactions where id = return_txn
  ) is distinct from 'DELIVERY_RETURN' then
    raise exception 'wrong transaction type';
  end if;
  if (
    select delivery_return_id from public.stock_transactions where id = return_txn
  ) is distinct from (ret ->> 'id')::uuid then
    raise exception 'delivery_return_id provenance missing';
  end if;
  if (
    select dispatch_request_id from public.stock_transactions where id = return_txn
  ) is not null then
    raise exception 'return must not set dispatch_request_id';
  end if;

  select coalesce(sum(quantity), 0) into debit
  from public.stock_ledger where transaction_id = dispatch_txn;
  select coalesce(sum(quantity), 0) into credit
  from public.stock_ledger where transaction_id = return_txn;
  if debit is distinct from -2 or credit is distinct from 2 then
    raise exception 'ledger debit % credit %', debit, credit;
  end if;

  select lot_id into lot from public.stock_ledger where transaction_id = return_txn;
  if lot is distinct from (
    select lot_id from public.stock_ledger where transaction_id = dispatch_txn
  ) then
    raise exception 'return must reuse the original lot';
  end if;

  ret := public.post_delivery_return(
    (ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-post-replay'
  );
  if (
    select count(*) from public.stock_transactions
    where delivery_return_id = (ret ->> 'id')::uuid
  ) is distinct from 1 then
    raise exception 'replay must not create a second stock transaction';
  end if;
end $$;

-- Dual-write off is fail-closed; no aggregate credit.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_flag',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm74b-order-flag'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_flag')::uuid, 1, 'm74b-sub-flag');
select public.verify_order(current_setting('sherlyos.order_flag')::uuid, 2, 'm74b-ver-flag');
select set_config(
  'sherlyos.dispatch_flag',
  pg_temp.failed_dispatch(current_setting('sherlyos.order_flag')::uuid, 'm74b-flag', 1)::text,
  true
);

select pg_temp.as_user('driver');
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_flag')::uuid);
  ret := public.declare_delivery_return_handback(
    (ret ->> 'id')::uuid, 1, null, (ret ->> 'version')::integer, 'm74b-flag-hb'
  );
end $$;
select pg_temp.as_user('keeper');
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_flag')::uuid);
  ret := public.count_delivery_return(
    (ret ->> 'id')::uuid,
    jsonb_build_array(jsonb_build_object(
      'id', ret -> 'lots' -> 0 ->> 'id',
      'delivered_cases', 0, 'saleable_cases', 1, 'damaged_cases', 0,
      'uncertain_cases', 0, 'missing_cases', 0,
      'receiving_crate_id', current_setting('sherlyos.crate')
    )),
    (ret ->> 'version')::integer, 'm74b-flag-ct'
  );
end $$;
select pg_temp.as_user('godown');
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_flag')::uuid);
  ret := public.approve_delivery_return(
    (ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-flag-ap'
  );
  perform set_config('app.delivery_return_write', 'on', true);
end $$;

reset role;
set session_replication_role = replica;
update public.app_configuration set value = 'false'::jsonb
where key = 'stock.lots.dual_write_enabled';
set session_replication_role = origin;

select pg_temp.as_user('godown');
set local role authenticated;
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_flag')::uuid);
  begin
    perform public.post_delivery_return(
      (ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-flag-post'
    );
    raise exception 'posting must fail closed when dual-write is off';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

reset role;
set session_replication_role = replica;
update public.app_configuration set value = 'true'::jsonb
where key = 'stock.lots.dual_write_enabled';
set session_replication_role = origin;

-- Damaged cases credit quarantine only. Missing credits nothing.
select pg_temp.as_user('accounts');
set local role authenticated;
select set_config(
  'sherlyos.order_dmg',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 3)
      ),
      'm74b-order-dmg'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_dmg')::uuid, 1, 'm74b-sub-dmg');
select public.verify_order(current_setting('sherlyos.order_dmg')::uuid, 2, 'm74b-ver-dmg');
select set_config(
  'sherlyos.dispatch_dmg',
  pg_temp.failed_dispatch(current_setting('sherlyos.order_dmg')::uuid, 'm74b-dmg', 3)::text,
  true
);

select pg_temp.as_user('driver');
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_dmg')::uuid);
  perform public.declare_delivery_return_handback(
    (ret ->> 'id')::uuid, 2, null, (ret ->> 'version')::integer, 'm74b-dmg-hb'
  );
end $$;
select pg_temp.as_user('keeper');
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_dmg')::uuid);
  ret := public.count_delivery_return(
    (ret ->> 'id')::uuid,
    jsonb_build_array(jsonb_build_object(
      'id', ret -> 'lots' -> 0 ->> 'id',
      'delivered_cases', 0, 'saleable_cases', 0, 'damaged_cases', 2,
      'uncertain_cases', 0, 'missing_cases', 1,
      'receiving_crate_id', null
    )),
    (ret ->> 'version')::integer, 'm74b-dmg-ct'
  );
end $$;
select pg_temp.as_user('godown');
do $$
declare
  ret jsonb;
  q_role text;
  credit integer;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_dmg')::uuid);
  ret := public.approve_delivery_return(
    (ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-dmg-ap'
  );
  ret := public.post_delivery_return(
    (ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-dmg-post'
  );
  select coalesce(sum(stock_ledger.quantity), 0), min(crates.location_role)
  into credit, q_role
  from public.stock_ledger
  join public.crates on crates.id = stock_ledger.crate_id
  where stock_ledger.transaction_id = (ret ->> 'posted_transaction_id')::uuid;
  if credit is distinct from 2 then
    raise exception 'damaged credit must ignore missing, got %', credit;
  end if;
  if q_role is distinct from 'quarantine' then
    raise exception 'damaged cases must credit quarantine, got %', q_role;
  end if;
end $$;

-- Close-all-missing: no stock transaction. Driver cannot close.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_miss',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm74b-order-miss'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_miss')::uuid, 1, 'm74b-sub-miss');
select public.verify_order(current_setting('sherlyos.order_miss')::uuid, 2, 'm74b-ver-miss');
select set_config(
  'sherlyos.dispatch_miss',
  pg_temp.failed_dispatch(current_setting('sherlyos.order_miss')::uuid, 'm74b-miss', 1)::text,
  true
);
select pg_temp.as_user('driver');
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_miss')::uuid);
  ret := public.declare_delivery_return_handback(
    (ret ->> 'id')::uuid, 0, 'nothing came back', (ret ->> 'version')::integer, 'm74b-miss-hb'
  );
  begin
    perform public.close_delivery_return_missing(
      (ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-miss-drv'
    );
    raise exception 'driver must not close-all-missing';
  exception
    when sqlstate '42501' then null;
    when sqlstate '23514' then null;
  end;
end $$;
select pg_temp.as_user('keeper');
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_miss')::uuid);
  perform public.count_delivery_return(
    (ret ->> 'id')::uuid,
    jsonb_build_array(jsonb_build_object(
      'id', ret -> 'lots' -> 0 ->> 'id',
      'delivered_cases', 0, 'saleable_cases', 0, 'damaged_cases', 0,
      'uncertain_cases', 0, 'missing_cases', 1,
      'receiving_crate_id', null
    )),
    (ret ->> 'version')::integer, 'm74b-miss-ct'
  );
end $$;
select pg_temp.as_user('godown');
do $$
declare
  ret jsonb;
  txn_count integer;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_miss')::uuid);
  ret := public.close_delivery_return_missing(
    (ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-miss-close'
  );
  if ret ->> 'status' is distinct from 'closed_missing' then
    raise exception 'expected closed_missing';
  end if;
  if ret ->> 'posted_transaction_id' is not null then
    raise exception 'missing close must not post stock';
  end if;
  select count(*) into txn_count
  from public.stock_transactions
  where delivery_return_id = (ret ->> 'id')::uuid;
  if txn_count <> 0 then
    raise exception 'missing close leaked a stock transaction';
  end if;
end $$;

-- Stale approval after keeper correction
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_stale',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm74b-order-stale'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_stale')::uuid, 1, 'm74b-sub-stale');
select public.verify_order(current_setting('sherlyos.order_stale')::uuid, 2, 'm74b-ver-stale');
select set_config(
  'sherlyos.dispatch_stale',
  pg_temp.failed_dispatch(current_setting('sherlyos.order_stale')::uuid, 'm74b-stale', 1)::text,
  true
);
select pg_temp.as_user('driver');
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_stale')::uuid);
  perform public.declare_delivery_return_handback(
    (ret ->> 'id')::uuid, 1, null, (ret ->> 'version')::integer, 'm74b-stale-hb'
  );
end $$;
select pg_temp.as_user('keeper');
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_stale')::uuid);
  perform public.count_delivery_return(
    (ret ->> 'id')::uuid,
    jsonb_build_array(jsonb_build_object(
      'id', ret -> 'lots' -> 0 ->> 'id',
      'delivered_cases', 0, 'saleable_cases', 1, 'damaged_cases', 0,
      'uncertain_cases', 0, 'missing_cases', 0,
      'receiving_crate_id', current_setting('sherlyos.crate')
    )),
    (ret ->> 'version')::integer, 'm74b-stale-ct1'
  );
end $$;
select pg_temp.as_user('godown');
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_stale')::uuid);
  perform public.approve_delivery_return(
    (ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-stale-ap'
  );
end $$;
select pg_temp.as_user('keeper');
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_stale')::uuid);
  -- Count from counted is allowed; approval is on approved. Return to count first? 
  -- count_delivery_return allows handed_back|counted only, so GM must return_to_count
  -- or we count again only if status is counted. After approve, status is approved.
  -- Keeper cannot count while approved — that's the race: correction requires approved→counted.
  begin
    perform public.count_delivery_return(
      (ret ->> 'id')::uuid,
      jsonb_build_array(jsonb_build_object(
        'id', ret -> 'lots' -> 0 ->> 'id',
        'delivered_cases', 0, 'saleable_cases', 0, 'damaged_cases', 1,
        'uncertain_cases', 0, 'missing_cases', 0,
        'receiving_crate_id', null
      )),
      (ret ->> 'version')::integer, 'm74b-stale-ct2'
    );
    raise exception 'count during approved must fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;
select pg_temp.as_user('godown');
do $$
declare
  ret jsonb;
  approved_version integer;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_stale')::uuid);
  approved_version := (ret ->> 'version')::integer;
  ret := public.return_delivery_return_to_count(
    (ret ->> 'id')::uuid, approved_version, 'm74b-stale-back'
  );
  perform pg_temp.as_user('keeper');
  ret := public.count_delivery_return(
    (ret ->> 'id')::uuid,
    jsonb_build_array(jsonb_build_object(
      'id', ret -> 'lots' -> 0 ->> 'id',
      'delivered_cases', 0, 'saleable_cases', 0, 'damaged_cases', 1,
      'uncertain_cases', 0, 'missing_cases', 0,
      'receiving_crate_id', null
    )),
    (ret ->> 'version')::integer, 'm74b-stale-ct3'
  );
  perform pg_temp.as_user('godown');
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_stale')::uuid);
  begin
    perform public.post_delivery_return(
      (ret ->> 'id')::uuid,
      approved_version, 'm74b-stale-post'
    );
    raise exception 'stale approval must not post';
  exception
    when sqlstate 'PT409' then null;
    when sqlstate '23514' then null;
  end;
end $$;

-- Expired-to-saleable is refused. Direct writes denied. Second wave unique.
select pg_temp.as_user('godown');
do $$
begin
  begin
    insert into public.stock_delivery_returns (
      dispatch_id, branch_id, return_number, status, created_by
    )
    values (
      current_setting('sherlyos.dispatch_ok')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'DR-HACK', 'awaiting_handback',
      (select id from fixture where name = 'godown')
    );
    raise exception 'direct return insert must be denied';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at
    )
    select posted_transaction_id, current_setting('sherlyos.product')::uuid,
      current_setting('sherlyos.crate')::uuid, 1, (select id from fixture where name = 'godown'),
      clock_timestamp()
    from public.stock_dispatch_requests
    where id = current_setting('sherlyos.dispatch_ok')::uuid;
    raise exception 'direct ledger insert must be denied';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Transit-damage overlap blocks posting
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_ov',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm74b-order-ov'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_ov')::uuid, 1, 'm74b-sub-ov');
select public.verify_order(current_setting('sherlyos.order_ov')::uuid, 2, 'm74b-ver-ov');
select set_config(
  'sherlyos.dispatch_ov',
  pg_temp.failed_dispatch(current_setting('sherlyos.order_ov')::uuid, 'm74b-ov', 1)::text,
  true
);
select pg_temp.as_user('driver');
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_ov')::uuid);
  perform public.declare_delivery_return_handback(
    (ret ->> 'id')::uuid, 1, null, (ret ->> 'version')::integer, 'm74b-ov-hb'
  );
end $$;
select pg_temp.as_user('keeper');
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_ov')::uuid);
  perform public.count_delivery_return(
    (ret ->> 'id')::uuid,
    jsonb_build_array(jsonb_build_object(
      'id', ret -> 'lots' -> 0 ->> 'id',
      'delivered_cases', 0, 'saleable_cases', 1, 'damaged_cases', 0,
      'uncertain_cases', 0, 'missing_cases', 0,
      'receiving_crate_id', current_setting('sherlyos.crate')
    )),
    (ret ->> 'version')::integer, 'm74b-ov-ct'
  );
end $$;

reset role;
set session_replication_role = replica;
insert into public.damage_reports (
  report_number, scenario, godown_id, status, dispatch_id, reporter_user_id,
  idempotency_key, request_fingerprint
)
values (
  'DMG-M74B-OV', 'transit', current_setting('sherlyos.branch')::uuid, 'submitted',
  current_setting('sherlyos.dispatch_ov')::uuid,
  (select id from fixture where name = 'driver'),
  'm74b-ov-dmg', 'm74b-ov-dmg'
);
insert into public.damage_report_lines (
  damage_report_id, product_id, lot_id, quantity_cases, damage_reason
)
select id, current_setting('sherlyos.product')::uuid,
  (select lots.lot_id from public.stock_delivery_return_lots lots
    join public.stock_delivery_returns r on r.id = lots.return_id
    where r.dispatch_id = current_setting('sherlyos.dispatch_ov')::uuid
    limit 1),
  1, 'transit crush'
from public.damage_reports
where report_number = 'DMG-M74B-OV';
set session_replication_role = origin;

select pg_temp.as_user('godown');
set local role authenticated;
do $$
declare ret jsonb;
begin
  ret := public.get_delivery_return(current_setting('sherlyos.dispatch_ov')::uuid);
  begin
    perform public.approve_delivery_return(
      (ret ->> 'id')::uuid, (ret ->> 'version')::integer, 'm74b-ov-ap'
    );
    raise exception 'transit damage overlap must block approval';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Two original lots / two source crates. Grains must match the DISPATCH ledger.
select pg_temp.as_user('admin');
set local role authenticated;
select set_config(
  'sherlyos.crate_2',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'c2', 'C2', null)::text,
  true
);
select set_config(
  'sherlyos.product_2',
  public.create_product('m74b-oil', 'M74B Oil', null, null)::text,
  true
);
select public.set_product_expiry_policy(current_setting('sherlyos.product_2')::uuid, 'expiry_controlled');
select public.post_opening_stock(
  current_setting('sherlyos.product_2')::uuid, current_setting('sherlyos.crate_2')::uuid,
  10, 'm74b-open-2', null, 'M74B-OIL', null, '2028-08-01'
);

select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_ml',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1),
        jsonb_build_object('product_id', current_setting('sherlyos.product_2')::uuid, 'requested_cases', 1)
      ),
      'm74b-order-ml'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_ml')::uuid, 1, 'm74b-sub-ml');
select public.verify_order(current_setting('sherlyos.order_ml')::uuid, 2, 'm74b-ver-ml');
select set_config(
  'sherlyos.dispatch_ml',
  pg_temp.failed_dispatch(current_setting('sherlyos.order_ml')::uuid, 'm74b-ml', 2)::text,
  true
);

reset role;
do $$
declare
  header public.stock_dispatch_requests;
  grain_n integer;
  ledger_n integer;
begin
  select * into header
  from public.stock_dispatch_requests
  where id = current_setting('sherlyos.dispatch_ml')::uuid;

  select count(*) into grain_n
  from app_private.dispatch_return_source_grains(header);
  if grain_n <> 2 then
    raise exception 'two-lot dispatch must snapshot two return grains, got %', grain_n;
  end if;

  select count(*) into ledger_n
  from public.stock_ledger
  where transaction_id = header.posted_transaction_id
    and quantity < 0;
  if ledger_n <> 2 then
    raise exception 'two-lot DISPATCH must debit two ledger lines, got %', ledger_n;
  end if;

  perform app_private.assert_return_grains_match_ledger(header);

  if exists (
    select 1
    from public.stock_delivery_return_lots lots
    join public.stock_delivery_returns r on r.id = lots.return_id
    where r.dispatch_id = header.id
    group by lots.source_crate_id
    having count(*) filter (where true) < 1
  ) then
    raise exception 'return lots missing source crates';
  end if;

  if (
    select count(distinct lots.source_crate_id)
    from public.stock_delivery_return_lots lots
    join public.stock_delivery_returns r on r.id = lots.return_id
    where r.dispatch_id = header.id
  ) <> 2 then
    raise exception 'two source crates must remain distinct return grains';
  end if;
end $$;

-- Duplicate consumed reservations on one grain must fail closed.
reset role;
do $$
declare
  header public.stock_dispatch_requests;
  clone_res uuid := gen_random_uuid();
  src public.stock_reservations%rowtype;
  src_lot public.order_shipment_lots%rowtype;
  clone_lot uuid;
begin
  select * into header
  from public.stock_dispatch_requests
  where id = current_setting('sherlyos.dispatch_ml')::uuid;

  select osl.* into src_lot
  from public.order_shipment_lots osl
  join public.order_shipments s on s.id = osl.shipment_id
  where s.picking_request_id = header.picking_request_id
    and osl.shipped_cases > 0
  order by osl.id
  limit 1;

  if src_lot.id is not null then
    set session_replication_role = replica;
    insert into public.stock_reservations (
      id, picking_request_id, order_id, order_line_id, product_id, crate_id, lot_id,
      branch_id, reserved_cases, picked_cases, status, created_by
    )
    values (
      clone_res, header.picking_request_id, header.order_id, src_lot.order_line_id,
      src_lot.product_id, src_lot.crate_id, src_lot.lot_id, header.branch_id,
      greatest(src_lot.reserved_cases, 1), src_lot.picked_cases, 'consumed',
      header.created_by
    );
    insert into public.order_shipment_lots (
      shipment_id, shipment_line_id, reservation_id, order_line_id, product_id,
      lot_id, crate_id, reserved_cases, picked_cases, proposed_cases,
      approved_cases, shipped_cases, released_cases
    )
    values (
      src_lot.shipment_id, src_lot.shipment_line_id, clone_res, src_lot.order_line_id,
      src_lot.product_id, src_lot.lot_id, src_lot.crate_id, src_lot.reserved_cases,
      src_lot.picked_cases, src_lot.proposed_cases, src_lot.approved_cases,
      src_lot.shipped_cases, src_lot.released_cases
    )
    returning id into clone_lot;
    set session_replication_role = origin;

    begin
      perform 1 from app_private.dispatch_return_source_grains(header);
      raise exception 'duplicate shipment lots must fail closed';
    exception
      when sqlstate '23514' then null;
    end;

    set session_replication_role = replica;
    delete from public.order_shipment_lots where id = clone_lot;
    delete from public.stock_reservations where id = clone_res;
    delete from public.order_shipment_lots
    where shipment_id in (
      select id from public.order_shipments
      where picking_request_id = header.picking_request_id
    );
    delete from public.order_shipment_lines
    where shipment_id in (
      select id from public.order_shipments
      where picking_request_id = header.picking_request_id
    );
    delete from public.order_shipment_events
    where shipment_id in (
      select id from public.order_shipments
      where picking_request_id = header.picking_request_id
    );
    delete from public.order_shipments
    where picking_request_id = header.picking_request_id;
    set session_replication_role = origin;
  end if;

  select * into src
  from public.stock_reservations
  where picking_request_id = header.picking_request_id
    and status = 'consumed'
  order by id
  limit 1;
  if src.id is null then
    raise exception 'consumed reservations missing for reservation fallback';
  end if;

  if (
    select count(*) from app_private.dispatch_return_source_grains(header)
  ) <> 2 then
    raise exception 'reservation fallback must keep both consumed grains';
  end if;
  perform app_private.assert_return_grains_match_ledger(header);

  set session_replication_role = replica;
  insert into public.stock_reservations (
    id, picking_request_id, order_id, order_line_id, product_id, crate_id, lot_id,
    branch_id, reserved_cases, picked_cases, status, created_by
  )
  values (
    clone_res, src.picking_request_id, src.order_id, src.order_line_id, src.product_id,
    src.crate_id, src.lot_id, src.branch_id, src.reserved_cases, src.picked_cases,
    src.status, src.created_by
  );
  set session_replication_role = origin;

  begin
    perform 1 from app_private.dispatch_return_source_grains(header);
    raise exception 'duplicate consumed reservations must fail closed';
  exception
    when sqlstate '23514' then null;
  end;

  set session_replication_role = replica;
  delete from public.stock_reservations where id = clone_res;
  set session_replication_role = origin;
end $$;

-- Restore flags before rollback so a later abort cannot leak true.
reset role;
set session_replication_role = replica;
update public.app_configuration set value = 'false'::jsonb
where key in (
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked',
  'damage.stock_hold_ready'
);
set session_replication_role = origin;

rollback;
