-- M7.3 local disposable SQL. Rolls back. Does not touch development cloud.
-- DN-to-picking coupling, shortage cannot handoff, cancel-and-reallocate.
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
  ('keeper', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.m73@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M73 Admin', true)
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
select set_config('sherlyos.branch', public.create_branch('m73_a', 'M73 A')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'salesperson'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'z1', 'Z1', null)::text, true);
select set_config('sherlyos.crate', public.create_crate(current_setting('sherlyos.zone')::uuid, 'c1', 'C1', null)::text, true);
select set_config('sherlyos.crate_lot', public.create_crate(current_setting('sherlyos.zone')::uuid, 'cl', 'CL', null)::text, true);
select set_config('sherlyos.sku', public.create_product('m73-sku', 'M73 soap', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.sku')::uuid, 'non_expiring');
select set_config('sherlyos.shop', public.create_shop('M73 shop', null, null)::text, true);
select public.assign_shop_salesperson(current_setting('sherlyos.shop')::uuid, (select id from fixture where name = 'salesperson'));

select pg_temp.as_user('salesperson');
select set_config(
  'sherlyos.order_full',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'salesperson', 'desk', null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.sku')::uuid, 'requested_cases', 2)
      ),
      'm73-order-full'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_full')::uuid, 1, 'm73-sub-full');

select pg_temp.as_user('accounts');
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
      'm73-order-short'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_short')::uuid, 1, 'm73-sub-short');

-- Verify does not reserve even after ATP is operational.
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
  'm73-open-lot',
  null,
  'M73-LOT',
  null,
  null
);

select pg_temp.as_user('accounts');
select public.verify_order(current_setting('sherlyos.order_full')::uuid, 2, 'm73-ver-full');
select public.verify_order(current_setting('sherlyos.order_short')::uuid, 2, 'm73-ver-short');

do $$
begin
  if exists (
    select 1 from public.stock_reservations
    where order_id in (
      current_setting('sherlyos.order_full')::uuid,
      current_setting('sherlyos.order_short')::uuid
    )
  ) then
    raise exception 'verify must not insert reservations';
  end if;
end $$;

-- Sent DN is not enough for allocation (D1).
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.dn_full',
  (
    public.create_delivery_note(current_setting('sherlyos.order_full')::uuid, 'm73-dn-full')
    -> 'delivery_note' ->> 'id'
  ),
  true
);
select public.generate_delivery_note(current_setting('sherlyos.dn_full')::uuid, 1, 'm73-gen-full');
select public.send_delivery_note(current_setting('sherlyos.dn_full')::uuid, 2, 'm73-send-full');

select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
  queue jsonb;
begin
  preview := public.preview_order_allocation(current_setting('sherlyos.order_full')::uuid);
  if preview ->> 'eligible' is distinct from 'false' then
    raise exception 'unacknowledged DN must block preview: %', preview;
  end if;
  begin
    perform public.reserve_order_allocation(
      current_setting('sherlyos.order_full')::uuid, 3, 'm73-res-early'
    );
    raise exception 'reserve before ack must fail';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%acknowledge the delivery note%' then
        raise exception 'unexpected reserve error: %', sqlerrm;
      end if;
  end;
  queue := public.list_picking_requests('pending_allocation');
  if jsonb_typeof(queue) is distinct from 'array' or jsonb_array_length(queue) <> 0 then
    raise exception 'pending queue must be empty before ack: %', queue;
  end if;
end $$;

-- Voided DN cannot be used for allocation. Historical voided row remains.
select pg_temp.as_user('accounts');
select public.void_delivery_note(
  current_setting('sherlyos.dn_full')::uuid, 3, 'wrong shop copy', 'm73-void-full'
);

select pg_temp.as_user('godown');
do $$
begin
  begin
    perform public.reserve_order_allocation(
      current_setting('sherlyos.order_full')::uuid, 3, 'm73-res-void'
    );
    raise exception 'voided DN must not allocate';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%acknowledge the delivery note%' then
        raise exception 'unexpected voided-DN reserve error: %', sqlerrm;
      end if;
  end;
end $$;

do $$
begin
  if not exists (
    select 1 from public.delivery_notes
    where id = current_setting('sherlyos.dn_full')::uuid
      and status = 'voided'
  ) then
    raise exception 'voided DN history was lost';
  end if;
end $$;

-- Replacement DN handshake, then allocate.
select pg_temp.handshake_dn(current_setting('sherlyos.order_full')::uuid, 'm73-hf');
select pg_temp.handshake_dn(current_setting('sherlyos.order_short')::uuid, 'm73-hs');

-- Acknowledged DN blocks order cancellation; allocation remains the authority.
select pg_temp.as_user('accounts');
do $$
begin
  begin
    perform public.cancel_order(
      current_setting('sherlyos.order_full')::uuid, 3, 'too late after ack', 'm73-cancel-acked'
    );
    raise exception 'cancel after acknowledged DN must fail';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%acknowledged delivery note%' then
        raise exception 'unexpected cancel-after-ack error: %', sqlerrm;
      end if;
  end;
end $$;

select pg_temp.as_user('godown');
do $$
declare
  queue jsonb;
  preview jsonb;
  reserved jsonb;
begin
  queue := public.list_picking_requests('pending_allocation');
  if jsonb_array_length(queue) <> 2 then
    raise exception 'acked verified orders should be pending: %', queue;
  end if;
  preview := public.preview_order_allocation(current_setting('sherlyos.order_full')::uuid);
  if preview ->> 'eligible' is distinct from 'true' then
    raise exception 'acked DN should preview: %', preview;
  end if;
  reserved := public.reserve_order_allocation(
    current_setting('sherlyos.order_full')::uuid, 3, 'm73-res-full'
  );
  if reserved ->> 'status' is distinct from 'allocated' then
    raise exception 'reserve after ack failed: %', reserved;
  end if;
  if reserved -> 'fulfilment' ->> 'ordered_cases' is distinct from '2'
    or reserved -> 'fulfilment' ->> 'allocated_cases' is distinct from '2'
    or reserved -> 'fulfilment' ->> 'short_shipment_operational' is distinct from 'false'
  then
    raise exception 'fulfilment snapshot wrong: %', reserved -> 'fulfilment';
  end if;
  perform set_config('sherlyos.req_full', reserved ->> 'id', true);
end $$;

-- Order viewers (Accounts) see the open picking snapshot. GM is not an order reader.
select pg_temp.as_user('accounts');
do $$
declare
  detail jsonb;
begin
  detail := public.get_order(current_setting('sherlyos.order_full')::uuid);
  if detail -> 'open_picking_request' ->> 'id' is distinct from current_setting('sherlyos.req_full') then
    raise exception 'get_order missing open picking: %', detail -> 'open_picking_request';
  end if;
end $$;

-- Store keeper cannot preview/reserve.
select pg_temp.as_user('keeper');
do $$
begin
  begin
    perform public.preview_order_allocation(current_setting('sherlyos.order_short')::uuid);
    raise exception 'store keeper must not preview';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Full pick can hand off. Picking does not post stock.
select pg_temp.as_user('godown');
select public.assign_picking_request(
  current_setting('sherlyos.req_full')::uuid,
  (select id from fixture where name = 'keeper'),
  (select version from public.stock_picking_requests where id = current_setting('sherlyos.req_full')::uuid),
  'm73-asg-full'
);
select pg_temp.as_user('keeper');
do $$
declare
  header jsonb;
  res jsonb;
  i int;
  ledger_after integer;
begin
  header := public.start_picking(
    current_setting('sherlyos.req_full')::uuid,
    (select version from public.stock_picking_requests where id = current_setting('sherlyos.req_full')::uuid),
    'm73-start-full'
  );
  for i in 0 .. jsonb_array_length(header -> 'reservations') - 1 loop
    res := header -> 'reservations' -> i;
    header := public.confirm_picking_quantity(
      current_setting('sherlyos.req_full')::uuid,
      (res ->> 'id')::uuid,
      (res ->> 'reserved_cases')::integer,
      (header ->> 'version')::integer,
      'm73-pick-full-' || i::text
    );
  end loop;
  header := public.complete_picking(
    current_setting('sherlyos.req_full')::uuid,
    (header ->> 'version')::integer,
    'm73-complete-full'
  );
  perform set_config('sherlyos.full_ver', header ->> 'version', true);
end $$;

select pg_temp.as_user('godown');
do $$
declare
  header jsonb;
begin
  header := public.confirm_picking_handoff(
    current_setting('sherlyos.req_full')::uuid,
    current_setting('sherlyos.full_ver')::integer,
    'm73-hand-full'
  );
  if header ->> 'status' is distinct from 'ready_for_dispatch' then
    raise exception 'full pick handoff failed: %', header;
  end if;
  -- Replay must not bump version.
  header := public.confirm_picking_handoff(
    current_setting('sherlyos.req_full')::uuid,
    current_setting('sherlyos.full_ver')::integer,
    'm73-hand-full'
  );
  if header ->> 'status' is distinct from 'ready_for_dispatch' then
    raise exception 'handoff replay lost status: %', header;
  end if;
end $$;

do $$
declare
  extra integer;
begin
  select count(*) into extra
  from public.stock_ledger
  where product_id = current_setting('sherlyos.sku')::uuid
    and transaction_id in (
      select id from public.stock_transactions where transaction_type <> 'OPENING_STOCK'
    );
  if extra <> 0 then
    raise exception 'picking must not post fulfilment stock';
  end if;
end $$;

-- Shortage: complete is allowed, handoff is refused. Cancel and reallocate.
select pg_temp.as_user('godown');
do $$
declare
  reserved jsonb;
begin
  reserved := public.reserve_order_allocation(
    current_setting('sherlyos.order_short')::uuid, 3, 'm73-res-short'
  );
  reserved := public.assign_picking_request(
    (reserved ->> 'id')::uuid,
    (select id from fixture where name = 'keeper'),
    (reserved ->> 'version')::integer,
    'm73-asg-short'
  );
  perform set_config('sherlyos.req_short', reserved ->> 'id', true);
end $$;

select pg_temp.as_user('keeper');
do $$
declare
  header jsonb;
  res jsonb;
begin
  header := public.start_picking(
    current_setting('sherlyos.req_short')::uuid,
    (select version from public.stock_picking_requests where id = current_setting('sherlyos.req_short')::uuid),
    'm73-start-short'
  );
  res := header -> 'reservations' -> 0;
  header := public.report_picking_shortage(
    current_setting('sherlyos.req_short')::uuid,
    (res ->> 'id')::uuid,
    2,
    'cartons missing in crate',
    (header ->> 'version')::integer,
    'm73-short-1'
  );
  header := public.complete_picking(
    current_setting('sherlyos.req_short')::uuid,
    (header ->> 'version')::integer,
    'm73-complete-short'
  );
  if header ->> 'status' is distinct from 'picked' then
    raise exception 'shortage complete should mark picked: %', header;
  end if;
  if header -> 'fulfilment' ->> 'has_shortage' is distinct from 'true' then
    raise exception 'fulfilment should flag shortage: %', header -> 'fulfilment';
  end if;
  perform set_config('sherlyos.short_ver', header ->> 'version', true);
end $$;

select pg_temp.as_user('godown');
do $$
declare
  header jsonb;
begin
  begin
    perform public.confirm_picking_handoff(
      current_setting('sherlyos.req_short')::uuid,
      current_setting('sherlyos.short_ver')::integer,
      'm73-hand-short'
    );
    raise exception 'short pick must not hand off to dispatch';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%Controlled short-shipment is not operational%' then
        raise exception 'unexpected short-handoff error: %', sqlerrm;
      end if;
  end;

  header := public.cancel_picking_request(
    current_setting('sherlyos.req_short')::uuid,
    current_setting('sherlyos.short_ver')::integer,
    'reallocate full order after shortage',
    'm73-cancel-short'
  );
  if header ->> 'status' is distinct from 'cancelled' then
    raise exception 'cancel after shortage failed: %', header;
  end if;

  header := public.reserve_order_allocation(
    current_setting('sherlyos.order_short')::uuid, 3, 'm73-res-short-2'
  );
  if header ->> 'status' is distinct from 'allocated' then
    raise exception 'reallocate after cancel failed: %', header;
  end if;
  if header -> 'fulfilment' ->> 'allocated_cases' is distinct from '2' then
    raise exception 'reallocate did not restore full fill: %', header -> 'fulfilment';
  end if;
end $$;

-- Original order quantities and voided DN history stay intact.
reset role;
do $$
begin
  if (select requested_cases from public.order_lines
      where order_id = current_setting('sherlyos.order_short')::uuid) is distinct from 2 then
    raise exception 'original order quantity must not change';
  end if;
  if (select status from public.delivery_notes where id = current_setting('sherlyos.dn_full')::uuid)
    is distinct from 'voided'
  then
    raise exception 'voided DN history lost';
  end if;
end $$;

rollback;
