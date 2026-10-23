-- M2 local disposable SQL. Rolls back. Does not touch development cloud.
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
  fixture.name || '.m2pk@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M2 Admin', true)
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

-- Cutover off: preview fail-closed
select pg_temp.as_user('admin');
set local role authenticated;
select set_config('sherlyos.branch', public.create_branch('m2pk_a', 'M2PK A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('m2pk_b', 'M2PK B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'other'), current_setting('sherlyos.branch_b')::uuid);
select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'z1', 'Z1', null)::text, true);
select set_config('sherlyos.crate_a', public.create_crate(current_setting('sherlyos.zone')::uuid, 'ca', 'CA', null)::text, true);
select set_config('sherlyos.crate_b', public.create_crate(current_setting('sherlyos.zone')::uuid, 'cb', 'CB', null)::text, true);
select set_config('sherlyos.exp', public.create_product('m2pk-exp', 'M2PK Expiry', null, null)::text, true);
select set_config('sherlyos.nx', public.create_product('m2pk-nx', 'M2PK Non-expiring', null, null)::text, true);
select set_config('sherlyos.unclass', public.create_product('m2pk-un', 'M2PK Unclass', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.exp')::uuid, 'expiry_controlled');
select public.set_product_expiry_policy(current_setting('sherlyos.nx')::uuid, 'non_expiring');
select set_config('sherlyos.shop', public.create_shop('M2PK shop', null, null)::text, true);

-- Fail-closed before lots exist: dual-write is still off.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_closed',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.exp')::uuid, 'requested_cases', 1)
      ),
      'm2pk-order-closed'
    ) -> 'order' ->> 'id'
  ),
  true
);
select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
begin
  preview := public.preview_order_allocation(current_setting('sherlyos.order_closed')::uuid);
  if preview ->> 'eligible' is distinct from 'false' then
    raise exception 'picking must fail closed without dual-write: %', preview;
  end if;
  if coalesce(preview -> 'blockers' ->> 0, '') not like '%dual-write%' then
    raise exception 'expected dual-write blocker, got %', preview -> 'blockers';
  end if;
end $$;

-- Seed-only window (blocked, dual-write still off) is not a picking workaround.
reset role;
update public.app_configuration set value = 'true'::jsonb
where key = 'stock.lots.aggregate_only_blocked';
select pg_temp.as_user('godown');
set local role authenticated;
do $$
declare
  preview jsonb;
  blockers text;
begin
  preview := public.preview_order_allocation(current_setting('sherlyos.order_closed')::uuid);
  blockers := (preview -> 'blockers')::text;
  if preview ->> 'eligible' is distinct from 'false' then
    raise exception 'seed-only window must not allow picking: %', preview;
  end if;
  if blockers not like '%dual-write%' or blockers not like '%aggregate posting%' then
    raise exception 'expected dual-write and seed-only blockers, got %', preview -> 'blockers';
  end if;
end $$;

reset role;
update public.app_configuration set value = 'true'::jsonb
where key = 'stock.lots.aggregate_only_blocked';
update public.app_configuration set value = 'true'::jsonb
where key = 'stock.lots.dual_write_enabled';

select pg_temp.as_user('admin');
set local role authenticated;

-- Two FEFO lots: earlier expiry must be allocated first.
select public.post_opening_stock(
  current_setting('sherlyos.exp')::uuid, current_setting('sherlyos.crate_a')::uuid,
  4, 'm2pk-open-exp-late', null, 'BATCH-LATE', null, '2028-12-01'
);
select public.post_opening_stock(
  current_setting('sherlyos.exp')::uuid, current_setting('sherlyos.crate_b')::uuid,
  4, 'm2pk-open-exp-early', null, 'BATCH-EARLY', null, '2027-01-15'
);
-- FIFO lots
select public.post_opening_stock(
  current_setting('sherlyos.nx')::uuid, current_setting('sherlyos.crate_a')::uuid,
  3, 'm2pk-open-nx-old', null, 'NX-OLD', null, null
);
select public.post_opening_stock(
  current_setting('sherlyos.nx')::uuid, current_setting('sherlyos.crate_b')::uuid,
  3, 'm2pk-open-nx-new', null, 'NX-NEW', null, null
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
        jsonb_build_object('product_id', current_setting('sherlyos.exp')::uuid, 'requested_cases', 5),
        jsonb_build_object('product_id', current_setting('sherlyos.nx')::uuid, 'requested_cases', 2)
      ),
      'm2pk-order-1'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order')::uuid, 1, 'm2pk-sub-1');
select public.verify_order(current_setting('sherlyos.order')::uuid, 2, 'm2pk-ver-1');

-- Store keeper cannot preview
select pg_temp.as_user('keeper');
do $$
begin
  begin
    perform public.preview_order_allocation(current_setting('sherlyos.order')::uuid);
    raise exception 'store keeper must not preview allocation';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Cross-branch manager cannot allocate
select pg_temp.as_user('other');
do $$
begin
  begin
    perform public.preview_order_allocation(current_setting('sherlyos.order')::uuid);
    raise exception 'cross-branch manager must not preview';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
  line jsonb;
  first_lot text;
begin
  preview := public.preview_order_allocation(current_setting('sherlyos.order')::uuid);
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

do $$
declare
  payload jsonb;
  replay jsonb;
begin
  payload := public.reserve_order_allocation(
    current_setting('sherlyos.order')::uuid, 3, 'm2pk-reserve-1'
  );
  if payload ->> 'status' is distinct from 'allocated' then
    raise exception 'reserve should create allocated request';
  end if;
  replay := public.reserve_order_allocation(
    current_setting('sherlyos.order')::uuid, 3, 'm2pk-reserve-1'
  );
  if replay ->> 'id' is distinct from payload ->> 'id' then
    raise exception 'idempotent reserve must replay';
  end if;
  perform set_config('sherlyos.request', payload ->> 'id', true);
end $$;

-- Duplicate second reservation on same order blocked
do $$
begin
  begin
    perform public.reserve_order_allocation(
      current_setting('sherlyos.order')::uuid, 3, 'm2pk-reserve-dup'
    );
    raise exception 'second active reservation must fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Direct DML denied
do $$
begin
  begin
    insert into public.stock_reservations (
      picking_request_id, order_id, order_line_id, product_id, crate_id, lot_id,
      branch_id, reserved_cases, status, created_by
    )
    select id, order_id, gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      gen_random_uuid(), branch_id, 1, 'active', created_by
    from public.stock_picking_requests
    where id = current_setting('sherlyos.request')::uuid;
    raise exception 'direct reservation insert must fail';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Transfer cannot consume reserved stock
select pg_temp.as_user('admin');
do $$
declare
  exp_lot uuid;
  crate uuid := current_setting('sherlyos.crate_b')::uuid;
  dest uuid := current_setting('sherlyos.crate_a')::uuid;
begin
  select stock_reservations.lot_id into exp_lot
  from public.stock_reservations
  join public.stock_lots on stock_lots.id = stock_reservations.lot_id
  where stock_reservations.picking_request_id = current_setting('sherlyos.request')::uuid
    and stock_lots.manufacturer_lot_code = 'BATCH-EARLY';

  begin
    perform public.post_crate_transfer(
      current_setting('sherlyos.exp')::uuid, crate, dest, 4,
      'm2pk-xfer-reserved', null,
      jsonb_build_array(jsonb_build_object('lot_id', exp_lot, 'quantity', 4))
    );
    raise exception 'transfer must not consume reserved lot stock';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

select pg_temp.as_user('godown');
select public.assign_picking_request(
  current_setting('sherlyos.request')::uuid,
  (select id from fixture where name = 'keeper'),
  1,
  'm2pk-assign-1'
);
select public.start_picking(current_setting('sherlyos.request')::uuid, 2, 'm2pk-start-1');

select pg_temp.as_user('keeper');
do $$
declare
  header jsonb;
  res jsonb;
  payload jsonb;
begin
  header := public.get_picking_request(current_setting('sherlyos.request')::uuid);
  res := header -> 'reservations' -> 0;
  payload := public.confirm_picking_quantity(
    current_setting('sherlyos.request')::uuid,
    (res ->> 'id')::uuid,
    (res ->> 'reserved_cases')::integer,
    (header ->> 'version')::integer,
    'm2pk-pick-1'
  );
  if payload -> 'reservations' -> 0 ->> 'picked_cases' is distinct from res ->> 'reserved_cases' then
    raise exception 'confirm pick did not store quantity';
  end if;
end $$;

-- Confirm remaining reservations then complete
do $$
declare
  header jsonb;
  res jsonb;
  i int;
begin
  header := public.get_picking_request(current_setting('sherlyos.request')::uuid);
  for i in 0 .. jsonb_array_length(header -> 'reservations') - 1 loop
    res := header -> 'reservations' -> i;
    if (res ->> 'picked_cases')::int is distinct from (res ->> 'reserved_cases')::int then
      header := public.confirm_picking_quantity(
        current_setting('sherlyos.request')::uuid,
        (res ->> 'id')::uuid,
        (res ->> 'reserved_cases')::integer,
        (header ->> 'version')::integer,
        'm2pk-pick-rest-' || i::text
      );
    end if;
  end loop;
  header := public.complete_picking(
    current_setting('sherlyos.request')::uuid,
    (header ->> 'version')::integer,
    'm2pk-complete-1'
  );
  if header ->> 'status' is distinct from 'picked' then
    raise exception 'complete should mark picked';
  end if;
end $$;

select pg_temp.as_user('godown');
do $$
declare
  header jsonb;
  handoff jsonb;
begin
  header := public.get_picking_request(current_setting('sherlyos.request')::uuid);
  header := public.confirm_picking_handoff(
    current_setting('sherlyos.request')::uuid,
    (header ->> 'version')::integer,
    'm2pk-handoff-1'
  );
  if header ->> 'status' is distinct from 'ready_for_dispatch' then
    raise exception 'handoff failed';
  end if;
  handoff := public.get_picking_handoff(current_setting('sherlyos.request')::uuid);
  if coalesce(handoff ->> 'stock_consumed', 'true') is distinct from 'false' then
    raise exception 'M2 must not consume stock';
  end if;
end $$;

-- Ledger unchanged by picking
do $$
declare
  lot_ledger integer;
begin
  select count(*) into lot_ledger from public.stock_ledger
  where lot_id in (
    select lot_id from public.stock_reservations
    where picking_request_id = current_setting('sherlyos.request')::uuid
  )
  and transaction_id in (
    select id from public.stock_transactions where transaction_type <> 'OPENING_STOCK'
  );
  if lot_ledger <> 0 then
    raise exception 'picking must not add non-opening lot ledger rows';
  end if;
end $$;

-- Remaining unreserved FEFO stock is BATCH-LATE (3). Verify still uses aggregate on-hand.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_cutover',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.exp')::uuid, 'requested_cases', 1)
      ),
      'm2pk-order-cutover'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_cutover')::uuid, 1, 'm2pk-sub-cutover');
select public.verify_order(current_setting('sherlyos.order_cutover')::uuid, 2, 'm2pk-ver-cutover');

select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
begin
  preview := public.preview_order_allocation(current_setting('sherlyos.order_cutover')::uuid);
  if preview ->> 'eligible' is distinct from 'true' then
    raise exception 'eligible leftover FEFO stock should preview: %', preview;
  end if;
end $$;

-- Expired lots are excluded from FEFO.
reset role;
update public.stock_lots
set expiry_date = current_date - 10
where manufacturer_lot_code = 'BATCH-LATE';

select pg_temp.as_user('godown');
set local role authenticated;
do $$
declare
  preview jsonb;
begin
  preview := public.preview_order_allocation(current_setting('sherlyos.order_cutover')::uuid);
  if preview ->> 'eligible' is distinct from 'false' then
    raise exception 'expired leftover stock must not FEFO-allocate: %', preview;
  end if;
end $$;

-- Shortage releases the unpicked hold without a ledger debit.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_short',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.nx')::uuid, 'requested_cases', 1)
      ),
      'm2pk-order-short'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order_short')::uuid, 1, 'm2pk-sub-short');
select public.verify_order(current_setting('sherlyos.order_short')::uuid, 2, 'm2pk-ver-short');

select pg_temp.as_user('godown');
do $$
declare
  payload jsonb;
  res jsonb;
begin
  payload := public.reserve_order_allocation(
    current_setting('sherlyos.order_short')::uuid, 3, 'm2pk-reserve-short'
  );
  payload := public.assign_picking_request(
    (payload ->> 'id')::uuid,
    (select id from fixture where name = 'keeper'),
    (payload ->> 'version')::integer,
    'm2pk-assign-short'
  );
  payload := public.start_picking(
    (payload ->> 'id')::uuid, (payload ->> 'version')::integer, 'm2pk-start-short'
  );
  perform set_config('sherlyos.short_request', payload ->> 'id', true);
  res := payload -> 'reservations' -> 0;
  perform set_config('sherlyos.short_res', res ->> 'id', true);
  perform set_config('sherlyos.short_version', payload ->> 'version', true);
end $$;

select pg_temp.as_user('keeper');
do $$
declare
  payload jsonb;
begin
  payload := public.report_picking_shortage(
    current_setting('sherlyos.short_request')::uuid,
    current_setting('sherlyos.short_res')::uuid,
    1,
    'carton missing in crate',
    current_setting('sherlyos.short_version')::integer,
    'm2pk-short-1'
  );
  if payload -> 'reservations' -> 0 ->> 'status' is distinct from 'released' then
    raise exception 'full shortage must release the hold: %', payload;
  end if;
  payload := public.complete_picking(
    current_setting('sherlyos.short_request')::uuid,
    (payload ->> 'version')::integer,
    'm2pk-complete-short'
  );
  if payload ->> 'status' is distinct from 'picked' then
    raise exception 'shortage completion should mark picked: %', payload;
  end if;
end $$;

-- Unclassified products cannot allocate even after dual-write.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order_unclass',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.unclass')::uuid, 'requested_cases', 1)
      ),
      'm2pk-order-unclass'
    ) -> 'order' ->> 'id'
  ),
  true
);
select pg_temp.as_user('godown');
do $$
declare
  preview jsonb;
  line jsonb;
begin
  preview := public.preview_order_allocation(current_setting('sherlyos.order_unclass')::uuid);
  if preview ->> 'eligible' is distinct from 'false' then
    raise exception 'unclassified product must not be eligible';
  end if;
  line := preview -> 'lines' -> 0;
  if coalesce(line ->> 'eligible', 'true') is distinct from 'false' then
    raise exception 'unclassified line must be blocked: %', line;
  end if;
end $$;

-- Delivery notes stay Phase 4.2 paperwork: allowed from verified without picking,
-- and they must not write the ledger or release holds.
reset role;
do $$
begin
  begin
    perform app_private.assert_picking_handoff_for_dispatch(
      current_setting('sherlyos.order_cutover')::uuid
    );
    raise exception 'M3 helper must reject verified orders without a handoff';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

select set_config(
  'sherlyos.ledger_before',
  (select count(*)::text from public.stock_ledger),
  true
);
select pg_temp.as_user('accounts');
set local role authenticated;
do $$
declare
  note jsonb;
begin
  note := public.create_delivery_note(
    current_setting('sherlyos.order_cutover')::uuid,
    'm2pk-dn-paper'
  );
  if note -> 'delivery_note' ->> 'status' is distinct from 'draft' then
    raise exception 'delivery note should remain paperwork: %', note;
  end if;
end $$;

reset role;
do $$
declare
  holds integer;
  ledger_after integer;
begin
  select count(*) into ledger_after from public.stock_ledger;
  if ledger_after::text is distinct from current_setting('sherlyos.ledger_before') then
    raise exception 'delivery note must not write stock_ledger';
  end if;
  select count(*) into holds
  from public.stock_reservations
  where picking_request_id = current_setting('sherlyos.request')::uuid
    and status = 'active';
  if holds < 1 then
    raise exception 'delivery note must not release picking holds';
  end if;
end $$;

reset role;
do $$
begin
  if app_private.assert_picking_handoff_for_dispatch(
    current_setting('sherlyos.order')::uuid
  ) is null then
    raise exception 'M3 helper must accept a ready_for_dispatch handoff';
  end if;
end $$;

-- Zero/negative quantity rejected
select pg_temp.as_user('keeper');
do $$
begin
  begin
    perform public.confirm_picking_quantity(
      current_setting('sherlyos.request')::uuid,
      (select id from public.stock_reservations limit 1),
      0, 1, 'm2pk-zero'
    );
    raise exception 'zero pick must fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

rollback;
