-- Local disposable checks for Phase 4.2C. The transaction rolls back.

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
  ('keeper', gen_random_uuid()),
  ('delivery', gen_random_uuid()),
  ('inactive_gm', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.phase42c@example.com',
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
  when 'keeper' then 'store_keeper'
  when 'delivery' then 'delivery_person'
  when 'inactive_gm' then 'godown_manager'
end;

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'admin'),
  true
);
set local role authenticated;

select set_config('sherlyos.branch_a', public.create_branch('p42c_a', 'Phase 42C A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('p42c_b', 'Phase 42C B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'accounts_b'), current_setting('sherlyos.branch_b')::uuid);
select public.assign_user_branch((select id from fixture where name = 'salesperson'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown_b'), current_setting('sherlyos.branch_b')::uuid);
select public.assign_user_branch((select id from fixture where name = 'inactive_gm'), current_setting('sherlyos.branch_a')::uuid);
select set_config('sherlyos.shop', public.create_shop('Phase 42C shop', null, 'Addr')::text, true);
select set_config('sherlyos.product', public.create_product('p42c-soap', 'Phase 42C soap', null, null)::text, true);

reset role;

insert into public.orders (
  order_number, shop_id, branch_id, source, created_by, status, version,
  idempotency_key, submitted_at, submitted_by, verified_at, verified_by
)
values (
  'SO-TEST-42C-001',
  current_setting('sherlyos.shop')::uuid,
  current_setting('sherlyos.branch_a')::uuid,
  'accounts',
  (select id from fixture where name = 'accounts'),
  'verified', 1, 'p42c-order-verified-01',
  now(), (select id from fixture where name = 'accounts'),
  now(), (select id from fixture where name = 'accounts')
);

select set_config(
  'sherlyos.order',
  (select id::text from public.orders where idempotency_key = 'p42c-order-verified-01'),
  true
);

insert into public.order_lines (order_id, product_id, requested_cases)
values (
  current_setting('sherlyos.order')::uuid,
  current_setting('sherlyos.product')::uuid,
  5
);

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
set local role authenticated;

do $$
declare
  created jsonb;
  generated jsonb;
  sent jsonb;
  replay jsonb;
  acked jsonb;
  listed jsonb;
  ledger_before bigint;
  ledger_after bigint;
  order_status text;
  order_version integer;
begin
  select count(*) into ledger_before from public.stock_ledger;

  created := public.create_delivery_note(current_setting('sherlyos.order')::uuid, 'p42c-create-01');
  perform set_config('sherlyos.dn', created -> 'delivery_note' ->> 'id', true);

  begin
    perform public.send_delivery_note(current_setting('sherlyos.dn')::uuid, 1, 'p42c-send-draft');
    raise exception 'send from draft allowed';
  exception
    when others then
      if sqlerrm not like '%cannot change from draft%' then
        raise;
      end if;
  end;

  generated := public.generate_delivery_note(current_setting('sherlyos.dn')::uuid, 1, 'p42c-generate-01');
  if generated -> 'delivery_note' ->> 'status' is distinct from 'generated' then
    raise exception 'generate failed';
  end if;

  sent := public.send_delivery_note(current_setting('sherlyos.dn')::uuid, 2, 'p42c-send-01');
  if sent -> 'delivery_note' ->> 'status' is distinct from 'sent' then
    raise exception 'send failed';
  end if;

  replay := public.send_delivery_note(current_setting('sherlyos.dn')::uuid, 2, 'p42c-send-01');
  if replay -> 'delivery_note' ->> 'version' is distinct from '3' then
    raise exception 'send idempotency bumped version';
  end if;

  begin
    perform public.send_delivery_note(current_setting('sherlyos.dn')::uuid, 2, 'p42c-send-stale');
    raise exception 'stale send allowed';
  exception
    when others then
      if sqlerrm not like '%changed by someone else%'
        and sqlerrm not like '%cannot change from sent%'
      then
        raise;
      end if;
  end;

  listed := public.list_delivery_notes('sent', null, null);
  if not exists (
    select 1
    from pg_catalog.jsonb_array_elements(listed) as row
    where row ->> 'id' = current_setting('sherlyos.dn')
      and row ? 'order_number'
      and (row ->> 'total_cases')::integer = 5
  ) then
    raise exception 'list enrichment missing';
  end if;

  select version into order_version from public.orders where id = current_setting('sherlyos.order')::uuid;
  begin
    perform public.cancel_order(
      current_setting('sherlyos.order')::uuid,
      order_version,
      'blocked by sent DN',
      'p42c-cancel-sent'
    );
    raise exception 'cancel with sent DN allowed';
  exception
    when others then
      if sqlerrm not like '%void the active delivery note%' then
        raise;
      end if;
  end;

  select count(*) into ledger_after from public.stock_ledger;
  if ledger_after <> ledger_before then
    raise exception 'ledger changed during send path';
  end if;

  select status into order_status from public.orders where id = current_setting('sherlyos.order')::uuid;
  if order_status is distinct from 'verified' then
    raise exception 'order status changed unexpectedly';
  end if;
end;
$$;

-- Accounts cannot acknowledge
do $$
begin
  begin
    perform public.acknowledge_delivery_note(
      current_setting('sherlyos.dn')::uuid, 3, 'p42c-accounts-ack'
    );
    raise exception 'accounts acknowledge allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' then
        raise;
      end if;
  end;
end;
$$;

-- Godown Manager acknowledge
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'godown'),
  true
);

do $$
declare
  acked jsonb;
  replay jsonb;
begin
  begin
    perform public.send_delivery_note(
      current_setting('sherlyos.dn')::uuid, 3, 'p42c-godown-send'
    );
    raise exception 'godown send allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' then
        raise;
      end if;
  end;

  acked := public.acknowledge_delivery_note(
    current_setting('sherlyos.dn')::uuid, 3, 'p42c-ack-01'
  );
  if acked -> 'delivery_note' ->> 'status' is distinct from 'acknowledged' then
    raise exception 'acknowledge failed';
  end if;

  replay := public.acknowledge_delivery_note(
    current_setting('sherlyos.dn')::uuid, 3, 'p42c-ack-01'
  );
  if replay -> 'delivery_note' ->> 'version' is distinct from '4' then
    raise exception 'ack idempotency bumped version';
  end if;

  begin
    perform public.void_delivery_note(
      current_setting('sherlyos.dn')::uuid, 4, 'nope', 'p42c-void-ack'
    );
    raise exception 'void acknowledged allowed for godown';
  exception
    when others then
      if sqlerrm not like '%not authorized%'
        and sqlerrm not like '%cannot change from acknowledged%'
      then
        raise;
      end if;
  end;
end;
$$;

-- Cross-godown acknowledge denied
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);

do $$
declare
  created jsonb;
begin
  -- Need a fresh sent DN on branch A for cross-godown tests after first DN is acknowledged.
  -- Create replacement is blocked while acknowledged open DN exists. Use a second order.
  null;
end;
$$;

reset role;

insert into public.orders (
  order_number, shop_id, branch_id, source, created_by, status, version,
  idempotency_key, submitted_at, submitted_by, verified_at, verified_by
)
values (
  'SO-TEST-42C-002',
  current_setting('sherlyos.shop')::uuid,
  current_setting('sherlyos.branch_a')::uuid,
  'accounts',
  (select id from fixture where name = 'accounts'),
  'verified', 1, 'p42c-order-verified-02',
  now(), (select id from fixture where name = 'accounts'),
  now(), (select id from fixture where name = 'accounts')
);

select set_config(
  'sherlyos.order_b',
  (select id::text from public.orders where idempotency_key = 'p42c-order-verified-02'),
  true
);

insert into public.order_lines (order_id, product_id, requested_cases)
values (
  current_setting('sherlyos.order_b')::uuid,
  current_setting('sherlyos.product')::uuid,
  2
);

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
set local role authenticated;

do $$
declare
  created jsonb;
begin
  created := public.create_delivery_note(current_setting('sherlyos.order_b')::uuid, 'p42c-create-02');
  perform set_config('sherlyos.dn_b', created -> 'delivery_note' ->> 'id', true);
  perform public.generate_delivery_note(current_setting('sherlyos.dn_b')::uuid, 1, 'p42c-generate-02');
  perform public.send_delivery_note(current_setting('sherlyos.dn_b')::uuid, 2, 'p42c-send-02');
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
    perform public.acknowledge_delivery_note(
      current_setting('sherlyos.dn_b')::uuid, 3, 'p42c-cross-ack'
    );
    raise exception 'cross-godown acknowledge allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' and sqlerrm not like '%godown is not authorized%' then
        raise;
      end if;
  end;
end;
$$;

-- Inactive GM denied
reset role;
update public.profiles
set is_active = false
where id = (select id from fixture where name = 'inactive_gm');
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'inactive_gm'),
  true
);
set local role authenticated;
do $$
begin
  begin
    perform public.acknowledge_delivery_note(
      current_setting('sherlyos.dn_b')::uuid, 3, 'p42c-inactive-ack'
    );
    raise exception 'inactive godown acknowledge allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' then
        raise;
      end if;
  end;
end;
$$;

-- Unauthorized roles
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'admin'),
  true
);
do $$
begin
  begin
    perform public.send_delivery_note(current_setting('sherlyos.dn_b')::uuid, 3, 'p42c-admin-send');
    raise exception 'admin send allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' then
        raise;
      end if;
  end;
  begin
    perform public.acknowledge_delivery_note(current_setting('sherlyos.dn_b')::uuid, 3, 'p42c-admin-ack');
    raise exception 'admin ack allowed';
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
    perform public.send_delivery_note(current_setting('sherlyos.dn_b')::uuid, 3, 'p42c-sales-send');
    raise exception 'salesperson send allowed';
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
    perform public.acknowledge_delivery_note(current_setting('sherlyos.dn_b')::uuid, 3, 'p42c-keeper-ack');
    raise exception 'keeper ack allowed';
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
    perform public.acknowledge_delivery_note(current_setting('sherlyos.dn_b')::uuid, 3, 'p42c-delivery-ack');
    raise exception 'delivery ack allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' then
        raise;
      end if;
  end;
end;
$$;

-- Accounts void sent before ack, then cancel
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
do $$
declare
  order_version integer;
begin
  perform public.void_delivery_note(
    current_setting('sherlyos.dn_b')::uuid, 3, 'void sent before ack', 'p42c-void-sent'
  );

  select version into order_version from public.orders where id = current_setting('sherlyos.order_b')::uuid;
  perform public.cancel_order(
    current_setting('sherlyos.order_b')::uuid,
    order_version,
    'cancel after void',
    'p42c-cancel-after-void'
  );

  begin
    insert into public.delivery_notes (
      order_id, shop_id, branch_id, status, version, idempotency_key, created_by
    ) values (
      current_setting('sherlyos.order')::uuid,
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'draft', 1, 'p42c-client-insert', (select id from fixture where name = 'accounts')
    );
    raise exception 'authenticated insert allowed';
  exception
    when insufficient_privilege then
      null;
  end;
end;
$$;

reset role;
do $$
begin
  begin
    update public.delivery_note_events
    set note = 'tamper'
    where delivery_note_id = current_setting('sherlyos.dn')::uuid;
    raise exception 'event update allowed';
  exception
    when others then
      if sqlerrm not like '%append-only%' then
        raise;
      end if;
  end;

  begin
    perform public.cancel_order(
      current_setting('sherlyos.order')::uuid,
      (select version from public.orders where id = current_setting('sherlyos.order')::uuid),
      'blocked by acknowledged',
      'p42c-cancel-ack'
    );
    raise exception 'cancel acknowledged DN order allowed';
  exception
    when others then
      if sqlerrm not like '%acknowledged delivery note%' then
        raise;
      end if;
  end;
end;
$$;

select 'phase_4_2c_delivery_notes ok' as result;

rollback;
