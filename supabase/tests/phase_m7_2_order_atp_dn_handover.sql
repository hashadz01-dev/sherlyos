-- M7.2 local disposable SQL. Rolls back. Does not touch development cloud.
-- Covers ORD-01 capture, picking-eligible ATP, DN handshake, D1 picking gate.
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
  ('godown_b', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('inactive_gm', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.m72@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M72 Admin', true)
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
  when 'godown_b' then 'godown_manager'
  when 'keeper' then 'store_keeper'
  when 'inactive_gm' then 'godown_manager'
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

-- Accounts create/generate/send, GM acknowledge. Required before reserve (D1).
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

select pg_temp.as_user('admin');
set local role authenticated;
select set_config('sherlyos.branch', public.create_branch('m72_a', 'M72 A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('m72_b', 'M72 B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'salesperson'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'inactive_gm'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown_b'), current_setting('sherlyos.branch_b')::uuid);
select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'z1', 'Z1', null)::text, true);
select set_config('sherlyos.crate', public.create_crate(current_setting('sherlyos.zone')::uuid, 'c1', 'C1', null)::text, true);
select set_config('sherlyos.crate_lot', public.create_crate(current_setting('sherlyos.zone')::uuid, 'cl', 'CL', null)::text, true);
select set_config('sherlyos.sku', public.create_product('m72-soap', 'M72 soap', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.sku')::uuid, 'non_expiring');
select set_config('sherlyos.shop', public.create_shop('M72 shop', null, null)::text, true);
select public.assign_shop_salesperson(
  current_setting('sherlyos.shop')::uuid,
  (select id from fixture where name = 'salesperson')
);

-- Gross opening without lots. Pre-cutover ATP must ignore this as pickable.
select public.post_opening_stock(
  current_setting('sherlyos.sku')::uuid,
  current_setting('sherlyos.crate')::uuid,
  10,
  'm72-open-gross',
  null
);

-- 1. Salesperson and Accounts capture (ORD-01)
select pg_temp.as_user('salesperson');
select set_config(
  'sherlyos.order_sp',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'salesperson', 'call-desk', null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.sku')::uuid, 'requested_cases', 2)
      ),
      'm72-ord-sp01'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_sp')::uuid, 1, 'm72-sub-sp01');

select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_ac',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'telecalling', 'enq-77', null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.sku')::uuid, 'requested_cases', 2)
      ),
      'm72-ord-ac01'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_ac')::uuid, 1, 'm72-sub-ac01');

-- 6. Pre-cutover safety: gross on-hand must not verify.
do $$
declare
  snapshot jsonb;
  detail text;
begin
  snapshot := public.check_order_availability(current_setting('sherlyos.order_ac')::uuid);
  if snapshot ->> 'reserves_stock' is distinct from 'false' then
    raise exception 'availability must declare non-reserving: %', snapshot;
  end if;
  if snapshot ->> 'picking_operational' is distinct from 'false' then
    raise exception 'pre-cutover must not be operational: %', snapshot;
  end if;
  if (snapshot -> 'lines' -> 0 ->> 'eligible_cases') is distinct from '0' then
    raise exception 'pre-cutover eligible_cases must be 0: %', snapshot;
  end if;
  if (snapshot -> 'lines' -> 0 ->> 'on_hand_cases') is distinct from '10' then
    raise exception 'on-hand should remain informational 10: %', snapshot;
  end if;
  if (snapshot -> 'lines' -> 0 ->> 'shortfall_cases') is distinct from '2' then
    raise exception 'pre-cutover shortfall should equal requested: %', snapshot;
  end if;

  begin
    perform public.verify_order(current_setting('sherlyos.order_ac')::uuid, 2, 'm72-ver-prec');
    raise exception 'pre-cutover verify must fail closed';
  exception
    when sqlstate 'P0001' then
      get stacked diagnostics detail = pg_exception_detail;
      if detail is null or detail not like '%shortfall_cases%' then
        raise exception 'pre-cutover shortage detail missing: %', detail;
      end if;
  end;

  if (select status from public.orders where id = current_setting('sherlyos.order_ac')::uuid)
    is distinct from 'submitted'
  then
    raise exception 'failed verify must leave submitted';
  end if;
end $$;

-- Enable operational picking for disposable proofs only. Transaction rolls back.
reset role;
set session_replication_role = replica;
update public.app_configuration set value = 'true'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
set session_replication_role = origin;

select pg_temp.as_user('admin');
set local role authenticated;
select public.post_opening_stock(
  current_setting('sherlyos.sku')::uuid,
  current_setting('sherlyos.crate_lot')::uuid,
  8,
  'm72-open-lot',
  null,
  'M72-LOT',
  null,
  null
);

-- 2/3. Accounts verification with picking-eligible ATP
select pg_temp.as_user('accounts');
do $$
declare
  snapshot jsonb;
  payload jsonb;
begin
  snapshot := public.check_order_availability(current_setting('sherlyos.order_ac')::uuid);
  if snapshot ->> 'picking_operational' is distinct from 'true' then
    raise exception 'dual-write window must be operational: %', snapshot;
  end if;
  if (snapshot -> 'lines' -> 0 ->> 'eligible_cases') is distinct from '2'
    or (snapshot -> 'lines' -> 0 ->> 'shortfall_cases') is distinct from '0'
    or coalesce(snapshot -> 'lines' -> 0 ->> 'eligible', 'false') is distinct from 'true'
  then
    raise exception 'eligible ATP should cover the 2-case request: %', snapshot;
  end if;
  payload := public.verify_order(current_setting('sherlyos.order_ac')::uuid, 2, 'm72-ver-ok');
  if payload -> 'order' ->> 'status' is distinct from 'verified' then
    raise exception 'eligible ATP should verify';
  end if;
  payload := public.verify_order(current_setting('sherlyos.order_ac')::uuid, 2, 'm72-ver-ok');
  if payload -> 'order' ->> 'version' is distinct from '3' then
    raise exception 'verify replay bumped version';
  end if;
end $$;

select pg_temp.as_user('salesperson');
select public.submit_order(current_setting('sherlyos.order_sp')::uuid, 1, 'm72-sub-sp01');
select pg_temp.as_user('accounts');
select public.verify_order(current_setting('sherlyos.order_sp')::uuid, 2, 'm72-ver-sp');

-- 7. DN create / generate / send (ORD-03). Paperwork only.
do $$
declare
  created jsonb;
  generated jsonb;
  sent jsonb;
  ledger_before integer;
  ledger_after integer;
  note_id uuid;
begin
  select count(*) into ledger_before from public.stock_ledger
  where product_id = current_setting('sherlyos.sku')::uuid;

  created := public.create_delivery_note(current_setting('sherlyos.order_ac')::uuid, 'm72-dn-ac');
  note_id := (created -> 'delivery_note' ->> 'id')::uuid;
  perform set_config('sherlyos.dn_ac', note_id::text, true);
  if created -> 'delivery_note' ->> 'status' is distinct from 'draft' then
    raise exception 'DN create should be draft';
  end if;
  generated := public.generate_delivery_note(note_id, 1, 'm72-dn-gen');
  if generated -> 'delivery_note' ->> 'status' is distinct from 'generated' then
    raise exception 'DN generate failed';
  end if;
  sent := public.send_delivery_note(note_id, 2, 'm72-dn-send');
  if sent -> 'delivery_note' ->> 'status' is distinct from 'sent' then
    raise exception 'DN send failed';
  end if;

  select count(*) into ledger_after from public.stock_ledger
  where product_id = current_setting('sherlyos.sku')::uuid;
  if ledger_after is distinct from ledger_before then
    raise exception 'DN paperwork mutated ledger';
  end if;
end $$;

-- 9. Picking blocked before acknowledgement
select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
begin
  preview := public.preview_order_allocation(current_setting('sherlyos.order_ac')::uuid);
  if preview ->> 'eligible' is distinct from 'false' then
    raise exception 'preview must block without DN ack: %', preview;
  end if;
  if (preview -> 'blockers')::text not like '%acknowledge the delivery note%' then
    raise exception 'expected DN ack blocker: %', preview -> 'blockers';
  end if;

  begin
    perform public.reserve_order_allocation(
      current_setting('sherlyos.order_ac')::uuid, 3, 'm72-res-early'
    );
    raise exception 'reserve must refuse before DN ack';
  exception
    when sqlstate '23514' then
      if sqlerrm not ilike '%acknowledge the delivery note%' then
        raise exception 'expected DN ack refusal, got %', sqlerrm;
      end if;
  end;

  if exists (
    select 1
    from jsonb_array_elements(public.list_picking_requests('pending_allocation')) as rows
    where rows ->> 'order_id' = current_setting('sherlyos.order_ac')
  ) then
    raise exception 'pending allocation listed an unacknowledged order';
  end if;
end $$;

-- 11. Unauthorized acknowledgement (Accounts and Store Keeper)
select pg_temp.as_user('accounts');
do $$
begin
  begin
    perform public.acknowledge_delivery_note(
      current_setting('sherlyos.dn_ac')::uuid, 3, 'm72-ack-acct'
    );
    raise exception 'accounts must not acknowledge';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

select pg_temp.as_user('keeper');
do $$
begin
  begin
    perform public.acknowledge_delivery_note(
      current_setting('sherlyos.dn_ac')::uuid, 3, 'm72-ack-keep'
    );
    raise exception 'store keeper must not acknowledge';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- 12. Cross-godown acknowledgement
select pg_temp.as_user('godown_b');
do $$
begin
  begin
    perform public.acknowledge_delivery_note(
      current_setting('sherlyos.dn_ac')::uuid, 3, 'm72-ack-xgod'
    );
    raise exception 'cross-godown ack must fail';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- 8. GM acknowledgement (ORD-04)
select pg_temp.as_user('godown');
do $$
declare
  payload jsonb;
  replay jsonb;
begin
  payload := public.acknowledge_delivery_note(
    current_setting('sherlyos.dn_ac')::uuid, 3, 'm72-ack-ok'
  );
  if payload -> 'delivery_note' ->> 'status' is distinct from 'acknowledged' then
    raise exception 'ack failed: %', payload;
  end if;
  if payload -> 'delivery_note' ->> 'acknowledged_by' is null
    or payload -> 'delivery_note' ->> 'acknowledged_at' is null
  then
    raise exception 'ack missing actor or timestamp';
  end if;

  -- 14. Idempotent replay by the same GM
  replay := public.acknowledge_delivery_note(
    current_setting('sherlyos.dn_ac')::uuid, 3, 'm72-ack-ok'
  );
  if replay -> 'delivery_note' ->> 'version' is distinct from payload -> 'delivery_note' ->> 'version' then
    raise exception 'ack replay bumped version';
  end if;
end $$;

-- Revoked assignment cannot replay ack.
reset role;
delete from public.user_branch_assignments
where user_id = (select id from fixture where name = 'godown')
  and branch_id = current_setting('sherlyos.branch')::uuid;
select pg_temp.as_user('godown');
set local role authenticated;
do $$
begin
  begin
    perform public.acknowledge_delivery_note(
      current_setting('sherlyos.dn_ac')::uuid, 3, 'm72-ack-ok'
    );
    raise exception 'revoked assignment replay must fail';
  exception
    when sqlstate '42501' then null;
  end;
end $$;
select pg_temp.as_user('admin');
set local role authenticated;
select public.assign_user_branch(
  (select id from fixture where name = 'godown'),
  current_setting('sherlyos.branch')::uuid
);

-- 10. Picking permitted after acknowledgement when other gates pass
select pg_temp.as_user('godown');
set local role authenticated;
do $$
declare
  preview jsonb;
  reserved jsonb;
begin
  preview := public.preview_order_allocation(current_setting('sherlyos.order_ac')::uuid);
  if preview ->> 'eligible' is distinct from 'true' then
    raise exception 'acked DN should allow preview: %', preview;
  end if;
  reserved := public.reserve_order_allocation(
    current_setting('sherlyos.order_ac')::uuid, 3, 'm72-res-ok'
  );
  if reserved ->> 'status' is distinct from 'allocated' then
    raise exception 'reserve after ack failed: %', reserved;
  end if;
end $$;

-- 4. Reservation-aware ATP: remaining eligible is 8-2=6
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_res',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.sku')::uuid, 'requested_cases', 7)
      ),
      'm72-ord-res'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_res')::uuid, 1, 'm72-sub-res');
do $$
declare
  snapshot jsonb;
begin
  snapshot := public.check_order_availability(current_setting('sherlyos.order_res')::uuid);
  if (snapshot -> 'lines' -> 0 ->> 'eligible_cases')::integer > 6 then
    raise exception 'reservation was not subtracted from ATP: %', snapshot;
  end if;
  begin
    perform public.verify_order(current_setting('sherlyos.order_res')::uuid, 2, 'm72-ver-res');
    raise exception 'over-reserved ATP must refuse verify';
  exception
    when sqlstate 'P0001' then null;
  end;
end $$;

-- 5. Quarantine/hold-aware ATP
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_q',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.sku')::uuid, 'requested_cases', 1)
      ),
      'm72-ord-q'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_q')::uuid, 1, 'm72-sub-q');

-- Replica-only: trusted GUC lets tests flip crate location_role without a
-- damage writer. Restored below. Does not activate operational flags.
reset role;
select app_private.enable_trusted_guc('app.quarantine_location_write');
update public.crates
set location_role = 'quarantine'
where id = current_setting('sherlyos.crate_lot')::uuid;

select pg_temp.as_user('accounts');
set local role authenticated;
do $$
declare
  snapshot jsonb;
begin
  snapshot := public.check_order_availability(current_setting('sherlyos.order_q')::uuid);
  if (snapshot -> 'lines' -> 0 ->> 'eligible_cases') is distinct from '0' then
    raise exception 'quarantine crate must not be pickable: %', snapshot;
  end if;
  begin
    perform public.verify_order(current_setting('sherlyos.order_q')::uuid, 2, 'm72-ver-q');
    raise exception 'quarantine stock must not verify';
  exception
    when sqlstate 'P0001' then null;
  end;
end $$;

reset role;
select app_private.enable_trusted_guc('app.quarantine_location_write');
update public.crates
set location_role = 'storage'
where id = current_setting('sherlyos.crate_lot')::uuid;

-- Inactive godown cannot accept a new acknowledgement.
select pg_temp.as_user('accounts');
set local role authenticated;
select set_config(
  'sherlyos.order_inact',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.sku')::uuid, 'requested_cases', 1)
      ),
      'm72-ord-inact'
    ) -> 'order' ->> 'id'
  ),
  true
);
-- Remaining eligible after reservation is 6; 1 case verifies.
select public.submit_order(current_setting('sherlyos.order_inact')::uuid, 1, 'm72-sub-inact');
select public.verify_order(current_setting('sherlyos.order_inact')::uuid, 2, 'm72-ver-inact');
select set_config(
  'sherlyos.dn_inact',
  (
    public.create_delivery_note(current_setting('sherlyos.order_inact')::uuid, 'm72-dn-inact')
    -> 'delivery_note' ->> 'id'
  ),
  true
);
select public.generate_delivery_note(current_setting('sherlyos.dn_inact')::uuid, 1, 'm72-inact-gen');
select public.send_delivery_note(current_setting('sherlyos.dn_inact')::uuid, 2, 'm72-inact-send');

select pg_temp.as_user('admin');
select public.set_branch_active(current_setting('sherlyos.branch')::uuid, false);

-- Assigned GM cannot work at an inactive godown (can_work_at_branch requires
-- is_active), so acknowledgement is denied. Admin 23514 inactive is covered
-- by M4.1; this proves the GM operational path is closed.
select pg_temp.as_user('godown');
set local role authenticated;
do $$
begin
  begin
    perform public.acknowledge_delivery_note(
      current_setting('sherlyos.dn_inact')::uuid, 3, 'm72-inact-ack'
    );
    raise exception 'inactive godown must not accept a new ack';
  exception
    when sqlstate '42501' then null;
    when sqlstate '23514' then
      if sqlerrm not ilike '%inactive%' then
        raise exception 'expected inactive refusal, got %', sqlerrm;
      end if;
  end;
end $$;

select pg_temp.as_user('admin');
select public.set_branch_active(current_setting('sherlyos.branch')::uuid, true);

-- Historical DN remains readable after the failed inactive ack.
select pg_temp.as_user('godown');
do $$
declare
  payload jsonb;
begin
  payload := public.get_delivery_note(current_setting('sherlyos.dn_ac')::uuid);
  if payload -> 'delivery_note' ->> 'status' is distinct from 'acknowledged' then
    raise exception 'historical ack must remain readable';
  end if;
end $$;

-- Direct table writes stay denied.
select pg_temp.as_user('godown');
do $$
begin
  begin
    update public.delivery_notes
    set status = 'acknowledged'
    where id = current_setting('sherlyos.dn_inact')::uuid;
    raise exception 'direct DN update must fail';
  exception
    when insufficient_privilege then null;
  end;
end $$;

-- Flags stay false after rollback; assert they were only replica-flipped in-tx.
do $$
begin
  if (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled')
    is distinct from 'true'::jsonb
  then
    raise exception 'test expected replica dual-write true inside the transaction';
  end if;
end $$;

rollback;
