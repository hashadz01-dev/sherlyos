-- Phase 4.3E.2B local disposable checks. Transaction rolls back.
-- Covers private dual-write helper, receipt attributions, RLS, flags, posting compatibility.

begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);

grant select on fixture to authenticated, anon, service_role;

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('accounts', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.phase43e2b@example.com',
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
      values ((select id from fixture where name = 'admin'), 'Phase 4.3E.2B Admin', true)
      on conflict (id) do update set is_active = true;

      insert into public.user_roles (user_id, role_id, assigned_by)
      select
        (select id from fixture where name = 'admin'),
        roles.id,
        (select id from fixture where name = 'admin')
      from public.roles
      where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.profiles (id, full_name, is_active)
select fixture.id, fixture.name, true
from fixture
where fixture.name <> 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles
  on roles.code = case fixture.name
    when 'godown' then 'godown_manager'
    when 'keeper' then 'store_keeper'
    when 'accounts' then 'accounts'
  end
where fixture.name in ('godown', 'keeper', 'accounts')
on conflict do nothing;

-- D1 permission matrix
do $$
begin
  if not exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'admin' and permissions.code = 'stock.lots.legacy.reconcile'
  ) then
    raise exception 'admin missing stock.lots.legacy.reconcile';
  end if;

  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code in ('godown_manager', 'store_keeper', 'accounts')
      and permissions.code = 'stock.lots.legacy.reconcile'
  ) then
    raise exception 'non-admin must not have stock.lots.legacy.reconcile';
  end if;
end $$;

-- Cutover flags remain disabled
do $$
declare
  blocked text;
  dual_write text;
begin
  select value::text into blocked
  from public.app_configuration where key = 'stock.lots.aggregate_only_blocked';
  select value::text into dual_write
  from public.app_configuration where key = 'stock.lots.dual_write_enabled';

  if blocked is distinct from 'false' then
    raise exception 'aggregate_only_blocked should be false, got %', blocked;
  end if;
  if dual_write is distinct from 'false' then
    raise exception 'dual_write_enabled should be false, got %', dual_write;
  end if;
end $$;

-- Client cannot execute private helper
do $$
begin
  if has_function_privilege('authenticated', 'app_private.apply_lot_aware_stock_deltas(jsonb)', 'execute') then
    raise exception 'authenticated must not execute apply_lot_aware_stock_deltas';
  end if;
  if has_function_privilege('anon', 'app_private.apply_lot_aware_stock_deltas(jsonb)', 'execute') then
    raise exception 'anon must not execute apply_lot_aware_stock_deltas';
  end if;
  if has_function_privilege('service_role', 'app_private.apply_lot_aware_stock_deltas(jsonb)', 'execute') then
    raise exception 'service_role must not execute apply_lot_aware_stock_deltas';
  end if;
end $$;

select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select set_config('sherlyos.branch', public.create_branch('p43e2b_a', 'Phase 4.3E.2B A')::text, true);
select set_config('sherlyos.branch_b', public.create_branch('p43e2b_b', 'Phase 4.3E.2B B')::text, true);
select public.assign_user_branch(
  (select id from fixture where name = 'godown'),
  current_setting('sherlyos.branch')::uuid
);
select public.assign_user_branch(
  (select id from fixture where name = 'keeper'),
  current_setting('sherlyos.branch')::uuid
);
select set_config(
  'sherlyos.zone',
  public.create_zone(current_setting('sherlyos.branch')::uuid, 'z43e2b', 'Z43E2B', null)::text,
  true
);
select set_config(
  'sherlyos.crate',
  public.create_crate(current_setting('sherlyos.zone')::uuid, 'c43e2b', 'C43E2B', null)::text,
  true
);
select set_config(
  'sherlyos.zone_b',
  public.create_zone(current_setting('sherlyos.branch_b')::uuid, 'z43e2bb', 'Z43E2BB', null)::text,
  true
);
select set_config(
  'sherlyos.crate_b',
  public.create_crate(current_setting('sherlyos.zone_b')::uuid, 'c43e2bb', 'C43E2BB', null)::text,
  true
);
select set_config(
  'sherlyos.product_exp',
  public.create_product('p43e2b-exp', 'Phase 4.3E.2B Expiry', null, null)::text,
  true
);
select set_config(
  'sherlyos.product_ne',
  public.create_product('p43e2b-ne', 'Phase 4.3E.2B NonExp', null, null)::text,
  true
);
select set_config(
  'sherlyos.product_open',
  public.create_product('p43e2b-open', 'Phase 4.3E.2B Opening Compat', null, null)::text,
  true
);
select public.set_product_expiry_policy(
  current_setting('sherlyos.product_exp')::uuid,
  'expiry_controlled'
);
select public.set_product_expiry_policy(
  current_setting('sherlyos.product_ne')::uuid,
  'non_expiring'
);
select set_config(
  'sherlyos.supplier',
  public.create_supplier('Phase 4.3E.2B Supplier', null, null)::text,
  true
);

reset role;

-- Seed lots as table owner for helper tests
do $$
declare
  lot1 uuid;
  lot2 uuid;
  lot_wrong_branch uuid;
  lot_other_product uuid;
  branch uuid := current_setting('sherlyos.branch')::uuid;
  branch_b uuid := current_setting('sherlyos.branch_b')::uuid;
  product_exp uuid := current_setting('sherlyos.product_exp')::uuid;
  product_ne uuid := current_setting('sherlyos.product_ne')::uuid;
  admin_id uuid := (select id from fixture where name = 'admin');
begin
  insert into public.stock_lots (
    product_id, branch_id, manufacturer_lot_code, expiry_date, received_on,
    status, origin, created_by
  ) values (
    product_exp, branch, 'LOT-A', current_date + 90, clock_timestamp(),
    'available', 'receipt', admin_id
  ) returning id into lot1;

  insert into public.stock_lots (
    product_id, branch_id, manufacturer_lot_code, expiry_date, received_on,
    status, origin, created_by
  ) values (
    product_exp, branch, 'LOT-B', current_date + 120, clock_timestamp(),
    'available', 'receipt', admin_id
  ) returning id into lot2;

  insert into public.stock_lots (
    product_id, branch_id, manufacturer_lot_code, expiry_date, received_on,
    status, origin, created_by
  ) values (
    product_exp, branch_b, 'LOT-X', current_date + 90, clock_timestamp(),
    'available', 'receipt', admin_id
  ) returning id into lot_wrong_branch;

  insert into public.stock_lots (
    product_id, branch_id, manufacturer_lot_code, expiry_date, received_on,
    status, origin, created_by
  ) values (
    product_ne, branch, null, null, clock_timestamp(),
    'available', 'opening', admin_id
  ) returning id into lot_other_product;

  perform set_config('sherlyos.lot1', lot1::text, true);
  perform set_config('sherlyos.lot2', lot2::text, true);
  perform set_config('sherlyos.lot_wrong_branch', lot_wrong_branch::text, true);
  perform set_config('sherlyos.lot_other_product', lot_other_product::text, true);
end $$;

-- Atomic aggregate + lot delta + quantity conservation
-- Caller posts matching ledger rows first; helper updates lot + aggregate balances.
do $$
declare
  crate uuid := current_setting('sherlyos.crate')::uuid;
  product uuid := current_setting('sherlyos.product_exp')::uuid;
  lot1 uuid := current_setting('sherlyos.lot1')::uuid;
  lot2 uuid := current_setting('sherlyos.lot2')::uuid;
  admin_id uuid := (select id from fixture where name = 'admin');
  txn_id uuid;
  agg integer;
  lot_sum integer;
begin
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    product_id, destination_crate_id, quantity
  ) values (
    'OPENING_STOCK',
    'P43E2B-HELPER-1',
    admin_id,
    'p43e2b-helper-' || substr(gen_random_uuid()::text, 1, 8),
    'p43e2b-helper-fp-1',
    product,
    crate,
    10
  ) returning id into txn_id;

  insert into public.stock_ledger (
    transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
  ) values
    (txn_id, product, crate, 7, admin_id, clock_timestamp(), lot1),
    (txn_id, product, crate, 3, admin_id, clock_timestamp(), lot2);

  perform app_private.apply_lot_aware_stock_deltas(jsonb_build_array(
    jsonb_build_object(
      'product_id', product, 'lot_id', lot1, 'crate_id', crate, 'quantity', 7
    ),
    jsonb_build_object(
      'product_id', product, 'lot_id', lot2, 'crate_id', crate, 'carton_delta', 3
    )
  ));

  select quantity into agg
  from public.stock_balances
  where crate_id = crate and product_id = product;

  select coalesce(sum(quantity), 0) into lot_sum
  from public.stock_lot_balances
  where crate_id = crate
    and lot_id in (lot1, lot2);

  if agg is distinct from 10 or lot_sum is distinct from 10 then
    raise exception 'conservation failed: agg=% lot_sum=%', agg, lot_sum;
  end if;
end $$;

-- Negative quantity rejection
do $$
begin
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
    true
  );

  begin
    perform app_private.apply_lot_aware_stock_deltas(jsonb_build_array(
      jsonb_build_object(
        'product_id', current_setting('sherlyos.product_exp')::uuid,
        'lot_id', current_setting('sherlyos.lot1')::uuid,
        'crate_id', current_setting('sherlyos.crate')::uuid,
        'quantity', -100
      )
    ));
    raise exception 'negative lot stock should fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Wrong product rejection
do $$
begin
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
    true
  );

  begin
    perform app_private.apply_lot_aware_stock_deltas(jsonb_build_array(
      jsonb_build_object(
        'product_id', current_setting('sherlyos.product_ne')::uuid,
        'lot_id', current_setting('sherlyos.lot1')::uuid,
        'crate_id', current_setting('sherlyos.crate')::uuid,
        'quantity', 1
      )
    ));
    raise exception 'wrong product should fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Wrong branch rejection
do $$
begin
  perform set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
    true
  );

  begin
    perform app_private.apply_lot_aware_stock_deltas(jsonb_build_array(
      jsonb_build_object(
        'product_id', current_setting('sherlyos.product_exp')::uuid,
        'lot_id', current_setting('sherlyos.lot_wrong_branch')::uuid,
        'crate_id', current_setting('sherlyos.crate')::uuid,
        'quantity', 1
      )
    ));
    raise exception 'wrong branch should fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- Existing stock-posting compatibility (opening still works; flags false)
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'admin'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'admin'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

do $$
declare
  posted jsonb;
begin
  posted := public.post_opening_stock(
    current_setting('sherlyos.product_open')::uuid,
    current_setting('sherlyos.crate')::uuid,
    4,
    'p43e2b-opening-' || gen_random_uuid()::text,
    null
  );
  if posted ->> 'id' is null then
    raise exception 'opening stock compatibility failed';
  end if;
end $$;

-- Receipt attributions: multi-lot, expiry policy, sum check, immutability
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'keeper'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'keeper'), 'role', 'authenticated')::text,
  true
);

do $$
declare
  receipt jsonb;
  selected_receipt uuid;
  line_id uuid;
  attrs jsonb;
  fp_before text;
  fp_after text;
begin
  receipt := public.create_stock_receipt(
    current_setting('sherlyos.branch')::uuid,
    current_setting('sherlyos.supplier')::uuid,
    'P43E2B-ATTR-' || substr(gen_random_uuid()::text, 1, 8),
    current_date,
    null,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product_exp')::uuid,
      'destination_crate_id', current_setting('sherlyos.crate')::uuid,
      'document_cases', 10,
      'counted_cases', 10,
      'damaged_cases', 0
    ))
  );
  selected_receipt := (receipt ->> 'id')::uuid;
  select stock_receipt_lines.id into line_id
  from public.stock_receipt_lines
  where stock_receipt_lines.receipt_id = selected_receipt;

  perform set_config('sherlyos.receipt_id', selected_receipt::text, true);
  perform set_config('sherlyos.line_id', line_id::text, true);

  -- Expiry required for expiry_controlled
  begin
    perform public.set_stock_receipt_line_lot_attributions(
      line_id,
      jsonb_build_array(jsonb_build_object(
        'carton_quantity', 10,
        'manufacturer_lot_code', 'NO-EXP'
      ))
    );
    raise exception 'expiry_controlled without expiry should fail';
  exception
    when sqlstate '23514' then null;
  end;

  -- Quantity must equal accepted_cases
  begin
    perform public.set_stock_receipt_line_lot_attributions(
      line_id,
      jsonb_build_array(
        jsonb_build_object(
          'carton_quantity', 4,
          'manufacturer_lot_code', 'A',
          'expiry_date', (current_date + 30)::text
        ),
        jsonb_build_object(
          'carton_quantity', 3,
          'manufacturer_lot_code', 'B',
          'expiry_date', (current_date + 60)::text
        )
      )
    );
    raise exception 'under-attributed quantity should fail';
  exception
    when sqlstate '23514' then null;
  end;

  attrs := public.set_stock_receipt_line_lot_attributions(
    line_id,
    jsonb_build_array(
      jsonb_build_object(
        'carton_quantity', 6,
        'manufacturer_lot_code', 'A1',
        'manufactured_on', (current_date - 10)::text,
        'expiry_date', (current_date + 30)::text
      ),
      jsonb_build_object(
        'carton_quantity', 4,
        'manufacturer_lot_code', 'B2',
        'expiry_date', (current_date + 60)::text
      )
    )
  );

  if jsonb_array_length(attrs) is distinct from 2 then
    raise exception 'expected two attribution rows, got %', attrs;
  end if;

  perform set_config('sherlyos.attr_count', jsonb_array_length(attrs)::text, true);
end $$;

reset role;

-- Fingerprint includes attributions (private helper; run as postgres)
do $$
declare
  selected_receipt uuid := current_setting('sherlyos.receipt_id')::uuid;
  line_id uuid := current_setting('sherlyos.line_id')::uuid;
  fp_with text;
  fp_without text;
begin
  fp_with := app_private.receipt_posting_fingerprint(selected_receipt);

  delete from public.stock_receipt_line_lot_attributions
  where receipt_line_id = line_id;

  fp_without := app_private.receipt_posting_fingerprint(selected_receipt);
  if fp_with is not distinct from fp_without then
    raise exception 'fingerprint should include attributions';
  end if;

  insert into public.stock_receipt_line_lot_attributions (
    receipt_line_id, carton_quantity, manufacturer_lot_code, manufactured_on, expiry_date, sort_order, created_by
  ) values
    (line_id, 6, 'A1', current_date - 10, current_date + 30, 0, (select id from fixture where name = 'keeper')),
    (line_id, 4, 'B2', null, current_date + 60, 1, (select id from fixture where name = 'keeper'));
end $$;

select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'keeper'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'keeper'), 'role', 'authenticated')::text,
  true
);
set local role authenticated;

-- Non-expiring product: expiry must be null
do $$
declare
  receipt jsonb;
  line_id uuid;
begin
  receipt := public.create_stock_receipt(
    current_setting('sherlyos.branch')::uuid,
    current_setting('sherlyos.supplier')::uuid,
    'P43E2B-NE-' || substr(gen_random_uuid()::text, 1, 8),
    current_date,
    null,
    jsonb_build_array(jsonb_build_object(
      'product_id', current_setting('sherlyos.product_ne')::uuid,
      'destination_crate_id', current_setting('sherlyos.crate')::uuid,
      'document_cases', 5,
      'counted_cases', 5,
      'damaged_cases', 0
    ))
  );
  select stock_receipt_lines.id into line_id
  from public.stock_receipt_lines
  where stock_receipt_lines.receipt_id = (receipt ->> 'id')::uuid;

  begin
    perform public.set_stock_receipt_line_lot_attributions(
      line_id,
      jsonb_build_array(jsonb_build_object(
        'carton_quantity', 5,
        'expiry_date', (current_date + 10)::text
      ))
    );
    raise exception 'non_expiring with expiry should fail';
  exception
    when sqlstate '23514' then null;
  end;

  perform public.set_stock_receipt_line_lot_attributions(
    line_id,
    jsonb_build_array(jsonb_build_object(
      'carton_quantity', 5,
      'manufacturer_lot_code', 'NE-1'
    ))
  );
end $$;

-- Accounts cannot set attributions
select set_config('request.jwt.claim.sub', (select id from fixture where name = 'accounts')::text, true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'accounts'), 'role', 'authenticated')::text,
  true
);

do $$
begin
  begin
    perform public.set_stock_receipt_line_lot_attributions(
      current_setting('sherlyos.line_id')::uuid,
      '[]'::jsonb
    );
    raise exception 'accounts should not set attributions';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Direct table insert denied for authenticated
do $$
begin
  begin
    insert into public.stock_receipt_line_lot_attributions (
      receipt_line_id, carton_quantity, expiry_date, sort_order
    ) values (
      current_setting('sherlyos.line_id')::uuid,
      1,
      current_date + 1,
      99
    );
    raise exception 'direct insert should be denied';
  exception
    when insufficient_privilege then null;
    when sqlstate '42501' then null;
  end;
end $$;

-- Post-verification immutability
select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'keeper'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'keeper'), 'role', 'authenticated')::text,
  true
);
select public.submit_stock_receipt(current_setting('sherlyos.receipt_id')::uuid);

select set_config('request.jwt.claim.sub', (select id::text from fixture where name = 'godown'), true);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', (select id from fixture where name = 'godown'), 'role', 'authenticated')::text,
  true
);
select public.verify_stock_receipt(
  current_setting('sherlyos.receipt_id')::uuid,
  'p43e2b-verify-' || gen_random_uuid()::text
);

do $$
begin
  begin
    perform public.set_stock_receipt_line_lot_attributions(
      current_setting('sherlyos.line_id')::uuid,
      jsonb_build_array(jsonb_build_object(
        'carton_quantity', 10,
        'manufacturer_lot_code', 'AFTER',
        'expiry_date', (current_date + 30)::text
      ))
    );
    raise exception 'post-verify attribution change should fail';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Flags still disabled after tests
do $$
begin
  if (
    select value from public.app_configuration where key = 'stock.lots.dual_write_enabled'
  ) is distinct from 'false'::jsonb then
    raise exception 'dual_write_enabled mutated';
  end if;
  if (
    select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked'
  ) is distinct from 'false'::jsonb then
    raise exception 'aggregate_only_blocked mutated';
  end if;
end $$;

rollback;
