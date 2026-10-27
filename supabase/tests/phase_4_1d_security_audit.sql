-- Phase 4.1D security and lifecycle audit. Transaction rolls back.
-- Targets local Docker only (piped to supabase_db_sherlyos).

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
  ('delivery', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id, 'authenticated', 'authenticated',
  fixture.name || '.phase41d@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name),
  now(), now()
from fixture;

insert into public.user_roles (user_id, role_id)
select fixture.id, roles.id
from fixture
join public.roles on roles.code = case fixture.name
  when 'admin' then 'admin'
  when 'accounts' then 'accounts'
  when 'salesperson' then 'salesperson'
  when 'godown' then 'godown_manager'
  when 'keeper' then 'store_keeper'
  else 'delivery_person'
end;

-- Static security invariants
do $$
begin
  if exists (
    select 1 from pg_class
    where relname in ('orders', 'order_lines', 'order_events')
      and (not relrowsecurity or not relforcerowsecurity)
  ) then
    raise exception 'orders tables must force RLS';
  end if;

  if exists (
    select 1
    from information_schema.role_table_grants
    where table_schema = 'public'
      and table_name in ('orders', 'order_lines', 'order_events')
      and grantee in ('anon', 'authenticated', 'public')
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
  ) then
    raise exception 'clients must not write order tables directly';
  end if;

  if exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'create_order','set_order','submit_order','hold_order',
        'verify_order','cancel_order','list_orders','get_order',
        'check_order_availability'
      )
      and (
        not p.prosecdef
        or has_function_privilege('anon', p.oid, 'EXECUTE')
        or not has_function_privilege('authenticated', p.oid, 'EXECUTE')
      )
  ) then
    raise exception 'order RPCs must be security definer, authenticated-only';
  end if;

  -- M2 added stock_reservations. 4.1 still requires clients cannot write holds directly.
  if exists (
    select 1
    from information_schema.role_table_grants
    where table_schema = 'public'
      and table_name = 'stock_reservations'
      and grantee in ('anon', 'authenticated', 'public')
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
  ) then
    raise exception 'clients must not write stock reservations directly';
  end if;

  if exists (
    select 1 from pg_trigger
    where tgrelid = 'public.order_events'::regclass
      and tgname = 'order_events_append_only'
      and tgenabled <> 'O'
  ) then
    raise exception 'order_events append-only trigger must be enabled';
  end if;
end;
$$;

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'admin'),
  true
);
set local role authenticated;

select set_config('sherlyos.branch', public.create_branch('p41d_a', 'Phase 41D')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'salesperson'), current_setting('sherlyos.branch')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch')::uuid);
select set_config('sherlyos.shop', public.create_shop('Phase 41D Shop', null, null)::text, true);
select public.assign_shop_salesperson(current_setting('sherlyos.shop')::uuid, (select id from fixture where name = 'salesperson'));
select set_config('sherlyos.product', public.create_product('p41d-sku', 'Phase 41D Soap', null, null)::text, true);
select public.set_product_expiry_policy(current_setting('sherlyos.product')::uuid, 'non_expiring');
select set_config('sherlyos.zone', public.create_zone(current_setting('sherlyos.branch')::uuid, 'Z', 'Z', null)::text, true);
select set_config('sherlyos.crate', public.create_crate(current_setting('sherlyos.zone')::uuid, 'c', 'C', null)::text, true);
reset role;
set session_replication_role = replica;
update public.app_configuration set value = 'true'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
set session_replication_role = origin;
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'admin'),
  true
);
set local role authenticated;
select public.post_opening_stock(
  current_setting('sherlyos.product')::uuid,
  current_setting('sherlyos.crate')::uuid,
  8,
  'p41d-open',
  null,
  'P41D-LOT',
  null,
  null
);

reset role;
select set_config('request.jwt.claims', '', true);

-- Full happy path + Rule A + terminal cancel
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'salesperson'),
  true
);
set local role authenticated;

select set_config(
  'sherlyos.order',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch')::uuid,
      'salesperson', null, 'draft note',
      jsonb_build_array(jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'requested_cases', 12
      )),
      'p41d-create'
    ) -> 'order' ->> 'id'
  ),
  true
);

do $$
declare
  payload jsonb;
  ver integer;
  ledger_before bigint;
  events_before integer;
begin
  select count(*) into ledger_before from public.stock_ledger;

  payload := public.set_order(
    current_setting('sherlyos.order')::uuid, 1,
    current_setting('sherlyos.shop')::uuid,
    current_setting('sherlyos.branch')::uuid,
    'salesperson', null, 'edited',
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'requested_cases', 12
    )),
    'p41d-edit'
  );
  if payload -> 'order' ->> 'version' is distinct from '2' then
    raise exception 'edit version';
  end if;

  payload := public.submit_order(current_setting('sherlyos.order')::uuid, 2, 'p41d-submit');
  if payload -> 'order' ->> 'status' is distinct from 'submitted' then
    raise exception 'submit failed';
  end if;

  -- immutable creator
  begin
    update public.orders
    set created_by = (select id from fixture where name = 'accounts')
    where id = current_setting('sherlyos.order')::uuid;
    raise exception 'created_by update should fail';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
  end;
end;
$$;

reset role;
select set_config('request.jwt.claims', '', true);

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
set local role authenticated;

do $$
declare
  ver integer;
  detail text;
  payload jsonb;
begin
  select version into ver from public.orders where id = current_setting('sherlyos.order')::uuid;

  -- Rule A: shortfall (12 requested, 8 on hand)
  begin
    perform public.verify_order(current_setting('sherlyos.order')::uuid, ver, 'p41d-verify-short');
    raise exception 'Rule A should reject';
  exception
    when sqlstate 'P0001' then
      get stacked diagnostics detail = pg_exception_detail;
      if detail is null or detail not like '%shortfall%' then
        raise exception 'shortage detail missing';
      end if;
  end;

  if (select status from public.orders where id = current_setting('sherlyos.order')::uuid) <> 'submitted'
    or (select version from public.orders where id = current_setting('sherlyos.order')::uuid) <> ver
  then
    raise exception 'Rule A mutated order';
  end if;

  if exists (
    select 1 from public.order_events
    where order_id = current_setting('sherlyos.order')::uuid and event_type = 'verified'
  ) then
    raise exception 'Rule A wrote verified event';
  end if;

  payload := public.hold_order(current_setting('sherlyos.order')::uuid, ver, 'Need lower qty', 'p41d-hold');
  if payload -> 'order' ->> 'status' is distinct from 'held' then
    raise exception 'hold failed';
  end if;
end;
$$;

reset role;
select set_config('request.jwt.claims', '', true);

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'salesperson'),
  true
);
set local role authenticated;

do $$
declare
  ver integer;
  payload jsonb;
begin
  select version into ver from public.orders where id = current_setting('sherlyos.order')::uuid;
  payload := public.set_order(
    current_setting('sherlyos.order')::uuid, ver,
    current_setting('sherlyos.shop')::uuid,
    current_setting('sherlyos.branch')::uuid,
    'salesperson', null, null,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product')::uuid,
      'requested_cases', 5
    )),
    'p41d-correct'
  );
  payload := public.submit_order(
    current_setting('sherlyos.order')::uuid,
    (payload -> 'order' ->> 'version')::integer,
    'p41d-resubmit'
  );
  if payload -> 'order' ->> 'status' is distinct from 'submitted' then
    raise exception 'resubmit failed';
  end if;
end;
$$;

reset role;
select set_config('request.jwt.claims', '', true);

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
set local role authenticated;

do $$
declare
  ver integer;
  payload jsonb;
  event_count integer;
begin
  select version into ver from public.orders where id = current_setting('sherlyos.order')::uuid;
  select count(*) into event_count from public.order_events
  where order_id = current_setting('sherlyos.order')::uuid;

  payload := public.verify_order(current_setting('sherlyos.order')::uuid, ver, 'p41d-verify-ok');
  if payload -> 'order' ->> 'status' is distinct from 'verified' then
    raise exception 'verify failed';
  end if;
  if (select count(*) from public.order_events where order_id = current_setting('sherlyos.order')::uuid)
    <> event_count + 1
  then
    raise exception 'verify did not append exactly one event';
  end if;

  -- idempotent verify replay
  payload := public.verify_order(current_setting('sherlyos.order')::uuid, ver, 'p41d-verify-ok');
  if (select count(*) from public.order_events where order_id = current_setting('sherlyos.order')::uuid)
    <> event_count + 1
  then
    raise exception 'verify replay duplicated events';
  end if;

  select version into ver from public.orders where id = current_setting('sherlyos.order')::uuid;
  payload := public.cancel_order(
    current_setting('sherlyos.order')::uuid, ver, 'Accounts closed request', 'p41d-cancel-verified'
  );
  if payload -> 'order' ->> 'status' is distinct from 'cancelled' then
    raise exception 'accounts cancel verified failed';
  end if;
end;
$$;

-- Restricted roles denied
do $$
declare
  actor text;
begin
  foreach actor in array array['godown', 'keeper', 'delivery', 'admin']
  loop
    perform set_config(
      'request.jwt.claims',
      (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = actor),
      true
    );
    set local role authenticated;
    begin
      perform public.create_order(
        current_setting('sherlyos.shop')::uuid,
        current_setting('sherlyos.branch')::uuid,
        'salesperson', null, null,
        jsonb_build_array(jsonb_build_object(
          'product_id', current_setting('sherlyos.product')::uuid,
          'requested_cases', 1
        )),
        'p41d-deny-' || actor
      );
      raise exception '% should not create', actor;
    exception
      when sqlstate '42501' then null;
    end;
    reset role;
  end loop;
end;
$$;

-- Admin can read cancelled order via monitor
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'admin'),
  true
);
set local role authenticated;
do $$
begin
  perform public.get_order(current_setting('sherlyos.order')::uuid);
  begin
    perform public.cancel_order(current_setting('sherlyos.order')::uuid, 99, 'x', 'p41d-admin-cancel');
    raise exception 'admin cancel should fail';
  exception
    when sqlstate '42501' then null;
    when sqlstate '23514' then null;
    when sqlstate 'PT409' then null;
  end;
end;
$$;

reset role;
select set_config('request.jwt.claims', '', true);

do $$
begin
  if exists (select 1 from public.stock_balances where quantity < 0) then
    raise exception 'negative balances';
  end if;
end;
$$;

rollback;
