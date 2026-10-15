-- Local disposable checks for Phase 2C.3. The transaction rolls back.
-- Run with: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f supabase/tests/phase_2c3_inventory_ledger.sql

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);

create temp table refs (
  name text primary key,
  id uuid not null
);

grant select on fixture to authenticated, anon, service_role;
grant select, insert, update, delete on refs to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('accounts', gen_random_uuid()),
  ('salesperson', gen_random_uuid()),
  ('delivery', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('inactive', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.phase2c3@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(),
  now()
from fixture;

select app_private.bootstrap_initial_admin(
  (select id from fixture where name = 'admin'),
  'create-initial-administrator'
);

insert into public.user_roles (user_id, role_id)
select fixture.id, roles.id
from fixture
join public.roles on roles.code = case fixture.name
  when 'godown' then 'godown_manager'
  when 'accounts' then 'accounts'
  when 'salesperson' then 'salesperson'
  when 'delivery' then 'delivery_person'
  when 'keeper' then 'store_keeper'
  when 'inactive' then 'store_keeper'
end
where fixture.name <> 'admin';

do $$
begin
  if (
    select count(*)
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where (roles.code, permissions.code) in (
      ('admin', 'stock.read'),
      ('admin', 'stock.opening.post'),
      ('admin', 'stock.transfer.post'),
      ('accounts', 'stock.read'),
      ('godown_manager', 'stock.read'),
      ('godown_manager', 'stock.transfer.post'),
      ('store_keeper', 'stock.read')
    )
  ) <> 7 then
    raise exception 'approved stock grant matrix is incomplete';
  end if;

  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code in ('salesperson', 'delivery_person')
      and permissions.code in ('stock.read', 'stock.opening.post', 'stock.transfer.post')
  ) or exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code in ('accounts', 'store_keeper')
      and permissions.code in ('stock.opening.post', 'stock.transfer.post')
  ) or exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code <> 'admin'
      and permissions.code = 'stock.opening.post'
  ) or exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code not in ('admin', 'godown_manager')
      and permissions.code = 'stock.transfer.post'
  ) then
    raise exception 'an unapproved stock grant exists';
  end if;

  if (
    select count(*)
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where permissions.code = 'stock.adjustment.post'
      and roles.code = 'godown_manager'
  ) <> 1 or exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where permissions.code = 'stock.adjustment.post'
      and roles.code <> 'godown_manager'
  ) then
    raise exception 'stock adjustment posting grants changed';
  end if;
end;
$$;

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'admin'),
  true
);
set local role authenticated;

insert into refs (name, id)
values
  ('branch_a', public.create_branch('phase2c3_a', 'Phase 2C3 A')),
  ('branch_b', public.create_branch('phase2c3_b', 'Phase 2C3 B'));

insert into refs (name, id)
values
  ('zone_a', public.create_zone((select id from refs where name = 'branch_a'), 'za', 'Zone A', null)),
  ('zone_b', public.create_zone((select id from refs where name = 'branch_b'), 'zb', 'Zone B', null)),
  ('zone_empty', public.create_zone((select id from refs where name = 'branch_a'), 'ze', 'Zone Empty', null));

insert into refs (name, id)
values
  ('crate_a1', public.create_crate((select id from refs where name = 'zone_a'), 'ca1', 'Crate A1', null)),
  ('crate_a2', public.create_crate((select id from refs where name = 'zone_a'), 'ca2', 'Crate A2', null)),
  ('crate_a3', public.create_crate((select id from refs where name = 'zone_a'), 'ca3', 'Crate A3', null)),
  ('crate_b1', public.create_crate((select id from refs where name = 'zone_b'), 'cb1', 'Crate B1', null)),
  ('soap', public.create_product('p2c3-soap', 'Phase 2C3 Soap', null, null)),
  ('oil', public.create_product('p2c3-oil', 'Phase 2C3 Oil', null, null)),
  ('tea', public.create_product('p2c3-tea', 'Phase 2C3 Tea', null, null));

select public.assign_user_branch((select id from fixture where name = 'godown'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'accounts'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'keeper'), (select id from refs where name = 'branch_a'));
select public.assign_user_branch((select id from fixture where name = 'inactive'), (select id from refs where name = 'branch_a'));

insert into refs (name, id)
values ('shop', public.create_shop('Phase 2C3 Shop', null, null));

do $$
declare
  first_post jsonb;
  replay jsonb;
  balance integer;
  txn_count integer;
  ledger_sum integer;
  visible integer;
begin
  first_post := public.post_opening_stock(
    (select id from refs where name = 'soap'),
    (select id from refs where name = 'crate_a1'),
    10,
    'open-soap-a1',
    'opening soap'
  );
  if first_post ->> 'reference_number' not like 'OS-%' then
    raise exception 'opening reference was not issued';
  end if;

  select stock_ledger.quantity
  into ledger_sum
  from public.stock_ledger
  where stock_ledger.transaction_id = (first_post ->> 'id')::uuid;
  if ledger_sum <> 10 then
    raise exception 'opening ledger entry is wrong';
  end if;

  select stock_balances.quantity
  into balance
  from public.stock_balances
  where crate_id = (select id from refs where name = 'crate_a1')
    and product_id = (select id from refs where name = 'soap');
  if balance <> 10 then
    raise exception 'opening balance is wrong';
  end if;

  perform public.post_opening_stock(
    (select id from refs where name = 'oil'),
    (select id from refs where name = 'crate_a1'),
    4,
    'open-oil-a1',
    null
  );
  perform public.post_opening_stock(
    (select id from refs where name = 'soap'),
    (select id from refs where name = 'crate_b1'),
    3,
    'open-soap-b1',
    null
  );

  if (
    select count(*)
    from public.stock_balances
    where crate_id = (select id from refs where name = 'crate_a1')
      and quantity > 0
  ) <> 2 then
    raise exception 'one crate did not hold multiple SKUs';
  end if;

  begin
    perform public.post_opening_stock(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      1,
      'open-soap-a1-again',
      null
    );
    raise exception 'duplicate opening was accepted';
  exception
    when unique_violation then
      null;
  end;

  first_post := public.post_opening_stock(
    (select id from refs where name = 'tea'),
    (select id from refs where name = 'crate_a2'),
    5,
    'open-tea-a2',
    'tea'
  );
  replay := public.post_opening_stock(
    (select id from refs where name = 'tea'),
    (select id from refs where name = 'crate_a2'),
    5,
    'open-tea-a2',
    'tea'
  );
  if replay ->> 'id' is distinct from first_post ->> 'id' then
    raise exception 'idempotent opening retry created another transaction';
  end if;
  select stock_balances.quantity into balance
  from public.stock_balances
  where crate_id = (select id from refs where name = 'crate_a2')
    and product_id = (select id from refs where name = 'tea');
  if balance <> 5 then
    raise exception 'idempotent opening retry changed the balance';
  end if;

  begin
    perform public.post_opening_stock(
      (select id from refs where name = 'tea'),
      (select id from refs where name = 'crate_a2'),
      6,
      'open-tea-a2',
      'tea'
    );
    raise exception 'conflicting idempotency key was accepted';
  exception
    when unique_violation then
      null;
  end;

  first_post := public.post_crate_transfer(
    (select id from refs where name = 'soap'),
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'crate_a2'),
    2,
    'move-soap-a1-a2',
    null
  );
  if first_post ->> 'reference_number' not like 'TR-%' then
    raise exception 'transfer reference was not issued';
  end if;
  if (
    select count(*)
    from public.stock_ledger
    where transaction_id = (first_post ->> 'id')::uuid
  ) <> 2 or (
    select coalesce(sum(quantity), -1)
    from public.stock_ledger
    where transaction_id = (first_post ->> 'id')::uuid
  ) <> 0 then
    raise exception 'transfer ledger did not net to zero';
  end if;

  select count(*) into txn_count from public.stock_transactions;
  begin
    perform public.post_crate_transfer(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      (select id from refs where name = 'crate_a2'),
      100,
      'move-soap-too-much',
      null
    );
    raise exception 'insufficient stock was accepted';
  exception
    when check_violation then
      null;
  end;
  if (select count(*) from public.stock_transactions) <> txn_count then
    raise exception 'failed posting left a transaction';
  end if;

  begin
    perform public.post_crate_transfer(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      (select id from refs where name = 'crate_b1'),
      1,
      'move-cross-admin',
      null
    );
    raise exception 'admin cross-godown transfer was accepted';
  exception
    when check_violation then
      null;
  end;

  begin
    perform public.post_opening_stock(
      (select id from refs where name = 'soap'),
      '00000000-0000-4000-8000-000000000099',
      1,
      'open-guessed',
      null
    );
    raise exception 'guessed crate was accepted';
  exception
    when insufficient_privilege then
      null;
  end;

  perform public.set_crate_active((select id from refs where name = 'crate_a3'), false);
  begin
    perform public.post_opening_stock(
      (select id from refs where name = 'oil'),
      (select id from refs where name = 'crate_a3'),
      1,
      'open-inactive-crate',
      null
    );
    raise exception 'posting into an inactive crate was accepted';
  exception
    when check_violation then
      null;
  end;
  perform public.set_crate_active((select id from refs where name = 'crate_a3'), true);

  begin
    perform public.set_crate_active((select id from refs where name = 'crate_a1'), false);
    raise exception 'crate with stock was deactivated';
  exception
    when check_violation then
      null;
  end;

  begin
    perform public.set_zone_active((select id from refs where name = 'zone_a'), false);
    raise exception 'zone with stock was deactivated';
  exception
    when check_violation then
      null;
  end;

  perform public.set_zone_active((select id from refs where name = 'zone_empty'), false);

  if not exists (
    select 1 from public.audit_logs where action = 'post_opening_stock'
  ) or not exists (
    select 1 from public.audit_logs where action = 'post_crate_transfer'
  ) then
    raise exception 'successful posting was not audited';
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
declare
  visible integer;
begin
  select count(*) into visible from public.list_stock_balances();
  if visible <> 4 then
    raise exception 'godown manager did not see assigned stock only';
  end if;

  select count(*) into visible
  from public.list_stock_balances(null, null, (select id from refs where name = 'crate_b1'), null);
  if visible <> 0 then
    raise exception 'godown manager read another godown through a guessed crate';
  end if;

  select count(*) into visible from public.stock_balances;
  if visible <> 4 then
    raise exception 'balance policy exposed another godown';
  end if;

  perform public.post_crate_transfer(
    (select id from refs where name = 'oil'),
    (select id from refs where name = 'crate_a1'),
    (select id from refs where name = 'crate_a2'),
    1,
    'gm-move-oil',
    null
  );

  begin
    perform public.post_opening_stock(
      (select id from refs where name = 'oil'),
      (select id from refs where name = 'crate_a2'),
      1,
      'gm-opening',
      null
    );
    raise exception 'godown manager posted opening stock';
  exception
    when insufficient_privilege then
      null;
  end;

  begin
    perform public.post_crate_transfer(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_b1'),
      (select id from refs where name = 'crate_a1'),
      1,
      'gm-cross',
      null
    );
    raise exception 'godown manager transferred across godowns';
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
  visible integer;
begin
  select count(*) into visible from public.list_stock_balances();
  if visible < 1 then
    raise exception 'accounts could not read an assigned godown';
  end if;
  if exists (
    select 1
    from public.list_stock_balances() as rows
    where rows.godown_id = (select id from refs where name = 'branch_b')
  ) then
    raise exception 'accounts read an unassigned godown';
  end if;

  begin
    perform public.post_opening_stock(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      1,
      'accounts-opening',
      null
    );
    raise exception 'accounts posted opening stock';
  exception
    when insufficient_privilege then
      null;
  end;

  begin
    perform public.post_crate_transfer(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      (select id from refs where name = 'crate_a2'),
      1,
      'accounts-transfer',
      null
    );
    raise exception 'accounts posted a transfer';
  exception
    when insufficient_privilege then
      null;
  end;
end;
$$;

reset role;
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'keeper'),
  true
);
set local role authenticated;

do $$
declare
  visible integer;
begin
  select count(*) into visible from public.list_stock_transactions();
  if visible < 1 then
    raise exception 'store keeper could not read assigned history';
  end if;
  if exists (
    select 1
    from public.list_stock_balances() as rows
    where rows.godown_id = (select id from refs where name = 'branch_b')
  ) then
    raise exception 'store keeper read an unassigned godown';
  end if;

  begin
    perform public.post_opening_stock(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      1,
      'keeper-opening',
      null
    );
    raise exception 'store keeper posted opening stock';
  exception
    when insufficient_privilege then
      null;
  end;

  begin
    perform public.post_crate_transfer(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      (select id from refs where name = 'crate_a2'),
      1,
      'keeper-transfer',
      null
    );
    raise exception 'store keeper posted a transfer';
  exception
    when insufficient_privilege then
      null;
  end;

  begin
    insert into public.stock_ledger (transaction_id, product_id, crate_id, quantity, actor_id, posted_at)
    values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 1, auth.uid(), now());
    raise exception 'direct ledger insert was accepted';
  exception
    when insufficient_privilege then
      null;
  end;

  begin
    update public.stock_balances set quantity = 0;
    raise exception 'direct balance update was accepted';
  exception
    when insufficient_privilege then
      null;
  end;
end;
$$;

reset role;
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'salesperson'),
  true
);
set local role authenticated;

do $$
begin
  if (select count(*) from public.stock_balances) <> 0
    or (select count(*) from public.shops) <> 0
  then
    raise exception 'salesperson saw stock or an unassigned shop';
  end if;

  begin
    perform public.list_stock_balances();
    raise exception 'salesperson listed stock';
  exception
    when insufficient_privilege then
      null;
  end;

  begin
    perform public.post_crate_transfer(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      (select id from refs where name = 'crate_a2'),
      1,
      'sales-transfer',
      null
    );
    raise exception 'salesperson posted a transfer';
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
  if (select count(*) from public.stock_ledger) <> 0 then
    raise exception 'delivery person saw the ledger';
  end if;
  begin
    perform public.post_opening_stock(
      (select id from refs where name = 'soap'),
      (select id from refs where name = 'crate_a1'),
      1,
      'delivery-opening',
      null
    );
    raise exception 'delivery person posted opening stock';
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

select public.set_employee_active((select id from fixture where name = 'inactive'), false);

reset role;
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'inactive'),
  true
);
set local role authenticated;

do $$
begin
  if (select count(*) from public.stock_balances) <> 0 then
    raise exception 'inactive user still saw stock';
  end if;
  begin
    perform public.list_stock_balances();
    raise exception 'inactive user listed stock';
  exception
    when insufficient_privilege then
      null;
  end;
end;
$$;

reset role;

do $$
begin
  if exists (
    select 1
    from (
      select crate_id, product_id, sum(quantity) as ledger_quantity
      from public.stock_ledger
      group by crate_id, product_id
    ) as ledger
    full join public.stock_balances as balances
      using (crate_id, product_id)
    where coalesce(ledger.ledger_quantity, 0) is distinct from coalesce(balances.quantity, -1)
  ) then
    raise exception 'ledger totals do not match projected balances';
  end if;

  if exists (
    select 1
    from public.stock_balances
    where quantity < 0
  ) then
    raise exception 'a negative balance exists';
  end if;
end;
$$;

rollback;
