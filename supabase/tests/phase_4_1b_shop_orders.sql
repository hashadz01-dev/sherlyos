-- Local disposable checks for Phase 4.1B. The transaction rolls back.
-- Run with: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f supabase/tests/phase_4_1b_shop_orders.sql

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
  fixture.name || '.phase41b@example.com',
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

select set_config('sherlyos.branch_a', public.create_branch('p41b_a', 'Phase 41B A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('p41b_b', 'Phase 41B B')::text, true);
select public.assign_user_branch((select id from fixture where name = 'accounts'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'salesperson'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'godown'), current_setting('sherlyos.branch_a')::uuid);
select public.assign_user_branch((select id from fixture where name = 'inactive'), current_setting('sherlyos.branch_a')::uuid);
select set_config('sherlyos.shop', public.create_shop('Phase 41B assigned', null, null)::text, true);
select set_config('sherlyos.shop_other', public.create_shop('Phase 41B other', null, null)::text, true);
select set_config('sherlyos.shop_inactive', public.create_shop('Phase 41B inactive', null, null)::text, true);
select public.set_shop_active(current_setting('sherlyos.shop_inactive')::uuid, false);
select public.assign_shop_salesperson(
  current_setting('sherlyos.shop')::uuid,
  (select id from fixture where name = 'salesperson')
);
select set_config('sherlyos.product', public.create_product('p41b-soap', 'Phase 41B soap', null, null)::text, true);
select set_config('sherlyos.product_two', public.create_product('p41b-oil', 'Phase 41B oil', null, null)::text, true);
select set_config('sherlyos.inactive_product', public.create_product('p41b-old', 'Phase 41B old', null, null)::text, true);
select public.set_product_active(current_setting('sherlyos.inactive_product')::uuid, false);

reset role;
select set_config('request.jwt.claims', '', true);

update public.profiles
set is_active = false
where id = (select id from fixture where name = 'inactive');

-- Ledger baseline
select set_config(
  'sherlyos.ledger_before',
  (select count(*)::text from public.stock_ledger),
  true
);
select set_config(
  'sherlyos.balance_before',
  (select count(*)::text from public.stock_balances),
  true
);

-- Salesperson creates a draft
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'salesperson'),
  true
);
set local role authenticated;

select set_config(
  'sherlyos.created',
  (
    public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'salesperson',
      'ref-1',
      'first draft',
      jsonb_build_array(
        jsonb_build_object(
          'product_id', current_setting('sherlyos.product')::uuid,
          'requested_cases', 3
        )
      ),
      'create-order-key-01'
    ) -> 'order' ->> 'id'
  ),
  true
);

do $$
declare
  payload jsonb;
  order_row public.orders%rowtype;
begin
  payload := public.get_order(current_setting('sherlyos.created')::uuid);
  if payload -> 'order' ->> 'status' is distinct from 'draft' then
    raise exception 'expected draft';
  end if;
  if payload -> 'order' ->> 'version' is distinct from '1' then
    raise exception 'expected version 1';
  end if;
  if jsonb_array_length(payload -> 'lines') <> 1 then
    raise exception 'expected one line';
  end if;
  if jsonb_array_length(payload -> 'events') <> 1 then
    raise exception 'expected created event';
  end if;

  select * into order_row from public.orders where id = current_setting('sherlyos.created')::uuid;
  if order_row.order_number not like 'SO-%' then
    raise exception 'order number missing';
  end if;
end;
$$;

-- Idempotent replay
do $$
declare
  first jsonb;
  second jsonb;
begin
  first := public.get_order(current_setting('sherlyos.created')::uuid);
  second := public.create_order(
    current_setting('sherlyos.shop')::uuid,
    current_setting('sherlyos.branch_a')::uuid,
    'salesperson',
    'ref-1',
    'first draft',
    jsonb_build_array(
      jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'requested_cases', 3
      )
    ),
    'create-order-key-01'
  );
  if first -> 'order' ->> 'id' is distinct from second -> 'order' ->> 'id' then
    raise exception 'create replay must return the same order';
  end if;
end;
$$;

-- Mismatched create body rejected
do $$
begin
  begin
    perform public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'salesperson',
      'ref-2',
      'first draft',
      jsonb_build_array(
        jsonb_build_object(
          'product_id', current_setting('sherlyos.product')::uuid,
          'requested_cases', 3
        )
      ),
      'create-order-key-01'
    );
    raise exception 'mismatched create should fail';
  exception
    when sqlstate '23514' then
      if sqlerrm not like 'idempotency key does not match the original request%' then
        raise;
      end if;
  end;
end;
$$;

-- Edit draft
do $$
declare
  payload jsonb;
begin
  payload := public.set_order(
    current_setting('sherlyos.created')::uuid,
    1,
    current_setting('sherlyos.shop')::uuid,
    current_setting('sherlyos.branch_a')::uuid,
    'salesperson',
    'ref-1b',
    'revised draft',
    jsonb_build_array(
      jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'requested_cases', 5
      ),
      jsonb_build_object(
        'product_id', current_setting('sherlyos.product_two')::uuid,
        'requested_cases', 2
      )
    ),
    'edit-order-key-01'
  );
  if payload -> 'order' ->> 'version' is distinct from '2' then
    raise exception 'expected version 2 after edit';
  end if;
  if payload -> 'order' ->> 'status' is distinct from 'draft' then
    raise exception 'edit must keep draft';
  end if;
  if jsonb_array_length(payload -> 'lines') <> 2 then
    raise exception 'expected two lines after edit';
  end if;
end;
$$;

-- Edit idempotent replay
do $$
declare
  payload jsonb;
begin
  payload := public.set_order(
    current_setting('sherlyos.created')::uuid,
    1,
    current_setting('sherlyos.shop')::uuid,
    current_setting('sherlyos.branch_a')::uuid,
    'salesperson',
    'ref-1b',
    'revised draft',
    jsonb_build_array(
      jsonb_build_object(
        'product_id', current_setting('sherlyos.product')::uuid,
        'requested_cases', 5
      ),
      jsonb_build_object(
        'product_id', current_setting('sherlyos.product_two')::uuid,
        'requested_cases', 2
      )
    ),
    'edit-order-key-01'
  );
  if payload -> 'order' ->> 'version' is distinct from '2' then
    raise exception 'edit replay must not bump version';
  end if;
end;
$$;

-- Stale version rejected
do $$
begin
  begin
    perform public.set_order(
      current_setting('sherlyos.created')::uuid,
      1,
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'salesperson',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object(
          'product_id', current_setting('sherlyos.product')::uuid,
          'requested_cases', 1
        )
      ),
      'edit-order-key-stale'
    );
    raise exception 'stale version should fail';
  exception
    when sqlstate 'PT409' then
      null;
  end;
end;
$$;

-- Unassigned shop rejected for salesperson
do $$
begin
  begin
    perform public.create_order(
      current_setting('sherlyos.shop_other')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'salesperson',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object(
          'product_id', current_setting('sherlyos.product')::uuid,
          'requested_cases', 1
        )
      ),
      'create-order-key-unassigned'
    );
    raise exception 'unassigned shop should fail';
  exception
    when sqlstate '42501' then
      null;
  end;
end;
$$;

-- Inactive product rejected
do $$
begin
  begin
    perform public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'salesperson',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object(
          'product_id', current_setting('sherlyos.inactive_product')::uuid,
          'requested_cases', 1
        )
      ),
      'create-order-key-inactive-product'
    );
    raise exception 'inactive product should fail';
  exception
    when sqlstate '23514' then
      null;
  end;
end;
$$;

-- Unauthorized godown rejected
do $$
begin
  begin
    perform public.create_order(
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_b')::uuid,
      'salesperson',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object(
          'product_id', current_setting('sherlyos.product')::uuid,
          'requested_cases', 1
        )
      ),
      'create-order-key-bad-godown'
    );
    raise exception 'unauthorized godown should fail';
  exception
    when sqlstate '42501' then
      null;
  end;
end;
$$;

reset role;
select set_config('request.jwt.claims', '', true);

-- Accounts can create for any active shop on an assigned godown
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'accounts'),
  true
);
set local role authenticated;

select set_config(
  'sherlyos.accounts_order',
  (
    public.create_order(
      current_setting('sherlyos.shop_other')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'accounts',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object(
          'product_id', current_setting('sherlyos.product')::uuid,
          'requested_cases', 1
        )
      ),
      'create-order-key-accounts'
    ) -> 'order' ->> 'id'
  ),
  true
);

-- Accounts cannot edit salesperson order
do $$
begin
  begin
    perform public.set_order(
      current_setting('sherlyos.created')::uuid,
      2,
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'accounts',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object(
          'product_id', current_setting('sherlyos.product')::uuid,
          'requested_cases', 1
        )
      ),
      'edit-order-key-accounts'
    );
    raise exception 'non-creator edit should fail';
  exception
    when sqlstate '42501' then
      null;
  end;
end;
$$;

reset role;
select set_config('request.jwt.claims', '', true);

-- Godown, keeper, delivery, admin cannot create
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
        current_setting('sherlyos.branch_a')::uuid,
        'salesperson',
        null,
        null,
        jsonb_build_array(
          jsonb_build_object(
            'product_id', current_setting('sherlyos.product')::uuid,
            'requested_cases', 1
          )
        ),
        'create-order-key-' || actor
      );
      raise exception '% should not create', actor;
    exception
      when sqlstate '42501' then
        null;
    end;
    reset role;
    perform set_config('request.jwt.claims', '', true);
  end loop;
end;
$$;

-- Inactive accounts denied
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'inactive'),
  true
);
set local role authenticated;
do $$
begin
  begin
    perform public.create_order(
      current_setting('sherlyos.shop_other')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'accounts',
      null,
      null,
      jsonb_build_array(
        jsonb_build_object(
          'product_id', current_setting('sherlyos.product')::uuid,
          'requested_cases', 1
        )
      ),
      'create-order-key-inactive'
    );
    raise exception 'inactive user should fail';
  exception
    when sqlstate '42501' then
      null;
  end;
end;
$$;
reset role;
select set_config('request.jwt.claims', '', true);

-- Direct table writes denied
select set_config(
  'request.jwt.claims',
  (select json_build_object('sub', id, 'role', 'authenticated')::text from fixture where name = 'salesperson'),
  true
);
set local role authenticated;
do $$
begin
  begin
    insert into public.orders (
      order_number, shop_id, branch_id, source, created_by, idempotency_key
    ) values (
      'SO-DIRECT',
      current_setting('sherlyos.shop')::uuid,
      current_setting('sherlyos.branch_a')::uuid,
      'salesperson',
      (select id from fixture where name = 'salesperson'),
      'direct-write-key-01'
    );
    raise exception 'direct order insert should fail';
  exception
    when insufficient_privilege then
      null;
  end;
end;
$$;

-- 4.1B capture must not leave verified orders
do $$
begin
  if exists (select 1 from public.orders where status = 'verified') then
    raise exception '4.1B capture path must not verify orders';
  end if;
end;
$$;

-- Ledger unchanged
do $$
begin
  if (select count(*) from public.stock_ledger)::text
    is distinct from current_setting('sherlyos.ledger_before')
    or (select count(*) from public.stock_balances)::text
      is distinct from current_setting('sherlyos.balance_before')
  then
    raise exception 'order capture must not change stock';
  end if;

  if exists (
    select 1 from public.orders where status = 'verified'
  ) then
    raise exception 'no order may be verified in 4.1B';
  end if;
end;
$$;

reset role;
select set_config('request.jwt.claims', '', true);

rollback;
