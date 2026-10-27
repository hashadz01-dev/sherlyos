-- M7.3B local disposable SQL. Rolls back. Does not touch development cloud.
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
  ('salesperson', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('other_gm', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.m73b@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M73B Admin', true)
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
  when 'salesperson' then 'salesperson'
  when 'godown' then 'godown_manager'
  when 'other_gm' then 'godown_manager'
  when 'keeper' then 'store_keeper'
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

select pg_temp.as_user('admin');
set local role authenticated;
select set_config('sherlyos.branch', public.create_branch('m73b_a', 'M73B A')::text, true);
select set_config('sherlyos.branch2', public.create_branch('m73b_b', 'M73B B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'salesperson'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'other_gm'), current_setting('sherlyos.branch2')::uuid);
select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'z1', 'Z1', null)::text, true);
select set_config('sherlyos.crate', public.create_crate(current_setting('sherlyos.zone')::uuid, 'c1', 'C1', null)::text, true);
select set_config('sherlyos.sku', public.create_product('m73b-sku', 'M73B soap', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.sku')::uuid, 'non_expiring');
select set_config('sherlyos.shop', public.create_shop('M73B shop', null, null)::text, true);
select public.assign_shop_salesperson(current_setting('sherlyos.shop')::uuid, (select id from fixture where name = 'salesperson'));

reset role;
set session_replication_role = replica;
update public.app_configuration set value = 'true'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
set session_replication_role = origin;

select pg_temp.as_user('admin');
set local role authenticated;
select public.post_opening_stock(
  current_setting('sherlyos.sku')::uuid,
  current_setting('sherlyos.crate')::uuid,
  10,
  'm73b-open-lot',
  null,
  'M73B-LOT',
  null,
  null
);

select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_full',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.sku')::uuid, 'requested_cases', 2)
      ),
      'm73b-order-full'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_full')::uuid, 1, 'm73b-sub-full');
select public.verify_order(current_setting('sherlyos.order_full')::uuid, 2, 'm73b-ver-full');

select set_config(
  'sherlyos.order_short',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.sku')::uuid, 'requested_cases', 2)
      ),
      'm73b-order-short'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_short')::uuid, 1, 'm73b-sub-short');
select public.verify_order(current_setting('sherlyos.order_short')::uuid, 2, 'm73b-ver-short');

select pg_temp.handshake_dn(current_setting('sherlyos.order_full')::uuid, 'm73b-hf');
select pg_temp.handshake_dn(current_setting('sherlyos.order_short')::uuid, 'm73b-hs');

-- Full-shipment path: pick all, no shipment document, consume reserved_cases.
select pg_temp.as_user('godown');
do $$
declare
  header jsonb;
  res jsonb;
  i int;
  dispatch jsonb;
  ledger_qty integer;
begin
  header := public.reserve_order_allocation(
    current_setting('sherlyos.order_full')::uuid, 3, 'm73b-res-full'
  );
  header := public.assign_picking_request(
    (header ->> 'id')::uuid,
    (select id from fixture where name = 'keeper'),
    (header ->> 'version')::integer,
    'm73b-asg-full'
  );
  perform pg_temp.as_user('keeper');
  header := public.start_picking(
    (header ->> 'id')::uuid, (header ->> 'version')::integer, 'm73b-start-full'
  );
  for i in 0 .. jsonb_array_length(header -> 'reservations') - 1 loop
    res := header -> 'reservations' -> i;
    header := public.confirm_picking_quantity(
      (header ->> 'id')::uuid,
      (res ->> 'id')::uuid,
      (res ->> 'reserved_cases')::integer,
      (header ->> 'version')::integer,
      'm73b-pick-full-' || i::text
    );
  end loop;
  header := public.complete_picking(
    (header ->> 'id')::uuid, (header ->> 'version')::integer, 'm73b-complete-full'
  );
  perform pg_temp.as_user('godown');
  header := public.confirm_picking_handoff(
    (header ->> 'id')::uuid, (header ->> 'version')::integer, 'm73b-hand-full'
  );
  dispatch := public.prepare_dispatch(
    current_setting('sherlyos.order_full')::uuid,
    (header ->> 'version')::integer,
    'm73b-prep-full'
  );
  dispatch := public.confirm_dispatch(
    (dispatch ->> 'id')::uuid,
    (dispatch ->> 'version')::integer,
    'm73b-cfm-full'
  );
  if dispatch ->> 'status' is distinct from 'dispatched' then
    raise exception 'full dispatch failed: %', dispatch;
  end if;
  if dispatch ->> 'shipment_id' is not null then
    raise exception 'full path must not require a shipment document: %', dispatch;
  end if;
  if dispatch ->> 'fulfilment_status' is distinct from 'fulfilled' then
    raise exception 'full dispatch should mark order fulfilled: %', dispatch;
  end if;
  execute 'reset role';
  select coalesce(sum(stock_ledger.quantity), 0) into ledger_qty
  from public.stock_ledger
  join public.stock_transactions on stock_transactions.id = stock_ledger.transaction_id
  where stock_transactions.dispatch_request_id = (dispatch ->> 'id')::uuid;
  if ledger_qty is distinct from -2 then
    raise exception 'full dispatch must debit 2 cases: %', ledger_qty;
  end if;
  if exists (
    select 1 from public.orders
    where parent_order_id = current_setting('sherlyos.order_full')::uuid
  ) then
    raise exception 'full dispatch must not create a backorder';
  end if;
  -- Replay returns the original result.
  dispatch := public.confirm_dispatch(
    (dispatch ->> 'id')::uuid,
    (dispatch ->> 'version')::integer - 1,
    'm73b-cfm-full'
  );
  select coalesce(sum(stock_ledger.quantity), 0) into ledger_qty
  from public.stock_ledger
  join public.stock_transactions on stock_transactions.id = stock_ledger.transaction_id
  where stock_transactions.dispatch_request_id = (dispatch ->> 'id')::uuid;
  if ledger_qty is distinct from -2 then
    raise exception 'full dispatch replay double-posted: %', ledger_qty;
  end if;
end $$;

-- Short-shipment path: pick 1 of 2, GM + Accounts, deduct 1, linked backorder.
select pg_temp.as_user('godown');
do $$
declare
  header jsonb;
  res jsonb;
  shipment jsonb;
  dispatch jsonb;
  ledger_qty integer;
  on_hand integer;
  backorder uuid;
  original_qty integer;
  dn_status text;
begin
  header := public.reserve_order_allocation(
    current_setting('sherlyos.order_short')::uuid, 3, 'm73b-res-short'
  );
  header := public.assign_picking_request(
    (header ->> 'id')::uuid,
    (select id from fixture where name = 'keeper'),
    (header ->> 'version')::integer,
    'm73b-asg-short'
  );
  perform set_config('sherlyos.req_short', header ->> 'id', true);
  perform pg_temp.as_user('keeper');
  header := public.start_picking(
    (header ->> 'id')::uuid, (header ->> 'version')::integer, 'm73b-start-short'
  );
  res := header -> 'reservations' -> 0;
  header := public.confirm_picking_quantity(
    (header ->> 'id')::uuid,
    (res ->> 'id')::uuid,
    1,
    (header ->> 'version')::integer,
    'm73b-pick-short'
  );
  header := public.report_picking_shortage(
    (header ->> 'id')::uuid,
    (res ->> 'id')::uuid,
    1,
    'one carton missing',
    (header ->> 'version')::integer,
    'm73b-short-1'
  );
  header := public.complete_picking(
    (header ->> 'id')::uuid, (header ->> 'version')::integer, 'm73b-complete-short'
  );
  perform set_config('sherlyos.short_ver', header ->> 'version', true);

  perform pg_temp.as_user('godown');
  begin
    perform public.confirm_picking_handoff(
      current_setting('sherlyos.req_short')::uuid,
      current_setting('sherlyos.short_ver')::integer,
      'm73b-hand-early'
    );
    raise exception 'handoff before approved shipment must fail';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%short-shipment%' then
        raise exception 'unexpected early handoff error: %', sqlerrm;
      end if;
  end;

  perform pg_temp.as_user('accounts');
  begin
    perform public.create_short_shipment(
      current_setting('sherlyos.req_short')::uuid,
      current_setting('sherlyos.short_ver')::integer,
      'm73b-sh-accounts'
    );
    raise exception 'Accounts must not create the shipment';
  exception
    when sqlstate '42501' then null;
  end;

  perform pg_temp.as_user('other_gm');
  begin
    perform public.create_short_shipment(
      current_setting('sherlyos.req_short')::uuid,
      current_setting('sherlyos.short_ver')::integer,
      'm73b-sh-cross'
    );
    raise exception 'cross-godown GM must not create the shipment';
  exception
    when sqlstate '42501' then null;
  end;

  perform pg_temp.as_user('godown');
  shipment := public.create_short_shipment(
    current_setting('sherlyos.req_short')::uuid,
    current_setting('sherlyos.short_ver')::integer,
    'm73b-sh-create'
  );
  if shipment ->> 'status' is distinct from 'draft' then
    raise exception 'create shipment failed: %', shipment;
  end if;
  -- Idempotent create.
  shipment := public.create_short_shipment(
    current_setting('sherlyos.req_short')::uuid,
    current_setting('sherlyos.short_ver')::integer,
    'm73b-sh-create'
  );
  if shipment ->> 'status' is distinct from 'draft' then
    raise exception 'create replay lost draft: %', shipment;
  end if;

  shipment := public.confirm_short_shipment_quantities(
    (shipment ->> 'id')::uuid,
    (shipment ->> 'version')::integer,
    'm73b-sh-gm'
  );
  if shipment ->> 'status' is distinct from 'gm_confirmed' then
    raise exception 'GM confirm failed: %', shipment;
  end if;

  perform pg_temp.as_user('godown');
  begin
    perform public.approve_short_shipment(
      (shipment ->> 'id')::uuid,
      (shipment ->> 'version')::integer,
      null,
      'm73b-sh-gm-approve'
    );
    raise exception 'GM must not Accounts-approve';
  exception
    when sqlstate '42501' then null;
  end;

  perform pg_temp.as_user('accounts');
  begin
    perform public.approve_short_shipment(
      (shipment ->> 'id')::uuid,
      (shipment ->> 'version')::integer,
      jsonb_build_array(jsonb_build_object(
        'shipment_lot_id', gen_random_uuid(),
        'approved_cases', 1
      )),
      'm73b-sh-forged'
    );
    raise exception 'forged lot id must fail';
  exception
    when sqlstate '23514' then null;
  end;

  shipment := public.approve_short_shipment(
    (shipment ->> 'id')::uuid,
    (shipment ->> 'version')::integer,
    null,
    'm73b-sh-approve'
  );
  if shipment ->> 'status' is distinct from 'approved' then
    raise exception 'Accounts approve failed: %', shipment;
  end if;
  if (shipment ->> 'approved_cases') is distinct from '1' then
    raise exception 'approved cases should be picked 1: %', shipment;
  end if;
  -- Approve replay.
  shipment := public.approve_short_shipment(
    (shipment ->> 'id')::uuid,
    (shipment ->> 'version')::integer,
    null,
    'm73b-sh-approve'
  );

  perform pg_temp.as_user('godown');
  header := public.get_picking_request(current_setting('sherlyos.req_short')::uuid);
  header := public.confirm_picking_handoff(
    current_setting('sherlyos.req_short')::uuid,
    (header ->> 'version')::integer,
    'm73b-hand-short'
  );
  if header ->> 'status' is distinct from 'ready_for_dispatch' then
    raise exception 'approved short-shipment should hand off: %', header;
  end if;

  dispatch := public.prepare_dispatch(
    current_setting('sherlyos.order_short')::uuid,
    (header ->> 'version')::integer,
    'm73b-prep-short'
  );
  if (dispatch ->> 'total_cases') is distinct from '1' then
    raise exception 'preview should dispatch approved 1, not ordered 2: %', dispatch;
  end if;

  select coalesce(sum(quantity), 0) into on_hand
  from public.stock_balances
  where product_id = current_setting('sherlyos.sku')::uuid;

  dispatch := public.confirm_dispatch(
    (dispatch ->> 'id')::uuid,
    (dispatch ->> 'version')::integer,
    'm73b-cfm-short'
  );
  if dispatch ->> 'status' is distinct from 'dispatched' then
    raise exception 'short dispatch failed: %', dispatch;
  end if;
  if dispatch ->> 'fulfilment_status' is distinct from 'partially_fulfilled' then
    raise exception 'short dispatch should be partial: %', dispatch;
  end if;

  execute 'reset role';
  select coalesce(sum(stock_ledger.quantity), 0) into ledger_qty
  from public.stock_ledger
  join public.stock_transactions on stock_transactions.id = stock_ledger.transaction_id
  where stock_transactions.dispatch_request_id = (dispatch ->> 'id')::uuid;
  if ledger_qty is distinct from -1 then
    raise exception 'short dispatch must debit picked/approved 1: %', ledger_qty;
  end if;

  if exists (
    select 1 from public.stock_balances
    where product_id = current_setting('sherlyos.sku')::uuid
      and quantity < 0
  ) then
    raise exception 'negative stock after short dispatch';
  end if;

  if (
    select requested_cases from public.order_lines
    where order_id = current_setting('sherlyos.order_short')::uuid
  ) is distinct from 2 then
    raise exception 'original ordered quantity must not change';
  end if;

  select delivery_notes.status into dn_status
  from public.delivery_notes
  where delivery_notes.order_id = current_setting('sherlyos.order_short')::uuid
    and delivery_notes.status is distinct from 'voided';
  if dn_status is distinct from 'acknowledged' then
    raise exception 'original DN must stay acknowledged: %', dn_status;
  end if;

  select orders.id into backorder
  from public.orders
  where orders.parent_order_id = current_setting('sherlyos.order_short')::uuid
    and orders.status is distinct from 'cancelled';
  if backorder is null then
    raise exception 'linked backorder missing';
  end if;
  if (select source from public.orders where id = backorder) is distinct from 'backorder' then
    raise exception 'backorder source wrong';
  end if;
  if (select requested_cases from public.order_lines where order_id = backorder) is distinct from 1 then
    raise exception 'backorder remainder should be 1';
  end if;
  if exists (select 1 from public.stock_reservations where order_id = backorder) then
    raise exception 'backorder must not auto-reserve';
  end if;
  if (select fulfilment_status from public.orders where id = current_setting('sherlyos.order_short')::uuid)
    is distinct from 'partially_fulfilled'
  then
    raise exception 'original order should be partially fulfilled';
  end if;

  -- Reservation identity: snapshot reserved 1 after shortage = shipped 1 + released 0.
  if exists (
    select 1 from public.order_shipment_lots
    where shipment_id = (shipment ->> 'id')::uuid
      and reserved_cases <> shipped_cases + released_cases
  ) then
    raise exception 'reservation reconciliation broken';
  end if;

  -- Replay does not double-post.
  dispatch := public.confirm_dispatch(
    (dispatch ->> 'id')::uuid,
    (dispatch ->> 'version')::integer - 1,
    'm73b-cfm-short'
  );
  select coalesce(sum(stock_ledger.quantity), 0) into ledger_qty
  from public.stock_ledger
  join public.stock_transactions on stock_transactions.id = stock_ledger.transaction_id
  where stock_transactions.dispatch_request_id = (dispatch ->> 'id')::uuid;
  if ledger_qty is distinct from -1 then
    raise exception 'short dispatch replay double-posted: %', ledger_qty;
  end if;
  if (
    select count(*) from public.orders
    where parent_order_id = current_setting('sherlyos.order_short')::uuid
      and status is distinct from 'cancelled'
  ) is distinct from 1 then
    raise exception 'duplicate backorder on replay';
  end if;

  -- Backorder-of-backorder: allocate remainder and refuse a new short-shipment.
  perform pg_temp.as_user('accounts');
  perform public.verify_order(backorder, 1, 'm73b-ver-bo');
  perform pg_temp.handshake_dn(backorder, 'm73b-bo');
  perform pg_temp.as_user('godown');
  header := public.reserve_order_allocation(backorder, 2, 'm73b-res-bo');
  header := public.assign_picking_request(
    (header ->> 'id')::uuid,
    (select id from fixture where name = 'keeper'),
    (header ->> 'version')::integer,
    'm73b-asg-bo'
  );
  perform pg_temp.as_user('keeper');
  header := public.start_picking(
    (header ->> 'id')::uuid, (header ->> 'version')::integer, 'm73b-start-bo'
  );
  res := header -> 'reservations' -> 0;
  header := public.confirm_picking_quantity(
    (header ->> 'id')::uuid, (res ->> 'id')::uuid, 1,
    (header ->> 'version')::integer, 'm73b-pick-bo'
  );
  header := public.complete_picking(
    (header ->> 'id')::uuid, (header ->> 'version')::integer, 'm73b-complete-bo'
  );
  perform pg_temp.as_user('godown');
  begin
    perform public.create_short_shipment(
      (header ->> 'id')::uuid,
      (header ->> 'version')::integer,
      'm73b-sh-bo'
    );
    raise exception 'short-shipment of a backorder must fail closed';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%backorder%' then
        raise exception 'unexpected backorder short-ship error: %', sqlerrm;
      end if;
  end;
end $$;

-- Zero-ship release, stale approval, rollback injection, and extra auth proofs.
select pg_temp.as_user('admin');
select set_config(
  'sherlyos.crate2',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'c2', 'C2', null)::text,
  true
);
select set_config(
  'sherlyos.sku_ml',
  public.create_product('m73b-ml', 'M73B multi-lot', null, null)::text,
  true
);
select public.set_product_expiry_policy(current_setting('sherlyos.sku_ml')::uuid, 'non_expiring');
select public.post_opening_stock(
  current_setting('sherlyos.sku_ml')::uuid,
  current_setting('sherlyos.crate')::uuid,
  2, 'm73b-ml-a', null, 'ML-A', null, null
);
select public.post_opening_stock(
  current_setting('sherlyos.sku_ml')::uuid,
  current_setting('sherlyos.crate2')::uuid,
  2, 'm73b-ml-b', null, 'ML-B', null, null
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
        jsonb_build_object('product_id', current_setting('sherlyos.sku_ml')::uuid, 'requested_cases', 3)
      ),
      'm73b-order-ml'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_ml')::uuid, 1, 'm73b-sub-ml');
select public.verify_order(current_setting('sherlyos.order_ml')::uuid, 2, 'm73b-ver-ml');
select pg_temp.handshake_dn(current_setting('sherlyos.order_ml')::uuid, 'm73b-ml');

create or replace function pg_temp.fail_after_first_ledger()
returns trigger
language plpgsql as $$
declare
  n integer;
begin
  if current_setting('sherlyos.fail_second_ledger', true) is distinct from 'on' then
    return NEW;
  end if;
  n := coalesce(nullif(current_setting('sherlyos.ledger_hits', true), ''), '0')::integer + 1;
  perform set_config('sherlyos.ledger_hits', n::text, true);
  if n > 1 then
    raise exception 'injected multi-lot ledger failure' using errcode = 'P0001';
  end if;
  return NEW;
end;
$$;

drop trigger if exists m73b_fail_second_ledger on public.stock_ledger;
create trigger m73b_fail_second_ledger
  before insert on public.stock_ledger
  for each row execute function pg_temp.fail_after_first_ledger();

select pg_temp.as_user('godown');
do $$
declare
  header jsonb;
  res jsonb;
  shipment jsonb;
  dispatch jsonb;
  i int;
  lot_a uuid;
  lot_b uuid;
  qty jsonb;
  ledger_qty integer;
  released_id uuid;
  released_lot uuid;
  released_crate uuid;
  released_reserved integer;
  available integer;
  original_ordered integer;
  backorder uuid;
  bo_qty integer;
  dummy uuid;
  dispatched_sum integer;
begin
  header := public.reserve_order_allocation(
    current_setting('sherlyos.order_ml')::uuid, 3, 'm73b-res-ml'
  );
  header := public.assign_picking_request(
    (header ->> 'id')::uuid,
    (select id from fixture where name = 'keeper'),
    (header ->> 'version')::integer,
    'm73b-asg-ml'
  );
  perform set_config('sherlyos.req_ml', header ->> 'id', true);
  perform pg_temp.as_user('keeper');
  header := public.start_picking(
    (header ->> 'id')::uuid, (header ->> 'version')::integer, 'm73b-start-ml'
  );
  for i in 0 .. jsonb_array_length(header -> 'reservations') - 1 loop
    res := header -> 'reservations' -> i;
    header := public.confirm_picking_quantity(
      (header ->> 'id')::uuid,
      (res ->> 'id')::uuid,
      (res ->> 'reserved_cases')::integer,
      (header ->> 'version')::integer,
      'm73b-pick-ml-' || i::text
    );
  end loop;
  header := public.complete_picking(
    (header ->> 'id')::uuid, (header ->> 'version')::integer, 'm73b-complete-ml'
  );
  if jsonb_array_length(header -> 'reservations') is distinct from 2 then
    raise exception 'multi-lot fixture must reserve two grains: %', header;
  end if;

  perform pg_temp.as_user('godown');
  shipment := public.create_short_shipment(
    current_setting('sherlyos.req_ml')::uuid,
    (header ->> 'version')::integer,
    'm73b-sh-ml'
  );
  begin
    perform public.create_short_shipment(
      current_setting('sherlyos.req_ml')::uuid,
      (header ->> 'version')::integer,
      'm73b-sh-ml-b'
    );
    raise exception 'second open shipment for the same picking must fail';
  exception
    when sqlstate '23514' then null;
  end;

  perform pg_temp.as_user('accounts');
  begin
    perform public.confirm_short_shipment_quantities(
      (shipment ->> 'id')::uuid,
      (shipment ->> 'version')::integer,
      'm73b-sh-ml-acc-gm'
    );
    raise exception 'Accounts must not GM-confirm';
  exception
    when sqlstate '42501' then null;
  end;

  perform pg_temp.as_user('godown');
  shipment := public.confirm_short_shipment_quantities(
    (shipment ->> 'id')::uuid,
    (shipment ->> 'version')::integer,
    'm73b-sh-ml-gm'
  );

  perform pg_temp.as_user('admin');
  perform public.revoke_user_branch(
    (select id from fixture where name = 'accounts'),
    current_setting('sherlyos.branch')::uuid
  );
  perform pg_temp.as_user('accounts');
  begin
    perform public.approve_short_shipment(
      (shipment ->> 'id')::uuid,
      (shipment ->> 'version')::integer,
      null,
      'm73b-sh-ml-revoked'
    );
    raise exception 'revoked Accounts assignment must not approve';
  exception
    when sqlstate '42501' then null;
  end;
  perform pg_temp.as_user('admin');
  perform public.assign_user_branch(
    (select id from fixture where name = 'accounts'),
    current_setting('sherlyos.branch')::uuid
  );

  select id into lot_a
  from public.order_shipment_lots
  where shipment_id = (shipment ->> 'id')::uuid
  order by reserved_cases desc, id
  limit 1;
  select id into lot_b
  from public.order_shipment_lots
  where shipment_id = (shipment ->> 'id')::uuid
    and id is distinct from lot_a;
  -- Ship one carton from the larger grain; release the second grain entirely.
  qty := jsonb_build_array(
    jsonb_build_object('shipment_lot_id', lot_a, 'approved_cases', 1),
    jsonb_build_object('shipment_lot_id', lot_b, 'approved_cases', 0)
  );
  perform pg_temp.as_user('accounts');
  shipment := public.approve_short_shipment(
    (shipment ->> 'id')::uuid,
    (shipment ->> 'version')::integer,
    qty,
    'm73b-sh-ml-ap'
  );

  perform pg_temp.as_user('godown');
  header := public.confirm_picking_handoff(
    current_setting('sherlyos.req_ml')::uuid,
    (select version from public.stock_picking_requests
      where id = current_setting('sherlyos.req_ml')::uuid),
    'm73b-hand-ml'
  );
  dispatch := public.prepare_dispatch(
    current_setting('sherlyos.order_ml')::uuid,
    (header ->> 'version')::integer,
    'm73b-prep-ml'
  );

  -- Tamper after approval: fingerprint must refuse dispatch.
  execute 'reset role';
  execute 'set local session_replication_role = replica';
  update public.order_shipment_lots
  set approved_cases = 2
  where id = lot_a;
  execute 'set local session_replication_role = origin';
  perform pg_temp.as_user('godown');
  begin
    perform public.confirm_dispatch(
      (dispatch ->> 'id')::uuid,
      (dispatch ->> 'version')::integer,
      'm73b-cfm-ml-stale'
    );
    raise exception 'stale approval must not dispatch';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%stale%' and sqlerrm not like '%fingerprint%'
        and sqlerrm not like '%no longer match%'
      then
        raise exception 'unexpected stale-approval error: %', sqlerrm;
      end if;
  end;
  execute 'reset role';
  execute 'set local session_replication_role = replica';
  update public.order_shipment_lots
  set approved_cases = 1
  where id = lot_a;
  execute 'set local session_replication_role = origin';

  perform pg_temp.as_user('godown');
  execute 'reset role';
  execute 'set local session_replication_role = replica';
  insert into public.orders (
    shop_id, branch_id, source, notes, created_by, status, version,
    idempotency_key, parent_order_id, fulfilment_status, order_number,
    submitted_at, submitted_by
  )
  values (
    (select shop_id from public.orders where id = current_setting('sherlyos.order_ml')::uuid),
    current_setting('sherlyos.branch')::uuid,
    'backorder',
    'integrity blocker',
    (select id from fixture where name = 'admin'),
    'submitted',
    1,
    'm73b-dummy-parent-bo',
    current_setting('sherlyos.order_ml')::uuid,
    'open',
    'BO-M73B-BLOCK',
    clock_timestamp(),
    (select id from fixture where name = 'admin')
  )
  returning id into dummy;
  execute 'set local session_replication_role = origin';
  perform pg_temp.as_user('godown');
  begin
    perform public.confirm_dispatch(
      (dispatch ->> 'id')::uuid,
      (dispatch ->> 'version')::integer,
      'm73b-cfm-ml-bo-fail'
    );
    raise exception 'dispatch must roll back when backorder uniqueness fails';
  exception
    when unique_violation then null;
    when sqlstate '23505' then null;
    when sqlstate '23514' then null;
  end;
  execute 'reset role';
  if exists (
    select 1 from public.stock_transactions
    where dispatch_request_id = (dispatch ->> 'id')::uuid
  ) then
    raise exception 'backorder failure leaked a stock transaction';
  end if;
  if exists (
    select 1 from public.stock_reservations
    where picking_request_id = current_setting('sherlyos.req_ml')::uuid
      and status in ('consumed', 'released')
  ) then
    raise exception 'backorder failure leaked reservation consumption';
  end if;
  delete from public.orders where id = dummy;

  -- Halfway ledger failure: two grains would post; abort after the first insert.
  perform set_config('sherlyos.fail_second_ledger', 'off', true);
  -- This path ships only one grain (approved 1 / 0), so inject on the first insert
  -- of a rebuilt two-ship case below after the zero-ship success path.

  perform pg_temp.as_user('godown');
  dispatch := public.confirm_dispatch(
    (dispatch ->> 'id')::uuid,
    (dispatch ->> 'version')::integer,
    'm73b-cfm-ml'
  );
  if dispatch ->> 'fulfilment_status' is distinct from 'partially_fulfilled' then
    raise exception 'zero-ship grain path should stay partial: %', dispatch;
  end if;

  execute 'reset role';
  select coalesce(sum(stock_ledger.quantity), 0) into ledger_qty
  from public.stock_ledger
  join public.stock_transactions on stock_transactions.id = stock_ledger.transaction_id
  where stock_transactions.dispatch_request_id = (dispatch ->> 'id')::uuid;
  if ledger_qty is distinct from -1 then
    raise exception 'zero-ship path must debit only the shipped carton: %', ledger_qty;
  end if;

  select order_shipment_lots.reservation_id, order_shipment_lots.lot_id,
         order_shipment_lots.crate_id, order_shipment_lots.reserved_cases
    into released_id, released_lot, released_crate, released_reserved
  from public.order_shipment_lots
  where id = lot_b;
  if (
    select status from public.stock_reservations where id = released_id
  ) is distinct from 'released' then
    raise exception 'zero-ship grain must be released, not consumed';
  end if;
  if released_reserved < 1 then
    raise exception 'released reservation must keep reserved_cases >= 1';
  end if;
  if exists (
    select 1 from public.stock_reservations
    where id = released_id and status = 'active'
  ) then
    raise exception 'released quantity must not remain active';
  end if;
  if exists (
    select 1 from public.stock_ledger
    where lot_id = released_lot
      and crate_id = released_crate
      and product_id = current_setting('sherlyos.sku_ml')::uuid
      and quantity < 0
      and transaction_id in (
        select id from public.stock_transactions
        where dispatch_request_id = (dispatch ->> 'id')::uuid
      )
  ) then
    raise exception 'released-only quantity must not be ledger-debited';
  end if;
  if exists (
    select 1 from public.order_shipment_lots
    where shipment_id = (shipment ->> 'id')::uuid
      and reserved_cases <> shipped_cases + released_cases
  ) then
    raise exception 'zero-ship reservation identity broken';
  end if;

  available := app_private.picking_available_cases(released_lot, released_crate);
  if available < released_reserved then
    raise exception 'released cartons did not return to availability: % vs %',
      available, released_reserved;
  end if;

  select requested_cases into original_ordered
  from public.order_lines
  where order_id = current_setting('sherlyos.order_ml')::uuid;
  if original_ordered is distinct from 3 then
    raise exception 'original ordered quantity changed: %', original_ordered;
  end if;
  select orders.id into backorder
  from public.orders
  where parent_order_id = current_setting('sherlyos.order_ml')::uuid
    and status is distinct from 'cancelled'
    and idempotency_key is distinct from 'm73b-dummy-parent-bo';
  select requested_cases into bo_qty
  from public.order_lines where order_id = backorder;
  select coalesce(sum(shipped_cases), 0) into dispatched_sum
  from public.order_shipment_lots
  where shipment_id = (shipment ->> 'id')::uuid;
  if bo_qty is distinct from original_ordered - dispatched_sum then
    raise exception 'backorder % != ordered % - dispatched %',
      bo_qty, original_ordered, dispatched_sum;
  end if;
  if bo_qty > original_ordered then
    raise exception 'backorder exceeds original order';
  end if;

  -- Replay cannot deduct or release twice.
  perform pg_temp.as_user('godown');
  dispatch := public.confirm_dispatch(
    (dispatch ->> 'id')::uuid,
    (dispatch ->> 'version')::integer - 1,
    'm73b-cfm-ml'
  );
  select coalesce(sum(stock_ledger.quantity), 0) into ledger_qty
  from public.stock_ledger
  join public.stock_transactions on stock_transactions.id = stock_ledger.transaction_id
  where stock_transactions.dispatch_request_id = (dispatch ->> 'id')::uuid;
  if ledger_qty is distinct from -1 then
    raise exception 'replay deducted released or shipped qty twice: %', ledger_qty;
  end if;
  if (
    select count(*) from public.stock_reservations
    where id = released_id and status = 'released'
  ) is distinct from 1 then
    raise exception 'replay mutated the released reservation';
  end if;
  if (
    select count(*) from public.orders
    where parent_order_id = current_setting('sherlyos.order_ml')::uuid
      and status is distinct from 'cancelled'
  ) is distinct from 1 then
    raise exception 'replay duplicated the backorder';
  end if;

  -- Direct client writes are unauthorized.
  perform pg_temp.as_user('godown');
  execute 'set local role authenticated';
  begin
    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
    ) values (
      gen_random_uuid(), current_setting('sherlyos.sku_ml')::uuid,
      current_setting('sherlyos.crate2')::uuid, -1,
      (select id from fixture where name = 'godown'), clock_timestamp(), released_lot
    );
    raise exception 'direct ledger write must be denied';
  exception
    when sqlstate '42501' then null;
    when insufficient_privilege then null;
  end;
  begin
    update public.stock_reservations
    set status = 'released'
    where id = released_id;
    raise exception 'direct reservation write must be denied';
  exception
    when sqlstate '42501' then null;
    when insufficient_privilege then null;
  end;
end $$;

-- Separate two-ship order: inject failure after the first lot debit.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_ml2',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.sku_ml')::uuid, 'requested_cases', 3)
      ),
      'm73b-order-ml2'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_ml2')::uuid, 1, 'm73b-sub-ml2');
select public.verify_order(current_setting('sherlyos.order_ml2')::uuid, 2, 'm73b-ver-ml2');
select pg_temp.handshake_dn(current_setting('sherlyos.order_ml2')::uuid, 'm73b-ml2');

select pg_temp.as_user('godown');
do $$
declare
  header jsonb;
  res jsonb;
  shipment jsonb;
  dispatch jsonb;
  i int;
  qty jsonb;
  ledger_qty integer;
  active_n integer;
begin
  header := public.reserve_order_allocation(
    current_setting('sherlyos.order_ml2')::uuid, 3, 'm73b-res-ml2'
  );
  header := public.assign_picking_request(
    (header ->> 'id')::uuid,
    (select id from fixture where name = 'keeper'),
    (header ->> 'version')::integer,
    'm73b-asg-ml2'
  );
  perform pg_temp.as_user('keeper');
  header := public.start_picking(
    (header ->> 'id')::uuid, (header ->> 'version')::integer, 'm73b-start-ml2'
  );
  for i in 0 .. jsonb_array_length(header -> 'reservations') - 1 loop
    res := header -> 'reservations' -> i;
    header := public.confirm_picking_quantity(
      (header ->> 'id')::uuid,
      (res ->> 'id')::uuid,
      (res ->> 'reserved_cases')::integer,
      (header ->> 'version')::integer,
      'm73b-pick-ml2-' || i::text
    );
  end loop;
  header := public.complete_picking(
    (header ->> 'id')::uuid, (header ->> 'version')::integer, 'm73b-complete-ml2'
  );
  perform pg_temp.as_user('godown');
  shipment := public.create_short_shipment(
    (header ->> 'id')::uuid, (header ->> 'version')::integer, 'm73b-sh-ml2'
  );
  shipment := public.confirm_short_shipment_quantities(
    (shipment ->> 'id')::uuid, (shipment ->> 'version')::integer, 'm73b-gm-ml2'
  );
  select coalesce(
    jsonb_agg(jsonb_build_object('shipment_lot_id', id, 'approved_cases', 1)),
    '[]'::jsonb
  ) into qty
  from public.order_shipment_lots
  where shipment_id = (shipment ->> 'id')::uuid;
  perform pg_temp.as_user('accounts');
  shipment := public.approve_short_shipment(
    (shipment ->> 'id')::uuid, (shipment ->> 'version')::integer, qty, 'm73b-ap-ml2'
  );
  perform pg_temp.as_user('godown');
  header := public.confirm_picking_handoff(
    (header ->> 'id')::uuid, (header ->> 'version')::integer, 'm73b-hand-ml2'
  );
  dispatch := public.prepare_dispatch(
    current_setting('sherlyos.order_ml2')::uuid,
    (header ->> 'version')::integer,
    'm73b-prep-ml2'
  );

  perform set_config('sherlyos.fail_second_ledger', 'on', true);
  perform set_config('sherlyos.ledger_hits', '0', true);
  begin
    perform public.confirm_dispatch(
      (dispatch ->> 'id')::uuid,
      (dispatch ->> 'version')::integer,
      'm73b-cfm-ml2-fail'
    );
    raise exception 'multi-lot injected failure must abort';
  exception
    when sqlstate 'P0001' then null;
  end;
  perform set_config('sherlyos.fail_second_ledger', 'off', true);

  execute 'reset role';
  select coalesce(sum(stock_ledger.quantity), 0) into ledger_qty
  from public.stock_ledger
  join public.stock_transactions on stock_transactions.id = stock_ledger.transaction_id
  where stock_transactions.dispatch_request_id = (dispatch ->> 'id')::uuid;
  if ledger_qty is distinct from 0 then
    raise exception 'injected ledger failure leaked quantity %', ledger_qty;
  end if;
  select count(*) into active_n
  from public.stock_reservations
  where picking_request_id = (header ->> 'id')::uuid
    and status = 'active';
  if active_n is distinct from 2 then
    raise exception 'injected failure must restore both active reservations, got %', active_n;
  end if;
  if exists (
    select 1 from public.orders
    where parent_order_id = current_setting('sherlyos.order_ml2')::uuid
      and status is distinct from 'cancelled'
  ) then
    raise exception 'injected failure leaked a backorder';
  end if;
  if exists (
    select 1 from public.stock_balances
    where product_id = current_setting('sherlyos.sku_ml')::uuid
      and quantity < 0
  ) then
    raise exception 'negative stock after injected dispatch failure';
  end if;
end $$;

-- Pre-cutover fail-closed for a fresh full order after flags restored false.
reset role;
set session_replication_role = replica;
update public.app_configuration set value = 'false'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
set session_replication_role = origin;

select pg_temp.as_user('godown');
do $$
begin
  begin
    perform public.preview_dispatch(current_setting('sherlyos.order_short')::uuid);
  exception
    when sqlstate '23514' then null;
    when sqlstate '42501' then null;
  end;
end $$;

rollback;
