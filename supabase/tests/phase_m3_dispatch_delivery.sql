-- M3 local disposable SQL. Rolls back. Does not touch development cloud.
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
  fixture.name || '.m3ds@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M3 Admin', true)
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
  if header ->> 'status' is distinct from 'ready_for_dispatch' then
    raise exception 'handoff failed for %', prefix;
  end if;
  return request_id;
end;
$$;

select pg_temp.as_user('admin');
set local role authenticated;
select set_config('sherlyos.branch', public.create_branch('m3ds_a', 'M3DS A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('m3ds_b', 'M3DS B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'driver'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'other'), current_setting('sherlyos.branch_b')::uuid);
select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'z1', 'Z1', null)::text, true);
select set_config('sherlyos.crate', public.create_crate(current_setting('sherlyos.zone')::uuid, 'c1', 'C1', null)::text, true);
select set_config('sherlyos.exp', public.create_product('m3ds-exp', 'M3DS Expiry', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.exp')::uuid, 'expiry_controlled');
select set_config('sherlyos.shop', public.create_shop('M3DS shop', null, null)::text, true);

-- Cutover disabled: dispatch preview fail-closed
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_closed',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.exp')::uuid, 'requested_cases', 2)
      ),
      'm3ds-order-closed'
    ) -> 'order' ->> 'id'
  ),
  true
);
select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
begin
  preview := public.preview_dispatch(current_setting('sherlyos.order_closed')::uuid);
  if preview ->> 'eligible' is distinct from 'false' then
    raise exception 'dispatch must fail closed without dual-write: %', preview;
  end if;
  if coalesce(preview -> 'blockers' ->> 0, '') not like '%dual-write%' then
    raise exception 'expected dual-write blocker, got %', preview -> 'blockers';
  end if;
end $$;

reset role;
-- Replica: operational dispatch proofs, not the unmatched-grain enable trigger.
set session_replication_role = replica;
update public.app_configuration set value = 'true'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
set session_replication_role = origin;

select pg_temp.as_user('admin');
set local role authenticated;
select public.post_opening_stock(
  current_setting('sherlyos.exp')::uuid, current_setting('sherlyos.crate')::uuid,
  10, 'm3ds-open-exp', null, 'M3-BATCH', null, '2028-06-01'
);

select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.exp')::uuid, 'requested_cases', 3)
      ),
      'm3ds-order-1'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order')::uuid, 1, 'm3ds-sub-1');
select public.verify_order(current_setting('sherlyos.order')::uuid, 2, 'm3ds-ver-1');

-- Delivery note paperwork does not authorize dispatch
select set_config(
  'sherlyos.note',
  (public.create_delivery_note(current_setting('sherlyos.order')::uuid, 'm3ds-dn-1') -> 'delivery_note' ->> 'id'),
  true
);

select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
begin
  preview := public.preview_dispatch(current_setting('sherlyos.order')::uuid);
  if preview ->> 'eligible' is distinct from 'false' then
    raise exception 'DN must not make dispatch eligible without picking handoff: %', preview;
  end if;
end $$;

select set_config('sherlyos.request', pg_temp.handoff(current_setting('sherlyos.order')::uuid, 'm3ds1')::text, true);

-- Store keeper cannot confirm dispatch
select pg_temp.as_user('keeper');
do $$
begin
  begin
    perform public.prepare_dispatch(current_setting('sherlyos.order')::uuid, 5, 'm3ds-bad-keeper');
    raise exception 'store keeper must not prepare dispatch';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Cross-branch manager cannot dispatch
select pg_temp.as_user('other');
do $$
begin
  begin
    perform public.preview_dispatch(current_setting('sherlyos.order')::uuid);
    raise exception 'cross-branch manager must not preview dispatch';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Anonymous denied
reset role;
set local role anon;
do $$
begin
  begin
    perform public.list_dispatch_queue(null);
    raise exception 'anonymous must not list dispatch';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

select pg_temp.as_user('godown');
set local role authenticated;

-- Invalid picking state already covered by missing handoff before pick.
-- Successful prepare + confirm
do $$
declare
  preview jsonb;
  prepared jsonb;
  replay_prep jsonb;
  confirmed jsonb;
  replay jsonb;
  header jsonb;
  opening integer;
  remaining integer;
  reserved_active integer;
  txn_count integer;
begin
  preview := public.preview_dispatch(current_setting('sherlyos.order')::uuid);
  if preview ->> 'eligible' is distinct from 'true' then
    raise exception 'ready handoff should be eligible: %', preview;
  end if;
  if preview ->> 'delivery_note_id' is null then
    raise exception 'existing delivery note should be linked in preview';
  end if;

  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order')::uuid,
    (preview ->> 'picking_version')::integer,
    'm3ds-prep-1'
  );
  if prepared ->> 'status' is distinct from 'preparing' then
    raise exception 'prepare should create preparing dispatch';
  end if;
  if prepared ->> 'stock_consumed' is distinct from 'false' then
    raise exception 'prepare must not consume stock';
  end if;
  if prepared ->> 'delivery_note_id' is distinct from current_setting('sherlyos.note') then
    raise exception 'dispatch should link existing delivery note';
  end if;

  replay_prep := public.prepare_dispatch(
    current_setting('sherlyos.order')::uuid,
    (preview ->> 'picking_version')::integer,
    'm3ds-prep-1'
  );
  if replay_prep ->> 'id' is distinct from prepared ->> 'id' then
    raise exception 'prepare replay must return the same document';
  end if;

  select quantity into opening
  from public.stock_balances
  where crate_id = current_setting('sherlyos.crate')::uuid
    and product_id = current_setting('sherlyos.exp')::uuid;

  confirmed := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm3ds-cfm-1'
  );
  if confirmed ->> 'status' is distinct from 'dispatched' then
    raise exception 'confirm should dispatch: %', confirmed;
  end if;
  if confirmed ->> 'stock_consumed' is distinct from 'true' then
    raise exception 'confirm must consume stock';
  end if;

  replay := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm3ds-cfm-1'
  );
  if replay ->> 'id' is distinct from confirmed ->> 'id'
    or replay ->> 'posted_transaction_id' is distinct from confirmed ->> 'posted_transaction_id'
  then
    raise exception 'confirm replay must return the original consumption';
  end if;

  replay := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, 999, 'm3ds-cfm-other'
  );
  if replay ->> 'posted_transaction_id' is distinct from confirmed ->> 'posted_transaction_id' then
    raise exception 'duplicate confirm key must not post a second ledger';
  end if;

  select quantity into remaining
  from public.stock_balances
  where crate_id = current_setting('sherlyos.crate')::uuid
    and product_id = current_setting('sherlyos.exp')::uuid;
  if remaining is distinct from opening - 3 then
    raise exception 'aggregate stock was not reduced by 3 (from % to %)', opening, remaining;
  end if;

  select count(*) into reserved_active
  from public.stock_reservations
  where picking_request_id = current_setting('sherlyos.request')::uuid
    and status = 'active';
  if reserved_active <> 0 then
    raise exception 'reservations must be consumed';
  end if;

  select count(*) into txn_count
  from public.stock_transactions
  where dispatch_request_id = (confirmed ->> 'id')::uuid
    and transaction_type = 'DISPATCH';
  if txn_count <> 1 then
    raise exception 'exactly one DISPATCH transaction is required, got %', txn_count;
  end if;

  if exists (
    select 1 from public.stock_ledger
    where transaction_id = (confirmed ->> 'posted_transaction_id')::uuid
      and quantity >= 0
  ) then
    raise exception 'dispatch ledger rows must be negative';
  end if;

  if confirmed ->> 'order_status' is distinct from 'verified' then
    raise exception 'order status must stay verified after dispatch';
  end if;

  perform set_config('sherlyos.dispatch', confirmed ->> 'id', true);
  perform set_config('sherlyos.dispatch_version', confirmed ->> 'version', true);
end $$;

-- Same prepare key with a different order must fail
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_b',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.exp')::uuid, 'requested_cases', 1)
      ),
      'm3ds-order-2'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_b')::uuid, 1, 'm3ds-sub-2');
select public.verify_order(current_setting('sherlyos.order_b')::uuid, 2, 'm3ds-ver-2');
select set_config('sherlyos.request_b', pg_temp.handoff(current_setting('sherlyos.order_b')::uuid, 'm3ds2')::text, true);

select pg_temp.as_user('godown');
do $$
begin
  begin
    perform public.prepare_dispatch(current_setting('sherlyos.order_b')::uuid, 5, 'm3ds-prep-1');
    raise exception 'same key with different order must fail';
  exception
    when sqlstate '23505' then null;
  end;
end $$;

-- Direct authenticated DML denied
do $$
begin
  begin
    update public.stock_dispatch_requests
    set status = 'delivered'
    where id = current_setting('sherlyos.dispatch')::uuid;
    raise exception 'direct dispatch update must fail';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Private helper stays revoked
do $$
begin
  begin
    perform app_private.assert_picking_handoff_for_dispatch(current_setting('sherlyos.order')::uuid);
    raise exception 'private handoff helper must not be executable';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Delivery assignment + POD + failed delivery on a second consumed dispatch
do $$
declare
  preview jsonb;
  prepared jsonb;
  confirmed jsonb;
  assigned jsonb;
  started jsonb;
  delivered jsonb;
  exceptioned jsonb;
  note_status text;
  remaining_after integer;
  remaining_before integer;
begin
  preview := public.preview_dispatch(current_setting('sherlyos.order_b')::uuid);
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_b')::uuid,
    (preview ->> 'picking_version')::integer,
    'm3ds-prep-2'
  );
  confirmed := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm3ds-cfm-2'
  );

  begin
    perform public.assign_dispatch_delivery(
      (confirmed ->> 'id')::uuid,
      (select id from fixture where name = 'keeper'),
      (confirmed ->> 'version')::integer,
      'm3ds-asg-bad'
    );
    raise exception 'store keeper must not be assignable as delivery personnel';
  exception
    when sqlstate '23514' then null;
  end;

  assigned := public.assign_dispatch_delivery(
    (confirmed ->> 'id')::uuid,
    (select id from fixture where name = 'driver'),
    (confirmed ->> 'version')::integer,
    'm3ds-asg-1'
  );
  if assigned ->> 'assigned_to' is distinct from (select id::text from fixture where name = 'driver') then
    raise exception 'assignment did not stick';
  end if;

  perform pg_temp.as_user('driver');
  started := public.start_dispatch_delivery(
    (confirmed ->> 'id')::uuid, (assigned ->> 'version')::integer, 'm3ds-go-1'
  );
  if started ->> 'status' is distinct from 'in_transit' then
    raise exception 'start should mark in_transit';
  end if;

  delivered := public.acknowledge_dispatch_delivery(
    (confirmed ->> 'id')::uuid, 'Shop keeper', 'left at counter',
    (started ->> 'version')::integer, 'm3ds-pod-1'
  );
  if delivered ->> 'status' is distinct from 'delivered' then
    raise exception 'POD should mark delivered';
  end if;
  if delivered ->> 'order_status' is distinct from 'verified' then
    raise exception 'POD must not change order status';
  end if;

  perform pg_temp.as_user('godown');
  select status into note_status
  from public.delivery_notes
  where id = current_setting('sherlyos.note')::uuid;
  -- Handshake acknowledges the note before picking; dispatch must leave that
  -- paperwork status unchanged.
  if note_status is distinct from 'acknowledged' then
    raise exception 'dispatch must not mutate delivery-note paperwork status, got %', note_status;
  end if;

  -- Failed delivery on the first dispatch (already consumed). Stock must not return.
  perform pg_temp.as_user('godown');
  select quantity into remaining_before
  from public.stock_balances
  where crate_id = current_setting('sherlyos.crate')::uuid
    and product_id = current_setting('sherlyos.exp')::uuid;

  exceptioned := public.report_dispatch_delivery_exception(
    current_setting('sherlyos.dispatch')::uuid,
    'customer refused delivery',
    current_setting('sherlyos.dispatch_version')::integer,
    'm3ds-fail-1'
  );
  if exceptioned ->> 'status' is distinct from 'exception' then
    raise exception 'failed delivery should record exception';
  end if;
  if exceptioned ->> 'physical_return_status' is distinct from 'pending_verification' then
    raise exception 'failed delivery must mark physical return pending';
  end if;

  select quantity into remaining_after
  from public.stock_balances
  where crate_id = current_setting('sherlyos.crate')::uuid
    and product_id = current_setting('sherlyos.exp')::uuid;
  if remaining_after is distinct from remaining_before then
    raise exception 'failed delivery must not restore inventory';
  end if;
end $$;

-- Cancellation fixture, then injected ledger failure must roll the whole confirm back.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_c',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.exp')::uuid, 'requested_cases', 1)
      ),
      'm3ds-order-3'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_c')::uuid, 1, 'm3ds-sub-3');
select public.verify_order(current_setting('sherlyos.order_c')::uuid, 2, 'm3ds-ver-3');
select set_config('sherlyos.request_c', pg_temp.handoff(current_setting('sherlyos.order_c')::uuid, 'm3ds3')::text, true);

reset role;
select set_config('request.jwt.claims', '', true);

create function pg_temp.inject_dispatch_ledger_failure()
returns trigger
language plpgsql
as $$
begin
  if new.quantity < 0 then
    raise exception 'injected dispatch ledger failure' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create constraint trigger m3ds_inject_dispatch_failure
after insert on public.stock_ledger
deferrable initially immediate
for each row
execute function pg_temp.inject_dispatch_ledger_failure();

select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
  prepared jsonb;
  active_holds integer;
  consumed_holds integer;
  txn_count integer;
begin
  preview := public.preview_dispatch(current_setting('sherlyos.order_c')::uuid);
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_c')::uuid,
    (preview ->> 'picking_version')::integer,
    'm3ds-prep-3'
  );
  perform set_config('sherlyos.dispatch_c', prepared ->> 'id', true);
  perform set_config('sherlyos.dispatch_c_ver', prepared ->> 'version', true);
  begin
    perform public.confirm_dispatch(
      (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm3ds-cfm-inject'
    );
    -- Distinct from the injected P0001 so a successful confirm cannot be mistaken for rollback.
    raise exception 'injected ledger failure must abort confirm_dispatch' using errcode = 'XX001';
  exception
    when sqlstate 'P0001' then
      if sqlerrm not like 'injected dispatch ledger failure%' then
        raise;
      end if;
  end;

  select count(*) into active_holds
  from public.stock_reservations
  where picking_request_id = current_setting('sherlyos.request_c')::uuid
    and status = 'active';
  select count(*) into consumed_holds
  from public.stock_reservations
  where picking_request_id = current_setting('sherlyos.request_c')::uuid
    and status = 'consumed';
  select count(*) into txn_count
  from public.stock_transactions
  where dispatch_request_id = (prepared ->> 'id')::uuid;

  if active_holds < 1 or consumed_holds <> 0 or txn_count <> 0 then
    raise exception
      'injected failure leaked consume or ledger (active %, consumed %, txn %)',
      active_holds, consumed_holds, txn_count;
  end if;
  if exists (
    select 1 from public.stock_dispatch_requests
    where id = (prepared ->> 'id')::uuid and stock_consumed
  ) then
    raise exception 'injected failure must not mark stock_consumed';
  end if;
end $$;

drop trigger m3ds_inject_dispatch_failure on public.stock_ledger;

select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
  prepared jsonb;
  cancelled jsonb;
  again jsonb;
begin
  prepared := public.get_dispatch_request(current_setting('sherlyos.dispatch_c')::uuid);
  preview := public.preview_dispatch(current_setting('sherlyos.order_c')::uuid);
  cancelled := public.cancel_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer,
    'not needed', 'm3ds-can-3'
  );
  if cancelled ->> 'status' is distinct from 'cancelled' then
    raise exception 'preparing dispatch should cancel';
  end if;

  begin
    perform public.confirm_dispatch(
      (prepared ->> 'id')::uuid, (cancelled ->> 'version')::integer, 'm3ds-cfm-cancelled'
    );
    raise exception 'cancelled dispatch must not consume stock';
  exception
    when sqlstate '23514' then null;
  end;

  again := public.prepare_dispatch(
    current_setting('sherlyos.order_c')::uuid,
    (preview ->> 'picking_version')::integer,
    'm3ds-prep-3b'
  );
  if again ->> 'status' is distinct from 'preparing' then
    raise exception 'a new dispatch workflow should be allowed after cancel';
  end if;

  begin
    perform public.cancel_order(
      current_setting('sherlyos.order')::uuid, 3, 'too late', 'm3ds-ord-can'
    );
    raise exception 'consumed dispatch must block order cancel';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Driver cannot see unassigned dispatch
select pg_temp.as_user('driver');
do $$
begin
  begin
    perform public.get_dispatch_request(current_setting('sherlyos.dispatch')::uuid);
    raise exception 'driver must not read unassigned historical dispatch';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

rollback;
