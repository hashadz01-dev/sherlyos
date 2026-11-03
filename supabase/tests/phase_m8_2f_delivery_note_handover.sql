-- M8.2F local disposable SQL. Rolls back. Does not touch development cloud.
-- Queue, create, duplicate, branch scope, and no stock mutation.
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
  ('accounts_none', gen_random_uuid()),
  ('accounts_other', gen_random_uuid()),
  ('salesperson', gen_random_uuid()),
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
  fixture.name || '.m82f@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M82F Admin', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select (select id from fixture where name = 'admin'), roles.id,
        (select id from fixture where name = 'admin')
      from public.roles where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.profiles (id, full_name, is_active)
select fixture.id, 'M82F ' || fixture.name, true from fixture where name <> 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles on roles.code = case fixture.name
  when 'accounts' then 'accounts'
  when 'accounts_none' then 'accounts'
  when 'accounts_other' then 'accounts'
  when 'salesperson' then 'salesperson'
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

create temp table flag_snapshot as
select key, value
from public.app_configuration
where key in (
  'damage.stock_hold_ready',
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked'
);
grant select on flag_snapshot to authenticated, anon, service_role;

select pg_temp.as_user('admin');
set local role authenticated;
select set_config('sherlyos.branch', public.create_branch('m82f_a', 'M82F Godown A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('m82f_b', 'M82F Godown B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'salesperson'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'accounts_other'), current_setting('sherlyos.branch_b')::uuid);
select set_config('sherlyos.sku', public.create_product('m82f-milk', 'M82F milk', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.sku')::uuid, 'non_expiring');
select set_config('sherlyos.shop', public.create_shop('M82F shop', null, null)::text, true);
select public.assign_shop_salesperson(
  current_setting('sherlyos.shop')::uuid,
  (select id from fixture where name = 'salesperson')
);
reset role;

insert into public.orders (
  order_number, shop_id, branch_id, source, created_by, status, version,
  idempotency_key, submitted_at, submitted_by, verified_at, verified_by
)
values
  (
    'SO-M82F-OPEN',
    current_setting('sherlyos.shop')::uuid,
    current_setting('sherlyos.branch')::uuid,
    'salesperson',
    (select id from fixture where name = 'salesperson'),
    'verified',
    3,
    'm82f-ord-open',
    now(),
    (select id from fixture where name = 'salesperson'),
    now(),
    (select id from fixture where name = 'accounts')
  ),
  (
    'SO-M82F-SUBMITTED',
    current_setting('sherlyos.shop')::uuid,
    current_setting('sherlyos.branch')::uuid,
    'salesperson',
    (select id from fixture where name = 'salesperson'),
    'submitted',
    2,
    'm82f-ord-submitted',
    now(),
    (select id from fixture where name = 'salesperson'),
    null,
    null
  ),
  (
    'SO-M82F-WITH-DN',
    current_setting('sherlyos.shop')::uuid,
    current_setting('sherlyos.branch')::uuid,
    'salesperson',
    (select id from fixture where name = 'salesperson'),
    'verified',
    3,
    'm82f-ord-dn',
    now(),
    (select id from fixture where name = 'salesperson'),
    now(),
    (select id from fixture where name = 'accounts')
  );

select set_config('sherlyos.order_open', (select id::text from public.orders where idempotency_key = 'm82f-ord-open'), true);
select set_config('sherlyos.order_submitted', (select id::text from public.orders where idempotency_key = 'm82f-ord-submitted'), true);
select set_config('sherlyos.order_dn', (select id::text from public.orders where idempotency_key = 'm82f-ord-dn'), true);

insert into public.order_lines (order_id, product_id, requested_cases)
values
  (current_setting('sherlyos.order_open')::uuid, current_setting('sherlyos.sku')::uuid, 2),
  (current_setting('sherlyos.order_submitted')::uuid, current_setting('sherlyos.sku')::uuid, 2),
  (current_setting('sherlyos.order_dn')::uuid, current_setting('sherlyos.sku')::uuid, 2);

insert into public.delivery_notes (
  order_id, shop_id, branch_id, status, version, idempotency_key, created_by
)
values (
  current_setting('sherlyos.order_dn')::uuid,
  current_setting('sherlyos.shop')::uuid,
  current_setting('sherlyos.branch')::uuid,
  'draft',
  1,
  'm82f-dn-existing',
  (select id from fixture where name = 'accounts')
);

-- DN-01 / DN-02 / DN-03: assigned Accounts queue
select pg_temp.as_user('accounts');
set local role authenticated;
do $$
declare
  queue jsonb;
begin
  queue := public.list_verified_orders_without_dn();
  if not exists (
    select 1 from jsonb_array_elements(queue) as row
    where row ->> 'id' = current_setting('sherlyos.order_open')
  ) then
    raise exception 'DN-01 queue missing verified order without DN: %', queue;
  end if;
  if exists (
    select 1 from jsonb_array_elements(queue) as row
    where row ->> 'id' = current_setting('sherlyos.order_submitted')
  ) then
    raise exception 'DN-02 queue included submitted order';
  end if;
  if exists (
    select 1 from jsonb_array_elements(queue) as row
    where row ->> 'id' = current_setting('sherlyos.order_dn')
  ) then
    raise exception 'DN-03 queue included order with active DN';
  end if;
end $$;

-- DN-07: Accounts company-wide scope can list without assignment.
-- Create stays on the assigned fixture below so DN-08 remains unique.
reset role;
select pg_temp.as_user('accounts_none');
set local role authenticated;
do $$
declare
  queue jsonb;
begin
  queue := public.list_verified_orders_without_dn();
  if not exists (
    select 1 from jsonb_array_elements(queue) as row
    where row ->> 'id' = current_setting('sherlyos.order_open')
  ) then
    raise exception 'unassigned Accounts missing Godown A verified order: %', queue;
  end if;
end $$;

reset role;
select pg_temp.as_user('accounts_other');
set local role authenticated;
do $$
declare
  queue jsonb;
begin
  queue := public.list_verified_orders_without_dn();
  if not exists (
    select 1 from jsonb_array_elements(queue) as row
    where row ->> 'id' = current_setting('sherlyos.order_open')
  ) then
    raise exception 'other-godown Accounts missing Godown A verified order: %', queue;
  end if;
end $$;

reset role;
select pg_temp.as_user('salesperson');
set local role authenticated;
do $$
begin
  begin
    perform public.list_verified_orders_without_dn();
    raise exception 'salesperson listed verified orders without DN';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.create_delivery_note(current_setting('sherlyos.order_open')::uuid, 'm82f-dn-sales');
    raise exception 'salesperson created a delivery note';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

reset role;
select pg_temp.as_user('keeper');
set local role authenticated;
do $$
begin
  begin
    perform public.list_verified_orders_without_dn();
    raise exception 'store keeper listed verified orders without DN';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.create_delivery_note(current_setting('sherlyos.order_open')::uuid, 'm82f-dn-keeper');
    raise exception 'store keeper created a delivery note';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- DN-08 / DN-09 / DN-10 / DN-11: assigned create, duplicate, queue drop, no stock write
reset role;
select pg_temp.as_user('accounts');
set local role authenticated;
do $$
declare
  created jsonb;
  replay jsonb;
  queue jsonb;
  ledger_before bigint;
  ledger_after bigint;
  line_count integer;
  linked_order uuid;
begin
  select count(*) into ledger_before from public.stock_ledger;

  begin
    perform public.create_delivery_note(
      current_setting('sherlyos.order_submitted')::uuid,
      'm82f-dn-submitted'
    );
    raise exception 'create on submitted order allowed';
  exception
    when sqlstate '23514' then null;
  end;

  created := public.create_delivery_note(
    current_setting('sherlyos.order_open')::uuid,
    'm82f-dn-create'
  );
  if created -> 'delivery_note' ->> 'status' is distinct from 'draft' then
    raise exception 'DN-08 create did not land in draft';
  end if;
  linked_order := (created -> 'delivery_note' ->> 'order_id')::uuid;
  if linked_order is distinct from current_setting('sherlyos.order_open')::uuid then
    raise exception 'DN-08 draft linked to the wrong order';
  end if;
  select count(*) into line_count
  from public.delivery_note_lines
  where delivery_note_id = (created -> 'delivery_note' ->> 'id')::uuid;
  if line_count <> 1 then
    raise exception 'DN-08 line snapshot incomplete: %', line_count;
  end if;
  if (
    select requested_cases
    from public.delivery_note_lines
    where delivery_note_id = (created -> 'delivery_note' ->> 'id')::uuid
  ) <> 2 then
    raise exception 'DN-08 quantities must copy the verified order';
  end if;

  replay := public.create_delivery_note(
    current_setting('sherlyos.order_open')::uuid,
    'm82f-dn-create'
  );
  if replay -> 'delivery_note' ->> 'id' is distinct from created -> 'delivery_note' ->> 'id' then
    raise exception 'DN-09 idempotent replay mismatched';
  end if;

  begin
    perform public.create_delivery_note(
      current_setting('sherlyos.order_open')::uuid,
      'm82f-dn-dup'
    );
    raise exception 'DN-09 duplicate open DN allowed';
  exception
    when sqlstate '23505' then null;
  end;

  queue := public.list_verified_orders_without_dn();
  if exists (
    select 1 from jsonb_array_elements(queue) as row
    where row ->> 'id' = current_setting('sherlyos.order_open')
  ) then
    raise exception 'DN-10 queue still listed the order after create';
  end if;

  select count(*) into ledger_after from public.stock_ledger;
  if ledger_after <> ledger_before then
    raise exception 'DN-11 draft creation wrote stock_ledger';
  end if;
end $$;

do $$
begin
  if exists (
    select 1
    from public.app_configuration
    join flag_snapshot on flag_snapshot.key = app_configuration.key
    where app_configuration.value is distinct from flag_snapshot.value
  ) then
    raise exception 'M8.2F must not change operational flags';
  end if;
end $$;

rollback;
