-- Local disposable checks for Phase 4.1A. The transaction rolls back.
-- Run with: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f supabase/tests/phase_4_1a_shop_orders.sql

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);

create temp table refs (
  name text primary key,
  id uuid not null
);

grant select on fixture, refs to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('accounts', gen_random_uuid()),
  ('salesperson', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('delivery', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('inactive', gen_random_uuid());

insert into auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.phase41a@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture;

insert into public.user_roles (user_id, role_id)
select fixture.id, roles.id
from fixture
join public.roles on roles.code = case fixture.name
  when 'admin' then 'admin'
  when 'accounts' then 'accounts'
  when 'salesperson' then 'salesperson'
  when 'godown' then 'godown_manager'
  when 'delivery' then 'delivery_person'
  when 'keeper' then 'store_keeper'
  when 'inactive' then 'accounts'
end;

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'admin'),
  true
);
set local role authenticated;

select set_config('sherlyos.branch_a', public.create_branch('p41a_a', 'Phase 41A A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('p41a_b', 'Phase 41A B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'salesperson'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'inactive'), current_setting('sherlyos.branch_a')::uuid);
select set_config('sherlyos.shop', public.create_shop('Phase 41A assigned', null, null)::text, true);
select set_config('sherlyos.shop_other', public.create_shop('Phase 41A other', null, null)::text, true);
select set_config('sherlyos.shop_inactive', public.create_shop('Phase 41A inactive', null, null)::text, true);
select public.set_shop_active(current_setting('sherlyos.shop_inactive')::uuid, false);
select public.assign_shop_salesperson(
  current_setting('sherlyos.shop')::uuid,
  (select id from fixture where name = 'salesperson')
);
select set_config('sherlyos.product', public.create_product('p41a-soap', 'Phase 41A soap', null, null)::text, true);
select set_config('sherlyos.inactive_product', public.create_product('p41a-old', 'Phase 41A old', null, null)::text, true);
select public.set_product_active(current_setting('sherlyos.inactive_product')::uuid, false);
select set_config(
  'sherlyos.zone',
  public.create_zone(current_setting('sherlyos.branch_a')::uuid, 'A', 'Zone A', null)::text,
  true
);
select set_config(
  'sherlyos.crate',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'c1', 'Crate 1', null)::text,
  true
);
select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate')::uuid,
  5,
  'p41a-open-soap',
  null
);

reset role;

with created as (
  insert into public.orders (shop_id, branch_id, source, created_by, idempotency_key, notes)
  values (
    current_setting('sherlyos.shop')::uuid,
    current_setting('sherlyos.branch_a')::uuid,
    'salesperson',
    (select id from fixture where name = 'salesperson'),
    'p41a-create-own',
    'Phase 41A draft'
  )
  returning id
)
insert into refs (name, id)
select 'own', id from created;

with created as (
  insert into public.orders (
    shop_id, branch_id, source, created_by, idempotency_key, status, submitted_at, submitted_by
  )
  values (
    current_setting('sherlyos.shop_other')::uuid,
    current_setting('sherlyos.branch_b')::uuid,
    'accounts',
    (select id from fixture where name = 'godown'),
    'p41a-other-branch',
    'submitted',
    now(),
    (select id from fixture where name = 'accounts')
  )
  returning id
)
insert into refs (name, id)
select 'other', id from created;

insert into public.order_lines (order_id, product_id, requested_cases)
values ((select id from refs where name = 'own'), current_setting('sherlyos.product')::uuid, 8);

insert into public.order_events (
  order_id, event_type, to_status, actor_id, version, idempotency_key, line_snapshot
)
values (
  (select id from refs where name = 'own'),
  'created',
  'draft',
  (select id from fixture where name = 'salesperson'),
  1,
  'p41a-event-own',
  jsonb_build_array(jsonb_build_object('product_id', current_setting('sherlyos.product'), 'requested_cases', 8))
);

do $$
declare
  generated text;
begin
  select order_number into generated from public.orders where id = (select id from refs where name = 'own');
  if generated !~ '^SO-[0-9]{8}-[0-9]{6}$' then
    raise exception 'order number was %', generated;
  end if;

  begin
    insert into public.order_lines (order_id, product_id, requested_cases)
    values ((select id from refs where name = 'own'), current_setting('sherlyos.product')::uuid, 1);
    raise exception 'duplicate order line was accepted';
  exception
    when unique_violation then
      null;
  end;

  begin
    insert into public.order_lines (order_id, product_id, requested_cases)
    values ((select id from refs where name = 'own'), current_setting('sherlyos.inactive_product')::uuid, 0);
    raise exception 'zero quantity was accepted';
  exception
    when check_violation then
      null;
  end;

  update public.orders
  set status = 'cancelled',
      cancelled_at = now(),
      cancelled_by = (select id from fixture where name = 'salesperson')
  where id = (select id from refs where name = 'other');

  begin
    update public.orders set notes = 'changed' where id = (select id from refs where name = 'other');
    raise exception 'cancelled order was changed';
  exception
    when check_violation then
      null;
  end;

  begin
    delete from public.order_events where order_id = (select id from refs where name = 'own');
    raise exception 'order event delete was accepted';
  exception
    when insufficient_privilege then
      null;
  end;
end;
$$;

do $$
begin
  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where (roles.code, permissions.code) in (
      ('accounts', 'shops.assign'),
      ('salesperson', 'stock.read'),
      ('salesperson', 'products.manage')
    )
  ) then
    raise exception 'an unapproved grant was added';
  end if;

  if (
    select count(*)
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where (roles.code, permissions.code) in (
      ('accounts', 'shops.read'),
      ('accounts', 'shops.read_all'),
      ('accounts', 'products.read'),
      ('salesperson', 'products.read')
    )
  ) <> 4 then
    raise exception 'approved catalog grants are incomplete';
  end if;
end;
$$;

select set_config('sherlyos.ledger_before', (select count(*) from public.stock_ledger)::text, true);

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'salesperson'),
  true
);
set local role authenticated;

do $$
declare
  seen integer;
begin
  if (select count(*) from public.shops where name like 'Phase 41A%') <> 1 then
    raise exception 'salesperson shop scope changed';
  end if;
  if exists (select 1 from public.products where sku = 'p41a-old') then
    raise exception 'salesperson saw an inactive product';
  end if;
  if (select count(*) from public.products where sku = 'p41a-soap') <> 1 then
    raise exception 'salesperson could not read active products';
  end if;
  select count(*) into seen from public.orders;
  if seen <> 1 then
    raise exception 'salesperson saw % orders', seen;
  end if;
  perform public.get_order((select id from refs where name = 'own'));
  begin
    perform public.get_order((select id from refs where name = 'other'));
    raise exception 'salesperson read another godown order';
  exception
    when insufficient_privilege then
      null;
  end;
  begin
    perform public.check_order_availability((select id from refs where name = 'own'));
    raise exception 'salesperson read availability';
  exception
    when insufficient_privilege then
      null;
  end;
  begin
    insert into public.orders (shop_id, branch_id, source, created_by, idempotency_key)
    values (
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'salesperson',
      (select id from fixture where name = 'salesperson'),
      'p41a-direct'
    );
    raise exception 'direct order insert was accepted';
  exception
    when insufficient_privilege then
      null;
  end;
end;
$$;

reset role;
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
set local role authenticated;

do $$
declare
  seen integer;
  detail jsonb;
begin
  if (select count(*) from public.shops where name like 'Phase 41A%' and is_active) <> 2 then
    raise exception 'accounts could not read active shops';
  end if;
  if exists (select 1 from public.shops where name = 'Phase 41A inactive') then
    raise exception 'accounts saw an inactive shop';
  end if;
  if exists (select 1 from public.products where sku = 'p41a-old') then
    raise exception 'accounts saw an inactive product';
  end if;
  select count(*) into seen from public.orders;
  if seen <> 1 then
    raise exception 'accounts saw % orders across godowns', seen;
  end if;
  begin
    perform public.get_order((select id from refs where name = 'other'));
    raise exception 'accounts read an unassigned godown';
  exception
    when insufficient_privilege then
      null;
  end;
  detail := public.check_order_availability((select id from refs where name = 'own'));
  if detail <> jsonb_build_array(
    jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'requested_cases', 8,
      'on_hand_cases', 5,
      'shortfall_cases', 3
    )
  ) then
    raise exception 'availability was %', detail;
  end if;
end;
$$;

reset role;
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'godown'),
  true
);
set local role authenticated;

do $$
begin
  if not exists (select 1 from public.products where sku = 'p41a-old') then
    raise exception 'godown manager lost inactive products';
  end if;
  begin
    perform public.list_orders();
    raise exception 'godown manager listed orders';
  exception
    when insufficient_privilege then
      null;
  end;
end;
$$;

reset role;
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'delivery'),
  true
);
set local role authenticated;

do $$
begin
  if (select count(*) from public.orders) <> 0 then
    raise exception 'delivery person saw orders';
  end if;
  begin
    perform public.list_orders();
    raise exception 'delivery person listed orders';
  exception
    when insufficient_privilege then
      null;
  end;
end;
$$;

reset role;
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'admin'),
  true
);
set local role authenticated;

do $$
declare
  seen integer;
begin
  select count(*) into seen from public.orders;
  if seen <> 2 then
    raise exception 'admin saw % orders', seen;
  end if;
  perform public.set_employee_active((select id from fixture where name = 'inactive'), false);
end;
$$;

reset role;
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'inactive'),
  true
);
set local role authenticated;

do $$
begin
  begin
    perform public.list_orders();
    raise exception 'inactive accounts listed orders';
  exception
    when insufficient_privilege then
      null;
  end;
end;
$$;

reset role;

do $$
begin
  if current_setting('sherlyos.ledger_before')::bigint <> (select count(*) from public.stock_ledger) then
    raise exception 'availability changed the ledger';
  end if;
  if exists (select 1 from public.stock_balances where quantity < 0) then
    raise exception 'negative balance exists';
  end if;
end;
$$;

rollback;
