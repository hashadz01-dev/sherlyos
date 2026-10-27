-- M7.4A local disposable SQL. Rolls back. Does not touch development cloud.
-- Vehicle master, assignment, POD metadata, failed/partial outcomes. No stock restock.
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
  fixture.name || '.m74a@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M74A Admin', true)
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
  perform pg_temp.as_user('accounts');
  payload := public.create_delivery_note(p_order, p_prefix || '-dn');
  note_id := (payload -> 'delivery_note' ->> 'id')::uuid;
  payload := public.generate_delivery_note(note_id, 1, p_prefix || '-gen');
  payload := public.send_delivery_note(note_id, 2, p_prefix || '-send');
  perform pg_temp.as_user('godown');
  payload := public.acknowledge_delivery_note(note_id, 3, p_prefix || '-ack');
  note_status := payload -> 'delivery_note' ->> 'status';
  if note_status is distinct from 'acknowledged' then
    raise exception 'DN handshake did not reach acknowledged: %', note_status;
  end if;
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

select pg_temp.as_user('admin');
set local role authenticated;
select set_config('sherlyos.branch', public.create_branch('m74a_a', 'M74A A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('m74a_b', 'M74A B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'driver'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'driver2'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'other'), current_setting('sherlyos.branch_b')::uuid);
select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'z1', 'Z1', null)::text, true);
select set_config('sherlyos.crate', public.create_crate(current_setting('sherlyos.zone')::uuid, 'c1', 'C1', null)::text, true);
select set_config('sherlyos.product', public.create_product('m74a-soap', 'M74A Soap', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.product')::uuid, 'expiry_controlled');
select set_config('sherlyos.shop', public.create_shop('M74A shop', null, null)::text, true);

-- Unauthorized vehicle creation
select pg_temp.as_user('keeper');
do $$
begin
  begin
    perform public.create_vehicle(
      current_setting('sherlyos.branch')::uuid, 'KL07M74BAD', 'van', 'Bad van', null, null
    );
    raise exception 'store keeper must not create vehicles';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

select pg_temp.as_user('godown');
select set_config(
  'sherlyos.vehicle',
  public.create_vehicle(
    current_setting('sherlyos.branch')::uuid, 'KL07 M74A 01', 'van', 'M74A van', 20, 'ops'
  )::text,
  true
);
select pg_temp.as_user('other');
select set_config(
  'sherlyos.vehicle_b',
  public.create_vehicle(
    current_setting('sherlyos.branch_b')::uuid, 'KL07M74B99', 'truck', 'Other van', null, null
  )::text,
  true
);
select pg_temp.as_user('godown');

do $$
begin
  begin
    perform public.create_vehicle(
      current_setting('sherlyos.branch')::uuid, 'KL07M74A01', 'van', 'Dup van', null, null
    );
    raise exception 'duplicate active registration must fail';
  exception
    when sqlstate '23505' then null;
  end;
end $$;

reset role;
set session_replication_role = replica;
update public.app_configuration set value = 'true'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
set session_replication_role = origin;

select pg_temp.as_user('admin');
set local role authenticated;
select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid, current_setting('sherlyos.crate')::uuid,
  20, 'm74a-open', null, 'M74A-BATCH', null, '2028-06-01'
);

-- Full dispatch + POD with vehicle and proof reference
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_pod',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 2)
      ),
      'm74a-order-pod'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_pod')::uuid, 1, 'm74a-sub-pod');
select public.verify_order(current_setting('sherlyos.order_pod')::uuid, 2, 'm74a-ver-pod');
select pg_temp.handoff(current_setting('sherlyos.order_pod')::uuid, 'm74a-pod');

select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
  prepared jsonb;
  confirmed jsonb;
  assigned jsonb;
  started jsonb;
  delivered jsonb;
  txn_before integer;
  txn_after integer;
  line_id uuid;
begin
  preview := public.preview_dispatch(current_setting('sherlyos.order_pod')::uuid);
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_pod')::uuid,
    (preview ->> 'picking_version')::integer,
    'm74a-prep-pod'
  );

  begin
    perform public.start_dispatch_delivery(
      (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm74a-go-prep'
    );
    raise exception 'delivery must not start without posted dispatch';
  exception
    when sqlstate '23514' then null;
    when sqlstate '42501' then null;
  end;

  confirmed := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm74a-cfm-pod'
  );

  begin
    perform public.assign_dispatch_delivery(
      (confirmed ->> 'id')::uuid,
      (select id from fixture where name = 'driver'),
      (confirmed ->> 'version')::integer,
      'm74a-asg-other-veh',
      current_setting('sherlyos.vehicle_b')::uuid
    );
    raise exception 'cross-godown vehicle must be refused';
  exception
    when sqlstate '23514' then null;
  end;

  assigned := public.assign_dispatch_delivery(
    (confirmed ->> 'id')::uuid,
    (select id from fixture where name = 'driver'),
    (confirmed ->> 'version')::integer,
    'm74a-asg-driver-only'
  );
  if assigned ->> 'vehicle_id' is not null then
    raise exception 'driver-only assign should leave vehicle empty';
  end if;

  perform pg_temp.as_user('driver');
  begin
    perform public.start_dispatch_delivery(
      (assigned ->> 'id')::uuid, (assigned ->> 'version')::integer, 'm74a-go-noveh'
    );
    raise exception 'start without vehicle must fail';
  exception
    when sqlstate '23514' then null;
  end;

  perform pg_temp.as_user('godown');
  assigned := public.assign_dispatch_delivery(
    (confirmed ->> 'id')::uuid,
    (select id from fixture where name = 'driver'),
    (assigned ->> 'version')::integer,
    'm74a-asg-veh',
    current_setting('sherlyos.vehicle')::uuid
  );
  if assigned ->> 'vehicle_id' is distinct from current_setting('sherlyos.vehicle') then
    raise exception 'vehicle did not stick';
  end if;

  perform pg_temp.as_user('driver2');
  begin
    perform public.start_dispatch_delivery(
      (assigned ->> 'id')::uuid, (assigned ->> 'version')::integer, 'm74a-go-other'
    );
    raise exception 'other driver must not start this run';
  exception
    when sqlstate '42501' then null;
  end;

  perform pg_temp.as_user('driver');
  started := public.start_dispatch_delivery(
    (assigned ->> 'id')::uuid, (assigned ->> 'version')::integer, 'm74a-go-pod'
  );
  if started ->> 'status' is distinct from 'in_transit' then
    raise exception 'start should mark in_transit';
  end if;

  perform pg_temp.as_user('godown');
  begin
    perform public.assign_dispatch_delivery(
      (started ->> 'id')::uuid,
      (select id from fixture where name = 'driver2'),
      (started ->> 'version')::integer,
      'm74a-asg-late',
      current_setting('sherlyos.vehicle')::uuid
    );
    raise exception 'reassignment after in_transit must fail';
  exception
    when sqlstate '23514' then null;
  end;

  perform pg_temp.as_user('driver2');
  begin
    perform public.acknowledge_dispatch_delivery(
      (started ->> 'id')::uuid, 'Forged', null,
      (started ->> 'version')::integer, 'm74a-pod-forged'
    );
    raise exception 'other driver must not record POD';
  exception
    when sqlstate '42501' then null;
  end;

  perform pg_temp.as_user('driver');
  delivered := public.acknowledge_dispatch_delivery(
    (started ->> 'id')::uuid, 'Shop owner', 'left at counter',
    (started ->> 'version')::integer, 'm74a-pod-ok', 'POD-REF-1'
  );
  if delivered ->> 'status' is distinct from 'delivered' then
    raise exception 'POD should mark delivered';
  end if;
  if delivered ->> 'delivery_outcome' is distinct from 'delivered' then
    raise exception 'POD outcome missing';
  end if;
  if delivered ->> 'proof_reference' is distinct from 'POD-REF-1' then
    raise exception 'proof reference missing';
  end if;
  if delivered ->> 'fulfilment_status' is distinct from 'fulfilled' then
    raise exception 'full original order should be fulfilled after full dispatch POD, got %',
      delivered ->> 'fulfilment_status';
  end if;
  if delivered ->> 'posted_transaction_id'
    is distinct from confirmed ->> 'posted_transaction_id'
  then
    raise exception 'POD must not replace the dispatch stock transaction';
  end if;

  if (
    select count(*) from public.stock_dispatch_outcome_lines
    where dispatch_id = (delivered ->> 'id')::uuid
  ) is distinct from 1 then
    raise exception 'POD should write one outcome line';
  end if;

  delivered := public.acknowledge_dispatch_delivery(
    (started ->> 'id')::uuid, 'Shop owner', 'left at counter',
    (delivered ->> 'version')::integer, 'm74a-pod-replay', 'POD-REF-1'
  );
  if (
    select count(*) from public.stock_dispatch_outcome_lines
    where dispatch_id = (delivered ->> 'id')::uuid
  ) is distinct from 1 then
    raise exception 'duplicate POD must not double-count';
  end if;

  select order_line_id into line_id
  from public.stock_dispatch_outcome_lines
  where dispatch_id = (delivered ->> 'id')::uuid;
  if (
    select delivered_cases from public.stock_dispatch_outcome_lines
    where dispatch_id = (delivered ->> 'id')::uuid
  ) is distinct from 2 then
    raise exception 'full POD delivered_cases should equal dispatched';
  end if;
end $$;

-- Failed delivery: no restock, return required
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_fail',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm74a-order-fail'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_fail')::uuid, 1, 'm74a-sub-fail');
select public.verify_order(current_setting('sherlyos.order_fail')::uuid, 2, 'm74a-ver-fail');
select pg_temp.handoff(current_setting('sherlyos.order_fail')::uuid, 'm74a-fail');

select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
  prepared jsonb;
  confirmed jsonb;
  assigned jsonb;
  excepted jsonb;
  txn_before integer;
  txn_after integer;
  receipt_after integer;
begin
  preview := public.preview_dispatch(current_setting('sherlyos.order_fail')::uuid);
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_fail')::uuid,
    (preview ->> 'picking_version')::integer,
    'm74a-prep-fail'
  );
  confirmed := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm74a-cfm-fail'
  );
  assigned := public.assign_dispatch_delivery(
    (confirmed ->> 'id')::uuid,
    (select id from fixture where name = 'driver'),
    (confirmed ->> 'version')::integer,
    'm74a-asg-fail',
    current_setting('sherlyos.vehicle')::uuid
  );

  excepted := public.report_dispatch_delivery_exception(
    (assigned ->> 'id')::uuid, 'shop closed',
    (assigned ->> 'version')::integer, 'm74a-exc-1'
  );
  if excepted ->> 'delivery_outcome' is distinct from 'failed' then
    raise exception 'failed outcome missing';
  end if;
  if excepted ->> 'return_required' is distinct from 'true' then
    raise exception 'return_required should be set';
  end if;
  if excepted ->> 'physical_return_status' is distinct from 'pending_verification' then
    raise exception 'physical return flag missing';
  end if;
  if excepted ->> 'posted_transaction_id'
    is distinct from confirmed ->> 'posted_transaction_id'
  then
    raise exception 'failed delivery must not replace the dispatch stock transaction';
  end if;
end $$;

-- Partial delivery quantities
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_part',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 3)
      ),
      'm74a-order-part'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_part')::uuid, 1, 'm74a-sub-part');
select public.verify_order(current_setting('sherlyos.order_part')::uuid, 2, 'm74a-ver-part');
select pg_temp.handoff(current_setting('sherlyos.order_part')::uuid, 'm74a-part');

select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
  prepared jsonb;
  confirmed jsonb;
  assigned jsonb;
  started jsonb;
  partial jsonb;
  line_id uuid;
  txn_before integer;
  txn_after integer;
begin
  preview := public.preview_dispatch(current_setting('sherlyos.order_part')::uuid);
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_part')::uuid,
    (preview ->> 'picking_version')::integer,
    'm74a-prep-part'
  );
  confirmed := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm74a-cfm-part'
  );
  assigned := public.assign_dispatch_delivery(
    (confirmed ->> 'id')::uuid,
    (select id from fixture where name = 'driver'),
    (confirmed ->> 'version')::integer,
    'm74a-asg-part',
    current_setting('sherlyos.vehicle')::uuid
  );
  perform pg_temp.as_user('driver');
  started := public.start_dispatch_delivery(
    (assigned ->> 'id')::uuid, (assigned ->> 'version')::integer, 'm74a-go-part'
  );
  select (delivery_lines -> 0 ->> 'order_line_id')::uuid
    into line_id
  from (select started -> 'delivery_lines' as delivery_lines) s;

  begin
    perform public.record_partial_dispatch_delivery(
      (started ->> 'id')::uuid,
      jsonb_build_array(jsonb_build_object('order_line_id', line_id, 'delivered_cases', 99)),
      'too many',
      (started ->> 'version')::integer,
      'm74a-part-badqty'
    );
    raise exception 'delivered qty above dispatched must fail';
  exception
    when sqlstate '23514' then null;
  end;

  partial := public.record_partial_dispatch_delivery(
    (started ->> 'id')::uuid,
    jsonb_build_array(jsonb_build_object('order_line_id', line_id, 'delivered_cases', 1)),
    'shop took one case',
    (started ->> 'version')::integer,
    'm74a-part-ok'
  );
  if partial ->> 'delivery_outcome' is distinct from 'partial' then
    raise exception 'partial outcome missing';
  end if;
  if partial ->> 'return_required' is distinct from 'true' then
    raise exception 'partial should mark return required';
  end if;
  if (
    select undelivered_cases from public.stock_dispatch_outcome_lines
    where dispatch_id = (partial ->> 'id')::uuid
  ) is distinct from 2 then
    raise exception 'undelivered should be 2';
  end if;
  if partial ->> 'posted_transaction_id'
    is distinct from confirmed ->> 'posted_transaction_id'
  then
    raise exception 'partial delivery must not replace the dispatch stock transaction';
  end if;

  begin
    perform public.record_partial_dispatch_delivery(
      (partial ->> 'id')::uuid,
      jsonb_build_array(jsonb_build_object('order_line_id', line_id, 'delivered_cases', 1)),
      'again',
      (partial ->> 'version')::integer,
      'm74a-part-dup'
    );
    raise exception 'duplicate partial must fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Inactive vehicle / driver and stale version
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_sec',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm74a-order-sec'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_sec')::uuid, 1, 'm74a-sub-sec');
select public.verify_order(current_setting('sherlyos.order_sec')::uuid, 2, 'm74a-ver-sec');
select pg_temp.handoff(current_setting('sherlyos.order_sec')::uuid, 'm74a-sec');

select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
  prepared jsonb;
  confirmed jsonb;
  idle uuid;
begin
  preview := public.preview_dispatch(current_setting('sherlyos.order_sec')::uuid);
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_sec')::uuid,
    (preview ->> 'picking_version')::integer,
    'm74a-prep-sec'
  );
  confirmed := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm74a-cfm-sec'
  );

  idle := public.create_vehicle(
    current_setting('sherlyos.branch')::uuid, 'KL07M74IDLE', 'van', 'Idle van', null, null
  );
  perform public.set_vehicle_active(idle, false);
  begin
    perform public.assign_dispatch_delivery(
      (confirmed ->> 'id')::uuid,
      (select id from fixture where name = 'driver'),
      (confirmed ->> 'version')::integer,
      'm74a-asg-idle',
      idle
    );
    raise exception 'inactive vehicle must be refused';
  exception
    when sqlstate '23514' then null;
  end;

  execute 'reset role';
  update public.profiles set is_active = false where id = (select id from fixture where name = 'driver2');
  execute 'set local role authenticated';
  perform pg_temp.as_user('godown');
  begin
    perform public.assign_dispatch_delivery(
      (confirmed ->> 'id')::uuid,
      (select id from fixture where name = 'driver2'),
      (confirmed ->> 'version')::integer,
      'm74a-asg-inactivedrv',
      current_setting('sherlyos.vehicle')::uuid
    );
    raise exception 'inactive driver must be refused';
  exception
    when sqlstate '23514' then null;
  end;
  execute 'reset role';
  update public.profiles set is_active = true where id = (select id from fixture where name = 'driver2');
  execute 'set local role authenticated';
  perform pg_temp.as_user('godown');

  begin
    perform public.assign_dispatch_delivery(
      (confirmed ->> 'id')::uuid,
      (select id from fixture where name = 'driver'),
      999,
      'm74a-asg-stale',
      current_setting('sherlyos.vehicle')::uuid
    );
    raise exception 'stale assignment must be refused';
  exception
    when sqlstate 'PT409' then null;
  end;
end $$;

-- M7.3B: short-shipped original is not fulfilled merely because its first shipment was delivered
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_short',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 2)
      ),
      'm74a-order-short'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_short')::uuid, 1, 'm74a-sub-short');
select public.verify_order(current_setting('sherlyos.order_short')::uuid, 2, 'm74a-ver-short');

select pg_temp.as_user('godown');
do $$
declare
  header jsonb;
  res jsonb;
  shipment jsonb;
  preview jsonb;
  prepared jsonb;
  confirmed jsonb;
  assigned jsonb;
  started jsonb;
  delivered jsonb;
  request_id uuid;
  backorder uuid;
  txn_before integer;
  txn_after integer;
begin
  perform pg_temp.handshake_dn(current_setting('sherlyos.order_short')::uuid, 'm74a-short');
  perform pg_temp.as_user('godown');
  header := public.reserve_order_allocation(
    current_setting('sherlyos.order_short')::uuid, 3, 'm74a-short-res'
  );
  request_id := (header ->> 'id')::uuid;
  header := public.assign_picking_request(
    request_id, (select id from fixture where name = 'keeper'), 1, 'm74a-short-asg'
  );
  header := public.start_picking(request_id, 2, 'm74a-short-start');
  perform pg_temp.as_user('keeper');
  header := public.get_picking_request(request_id);
  res := header -> 'reservations' -> 0;
  header := public.confirm_picking_quantity(
    request_id, (res ->> 'id')::uuid, 1,
    (header ->> 'version')::integer, 'm74a-short-pick'
  );
  header := public.report_picking_shortage(
    request_id, (res ->> 'id')::uuid, 1, 'one case short',
    (header ->> 'version')::integer, 'm74a-short-sh'
  );
  header := public.complete_picking(request_id, (header ->> 'version')::integer, 'm74a-short-done');

  perform pg_temp.as_user('godown');
  header := public.get_picking_request(request_id);
  shipment := public.create_short_shipment(request_id, (header ->> 'version')::integer, 'm74a-sh-create');
  shipment := public.confirm_short_shipment_quantities(
    (shipment ->> 'id')::uuid, (shipment ->> 'version')::integer, 'm74a-sh-gm'
  );
  perform pg_temp.as_user('accounts');
  shipment := public.approve_short_shipment(
    (shipment ->> 'id')::uuid, (shipment ->> 'version')::integer, null, 'm74a-sh-ap'
  );

  perform pg_temp.as_user('godown');
  header := public.get_picking_request(request_id);
  header := public.confirm_picking_handoff(
    request_id, (header ->> 'version')::integer, 'm74a-short-ho'
  );
  preview := public.preview_dispatch(current_setting('sherlyos.order_short')::uuid);
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_short')::uuid,
    (header ->> 'version')::integer,
    'm74a-prep-short'
  );
  confirmed := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm74a-cfm-short'
  );
  assigned := public.assign_dispatch_delivery(
    (confirmed ->> 'id')::uuid,
    (select id from fixture where name = 'driver'),
    (confirmed ->> 'version')::integer,
    'm74a-asg-short',
    current_setting('sherlyos.vehicle')::uuid
  );
  perform pg_temp.as_user('driver');
  started := public.start_dispatch_delivery(
    (assigned ->> 'id')::uuid, (assigned ->> 'version')::integer, 'm74a-go-short'
  );
  delivered := public.acknowledge_dispatch_delivery(
    (started ->> 'id')::uuid, 'Shop owner', null,
    (started ->> 'version')::integer, 'm74a-pod-short'
  );
  if delivered ->> 'fulfilment_status' is not distinct from 'fulfilled' then
    raise exception 'short-shipped original must not become fulfilled because its first shipment was delivered';
  end if;
  if delivered ->> 'fulfilment_status' is distinct from 'partially_fulfilled' then
    raise exception 'expected partially_fulfilled, got %', delivered ->> 'fulfilment_status';
  end if;
  backorder := (delivered ->> 'backorder_id')::uuid;
  if backorder is null then
    raise exception 'linked backorder missing after short dispatch';
  end if;
  -- GM cannot select orders; use payload fields already asserted.
  if delivered ->> 'order_status' is distinct from 'verified' then
    raise exception 'POD must not rewrite original order status';
  end if;
  if delivered ->> 'posted_transaction_id'
    is distinct from confirmed ->> 'posted_transaction_id'
  then
    raise exception 'short-shipment POD must not replace the dispatch stock transaction';
  end if;
end $$;

-- Direct table writes stay denied
select pg_temp.as_user('godown');
do $$
begin
  begin
    insert into public.vehicles (
      branch_id, registration_number, registration_normalized, vehicle_type,
      display_name, created_by
    )
    values (
      current_setting('sherlyos.branch')::uuid, 'KL07HACK', 'kl07hack', 'van',
      'hack', (select id from fixture where name = 'godown')
    );
    raise exception 'direct vehicle insert must be denied';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

rollback;
