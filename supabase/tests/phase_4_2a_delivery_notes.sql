-- Local disposable checks for Phase 4.2A. The transaction rolls back.
-- Run with: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f supabase/tests/phase_4_2a_delivery_notes.sql

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
  ('accounts_b', gen_random_uuid()),
  ('salesperson', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('godown_b', gen_random_uuid()),
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
  fixture.name || '.phase42a@example.com',
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
  when 'accounts_b' then 'accounts'
  when 'salesperson' then 'salesperson'
  when 'godown' then 'godown_manager'
  when 'godown_b' then 'godown_manager'
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

select set_config('sherlyos.branch_a', public.create_branch('p42a_a', 'Phase 42A A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('p42a_b', 'Phase 42A B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'accounts_b'), current_setting('sherlyos.branch_b')::uuid);
select public.assign_user_branch((select id from fixture where name = 'salesperson'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown_b'), current_setting('sherlyos.branch_b')::uuid);
select public.assign_user_branch((select id from fixture where name = 'inactive'), current_setting('sherlyos.branch_a')::uuid);

select set_config('sherlyos.shop', public.create_shop('Phase 42A shop', null, 'Addr')::text, true);
select set_config('sherlyos.product', public.create_product('p42a-soap', 'Phase 42A soap', null, null)::text, true);

reset role;

do $$
begin
  if to_regclass('public.delivery_notes') is null
    or to_regclass('public.delivery_note_lines') is null
    or to_regclass('public.delivery_note_events') is null
  then
    raise exception 'delivery note tables missing';
  end if;

  if not exists (
    select 1 from public.permissions where code = 'delivery_notes.acknowledge'
  ) then
    raise exception 'delivery_notes.acknowledge missing';
  end if;

  if not exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'godown_manager'
      and permissions.code = 'delivery_notes.acknowledge'
  ) then
    raise exception 'godown manager missing acknowledge grant';
  end if;

  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where permissions.code = 'delivery_notes.acknowledge'
      and roles.code <> 'godown_manager'
  ) then
    raise exception 'acknowledge granted outside godown manager';
  end if;

  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code in ('godown_manager', 'salesperson', 'store_keeper', 'delivery_person', 'admin')
      and permissions.code = 'delivery_notes.issue'
  ) then
    raise exception 'delivery_notes.issue wrongly expanded';
  end if;
end;
$$;

insert into public.orders (
  order_number,
  shop_id,
  branch_id,
  source,
  created_by,
  status,
  version,
  idempotency_key,
  submitted_at,
  submitted_by,
  verified_at,
  verified_by
)
values (
  'SO-TEST-42A-001',
  current_setting('sherlyos.shop')::uuid,
  current_setting('sherlyos.branch_a')::uuid,
  'accounts',
  (select id from fixture where name = 'accounts'),
  'verified',
  1,
  'p42a-order-verified-01',
  now(),
  (select id from fixture where name = 'accounts'),
  now(),
  (select id from fixture where name = 'accounts')
);

select set_config(
  'sherlyos.order_verified',
  (select id::text from public.orders where idempotency_key = 'p42a-order-verified-01'),
  true
);

insert into public.order_lines (order_id, product_id, requested_cases)
values (
  current_setting('sherlyos.order_verified')::uuid,
  current_setting('sherlyos.product')::uuid,
  3
);

insert into public.orders (
  order_number,
  shop_id,
  branch_id,
  source,
  created_by,
  status,
  version,
  idempotency_key,
  submitted_at,
  submitted_by,
  verified_at,
  verified_by,
  cancelled_at,
  cancelled_by,
  cancellation_reason
)
values (
  'SO-TEST-42A-002',
  current_setting('sherlyos.shop')::uuid,
  current_setting('sherlyos.branch_a')::uuid,
  'accounts',
  (select id from fixture where name = 'accounts'),
  'cancelled',
  2,
  'p42a-order-cancelled-01',
  now(),
  (select id from fixture where name = 'accounts'),
  now(),
  (select id from fixture where name = 'accounts'),
  now(),
  (select id from fixture where name = 'accounts'),
  'fixture cancel'
);

select set_config(
  'sherlyos.order_cancelled',
  (select id::text from public.orders where idempotency_key = 'p42a-order-cancelled-01'),
  true
);

insert into public.orders (
  order_number,
  shop_id,
  branch_id,
  source,
  created_by,
  status,
  version,
  idempotency_key,
  submitted_at,
  submitted_by,
  verified_at,
  verified_by
)
values (
  'SO-TEST-42A-003',
  current_setting('sherlyos.shop')::uuid,
  current_setting('sherlyos.branch_a')::uuid,
  'accounts',
  (select id from fixture where name = 'accounts'),
  'verified',
  1,
  'p42a-order-verified-open-01',
  now(),
  (select id from fixture where name = 'accounts'),
  now(),
  (select id from fixture where name = 'accounts')
);

select set_config(
  'sherlyos.order_verified_open',
  (select id::text from public.orders where idempotency_key = 'p42a-order-verified-open-01'),
  true
);

insert into public.delivery_notes (
  order_id,
  shop_id,
  branch_id,
  status,
  version,
  idempotency_key,
  created_by
)
values (
  current_setting('sherlyos.order_verified')::uuid,
  current_setting('sherlyos.shop')::uuid,
  current_setting('sherlyos.branch_a')::uuid,
  'draft',
  1,
  'p42a-dn-draft-01',
  (select id from fixture where name = 'accounts')
);

select set_config(
  'sherlyos.dn_draft',
  (select id::text from public.delivery_notes where idempotency_key = 'p42a-dn-draft-01'),
  true
);

insert into public.delivery_note_lines (delivery_note_id, product_id, requested_cases)
values (
  current_setting('sherlyos.dn_draft')::uuid,
  current_setting('sherlyos.product')::uuid,
  3
);

insert into public.delivery_note_events (
  delivery_note_id,
  event_type,
  from_status,
  to_status,
  actor_id,
  version,
  idempotency_key,
  line_snapshot
)
values (
  current_setting('sherlyos.dn_draft')::uuid,
  'created',
  null,
  'draft',
  (select id from fixture where name = 'accounts'),
  1,
  'p42a-dn-event-created-01',
  '[]'::jsonb
);

do $$
declare
  noted text;
  ledger_before bigint;
  ledger_after bigint;
begin
  select delivery_note_number into noted
  from public.delivery_notes
  where id = current_setting('sherlyos.dn_draft')::uuid;

  if noted !~ '^DN-[0-9]{8}-[0-9]{6}$' then
    raise exception 'delivery note number format invalid: %', noted;
  end if;

  select count(*) into ledger_before from public.stock_ledger;

  begin
    insert into public.delivery_notes (
      order_id,
      shop_id,
      branch_id,
      status,
      version,
      idempotency_key,
      created_by
    )
    values (
      current_setting('sherlyos.order_verified')::uuid,
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'draft',
      1,
      'p42a-dn-draft-dup',
      (select id from fixture where name = 'accounts')
    );
    raise exception 'duplicate open DN was allowed';
  exception
    when unique_violation then
      null;
  end;

  insert into public.delivery_notes (
    order_id,
    shop_id,
    branch_id,
    status,
    version,
    idempotency_key,
    created_by,
    voided_at,
    voided_by,
    void_reason
  )
  values (
    current_setting('sherlyos.order_cancelled')::uuid,
    current_setting('sherlyos.shop')::uuid,
    current_setting('sherlyos.branch_a')::uuid,
    'voided',
    1,
    'p42a-dn-voided-01',
    (select id from fixture where name = 'accounts'),
    now(),
    (select id from fixture where name = 'accounts'),
    'fixture void'
  );

  begin
    update public.delivery_note_events
    set note = 'tamper'
    where idempotency_key = 'p42a-dn-event-created-01';
    raise exception 'event update allowed';
  exception
    when others then
      if sqlerrm not like '%append-only%' then
        raise;
      end if;
  end;

  begin
    delete from public.delivery_note_events
    where idempotency_key = 'p42a-dn-event-created-01';
    raise exception 'event delete allowed';
  exception
    when others then
      if sqlerrm not like '%append-only%' then
        raise;
      end if;
  end;

  begin
    update public.delivery_note_lines
    set requested_cases = 9
    where delivery_note_id = current_setting('sherlyos.dn_draft')::uuid;
    raise exception 'line update allowed';
  exception
    when others then
      if sqlerrm not like '%immutable%' then
        raise;
      end if;
  end;

  begin
    delete from public.delivery_note_lines
    where delivery_note_id = current_setting('sherlyos.dn_draft')::uuid;
    raise exception 'line delete allowed';
  exception
    when others then
      if sqlerrm not like '%immutable%' then
        raise;
      end if;
  end;

  select count(*) into ledger_after from public.stock_ledger;
  if ledger_after <> ledger_before then
    raise exception 'stock ledger changed during DN fixture setup';
  end if;
end;
$$;

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
set local role authenticated;

do $$
begin
  begin
    insert into public.delivery_notes (
      order_id,
      shop_id,
      branch_id,
      status,
      version,
      idempotency_key,
      created_by
    )
    values (
      current_setting('sherlyos.order_verified')::uuid,
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'draft',
      1,
      'p42a-client-insert',
      (select id from fixture where name = 'accounts')
    );
    raise exception 'authenticated insert on delivery_notes allowed';
  exception
    when insufficient_privilege then
      null;
  end;
end;
$$;

do $$
declare
  listed jsonb;
  detail jsonb;
  queue jsonb;
begin
  listed := public.list_delivery_notes(null, null, null);
  if pg_catalog.jsonb_array_length(listed) < 1 then
    raise exception 'accounts list empty';
  end if;

  detail := public.get_delivery_note(current_setting('sherlyos.dn_draft')::uuid);
  if detail -> 'delivery_note' ->> 'id' is distinct from current_setting('sherlyos.dn_draft') then
    raise exception 'accounts get failed';
  end if;

  queue := public.list_verified_orders_without_dn();
  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(queue) as row
    where row ->> 'id' = current_setting('sherlyos.order_verified')
  ) then
    raise exception 'queue included order with open DN';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(queue) as row
    where row ->> 'id' = current_setting('sherlyos.order_cancelled')
  ) then
    raise exception 'queue included cancelled order';
  end if;

  if not exists (
    select 1
    from pg_catalog.jsonb_array_elements(queue) as row
    where row ->> 'id' = current_setting('sherlyos.order_verified_open')
  ) then
    raise exception 'queue missing verified order without DN';
  end if;
end;
$$;

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts_b'),
  true
);

do $$
begin
  begin
    perform public.get_delivery_note(current_setting('sherlyos.dn_draft')::uuid);
    raise exception 'cross-godown accounts get allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' then
        raise;
      end if;
  end;
end;
$$;

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'godown'),
  true
);

do $$
declare
  listed jsonb;
begin
  listed := public.list_delivery_notes('draft', null, null);
  if pg_catalog.jsonb_array_length(listed) < 1 then
    raise exception 'godown list empty';
  end if;
  perform public.get_delivery_note(current_setting('sherlyos.dn_draft')::uuid);
end;
$$;

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'godown_b'),
  true
);

do $$
begin
  begin
    perform public.get_delivery_note(current_setting('sherlyos.dn_draft')::uuid);
    raise exception 'cross-godown manager get allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' then
        raise;
      end if;
  end;

  begin
    perform public.list_verified_orders_without_dn();
    raise exception 'godown list_verified_orders_without_dn allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' then
        raise;
      end if;
  end;
end;
$$;

reset role;
update public.profiles
set is_active = false
where id = (select id from fixture where name = 'inactive');

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'inactive'),
  true
);
set local role authenticated;

do $$
begin
  begin
    perform public.list_delivery_notes(null, null, null);
    raise exception 'inactive list allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' then
        raise;
      end if;
  end;
end;
$$;

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'admin'),
  true
);

do $$
declare
  listed jsonb;
begin
  listed := public.list_delivery_notes(null, null, null);
  if pg_catalog.jsonb_array_length(listed) < 1 then
    raise exception 'admin monitor list empty';
  end if;
  perform public.get_delivery_note(current_setting('sherlyos.dn_draft')::uuid);

  begin
    perform public.list_verified_orders_without_dn();
    raise exception 'admin list_verified_orders_without_dn allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' then
        raise;
      end if;
  end;
end;
$$;

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'salesperson'),
  true
);
do $$
begin
  begin
    perform public.list_verified_orders_without_dn();
    raise exception 'salesperson queue allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' then
        raise;
      end if;
  end;
end;
$$;

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'keeper'),
  true
);
do $$
begin
  begin
    perform public.list_delivery_notes(null, null, null);
    raise exception 'keeper list allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' then
        raise;
      end if;
  end;
end;
$$;

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'delivery'),
  true
);
do $$
begin
  begin
    perform public.get_delivery_note(current_setting('sherlyos.dn_draft')::uuid);
    raise exception 'delivery get allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' then
        raise;
      end if;
  end;
end;
$$;

set local role anon;
do $$
begin
  begin
    perform public.list_delivery_notes(null, null, null);
    raise exception 'anon list allowed';
  exception
    when insufficient_privilege then
      null;
    when others then
      if sqlerrm not like '%not authorized%' and sqlerrm not like '%permission denied%' then
        raise;
      end if;
  end;
end;
$$;

reset role;

do $$
begin
  if not exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'accounts'
      and permissions.code in ('orders.capture', 'orders.verify', 'delivery_notes.issue')
    group by roles.code
    having count(distinct permissions.code) = 3
  ) then
    raise exception 'phase 4.1 accounts grants missing';
  end if;
end;
$$;

select 'phase_4_2a_delivery_notes ok' as result;

rollback;
