-- Disposable fixture for overlapping receiving sessions.
-- The runner is supabase/tests/phase_3_1_concurrency.mjs.

create or replace function public.phase31_claim(actor_email text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config(
    'request.jwt.claims',
    (
      select pg_catalog.json_build_object('sub', id, 'role', 'authenticated')::text
      from auth.users
      where email = actor_email
    ),
    false
  );
end;
$$;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  gen_random_uuid(),
  'authenticated',
  'authenticated',
  address.email,
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', address.full_name),
  now(),
  now()
from (
  values
    ('admin.phase31race@example.com', 'Phase 31 Race Admin'),
    ('manager.phase31race@example.com', 'Phase 31 Race Manager'),
    ('manager2.phase31race@example.com', 'Phase 31 Race Manager 2'),
    ('keeper.phase31race@example.com', 'Phase 31 Race Keeper')
) as address (email, full_name);

select app_private.bootstrap_initial_admin(
  (select id from auth.users where email = 'admin.phase31race@example.com'),
  'create-initial-administrator'
);

insert into public.user_roles (user_id, role_id)
select users.id, roles.id
from auth.users as users
join public.roles on roles.code = case users.email
  when 'manager.phase31race@example.com' then 'godown_manager'
  when 'manager2.phase31race@example.com' then 'godown_manager'
  else 'store_keeper'
end
where users.email in (
  'manager.phase31race@example.com',
  'manager2.phase31race@example.com',
  'keeper.phase31race@example.com'
);

select public.phase31_claim('admin.phase31race@example.com');

select public.create_branch('phase31_race', 'Phase 31 Race');

select public.create_zone(
  (select id from public.branches where code = 'phase31_race'),
  'rz',
  'Race Zone',
  null
);
select public.create_zone(
  (select id from public.branches where code = 'phase31_race'),
  'rzoff',
  'Race Zone Off',
  null
);
select public.create_zone(
  (select id from public.branches where code = 'phase31_race'),
  'rzempty',
  'Race Zone Empty',
  null
);

select public.create_crate(
  (select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase31_race')),
  'race-verify', 'Race Verify', null
);
select public.create_crate(
  (select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase31_race')),
  'race-edit', 'Race Edit', null
);
select public.create_crate(
  (select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase31_race')),
  'race-cancel', 'Race Cancel', null
);
select public.create_crate(
  (select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase31_race')),
  'race-add', 'Race Add', null
);
select public.create_crate(
  (select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase31_race')),
  'race-crate', 'Race Crate', null
);
select public.create_crate(
  (select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase31_race')),
  'race-dead', 'Race Dead', null
);
select public.create_crate(
  (select id from public.zones where code = 'rzoff' and branch_id = (select id from public.branches where code = 'phase31_race')),
  'race-zone', 'Race Zone Crate', null
);
select public.create_crate(
  (select id from public.zones where code = 'rzempty' and branch_id = (select id from public.branches where code = 'phase31_race')),
  'race-zempty', 'Race Zone Empty Crate', null
);
select public.create_crate(
  (select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase31_race')),
  'race-product', 'Race Product', null
);
select public.create_crate(
  (select id from public.zones where code = 'rz' and branch_id = (select id from public.branches where code = 'phase31_race')),
  'race-supplier', 'Race Supplier', null
);

select public.create_product('p31-race-verify', 'Race Verify', null, null);
select public.create_product('p31-race-edit', 'Race Edit', null, null);
select public.create_product('p31-race-cancel', 'Race Cancel', null, null);
select public.create_product('p31-race-add', 'Race Add', null, null);
select public.create_product('p31-race-crate', 'Race Crate', null, null);
select public.create_product('p31-race-dead', 'Race Dead', null, null);
select public.create_product('p31-race-zone', 'Race Zone', null, null);
select public.create_product('p31-race-zempty', 'Race Zone Empty', null, null);
select public.create_product('p31-race-product', 'Race Product', null, null);
select public.create_product('p31-race-supplier', 'Race Supplier', null, null);
select public.create_supplier('Phase 31 Race Supplier', null, null);
select public.create_supplier('Phase 31 Race Supplier Off', null, null);

select public.assign_user_branch(
  (select id from auth.users where email = 'manager.phase31race@example.com'),
  (select id from public.branches where code = 'phase31_race')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'manager2.phase31race@example.com'),
  (select id from public.branches where code = 'phase31_race')
);
select public.assign_user_branch(
  (select id from auth.users where email = 'keeper.phase31race@example.com'),
  (select id from public.branches where code = 'phase31_race')
);

select public.phase31_claim('keeper.phase31race@example.com');

select public.create_stock_receipt(
  (select id from public.branches where code = 'phase31_race'),
  (select id from public.suppliers where name = 'Phase 31 Race Supplier'),
  'RACE-VERIFY', current_date, null,
  jsonb_build_array(jsonb_build_object(
    'product_id', (select id from public.products where sku = 'p31-race-verify'),
    'destination_crate_id', (select id from public.crates where code = 'race-verify'),
    'document_cases', 6, 'counted_cases', 6, 'damaged_cases', 1
  ))
);
select public.submit_stock_receipt((select id from public.stock_receipts where document_reference = 'RACE-VERIFY'));

select public.create_stock_receipt(
  (select id from public.branches where code = 'phase31_race'),
  (select id from public.suppliers where name = 'Phase 31 Race Supplier'),
  'RACE-EDIT', current_date, null,
  jsonb_build_array(jsonb_build_object(
    'product_id', (select id from public.products where sku = 'p31-race-edit'),
    'destination_crate_id', (select id from public.crates where code = 'race-edit'),
    'document_cases', 4, 'counted_cases', 4, 'damaged_cases', 1
  ))
);
select public.submit_stock_receipt((select id from public.stock_receipts where document_reference = 'RACE-EDIT'));

select public.create_stock_receipt(
  (select id from public.branches where code = 'phase31_race'),
  (select id from public.suppliers where name = 'Phase 31 Race Supplier'),
  'RACE-CANCEL', current_date, null,
  jsonb_build_array(jsonb_build_object(
    'product_id', (select id from public.products where sku = 'p31-race-cancel'),
    'destination_crate_id', (select id from public.crates where code = 'race-cancel'),
    'document_cases', 2, 'counted_cases', 2, 'damaged_cases', 0
  ))
);
select public.submit_stock_receipt((select id from public.stock_receipts where document_reference = 'RACE-CANCEL'));

select public.create_stock_receipt(
  (select id from public.branches where code = 'phase31_race'),
  (select id from public.suppliers where name = 'Phase 31 Race Supplier'),
  'RACE-ADD-1', current_date, null,
  jsonb_build_array(jsonb_build_object(
    'product_id', (select id from public.products where sku = 'p31-race-add'),
    'destination_crate_id', (select id from public.crates where code = 'race-add'),
    'document_cases', 4, 'counted_cases', 4, 'damaged_cases', 0
  ))
);
select public.submit_stock_receipt((select id from public.stock_receipts where document_reference = 'RACE-ADD-1'));

select public.create_stock_receipt(
  (select id from public.branches where code = 'phase31_race'),
  (select id from public.suppliers where name = 'Phase 31 Race Supplier'),
  'RACE-ADD-2', current_date, null,
  jsonb_build_array(jsonb_build_object(
    'product_id', (select id from public.products where sku = 'p31-race-add'),
    'destination_crate_id', (select id from public.crates where code = 'race-add'),
    'document_cases', 5, 'counted_cases', 5, 'damaged_cases', 0
  ))
);
select public.submit_stock_receipt((select id from public.stock_receipts where document_reference = 'RACE-ADD-2'));

select public.create_stock_receipt(
  (select id from public.branches where code = 'phase31_race'),
  (select id from public.suppliers where name = 'Phase 31 Race Supplier'),
  'RACE-CRATE', current_date, null,
  jsonb_build_array(jsonb_build_object(
    'product_id', (select id from public.products where sku = 'p31-race-crate'),
    'destination_crate_id', (select id from public.crates where code = 'race-crate'),
    'document_cases', 2, 'counted_cases', 2, 'damaged_cases', 0
  ))
);
select public.submit_stock_receipt((select id from public.stock_receipts where document_reference = 'RACE-CRATE'));

select public.create_stock_receipt(
  (select id from public.branches where code = 'phase31_race'),
  (select id from public.suppliers where name = 'Phase 31 Race Supplier'),
  'RACE-DEAD', current_date, null,
  jsonb_build_array(jsonb_build_object(
    'product_id', (select id from public.products where sku = 'p31-race-dead'),
    'destination_crate_id', (select id from public.crates where code = 'race-dead'),
    'document_cases', 1, 'counted_cases', 1, 'damaged_cases', 0
  ))
);
select public.submit_stock_receipt((select id from public.stock_receipts where document_reference = 'RACE-DEAD'));

select public.create_stock_receipt(
  (select id from public.branches where code = 'phase31_race'),
  (select id from public.suppliers where name = 'Phase 31 Race Supplier'),
  'RACE-ZONE', current_date, null,
  jsonb_build_array(jsonb_build_object(
    'product_id', (select id from public.products where sku = 'p31-race-zone'),
    'destination_crate_id', (select id from public.crates where code = 'race-zone'),
    'document_cases', 3, 'counted_cases', 3, 'damaged_cases', 0
  ))
);
select public.submit_stock_receipt((select id from public.stock_receipts where document_reference = 'RACE-ZONE'));

select public.create_stock_receipt(
  (select id from public.branches where code = 'phase31_race'),
  (select id from public.suppliers where name = 'Phase 31 Race Supplier'),
  'RACE-ZONE-OFF', current_date, null,
  jsonb_build_array(jsonb_build_object(
    'product_id', (select id from public.products where sku = 'p31-race-zempty'),
    'destination_crate_id', (select id from public.crates where code = 'race-zempty'),
    'document_cases', 1, 'counted_cases', 1, 'damaged_cases', 0
  ))
);
select public.submit_stock_receipt((select id from public.stock_receipts where document_reference = 'RACE-ZONE-OFF'));

select public.create_stock_receipt(
  (select id from public.branches where code = 'phase31_race'),
  (select id from public.suppliers where name = 'Phase 31 Race Supplier'),
  'RACE-PRODUCT', current_date, null,
  jsonb_build_array(jsonb_build_object(
    'product_id', (select id from public.products where sku = 'p31-race-product'),
    'destination_crate_id', (select id from public.crates where code = 'race-product'),
    'document_cases', 4, 'counted_cases', 4, 'damaged_cases', 1
  ))
);
select public.submit_stock_receipt((select id from public.stock_receipts where document_reference = 'RACE-PRODUCT'));

select public.create_stock_receipt(
  (select id from public.branches where code = 'phase31_race'),
  (select id from public.suppliers where name = 'Phase 31 Race Supplier Off'),
  'RACE-SUPPLIER', current_date, null,
  jsonb_build_array(jsonb_build_object(
    'product_id', (select id from public.products where sku = 'p31-race-supplier'),
    'destination_crate_id', (select id from public.crates where code = 'race-supplier'),
    'document_cases', 2, 'counted_cases', 2, 'damaged_cases', 0
  ))
);
select public.submit_stock_receipt((select id from public.stock_receipts where document_reference = 'RACE-SUPPLIER'));

create or replace function public.phase31_hold_verify()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase31_claim('manager.phase31race@example.com');
  perform public.verify_stock_receipt(
    (select id from public.stock_receipts where document_reference = 'RACE-VERIFY'),
    'phase31-verify-hold'
  );
  perform pg_catalog.pg_sleep(3);
end;
$$;

create or replace function public.phase31_hold_edit()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase31_claim('manager.phase31race@example.com');
  perform public.verify_stock_receipt(
    (select id from public.stock_receipts where document_reference = 'RACE-EDIT'),
    'phase31-edit-hold'
  );
  perform pg_catalog.pg_sleep(3);
end;
$$;

create or replace function public.phase31_hold_cancel()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase31_claim('manager.phase31race@example.com');
  perform public.verify_stock_receipt(
    (select id from public.stock_receipts where document_reference = 'RACE-CANCEL'),
    'phase31-cancel-hold'
  );
  perform pg_catalog.pg_sleep(3);
end;
$$;

create or replace function public.phase31_hold_add()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase31_claim('manager.phase31race@example.com');
  perform public.verify_stock_receipt(
    (select id from public.stock_receipts where document_reference = 'RACE-ADD-1'),
    'phase31-add-hold'
  );
  perform pg_catalog.pg_sleep(3);
end;
$$;

create or replace function public.phase31_hold_crate_post()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase31_claim('manager.phase31race@example.com');
  perform public.verify_stock_receipt(
    (select id from public.stock_receipts where document_reference = 'RACE-CRATE'),
    'phase31-crate-hold'
  );
  perform pg_catalog.pg_sleep(3);
end;
$$;

create or replace function public.phase31_hold_crate_off()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase31_claim('manager.phase31race@example.com');
  perform public.zones.id
  from public.zones
  join public.crates on crates.zone_id = zones.id
  where crates.code = 'race-dead'
  for update;
  perform public.crates.id
  from public.crates
  where crates.code = 'race-dead'
  for update;
  perform pg_catalog.pg_sleep(3);
  perform public.set_crate_active(
    (select id from public.crates where code = 'race-dead'),
    false
  );
end;
$$;

create or replace function public.phase31_hold_zone_post()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase31_claim('manager.phase31race@example.com');
  perform public.verify_stock_receipt(
    (select id from public.stock_receipts where document_reference = 'RACE-ZONE'),
    'phase31-zone-hold'
  );
  perform pg_catalog.pg_sleep(3);
end;
$$;

create or replace function public.phase31_hold_zone_off()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase31_claim('manager.phase31race@example.com');
  perform public.zones.id
  from public.zones
  where zones.code = 'rzempty'
  for update;
  perform public.crates.id
  from public.crates
  where crates.zone_id = (select id from public.zones where code = 'rzempty')
  order by crates.id
  for update;
  perform pg_catalog.pg_sleep(3);
  perform public.set_zone_active(
    (select id from public.zones where code = 'rzempty'),
    false
  );
end;
$$;

create or replace function public.phase31_hold_product_off()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase31_claim('admin.phase31race@example.com');
  perform public.products.id
  from public.products
  where products.sku = 'p31-race-product'
  for update;
  perform pg_catalog.pg_sleep(3);
  perform public.set_product_active(
    (select id from public.products where sku = 'p31-race-product'),
    false
  );
end;
$$;

create or replace function public.phase31_hold_supplier_off()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase31_claim('admin.phase31race@example.com');
  perform public.suppliers.id
  from public.suppliers
  where suppliers.name = 'Phase 31 Race Supplier Off'
  for update;
  perform pg_catalog.pg_sleep(3);
  perform public.set_supplier_active(
    (select id from public.suppliers where name = 'Phase 31 Race Supplier Off'),
    false
  );
end;
$$;

create or replace function public.phase31_hold_duplicate()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.phase31_claim('keeper.phase31race@example.com');
  perform public.create_stock_receipt(
    (select id from public.branches where code = 'phase31_race'),
    (select id from public.suppliers where name = 'Phase 31 Race Supplier'),
    'RACE-DUP',
    current_date,
    null,
    jsonb_build_array(jsonb_build_object(
      'product_id', (select id from public.products where sku = 'p31-race-verify'),
      'destination_crate_id', (select id from public.crates where code = 'race-verify'),
      'document_cases', 1, 'counted_cases', 1, 'damaged_cases', 0
    ))
  );
  perform pg_catalog.pg_sleep(3);
end;
$$;
