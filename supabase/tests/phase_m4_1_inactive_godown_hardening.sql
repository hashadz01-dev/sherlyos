-- M4.1 local disposable SQL. Rolls back. Does not touch development cloud.
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
  fixture.name || '.m41sql@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M41 Admin', true)
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

create or replace function pg_temp.handshake_dn(p_order uuid, p_prefix text, p_gm text default 'godown')
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
    perform pg_temp.as_user(p_gm);
    payload := public.acknowledge_delivery_note(note_id, note_version, p_prefix || '-ack');
    note_status := payload -> 'delivery_note' ->> 'status';
  end if;

  if note_status is distinct from 'acknowledged' then
    raise exception 'DN handshake did not reach acknowledged: %', note_status;
  end if;
  return note_id;
end;
$$;

create or replace function pg_temp.expect_state(got text, want text, label text)
returns void language plpgsql as $$
begin
  if got is distinct from want then
    raise exception '%: expected %, got %', label, want, got;
  end if;
end;
$$;

select pg_temp.as_user('admin');
set local role authenticated;

select set_config(
  'sherlyos.branch',
  public.create_branch('m41sql_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10), 'M41SQL A')::text,
  true
);
select set_config(
  'sherlyos.branch_b',
  public.create_branch('m41sql_b_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8), 'M41SQL B')::text,
  true
);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'driver'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'other'), current_setting('sherlyos.branch_b')::uuid);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch_b')::uuid);

select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'z1', 'Z1', null)::text, true);
select set_config('sherlyos.crate', public.create_crate(current_setting('sherlyos.zone')::uuid, 'ca', 'CA', null)::text, true);
select set_config('sherlyos.zone_b', public.create_zone(current_setting('sherlyos.branch_b')::uuid, 'zb', 'ZB', null)::text, true);
select set_config('sherlyos.crate_b', public.create_crate(current_setting('sherlyos.zone_b')::uuid, 'cb', 'CB', null)::text, true);

select set_config('sherlyos.product', public.create_product('m41ig-soap', 'M41IG Soap', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.product')::uuid, 'expiry_controlled');
select set_config('sherlyos.shop', public.create_shop('M41IG shop', null, null)::text, true);

reset role;
-- Replica: inactive-godown proofs, not the unmatched-grain enable trigger.
set session_replication_role = replica;
update public.app_configuration set value = 'true'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
set session_replication_role = origin;

select pg_temp.as_user('admin');
set local role authenticated;

select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate')::uuid,
  8, 'm41ig-open-a', null, 'M41-A', null, '2028-06-01'
);
select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate_b')::uuid,
  5, 'm41ig-open-b', null, 'M41-B', null, '2028-07-01'
);

select set_config(
  'sherlyos.ledger_open',
  (select count(*)::text from public.stock_ledger where product_id = current_setting('sherlyos.product')::uuid),
  true
);

-- Active godown still reserves, picks, prepares, and confirms.
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
      'm41ig-order-live'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_live')::uuid, 1, 'm41ig-sub-live');
select public.verify_order(current_setting('sherlyos.order_live')::uuid, 2, 'm41ig-ver-live');
select pg_temp.handshake_dn(current_setting('sherlyos.order_live')::uuid, 'm41ig-hlive');

select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
  reserved jsonb;
  header jsonb;
  res jsonb;
  prepared jsonb;
  confirmed jsonb;
begin
  preview := public.preview_order_allocation(current_setting('sherlyos.order_live')::uuid);
  if preview ->> 'eligible' is distinct from 'true' then
    raise exception 'active godown preview must stay eligible: %', preview;
  end if;

  reserved := public.reserve_order_allocation(
    current_setting('sherlyos.order_live')::uuid, 3, 'm41ig-res-live'
  );
  perform set_config('sherlyos.request_live', reserved ->> 'id', true);

  reserved := public.assign_picking_request(
    (reserved ->> 'id')::uuid,
    (select id from fixture where name = 'keeper'),
    (reserved ->> 'version')::integer,
    'm41ig-asg-live'
  );
  reserved := public.start_picking(
    (reserved ->> 'id')::uuid, (reserved ->> 'version')::integer, 'm41ig-start-live'
  );

  perform pg_temp.as_user('keeper');
  header := public.get_picking_request((reserved ->> 'id')::uuid);
  res := header -> 'reservations' -> 0;
  header := public.confirm_picking_quantity(
    (reserved ->> 'id')::uuid,
    (res ->> 'id')::uuid,
    (res ->> 'reserved_cases')::integer,
    (header ->> 'version')::integer,
    'm41ig-pick-live'
  );
  header := public.complete_picking(
    (reserved ->> 'id')::uuid, (header ->> 'version')::integer, 'm41ig-cmp-live'
  );

  perform pg_temp.as_user('godown');
  header := public.confirm_picking_handoff(
    (reserved ->> 'id')::uuid, (header ->> 'version')::integer, 'm41ig-hand-live'
  );
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_live')::uuid,
    (header ->> 'version')::integer,
    'm41ig-prep-live'
  );
  confirmed := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm41ig-cfm-live'
  );
  if confirmed ->> 'status' is distinct from 'dispatched'
    or confirmed ->> 'stock_consumed' is distinct from 'true'
  then
    raise exception 'active confirm_dispatch failed: %', confirmed;
  end if;
  perform set_config('sherlyos.dispatch_live', confirmed ->> 'id', true);
  perform set_config('sherlyos.dispatch_live_version', confirmed ->> 'version', true);
end $$;

-- Second consumed dispatch for the post-consume exception path.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_exc',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm41ig-order-exc'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_exc')::uuid, 1, 'm41ig-sub-exc');
select public.verify_order(current_setting('sherlyos.order_exc')::uuid, 2, 'm41ig-ver-exc');
select pg_temp.handshake_dn(current_setting('sherlyos.order_exc')::uuid, 'm41ig-hexc');

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
    current_setting('sherlyos.order_exc')::uuid, 3, 'm41ig-res-exc'
  );
  reserved := public.assign_picking_request(
    (reserved ->> 'id')::uuid,
    (select id from fixture where name = 'keeper'),
    (reserved ->> 'version')::integer,
    'm41ig-asg-exc'
  );
  reserved := public.start_picking(
    (reserved ->> 'id')::uuid, (reserved ->> 'version')::integer, 'm41ig-start-exc'
  );
  perform pg_temp.as_user('keeper');
  header := public.get_picking_request((reserved ->> 'id')::uuid);
  res := header -> 'reservations' -> 0;
  header := public.confirm_picking_quantity(
    (reserved ->> 'id')::uuid,
    (res ->> 'id')::uuid,
    (res ->> 'reserved_cases')::integer,
    (header ->> 'version')::integer,
    'm41ig-pick-exc'
  );
  header := public.complete_picking(
    (reserved ->> 'id')::uuid, (header ->> 'version')::integer, 'm41ig-cmp-exc'
  );
  perform pg_temp.as_user('godown');
  header := public.confirm_picking_handoff(
    (reserved ->> 'id')::uuid, (header ->> 'version')::integer, 'm41ig-hand-exc'
  );
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_exc')::uuid,
    (header ->> 'version')::integer,
    'm41ig-prep-exc'
  );
  confirmed := public.confirm_dispatch(
    (prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm41ig-cfm-exc'
  );
  perform set_config('sherlyos.dispatch_exc', confirmed ->> 'id', true);
  perform set_config('sherlyos.dispatch_exc_version', confirmed ->> 'version', true);
end $$;

-- In-flight allocated request created while active, then the godown is deactivated.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_hold',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm41ig-order-hold'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_hold')::uuid, 1, 'm41ig-sub-hold');
select public.verify_order(current_setting('sherlyos.order_hold')::uuid, 2, 'm41ig-ver-hold');
select pg_temp.handshake_dn(current_setting('sherlyos.order_hold')::uuid, 'm41ig-hhold');

select pg_temp.as_user('godown');
do $$
declare
  reserved jsonb;
begin
  reserved := public.reserve_order_allocation(
    current_setting('sherlyos.order_hold')::uuid, 3, 'm41ig-res-hold'
  );
  perform set_config('sherlyos.request_hold', reserved ->> 'id', true);
  perform set_config('sherlyos.request_hold_version', reserved ->> 'version', true);
end $$;

-- Preparing dispatch, then deactivate before confirm.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_prep',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm41ig-order-prep'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_prep')::uuid, 1, 'm41ig-sub-prep');
select public.verify_order(current_setting('sherlyos.order_prep')::uuid, 2, 'm41ig-ver-prep');
select pg_temp.handshake_dn(current_setting('sherlyos.order_prep')::uuid, 'm41ig-hprep');

select pg_temp.as_user('godown');
do $$
declare
  reserved jsonb;
  header jsonb;
  res jsonb;
  prepared jsonb;
begin
  reserved := public.reserve_order_allocation(
    current_setting('sherlyos.order_prep')::uuid, 3, 'm41ig-res-prep'
  );
  reserved := public.assign_picking_request(
    (reserved ->> 'id')::uuid,
    (select id from fixture where name = 'keeper'),
    (reserved ->> 'version')::integer,
    'm41ig-asg-prep'
  );
  reserved := public.start_picking(
    (reserved ->> 'id')::uuid, (reserved ->> 'version')::integer, 'm41ig-start-prep'
  );
  perform pg_temp.as_user('keeper');
  header := public.get_picking_request((reserved ->> 'id')::uuid);
  res := header -> 'reservations' -> 0;
  header := public.confirm_picking_quantity(
    (reserved ->> 'id')::uuid,
    (res ->> 'id')::uuid,
    (res ->> 'reserved_cases')::integer,
    (header ->> 'version')::integer,
    'm41ig-pick-prep'
  );
  header := public.complete_picking(
    (reserved ->> 'id')::uuid, (header ->> 'version')::integer, 'm41ig-cmp-prep'
  );
  perform pg_temp.as_user('godown');
  header := public.confirm_picking_handoff(
    (reserved ->> 'id')::uuid, (header ->> 'version')::integer, 'm41ig-hand-prep'
  );
  prepared := public.prepare_dispatch(
    current_setting('sherlyos.order_prep')::uuid,
    (header ->> 'version')::integer,
    'm41ig-prep-1'
  );
  perform set_config('sherlyos.dispatch_prep', prepared ->> 'id', true);
  perform set_config('sherlyos.dispatch_prep_version', prepared ->> 'version', true);
end $$;

-- Verified order that must not allocate after deactivation.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_new',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm41ig-order-new'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_new')::uuid, 1, 'm41ig-sub-new');
select public.verify_order(current_setting('sherlyos.order_new')::uuid, 2, 'm41ig-ver-new');

select pg_temp.as_user('admin');
select public.set_branch_active(current_setting('sherlyos.branch')::uuid, false);

select set_config(
  'sherlyos.ledger_mid',
  (select count(*)::text from public.stock_ledger where product_id = current_setting('sherlyos.product')::uuid),
  true
);

-- Private helper is not executable.
do $$
begin
  begin
    perform app_private.assert_operational_active_branch(current_setting('sherlyos.branch')::uuid);
    raise exception 'private operational guard must not be executable';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Admin cannot start new operational writes at the inactive godown.
do $$
begin
  begin
    perform public.preview_order_allocation(current_setting('sherlyos.order_new')::uuid);
    raise exception 'admin preview on inactive godown must fail';
  exception
    when sqlstate '23514' then
      if sqlerrm not ilike '%inactive%' then
        raise exception 'expected inactive message, got %', sqlerrm;
      end if;
  end;

  begin
    perform public.reserve_order_allocation(
      current_setting('sherlyos.order_new')::uuid, 3, 'm41ig-res-new'
    );
    raise exception 'admin reserve on inactive godown must fail';
  exception
    when sqlstate '23514' then
      if sqlerrm not ilike '%inactive%' then
        raise exception 'expected inactive message, got %', sqlerrm;
      end if;
  end;

  begin
    perform public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm41ig-order-blocked'
    );
    raise exception 'admin create_order on inactive godown must fail';
  exception
    when sqlstate '42501' then null;
  end;

  begin
    perform public.prepare_dispatch(
      current_setting('sherlyos.order_new')::uuid, 1, 'm41ig-prep-new'
    );
    raise exception 'admin prepare_dispatch on inactive godown must fail';
  exception
    when sqlstate '23514' then
      if sqlerrm not ilike '%inactive%' then
        raise exception 'expected inactive message, got %', sqlerrm;
      end if;
  end;

  begin
    perform public.confirm_dispatch(
      current_setting('sherlyos.dispatch_prep')::uuid,
      current_setting('sherlyos.dispatch_prep_version')::integer,
      'm41ig-cfm-inactive'
    );
    raise exception 'admin confirm_dispatch on inactive godown must fail';
  exception
    when sqlstate '23514' then
      if sqlerrm not ilike '%inactive%' then
        raise exception 'expected inactive confirm message, got %', sqlerrm;
      end if;
  end;

  begin
    perform public.post_opening_stock(
      current_setting('sherlyos.product')::uuid,
      current_setting('sherlyos.crate')::uuid,
      1, 'm41ig-open-inactive', null, 'M41-X', null, '2028-08-01'
    );
    raise exception 'admin opening on inactive godown must fail';
  exception
    when sqlstate '23514' then
      if sqlerrm not ilike '%inactive%' then
        raise exception 'expected inactive location message, got %', sqlerrm;
      end if;
  end;
end $$;

-- Assigned manager loses can_work_at_branch; unauthorized stays 42501.
select pg_temp.as_user('godown');
do $$
begin
  begin
    perform public.reserve_order_allocation(
      current_setting('sherlyos.order_new')::uuid, 3, 'm41ig-res-gdn'
    );
    raise exception 'assigned manager must not reserve after deactivation';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

select pg_temp.as_user('other');
do $$
begin
  begin
    perform public.reserve_order_allocation(
      current_setting('sherlyos.order_new')::uuid, 3, 'm41ig-res-other'
    );
    raise exception 'cross-branch manager must not reserve';
  exception
    when sqlstate '42501' then null;
  end;

  begin
    perform public.prepare_dispatch(
      current_setting('sherlyos.order_new')::uuid, 1, 'm41ig-prep-other'
    );
    raise exception 'cross-branch manager must not prepare dispatch';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

select pg_temp.as_user('keeper');
do $$
begin
  begin
    perform public.start_picking(
      current_setting('sherlyos.request_hold')::uuid,
      current_setting('sherlyos.request_hold_version')::integer,
      'm41ig-start-hold'
    );
    raise exception 'in-flight start_picking must fail after deactivation';
  exception
    when sqlstate '42501' then null;
    when sqlstate '23514' then
      if sqlerrm not ilike '%inactive%' then
        raise;
      end if;
  end;
end $$;

-- Post-consume delivery remains allowed after deactivation. Preparing cannot bypass.
select pg_temp.as_user('godown');
do $$
declare
  txn_before integer;
  txn_after integer;
  assigned jsonb;
  started jsonb;
  delivered jsonb;
  replay jsonb;
  excepted jsonb;
begin
  select count(*) into txn_before
  from public.stock_transactions
  where transaction_type = 'DISPATCH'
    and product_id = current_setting('sherlyos.product')::uuid;

  begin
    perform public.assign_dispatch_delivery(
      current_setting('sherlyos.dispatch_prep')::uuid,
      (select id from fixture where name = 'driver'),
      current_setting('sherlyos.dispatch_prep_version')::integer,
      'm41ig-asg-prep'
    );
    raise exception 'preparing dispatch must not enter delivery';
  exception
    when sqlstate '23514' then null;
  end;

  perform pg_temp.as_user('other');
  begin
    perform public.assign_dispatch_delivery(
      current_setting('sherlyos.dispatch_live')::uuid,
      (select id from fixture where name = 'driver'),
      current_setting('sherlyos.dispatch_live_version')::integer,
      'm41ig-asg-other'
    );
    raise exception 'cross-branch manager must not assign delivery';
  exception
    when sqlstate '42501' then null;
  end;

  perform pg_temp.as_user('keeper');
  begin
    perform public.start_dispatch_delivery(
      current_setting('sherlyos.dispatch_live')::uuid,
      current_setting('sherlyos.dispatch_live_version')::integer,
      'm41ig-start-keeper'
    );
    raise exception 'store keeper must not start delivery';
  exception
    when sqlstate '42501' then null;
  end;

  perform pg_temp.as_user('godown');
  assigned := public.assign_dispatch_delivery(
    current_setting('sherlyos.dispatch_live')::uuid,
    (select id from fixture where name = 'driver'),
    current_setting('sherlyos.dispatch_live_version')::integer,
    'm41ig-asg-live'
  );

  perform pg_temp.as_user('driver');
  started := public.start_dispatch_delivery(
    (assigned ->> 'id')::uuid, (assigned ->> 'version')::integer, 'm41ig-go-live'
  );
  if started ->> 'status' is distinct from 'in_transit' then
    raise exception 'driver start after deactivation failed: %', started;
  end if;

  delivered := public.acknowledge_dispatch_delivery(
    (started ->> 'id')::uuid,
    'Shop receiver',
    'm41 pod',
    (started ->> 'version')::integer,
    'm41ig-pod-live'
  );
  if delivered ->> 'status' is distinct from 'delivered' then
    raise exception 'driver POD after deactivation failed: %', delivered;
  end if;

  replay := public.acknowledge_dispatch_delivery(
    (started ->> 'id')::uuid,
    'Shop receiver',
    'm41 pod',
    (started ->> 'version')::integer,
    'm41ig-pod-live'
  );
  if replay ->> 'id' is distinct from delivered ->> 'id'
    or replay ->> 'status' is distinct from 'delivered'
  then
    raise exception 'POD replay must follow existing idempotency: %', replay;
  end if;

  perform pg_temp.as_user('godown');
  excepted := public.report_dispatch_delivery_exception(
    current_setting('sherlyos.dispatch_exc')::uuid,
    'shop closed after consume',
    current_setting('sherlyos.dispatch_exc_version')::integer,
    'm41ig-exc-1'
  );
  if excepted ->> 'status' is distinct from 'exception' then
    raise exception 'delivery exception after deactivation failed: %', excepted;
  end if;

  select count(*) into txn_after
  from public.stock_transactions
  where transaction_type = 'DISPATCH'
    and product_id = current_setting('sherlyos.product')::uuid;
  if txn_after <> txn_before then
    raise exception 'delivery progression must not post stock (% vs %)', txn_after, txn_before;
  end if;
end $$;

-- Existing allocated request is not auto-cancelled; admin may release it.
select pg_temp.as_user('admin');
do $$
declare
  hold_status text;
  cancelled jsonb;
  remaining integer;
begin
  select status into hold_status
  from public.stock_picking_requests
  where id = current_setting('sherlyos.request_hold')::uuid;
  perform pg_temp.expect_state(hold_status, 'allocated', 'in-flight picking stays allocated');

  cancelled := public.cancel_picking_request(
    current_setting('sherlyos.request_hold')::uuid,
    current_setting('sherlyos.request_hold_version')::integer,
    'release after godown deactivation',
    'm41ig-cancel-hold'
  );
  if cancelled ->> 'status' is distinct from 'cancelled' then
    raise exception 'admin cancel_picking after deactivation failed: %', cancelled;
  end if;

  select count(*) into remaining
  from public.stock_reservations
  where picking_request_id = current_setting('sherlyos.request_hold')::uuid
    and status = 'active';
  if remaining <> 0 then
    raise exception 'cancel must release active reservations, remaining %', remaining;
  end if;
end $$;

-- Preparing dispatch remains until explicitly cancelled; confirm already denied.
do $$
declare
  cancelled jsonb;
  disp_status text;
begin
  select status into disp_status
  from public.stock_dispatch_requests
  where id = current_setting('sherlyos.dispatch_prep')::uuid;
  if disp_status is distinct from 'preparing' then
    raise exception 'preparing dispatch must remain preparing, got %', disp_status;
  end if;

  cancelled := public.cancel_dispatch(
    current_setting('sherlyos.dispatch_prep')::uuid,
    current_setting('sherlyos.dispatch_prep_version')::integer,
    'release after godown deactivation',
    'm41ig-cancel-disp'
  );
  if cancelled ->> 'status' is distinct from 'cancelled' then
    raise exception 'admin cancel_dispatch after deactivation failed: %', cancelled;
  end if;
end $$;

-- Stock adjustment create is denied. Replica-insert a closed header only.
reset role;
set session_replication_role = replica;
insert into public.stock_verifications (
  verification_number, godown_id, business_date, status,
  snapshot_at, snapshot_ledger_boundary, started_by, started_at,
  closed_by, closed_at, closure_result, closure_note
)
values (
  'M41IG-CLOSED-1',
  current_setting('sherlyos.branch')::uuid,
  current_date,
  'closed',
  clock_timestamp(),
  'ledger-id-set',
  (select id from fixture where name = 'admin'),
  clock_timestamp(),
  (select id from fixture where name = 'admin'),
  clock_timestamp(),
  'matched',
  'm41 fixture'
);
set session_replication_role = origin;

select pg_temp.as_user('admin');
set local role authenticated;
do $$
declare
  verification uuid;
begin
  select id into verification
  from public.stock_verifications
  where verification_number = 'M41IG-CLOSED-1';

  begin
    perform public.create_stock_adjustment(
      verification,
      'shortage',
      'admin inactive request',
      '{}'::uuid[],
      'm41ig-adj-admin',
      null
    );
    raise exception 'admin must not create stock adjustment on inactive godown';
  exception
    when sqlstate '23514' then
      if sqlerrm not ilike '%inactive%' then
        raise exception 'expected inactive adjustment message, got %', sqlerrm;
      end if;
    when sqlstate '42501' then
      null;
  end;
end $$;

select pg_temp.as_user('godown');
do $$
declare
  verification uuid;
begin
  select id into verification
  from public.stock_verifications
  where verification_number = 'M41IG-CLOSED-1';
  begin
    perform public.create_stock_adjustment(
      verification,
      'shortage',
      'manager inactive request',
      '{}'::uuid[],
      'm41ig-adj-gdn',
      null
    );
    raise exception 'assigned manager must not create adjustment after deactivation';
  exception
    when sqlstate '42501' then null;
    when sqlstate '23514' then
      if sqlerrm not ilike '%inactive%' then
        raise;
      end if;
  end;
end $$;

-- Denied writes must not add ledger rows. Count as the table owner so RLS
-- does not hide inactive-godown rows from the assigned manager.
reset role;
do $$
declare
  mid integer := current_setting('sherlyos.ledger_mid')::integer;
  now_count integer;
begin
  select count(*) into now_count
  from public.stock_ledger
  where product_id = current_setting('sherlyos.product')::uuid;
  if now_count <> mid then
    raise exception 'denied inactive writes mutated ledger (% vs %)', now_count, mid;
  end if;
end $$;

-- Historical reporting still includes inactive stock and accepts the UUID filter.
select pg_temp.as_user('admin');
do $$
declare
  dash jsonb;
  inv jsonb;
  filtered jsonb;
  on_hand integer;
begin
  dash := public.get_operations_dashboard(current_setting('sherlyos.branch')::uuid);
  inv := public.list_inventory_report('crate', null, null, null, null, null, null, false, 1, 50);
  filtered := public.list_inventory_report(
    'crate', current_setting('sherlyos.branch')::uuid,
    null, null, null, null, null, false, 1, 50
  );
  on_hand := coalesce((dash -> 'inventory' ->> 'total_cartons_on_hand')::int, 0);
  if on_hand < 1 then
    raise exception 'dashboard must still include inactive godown stock, got %', dash -> 'inventory';
  end if;
  if coalesce((filtered ->> 'total_count')::int, 0) < 1 then
    raise exception 'admin inactive branch filter must return stock: %', filtered;
  end if;
  if coalesce((inv ->> 'total_count')::int, 0) < 2 then
    raise exception 'unfiltered inventory must include both godowns: %', inv;
  end if;
end $$;

-- Active godown B is still usable after A is deactivated.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_b',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_b')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm41ig-order-b'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_b')::uuid, 1, 'm41ig-sub-b');
select public.verify_order(current_setting('sherlyos.order_b')::uuid, 2, 'm41ig-ver-b');
select pg_temp.handshake_dn(current_setting('sherlyos.order_b')::uuid, 'm41ig-hb', 'other');

select pg_temp.as_user('other');
do $$
declare
  preview jsonb;
  reserved jsonb;
begin
  preview := public.preview_order_allocation(current_setting('sherlyos.order_b')::uuid);
  if preview ->> 'eligible' is distinct from 'true' then
    raise exception 'active godown B preview failed: %', preview;
  end if;
  reserved := public.reserve_order_allocation(
    current_setting('sherlyos.order_b')::uuid, 3, 'm41ig-res-b'
  );
  if reserved ->> 'status' is distinct from 'allocated' then
    raise exception 'active godown B reserve failed: %', reserved;
  end if;
end $$;

rollback;
