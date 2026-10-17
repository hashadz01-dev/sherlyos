-- Local disposable checks for Phase 4.2B. The transaction rolls back.
-- Run with: Get-Content -Raw supabase/tests/phase_4_2b_delivery_notes.sql | docker exec -i supabase_db_sherlyos psql -U postgres -d postgres -v ON_ERROR_STOP=1

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
  ('keeper', gen_random_uuid()),
  ('delivery', gen_random_uuid()),
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
  fixture.name || '.phase42b@example.com',
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
  when 'keeper' then 'store_keeper'
  when 'delivery' then 'delivery_person'
  when 'inactive' then 'accounts'
end;

select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'admin'),
  true
);
set local role authenticated;

select set_config('sherlyos.branch_a', public.create_branch('p42b_a', 'Phase 42B A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('p42b_b', 'Phase 42B B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'accounts_b'), current_setting('sherlyos.branch_b')::uuid);
select public.assign_user_branch((select id from fixture where name = 'salesperson'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'inactive'), current_setting('sherlyos.branch_a')::uuid);
select set_config('sherlyos.shop', public.create_shop('Phase 42B shop', null, 'Addr')::text, true);
select set_config('sherlyos.product', public.create_product('p42b-soap', 'Phase 42B soap', null, null)::text, true);
select set_config('sherlyos.product_b', public.create_product('p42b-oil', 'Phase 42B oil', null, null)::text, true);

reset role;

-- Company identity intentionally unset at start so print_ready is false.
delete from public.app_configuration
where key in ('company.legal_name', 'company.registered_address', 'company.tax_id');

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
  'SO-TEST-42B-001',
  current_setting('sherlyos.shop')::uuid,
  current_setting('sherlyos.branch_a')::uuid,
  'accounts',
  (select id from fixture where name = 'accounts'),
  'verified',
  1,
  'p42b-order-verified-01',
  now(),
  (select id from fixture where name = 'accounts'),
  now(),
  (select id from fixture where name = 'accounts')
);

select set_config(
  'sherlyos.order_verified',
  (select id::text from public.orders where idempotency_key = 'p42b-order-verified-01'),
  true
);

insert into public.order_lines (order_id, product_id, requested_cases)
values
  (
    current_setting('sherlyos.order_verified')::uuid,
    current_setting('sherlyos.product')::uuid,
    3
  ),
  (
    current_setting('sherlyos.order_verified')::uuid,
    current_setting('sherlyos.product_b')::uuid,
    2
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
  submitted_by
)
values (
  'SO-TEST-42B-002',
  current_setting('sherlyos.shop')::uuid,
  current_setting('sherlyos.branch_a')::uuid,
  'accounts',
  (select id from fixture where name = 'accounts'),
  'submitted',
  1,
  'p42b-order-submitted-01',
  now(),
  (select id from fixture where name = 'accounts')
);

select set_config(
  'sherlyos.order_submitted',
  (select id::text from public.orders where idempotency_key = 'p42b-order-submitted-01'),
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
  'SO-TEST-42B-003',
  current_setting('sherlyos.shop')::uuid,
  current_setting('sherlyos.branch_a')::uuid,
  'accounts',
  (select id from fixture where name = 'accounts'),
  'verified',
  1,
  'p42b-order-verified-02',
  now(),
  (select id from fixture where name = 'accounts'),
  now(),
  (select id from fixture where name = 'accounts')
);

select set_config(
  'sherlyos.order_verified_b',
  (select id::text from public.orders where idempotency_key = 'p42b-order-verified-02'),
  true
);

insert into public.order_lines (order_id, product_id, requested_cases)
values (
  current_setting('sherlyos.order_verified_b')::uuid,
  current_setting('sherlyos.product')::uuid,
  1
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
  voided jsonb;
  replay jsonb;
  print_payload jsonb;
  identity jsonb;
  line_count integer;
  ledger_before bigint;
  ledger_after bigint;
  order_version integer;
begin
  select count(*) into ledger_before from public.stock_ledger;

  begin
    perform public.create_delivery_note(
      current_setting('sherlyos.order_submitted')::uuid,
      'p42b-create-submitted'
    );
    raise exception 'create on submitted order allowed';
  exception
    when others then
      if sqlerrm not like '%verified order%' then
        raise;
      end if;
  end;

  created := public.create_delivery_note(
    current_setting('sherlyos.order_verified')::uuid,
    'p42b-create-01'
  );

  if created -> 'delivery_note' ->> 'status' is distinct from 'draft' then
    raise exception 'create did not land in draft';
  end if;

  perform set_config('sherlyos.dn', created -> 'delivery_note' ->> 'id', true);

  select count(*) into line_count
  from public.delivery_note_lines
  where delivery_note_id = current_setting('sherlyos.dn')::uuid;

  if line_count <> 2 then
    raise exception 'line snapshot incomplete: %', line_count;
  end if;

  replay := public.create_delivery_note(
    current_setting('sherlyos.order_verified')::uuid,
    'p42b-create-01'
  );
  if replay -> 'delivery_note' ->> 'id' is distinct from current_setting('sherlyos.dn') then
    raise exception 'create idempotency replay mismatched';
  end if;

  begin
    perform public.create_delivery_note(
      current_setting('sherlyos.order_verified')::uuid,
      'p42b-create-dup'
    );
    raise exception 'duplicate open DN allowed';
  exception
    when others then
      if sqlerrm not like '%active delivery note%' then
        raise;
      end if;
  end;

  generated := public.generate_delivery_note(
    current_setting('sherlyos.dn')::uuid,
    1,
    'p42b-generate-01'
  );
  if generated -> 'delivery_note' ->> 'status' is distinct from 'generated' then
    raise exception 'generate failed';
  end if;

  begin
    perform public.generate_delivery_note(
      current_setting('sherlyos.dn')::uuid,
      1,
      'p42b-generate-stale'
    );
    raise exception 'stale generate allowed';
  exception
    when others then
      if sqlerrm not like '%changed by someone else%'
        and sqlerrm not like '%cannot change from generated%'
      then
        raise;
      end if;
  end;

  identity := public.get_company_print_identity();
  if coalesce((identity ->> 'ready')::boolean, true) then
    raise exception 'identity should be unready without config';
  end if;

  print_payload := public.get_delivery_note_print(current_setting('sherlyos.dn')::uuid);
  if coalesce((print_payload ->> 'print_ready')::boolean, true) then
    raise exception 'print_ready should be false without company identity';
  end if;

  begin
    perform public.get_delivery_note_print(
      (
        select id from public.delivery_notes
        where order_id = current_setting('sherlyos.order_verified_b')::uuid
      )
    );
  exception
    when others then
      null;
  end;

  -- Configure identity inside privileged path by temporarily resetting role.
  reset role;
  insert into public.app_configuration (key, value, description)
  values
    ('company.legal_name', '"Local Test Co"'::jsonb, 'Local test identity only.'),
    ('company.registered_address', '"1 Test Street"'::jsonb, 'Local test identity only.')
  on conflict (key) do update
    set value = excluded.value,
        description = excluded.description;
  perform set_config(
    'request.jwt.claims',
    (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
    true
  );
  set local role authenticated;

  print_payload := public.get_delivery_note_print(current_setting('sherlyos.dn')::uuid);
  if not coalesce((print_payload ->> 'print_ready')::boolean, false) then
    raise exception 'print_ready should be true after identity config';
  end if;

  select version into order_version
  from public.orders
  where id = current_setting('sherlyos.order_verified')::uuid;

  begin
    perform public.cancel_order(
      current_setting('sherlyos.order_verified')::uuid,
      order_version,
      'should fail with active DN',
      'p42b-cancel-blocked-01'
    );
    raise exception 'cancel with active DN allowed';
  exception
    when others then
      if sqlerrm not like '%void the active delivery note%' then
        raise;
      end if;
  end;

  voided := public.void_delivery_note(
    current_setting('sherlyos.dn')::uuid,
    2,
    'fixture void after generate',
    'p42b-void-01'
  );
  if voided -> 'delivery_note' ->> 'status' is distinct from 'voided' then
    raise exception 'void failed';
  end if;

  perform public.cancel_order(
    current_setting('sherlyos.order_verified')::uuid,
    order_version,
    'cancel after void',
    'p42b-cancel-after-void-01'
  );

  -- Second DN path: draft void + sent void support + ack rejection.
  created := public.create_delivery_note(
    current_setting('sherlyos.order_verified_b')::uuid,
    'p42b-create-02'
  );
  perform set_config('sherlyos.dn_b', created -> 'delivery_note' ->> 'id', true);

  voided := public.void_delivery_note(
    current_setting('sherlyos.dn_b')::uuid,
    1,
    'void draft',
    'p42b-void-draft-01'
  );
  if voided -> 'delivery_note' ->> 'status' is distinct from 'voided' then
    raise exception 'draft void failed';
  end if;

  created := public.create_delivery_note(
    current_setting('sherlyos.order_verified_b')::uuid,
    'p42b-create-03'
  );
  perform set_config('sherlyos.dn_c', created -> 'delivery_note' ->> 'id', true);
  perform public.generate_delivery_note(
    current_setting('sherlyos.dn_c')::uuid,
    1,
    'p42b-generate-03'
  );

  reset role;
  update public.delivery_notes
  set
    status = 'sent',
    sent_at = now(),
    sent_by = (select id from fixture where name = 'accounts'),
    version = 3
  where id = current_setting('sherlyos.dn_c')::uuid;
  perform set_config(
    'request.jwt.claims',
    (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
    true
  );
  set local role authenticated;

  voided := public.void_delivery_note(
    current_setting('sherlyos.dn_c')::uuid,
    3,
    'void sent',
    'p42b-void-sent-01'
  );
  if voided -> 'delivery_note' ->> 'status' is distinct from 'voided' then
    raise exception 'sent void failed';
  end if;

  created := public.create_delivery_note(
    current_setting('sherlyos.order_verified_b')::uuid,
    'p42b-create-04'
  );
  perform set_config('sherlyos.dn_d', created -> 'delivery_note' ->> 'id', true);
  perform public.generate_delivery_note(
    current_setting('sherlyos.dn_d')::uuid,
    1,
    'p42b-generate-04'
  );
  reset role;
  update public.delivery_notes
  set
    status = 'acknowledged',
    sent_at = now(),
    sent_by = (select id from fixture where name = 'accounts'),
    acknowledged_at = now(),
    acknowledged_by = (select id from fixture where name = 'godown'),
    version = 3
  where id = current_setting('sherlyos.dn_d')::uuid;
  perform set_config(
    'request.jwt.claims',
    (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
    true
  );
  set local role authenticated;

  begin
    perform public.void_delivery_note(
      current_setting('sherlyos.dn_d')::uuid,
      3,
      'should fail',
      'p42b-void-ack-01'
    );
    raise exception 'acknowledged void allowed';
  exception
    when others then
      if sqlerrm not like '%cannot change from acknowledged%' then
        raise;
      end if;
  end;

  select version into order_version
  from public.orders
  where id = current_setting('sherlyos.order_verified_b')::uuid;

  begin
    perform public.cancel_order(
      current_setting('sherlyos.order_verified_b')::uuid,
      order_version,
      'should fail acknowledged',
      'p42b-cancel-ack-01'
    );
    raise exception 'cancel with acknowledged DN allowed';
  exception
    when others then
      if sqlerrm not like '%acknowledged delivery note%' then
        raise;
      end if;
  end;

  begin
    insert into public.delivery_notes (
      order_id, shop_id, branch_id, status, version, idempotency_key, created_by
    ) values (
      current_setting('sherlyos.order_verified_b')::uuid,
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'draft', 1, 'p42b-client-insert', (select id from fixture where name = 'accounts')
    );
    raise exception 'authenticated insert allowed';
  exception
    when insufficient_privilege then
      null;
  end;

  select count(*) into ledger_after from public.stock_ledger;
  if ledger_after <> ledger_before then
    raise exception 'stock ledger changed during DN mutations';
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
    perform public.create_delivery_note(
      current_setting('sherlyos.order_verified_b')::uuid,
      'p42b-cross-create'
    );
    raise exception 'cross-godown create allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' and sqlerrm not like '%godown is not authorized%' then
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
begin
  begin
    perform public.create_delivery_note(
      current_setting('sherlyos.order_verified_b')::uuid,
      'p42b-godown-create'
    );
    raise exception 'godown create allowed';
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
    perform public.create_delivery_note(
      current_setting('sherlyos.order_verified_b')::uuid,
      'p42b-sales-create'
    );
    raise exception 'salesperson create allowed';
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
    perform public.generate_delivery_note(
      current_setting('sherlyos.dn_d')::uuid,
      3,
      'p42b-keeper-generate'
    );
    raise exception 'keeper generate allowed';
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
    perform public.void_delivery_note(
      current_setting('sherlyos.dn_d')::uuid,
      3,
      'nope',
      'p42b-delivery-void'
    );
    raise exception 'delivery void allowed';
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
    perform public.create_delivery_note(
      current_setting('sherlyos.order_verified_b')::uuid,
      'p42b-inactive-create'
    );
    raise exception 'inactive create allowed';
  exception
    when others then
      if sqlerrm not like '%not authorized%' then
        raise;
      end if;
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
end;
$$;

do $$
begin
  if exists (select 1 from public.stock_balances where quantity < 0) then
    raise exception 'negative balances exist';
  end if;
end;
$$;

select 'phase_4_2b_delivery_notes ok' as result;

rollback;
