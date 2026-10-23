-- M4 local disposable SQL. Rolls back. Does not touch development cloud.
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
  ('other', gen_random_uuid()),
  ('sales', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.m4qi@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M4 Admin', true)
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
  when 'sales' then 'salesperson'
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

create or replace function pg_temp.expect(ok boolean, msg text)
returns void language plpgsql as $$
begin
  if not ok then
    raise exception '%', msg;
  end if;
end;
$$;

-- Cutover must stay inactive for the first reporting block.
select pg_temp.expect(
  coalesce((select value from public.app_configuration where key = 'stock.lots.dual_write_enabled'), 'false'::jsonb)
    = 'false'::jsonb
  and coalesce((select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked'), 'false'::jsonb)
    = 'false'::jsonb,
  'cutover flags must be false at M4 start'
);

-- CSV formula injection is escaped before any operational data exists.
select pg_temp.expect(
  app_private.report_csv_cell('=1+1') = '"''=1+1"',
  'csv formula prefix'
);
select pg_temp.expect(
  app_private.report_csv_cell('a"b') = '"a""b"',
  'csv quote escape'
);
select pg_temp.expect(
  app_private.report_csv_cell(' =1+1') = '"'' =1+1"',
  'csv leading space formula'
);
select pg_temp.expect(
  app_private.report_csv_cell(E'\t=1+1') = '"' || '''' || E'\t=1+1' || '"',
  'csv leading tab formula'
);
select pg_temp.expect(
  app_private.report_csv_cell(E'\n+cmd') = '"' || '''' || E'\n+cmd' || '"',
  'csv leading newline formula'
);
select pg_temp.expect(
  app_private.report_csv_cell(E'\r-1+1') = '"' || '''' || E'\r-1+1' || '"',
  'csv leading cr formula'
);
select pg_temp.expect(
  app_private.report_csv_cell(chr(1) || '@SUM') = '"' || '''' || chr(1) || '@SUM' || '"',
  'csv leading control formula'
);
select pg_temp.expect(
  app_private.report_csv_cell(chr(160) || '=1+1') = '"' || '''' || chr(160) || '=1+1' || '"',
  'csv leading nbsp formula'
);
select pg_temp.expect(
  app_private.report_csv_cell(chr(65279) || '=1+1') = '"' || '''' || chr(65279) || '=1+1' || '"',
  'csv leading bom formula'
);
select pg_temp.expect(
  app_private.report_csv_cell('safe-name') = '"safe-name"',
  'csv ordinary hyphen stays unprefixed'
);

select pg_temp.as_user('admin');
set local role authenticated;

select set_config('sherlyos.branch', public.create_branch('m4qi_a', 'M4QI A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('m4qi_b', 'M4QI B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'keeper'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'driver'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'sales'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'other'), current_setting('sherlyos.branch_b')::uuid);
select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'z1', 'Z1', null)::text, true);
select set_config('sherlyos.crate', public.create_crate(current_setting('sherlyos.zone')::uuid, 'c1', 'C1', null)::text, true);
select set_config('sherlyos.crate_b', public.create_crate(current_setting('sherlyos.zone')::uuid, 'c2', 'C2', null)::text, true);
select set_config('sherlyos.product', public.create_product('m4qi-soap', '=CMD soap', null, null)::text, true);
select set_config('sherlyos.product2', public.create_product('m4qi-oil', 'M4QI oil', null, null)::text, true);
select set_config('sherlyos.product3', public.create_product('m4qi-lot', 'M4QI lot soap', null, null)::text, true);
select set_config('sherlyos.shop', public.create_shop('M4QI shop', null, null)::text, true);
select public.assign_shop_salesperson(
  current_setting('sherlyos.shop')::uuid,
  (select id from fixture where name = 'sales')
);

-- Empty-ish dashboard before opening stock (unclassified products still count).
do $$
declare
  dash jsonb;
begin
  dash := public.get_operations_dashboard(null);
  perform pg_temp.expect(dash ->> 'timezone' = 'UTC', 'dashboard timezone');
  perform pg_temp.expect((dash -> 'cutover' ->> 'dual_write_enabled')::boolean is false, 'cutover off');
  perform pg_temp.expect(
    dash -> 'inventory' -> 'available_to_pick' ->> 'state' = 'not_applicable',
    'available-to-pick not applicable'
  );
  perform pg_temp.expect(dash -> 'inventory' -> 'available_to_pick' ->> 'value' is null, 'available-to-pick value null');
  perform pg_temp.expect((dash -> 'inventory' ->> 'total_cartons_on_hand')::int = 0, 'empty on-hand');
  perform pg_temp.expect((dash -> 'inventory' ->> 'lot_attributed_cartons')::int = 0, 'empty lots');
end $$;

select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate')::uuid,
  10, 'm4qi-open-1', null
);
select public.post_opening_stock(
  current_setting('sherlyos.product2')::uuid,
  current_setting('sherlyos.crate')::uuid,
  4, 'm4qi-open-2', null
);

do $$
declare
  dash jsonb;
  inv jsonb;
  before_qty integer;
  after_qty integer;
  moved jsonb;
  page1 jsonb;
  page2 jsonb;
  export jsonb;
  orders jsonb;
begin
  select coalesce(sum(quantity), 0) into before_qty from public.stock_balances;

  dash := public.get_operations_dashboard(null);
  inv := public.list_inventory_report('crate', null, null, null, null, null, null, false, 1, 50);
  moved := public.list_stock_movement_report(null, null, null, null, null, 1, 50);
  perform public.list_lot_stock_report(null, null, null, null, null, 1, 50);
  perform public.list_order_picking_report(null, null, null, null, null, null, null, 1, 50);
  perform public.list_dispatch_delivery_report(null, null, null, null, 1, 50);
  perform public.list_operations_exceptions(null, 1, 50);
  export := public.export_operations_report(
    'inventory', 'crate', null, null, null, null, null, null, false,
    null, null, null, null, null, null, null, null, null, null
  );

  select coalesce(sum(quantity), 0) into after_qty from public.stock_balances;
  perform pg_temp.expect(before_qty = after_qty, 'report rpcs must not change stock');
  perform pg_temp.expect((dash -> 'inventory' ->> 'total_cartons_on_hand')::int = 14, 'on-hand 14');
  perform pg_temp.expect((dash -> 'inventory' ->> 'products_with_positive_stock')::int = 2, 'two products');
  perform pg_temp.expect((dash -> 'inventory' ->> 'active_reserved_cartons')::int = 0, 'no reservations');
  perform pg_temp.expect(
    dash -> 'inventory' -> 'available_to_pick' ->> 'state' = 'not_applicable',
    'on-hand is not available-to-pick'
  );
  perform pg_temp.expect((dash -> 'inventory' ->> 'lot_attributed_cartons')::int = 0, 'no lots while cutover off');
  perform pg_temp.expect((inv ->> 'total_count')::int = 2, 'inventory rows');
  perform pg_temp.expect((moved -> 'summary' ->> 'opening_cartons')::int = 14, 'opening summary');
  perform pg_temp.expect((moved -> 'summary' ->> 'transfer_cartons')::int = 0, 'no transfers yet');
  perform pg_temp.expect(export ->> 'csv' like '%grain%', 'csv header');
  perform pg_temp.expect(export ->> 'csv' like '%''=CMD soap%' or export ->> 'csv' like '%"=CMD soap%', 'csv formula protected');

  page1 := public.list_inventory_report('product', null, null, null, null, null, null, false, 1, 1);
  page2 := public.list_inventory_report('product', null, null, null, null, null, null, false, 2, 1);
  perform pg_temp.expect((page1 ->> 'page_size')::int = 1, 'page size');
  perform pg_temp.expect((page1 ->> 'total_count')::int = 2, 'paged total');
  perform pg_temp.expect(
    page1 -> 'rows' -> 0 ->> 'row_key' is distinct from page2 -> 'rows' -> 0 ->> 'row_key',
    'stable pagination'
  );

  -- Future UTC window excludes today's opening.
  moved := public.list_stock_movement_report(
    null, null, 'OPENING_STOCK',
    (date_trunc('day', timezone('UTC', clock_timestamp())) + interval '1 day'),
    (date_trunc('day', timezone('UTC', clock_timestamp())) + interval '2 day'),
    1, 50
  );
  perform pg_temp.expect((moved ->> 'total_count')::int = 0, 'future window empty');

  moved := public.list_stock_movement_report(
    null, null, 'OPENING_STOCK',
    date_trunc('day', timezone('UTC', clock_timestamp())),
    date_trunc('day', timezone('UTC', clock_timestamp())) + interval '1 day',
    1, 50
  );
  perform pg_temp.expect((moved ->> 'total_count')::int = 2, 'today half-open includes opening');

  begin
    perform public.list_stock_movement_report(null, null, null, clock_timestamp(), clock_timestamp() - interval '1 hour', 1, 50);
    raise exception 'inverted window must fail';
  exception
    when sqlstate '23514' then null;
  end;

  begin
    perform public.list_stock_movement_report(null, null, null, clock_timestamp(), clock_timestamp(), 1, 50);
    raise exception 'empty interval must fail';
  exception
    when sqlstate '23514' then null;
  end;

  moved := public.list_stock_movement_report(
    null, null, 'OPENING_STOCK',
    date_trunc('day', timezone('UTC', clock_timestamp())) - interval '1 day',
    date_trunc('day', timezone('UTC', clock_timestamp())),
    1, 50
  );
  perform pg_temp.expect((moved ->> 'total_count')::int = 0, 'previous UTC day exclusive of today');

  moved := public.list_stock_movement_report(
    null, null, 'OPENING_STOCK',
    date_trunc('month', timezone('UTC', clock_timestamp())),
    date_trunc('month', timezone('UTC', clock_timestamp())) + interval '1 month',
    1, 50
  );
  perform pg_temp.expect((moved ->> 'total_count')::int = 2, 'month window includes opening');

  moved := public.list_stock_movement_report(
    null, null, 'OPENING_STOCK',
    date_trunc('year', timezone('UTC', clock_timestamp())),
    date_trunc('year', timezone('UTC', clock_timestamp())) + interval '1 year',
    1, 50
  );
  perform pg_temp.expect((moved ->> 'total_count')::int = 2, 'year window includes opening');

  page1 := public.list_inventory_report('product', null, null, null, null, null, null, false, 1, 500);
  perform pg_temp.expect((page1 ->> 'page_size')::int = 100, 'page size clamped to 100');

  begin
    perform app_private.report_csv_cell('ok');
    raise exception 'authenticated must not execute private csv helper';
  exception
    when insufficient_privilege then null;
  end;

  orders := public.list_order_picking_report(null, null, null, null, null, null, null, 1, 50);
  perform pg_temp.expect((orders ->> 'total_count')::int = 0, 'no orders yet');
end $$;

select public.post_crate_transfer(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate')::uuid,
  current_setting('sherlyos.crate_b')::uuid,
  3, 'm4qi-xfer-1', null
);

do $$
declare
  moved jsonb;
  dash jsonb;
begin
  moved := public.list_stock_movement_report(null, null, 'CRATE_TRANSFER', null, null, 1, 50);
  perform pg_temp.expect((moved ->> 'total_count')::int = 1, 'transfer counted once');
  perform pg_temp.expect((moved -> 'summary' ->> 'transfer_cartons')::int = 3, 'transfer quantity once');
  dash := public.get_operations_dashboard(null);
  perform pg_temp.expect((dash -> 'inventory' ->> 'total_cartons_on_hand')::int = 14, 'transfer does not inflate on-hand');
end $$;

select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.order',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 2)
      ),
      'm4qi-order-1'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.order')::uuid, 1, 'm4qi-sub-1');
select public.verify_order(current_setting('sherlyos.order')::uuid, 2, 'm4qi-ver-1');

select pg_temp.as_user('sales');
select set_config(
  'sherlyos.sales_order',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'salesperson', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product')::uuid, 'requested_cases', 1)
      ),
      'm4qi-order-sales'
    ) -> 'order' ->> 'id'
  ),
  true
);

select pg_temp.as_user('godown');
do $$
declare
  dash jsonb;
  orders jsonb;
begin
  dash := public.get_operations_dashboard(null);
  perform pg_temp.expect((dash -> 'orders' ->> 'verified')::int >= 1, 'verified orders');
  perform pg_temp.expect((dash -> 'orders' ->> 'awaiting_picking')::int >= 1, 'awaiting picking');
  perform pg_temp.expect((dash -> 'orders' ->> 'draft')::int = 0, 'godown does not see salesperson drafts');
  orders := public.list_order_picking_report(null, null, null, 'verified', 'none', null, null, 1, 50);
  perform pg_temp.expect((orders ->> 'total_count')::int >= 1, 'verified awaiting allocation');
  perform pg_temp.expect((orders -> 'rows' -> 0 ->> 'stock_dispatched')::boolean is false, 'not dispatched');
  perform pg_temp.expect((orders -> 'rows' -> 0 ->> 'awaiting_allocation')::boolean, 'awaiting allocation');
end $$;

-- Salesperson cannot filter by another salesperson and sees only own rows.
select pg_temp.as_user('sales');
do $$
declare
  orders jsonb;
begin
  begin
    perform public.list_order_picking_report(
      null, null, (select id from fixture where name = 'accounts'), null, null, null, null, 1, 50
    );
    raise exception 'salesperson must not filter by other salesperson';
  exception
    when sqlstate '42501' then null;
  end;
  orders := public.list_order_picking_report(null, null, null, null, null, null, null, 1, 50);
  perform pg_temp.expect((orders ->> 'total_count')::int = 1, 'salesperson own orders only');
  perform pg_temp.expect(orders -> 'rows' -> 0 ->> 'order_status' = 'draft', 'salesperson own draft');
end $$;

-- Cross-branch godown manager denied, including unfiltered leakage.
select pg_temp.as_user('other');
do $$
declare
  inv jsonb;
begin
  begin
    perform public.get_operations_dashboard(current_setting('sherlyos.branch')::uuid);
    raise exception 'cross-branch dashboard must be denied';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.list_inventory_report(
      'crate', current_setting('sherlyos.branch')::uuid, null, null, null, null, null, false, 1, 50
    );
    raise exception 'cross-branch inventory must be denied';
  exception
    when sqlstate '42501' then null;
  end;
  inv := public.list_inventory_report('crate', null, null, null, null, null, null, false, 1, 50);
  perform pg_temp.expect((inv ->> 'total_count')::int = 0, 'other branch inventory empty');
  perform pg_temp.expect(inv ->> 'rows' not like '%m4qi-soap%', 'no cross-branch sku in other inventory');
end $$;

-- Driver cannot read inventory; can read assigned dispatch only.
select pg_temp.as_user('driver');
do $$
declare
  dash jsonb;
  dispatch jsonb;
begin
  begin
    perform public.list_inventory_report('crate', null, null, null, null, null, null, false, 1, 50);
    raise exception 'driver must not read inventory report';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.list_inventory_report(
      'crate', current_setting('sherlyos.branch')::uuid, null, null, null, null, null, false, 1, 50
    );
    raise exception 'driver assigned-branch inventory must be denied';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.export_operations_report(
      'inventory', 'crate', null, null, null, null, null, null, false,
      null, null, null, null, null, null, null, null, null, null
    );
    raise exception 'driver must not export inventory';
  exception
    when sqlstate '42501' then null;
  end;
  dash := public.get_operations_dashboard(null);
  perform pg_temp.expect((dash -> 'inventory' ->> 'visible')::boolean is not true, 'driver inventory hidden');
  perform pg_temp.expect((dash -> 'deliveries' ->> 'visible')::boolean, 'driver deliveries visible');
  perform pg_temp.expect((dash -> 'dispatch' ->> 'visible')::boolean, 'driver dispatch group visible');
  dispatch := public.list_dispatch_delivery_report(null, null, null, null, 1, 50);
  perform pg_temp.expect((dispatch ->> 'total_count')::int = 0, 'driver has no assigned dispatches');
end $$;

-- Store keeper can read inventory and orders/picking, not dispatch or capture drafts.
select pg_temp.as_user('keeper');
do $$
declare
  inv jsonb;
  dash jsonb;
  orders jsonb;
begin
  inv := public.list_inventory_report('godown', null, null, null, null, null, null, false, 1, 50);
  perform pg_temp.expect((inv ->> 'total_count')::int = 1, 'keeper godown grain');
  dash := public.get_operations_dashboard(null);
  perform pg_temp.expect((dash -> 'orders' ->> 'draft')::int = 0, 'keeper cannot count salesperson drafts');
  orders := public.list_order_picking_report(null, null, null, 'draft', null, null, null, 1, 50);
  perform pg_temp.expect((orders ->> 'total_count')::int = 0, 'keeper cannot list capture drafts');
  orders := public.list_order_picking_report(null, null, null, 'verified', null, null, null, 1, 50);
  perform pg_temp.expect((orders ->> 'total_count')::int >= 1, 'keeper can list verified workload');
  begin
    perform public.list_dispatch_delivery_report(null, null, null, null, 1, 50);
    raise exception 'store keeper must not read dispatch report';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.export_operations_report(
      'dispatch', 'crate', null, null, null, null, null, null, false,
      null, null, null, null, null, null, null, null, null, null
    );
    raise exception 'store keeper must not export dispatch';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Delivery-note paperwork must not count as customer proof of delivery.
select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.dn',
  (
    public.create_delivery_note(
      current_setting('sherlyos.order')::uuid,
      'm4qi-dn-create-01'
    ) -> 'delivery_note' ->> 'id'
  ),
  true
);

select pg_temp.as_user('godown');
do $$
declare
  dash jsonb;
  note_count integer;
begin
  select count(*) into note_count
  from public.delivery_notes
  where delivery_notes.order_id = current_setting('sherlyos.order')::uuid;
  perform pg_temp.expect(note_count = 1, 'delivery note exists');
  dash := public.get_operations_dashboard(null);
  perform pg_temp.expect((dash -> 'dispatch' ->> 'delivered')::int = 0, 'dn paperwork is not customer pod');
  perform pg_temp.expect((dash -> 'dispatch' ->> 'dispatched')::int = 0, 'dn does not consume stock');
end $$;

-- Bounded inventory pages and formula-prefixed user text in export.
select pg_temp.as_user('admin');
do $$
declare
  i integer;
  pid uuid;
  inv jsonb;
  export jsonb;
  plan jsonb;
  order_count integer;
  order_count_after integer;
  balance_before integer;
  balance_after integer;
begin
  select count(*) into order_count from public.orders;
  select coalesce(sum(quantity), 0) into balance_before from public.stock_balances;

  pid := public.create_product('m4qi-inj', chr(160) || '=SUM(A1)', null, null);
  perform public.post_opening_stock(
    pid, current_setting('sherlyos.crate')::uuid, 1, 'm4qi-open-inj', null
  );

  for i in 1..40 loop
    pid := public.create_product(
      'm4qi-p' || lpad(i::text, 3, '0'),
      'M4QI perf ' || i::text,
      null,
      null
    );
    perform public.post_opening_stock(
      pid,
      current_setting('sherlyos.crate')::uuid,
      1,
      'm4qi-perf-' || lpad(i::text, 3, '0'),
      null
    );
  end loop;

  inv := public.list_inventory_report('product', null, null, null, null, null, null, false, 1, 10);
  perform pg_temp.expect((inv ->> 'total_count')::int >= 43, 'perf inventory total');
  perform pg_temp.expect(jsonb_array_length(inv -> 'rows') = 10, 'perf inventory page bounded');

  execute
    'explain (analyze, buffers, format json)
     select stock_balances.quantity
     from public.stock_balances
     join public.crates on crates.id = stock_balances.crate_id
     join public.zones on zones.id = crates.zone_id
     where zones.branch_id = $1
     order by stock_balances.product_id
     limit 10'
  into plan
  using current_setting('sherlyos.branch')::uuid;
  raise notice 'm4 inventory plan %', plan;
  perform pg_temp.expect(plan is not null, 'inventory join has a plan');

  export := public.export_operations_report(
    'inventory', 'product', null, null, null, null, null, null, false,
    null, null, null, null, null, null, null, null, null, null
  );
  perform pg_temp.expect(
    export ->> 'csv' like '%' || '''' || chr(160) || '=SUM(A1)%',
    'export prefixes nbsp formula name'
  );
  perform pg_temp.expect((export ->> 'truncated')::boolean is false, 'export under cap');
  perform pg_temp.expect((export ->> 'row_count')::int = (export ->> 'total_count')::int, 'export count matches');

  perform public.get_operations_dashboard(null);
  perform public.list_stock_movement_report(null, null, null, null, null, 1, 50);
  select count(*) into order_count_after from public.orders;
  select coalesce(sum(quantity), 0) into balance_after from public.stock_balances;
  perform pg_temp.expect(order_count = order_count_after, 'reporting cannot create orders');
  perform pg_temp.expect(balance_after = balance_before + 41, 'reporting cannot change opening stock');
end $$;

-- Anonymous denied.
reset role;
set local role anon;
do $$
begin
  begin
    perform public.get_operations_dashboard(null);
    raise exception 'anon dashboard';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.export_operations_report(
      'inventory', 'crate', null, null, null, null, null, null, false,
      null, null, null, null, null, null, null, null, null, null
    );
    raise exception 'anon export';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Unknown expiry fixture: expiry-controlled product with a null date stays unknown.
select pg_temp.as_user('admin');
set local role authenticated;
select public.set_product_expiry_policy(current_setting('sherlyos.product')::uuid, 'expiry_controlled');

reset role;
set session_replication_role = replica;
insert into public.stock_lots (
  product_id, branch_id, status, origin, expiry_date, received_on, created_by
)
values (
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.branch')::uuid,
  'available',
  'opening',
  null,
  clock_timestamp(),
  (select id from fixture where name = 'admin')
);
insert into public.stock_lot_balances (lot_id, crate_id, quantity)
select id, current_setting('sherlyos.crate')::uuid, 1
from public.stock_lots
where product_id = current_setting('sherlyos.product')::uuid
  and expiry_date is null
limit 1;
set session_replication_role = origin;

select pg_temp.as_user('admin');
set local role authenticated;
do $$
declare
  lots jsonb;
begin
  lots := public.list_lot_stock_report(null, null, null, null, 'unknown_expiry', 1, 50);
  perform pg_temp.expect((lots ->> 'total_count')::int >= 1, 'unknown expiry bucket');
  perform pg_temp.expect(lots -> 'rows' -> 0 ->> 'expiry_date' is null, 'unknown stays unknown');
  perform pg_temp.expect((lots ->> 'near_expiry_warning_days')::int = 90, 'approved 90-day window');
end $$;

-- Dual-write disposable dispatch: preparing is not dispatched; confirm is unique.
-- Replica bypasses the unmatched-grain guard because this transaction already
-- holds aggregate-only opening rows. Flags are restored before rollback.
reset role;
set session_replication_role = replica;
update public.app_configuration
set value = 'true'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
set session_replication_role = origin;

select pg_temp.as_user('admin');
set local role authenticated;
select public.set_product_expiry_policy(current_setting('sherlyos.product3')::uuid, 'non_expiring');
select public.post_opening_stock(
  current_setting('sherlyos.product3')::uuid,
  current_setting('sherlyos.crate')::uuid,
  6, 'm4qi-open-lot', null, 'M4-BATCH', null, null
);

select pg_temp.as_user('accounts');
select set_config(
  'sherlyos.dispatch_order',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'accounts', null, null,
      jsonb_build_array(
        jsonb_build_object('product_id', current_setting('sherlyos.product3')::uuid, 'requested_cases', 2)
      ),
      'm4qi-order-disp'
    ) -> 'order' ->> 'id'
  ),
  true
);
select public.submit_order(current_setting('sherlyos.dispatch_order')::uuid, 1, 'm4qi-sub-d');
select public.verify_order(current_setting('sherlyos.dispatch_order')::uuid, 2, 'm4qi-ver-d');

select pg_temp.as_user('godown');
do $$
declare
  header jsonb;
  res jsonb;
  request_id uuid;
  prepared jsonb;
  confirmed jsonb;
  replay jsonb;
  dash jsonb;
  picking jsonb;
  dispatch jsonb;
  txn_count integer;
  i int;
begin
  header := public.reserve_order_allocation(current_setting('sherlyos.dispatch_order')::uuid, 3, 'm4qi-reserve');
  request_id := (header ->> 'id')::uuid;
  header := public.assign_picking_request(request_id, (select id from fixture where name = 'keeper'), 1, 'm4qi-assign');
  header := public.start_picking(request_id, 2, 'm4qi-start1');
  perform pg_temp.as_user('keeper');
  header := public.get_picking_request(request_id);
  for i in 0 .. jsonb_array_length(header -> 'reservations') - 1 loop
    res := header -> 'reservations' -> i;
    header := public.confirm_picking_quantity(
      request_id, (res ->> 'id')::uuid, (res ->> 'reserved_cases')::integer,
      (header ->> 'version')::integer, 'm4qi-pick-' || i::text
    );
  end loop;
  header := public.complete_picking(request_id, (header ->> 'version')::integer, 'm4qi-complete');
  perform pg_temp.as_user('godown');
  header := public.confirm_picking_handoff(request_id, (header ->> 'version')::integer, 'm4qi-handoff');

  dash := public.get_operations_dashboard(null);
  perform pg_temp.expect((dash -> 'inventory' -> 'available_to_pick' ->> 'state') = 'available', 'available when dual-write on');
  perform pg_temp.expect(
    (dash -> 'inventory' ->> 'total_cartons_on_hand')::int
      is distinct from (dash -> 'inventory' -> 'available_to_pick' ->> 'value')::int
    or (dash -> 'inventory' ->> 'active_reserved_cartons')::int > 0,
    'available-to-pick is not blindly on-hand'
  );

  prepared := public.prepare_dispatch(current_setting('sherlyos.dispatch_order')::uuid, (header ->> 'version')::integer, 'm4qi-prepare');
  dash := public.get_operations_dashboard(null);
  perform pg_temp.expect((dash -> 'dispatch' ->> 'preparing')::int >= 1, 'preparing visible');
  perform pg_temp.expect((dash -> 'dispatch' ->> 'dispatched')::int = 0, 'preparing is not dispatched');
  dispatch := public.list_dispatch_delivery_report(null, 'preparing', null, null, 1, 50);
  perform pg_temp.expect((dispatch -> 'rows' -> 0 ->> 'stock_consumed')::boolean is false, 'preparing unconsumed');
  perform pg_temp.expect((dispatch -> 'rows' -> 0 ->> 'dispatched_cartons')::int = 0, 'no DISPATCH txn yet');

  confirmed := public.confirm_dispatch((prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm4qi-confirm');
  replay := public.confirm_dispatch((prepared ->> 'id')::uuid, (prepared ->> 'version')::integer, 'm4qi-confirm');
  perform pg_temp.expect(replay ->> 'posted_transaction_id' = confirmed ->> 'posted_transaction_id', 'idempotent confirm');

  select count(*) into txn_count
  from public.stock_transactions
  where dispatch_request_id = (prepared ->> 'id')::uuid
    and transaction_type = 'DISPATCH';
  perform pg_temp.expect(txn_count = 1, 'one DISPATCH transaction');

  dash := public.get_operations_dashboard(null);
  perform pg_temp.expect((dash -> 'dispatch' ->> 'dispatched')::int >= 1, 'consumed dispatch counted');
  perform pg_temp.expect((dash -> 'dispatch' ->> 'dispatched_cartons')::int = 2, 'DISPATCH carton total');

  picking := public.list_order_picking_report(null, null, null, null, 'ready_for_dispatch', null, null, 1, 50);
  perform pg_temp.expect((picking -> 'rows' -> 0 ->> 'picking_status') = 'ready_for_dispatch', 'picking remains handoff');
  perform pg_temp.expect((picking -> 'rows' -> 0 ->> 'stock_dispatched')::boolean, 'stock dispatched from consumed dispatch');
end $$;

reset role;
set session_replication_role = replica;
update public.app_configuration
set value = 'false'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
set session_replication_role = origin;

select pg_temp.expect(
  (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled') = 'false'::jsonb,
  'flags restored false before rollback'
);

rollback;
