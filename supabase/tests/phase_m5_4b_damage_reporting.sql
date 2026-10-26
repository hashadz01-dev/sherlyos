-- M5.4B local source-picker and draft-evidence payload tests.
-- Rolls back. Does not flip damage.stock_hold_ready or lot cutover flags.
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
  ('driver', gen_random_uuid()),
  ('sales', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.m54bsql@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M54B SQL Admin', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select (select id from fixture where name = 'admin'), roles.id,
        (select id from fixture where name = 'admin')
      from public.roles where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.profiles (id, full_name, is_active)
select fixture.id, fixture.name, true from fixture where name <> 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles on roles.code = case fixture.name
  when 'godown' then 'godown_manager'
  when 'keeper' then 'store_keeper'
  when 'driver' then 'delivery_person'
  when 'sales' then 'salesperson'
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

set session_replication_role = replica;

insert into public.branches (code, name, is_active)
values
  ('m54b_sql_gd', 'M54B SQL Godown', true),
  ('m54b_sql_gd2', 'M54B SQL Other', true);

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code = 'm54b_sql_gd'
  and fixture.name in ('admin', 'godown', 'keeper', 'driver');

insert into public.zones (branch_id, code, name, is_active)
select id, 'm54b_sql_z', 'M54B SQL Zone', true from public.branches where code = 'm54b_sql_gd';

insert into public.crates (zone_id, code, name, is_active)
select id, 'm54b_sql_c', 'M54B SQL Crate', true from public.zones where code = 'm54b_sql_z';

insert into public.products (sku, name, is_active)
values ('m54b_sql_sku', 'M54B SQL Product', true);

insert into public.products (sku, name, is_active)
select
  'zzz_m54b_p_' || lpad(gs::text, 3, '0'),
  'M54B extra ' || gs::text,
  true
from generate_series(1, 210) as gs;

insert into public.suppliers (name, is_active)
values ('M54B SQL Supplier', true);

insert into public.shops (name, is_active)
values ('M54B SQL Shop', true);

insert into public.stock_balances (crate_id, product_id, quantity)
select crates.id, products.id, 6
from public.crates, public.products
where crates.code = 'm54b_sql_c'
  and products.sku = 'm54b_sql_sku';

insert into public.stock_receipts (
  receipt_number, godown_id, supplier_id, document_reference,
  normalized_document_reference, received_date, status, created_by,
  verified_by, verified_at, posted_at, posting_idempotency_key, posting_fingerprint
)
select
  'm54b-sql-rcv',
  branches.id,
  suppliers.id,
  'M54B-DOC',
  'm54b-doc',
  current_date,
  'posted',
  (select id from fixture where name = 'keeper'),
  (select id from fixture where name = 'godown'),
  now(),
  now(),
  'm54b-sql-rcv-post',
  'm54b-sql-rcv-fp'
from public.branches, public.suppliers
where branches.code = 'm54b_sql_gd'
  and suppliers.name = 'M54B SQL Supplier';

insert into public.stock_receipts (
  receipt_number, godown_id, supplier_id, document_reference,
  normalized_document_reference, received_date, status, created_by,
  verified_by, verified_at, posted_at, posting_idempotency_key, posting_fingerprint
)
select
  'm54b-sql-rcv2',
  branches.id,
  suppliers.id,
  'M54B-DOC-2',
  'm54b-doc-2',
  current_date,
  'posted',
  (select id from fixture where name = 'keeper'),
  (select id from fixture where name = 'godown'),
  now(),
  now(),
  'm54b-sql-rcv2-post',
  'm54b-sql-rcv2-fp'
from public.branches, public.suppliers
where branches.code = 'm54b_sql_gd2'
  and suppliers.name = 'M54B SQL Supplier';

insert into public.stock_receipt_lines (
  receipt_id, product_id, destination_crate_id, document_cases, counted_cases, damaged_cases
)
select stock_receipts.id, products.id, crates.id, 10, 8, 3
from public.stock_receipts, public.products, public.crates
where stock_receipts.receipt_number in ('m54b-sql-rcv', 'm54b-sql-rcv2')
  and products.sku = 'm54b_sql_sku'
  and crates.code = 'm54b_sql_c';

insert into public.orders (
  order_number, shop_id, branch_id, status, source, version, created_by,
  idempotency_key, verified_by, verified_at, submitted_by, submitted_at
)
select
  'm54b-sql-ord', shops.id, branches.id, 'verified', 'accounts', 1,
  (select id from fixture where name = 'admin'),
  'm54b-sql-ord-key', (select id from fixture where name = 'admin'), now(),
  (select id from fixture where name = 'admin'), now()
from public.shops, public.branches
where shops.name = 'M54B SQL Shop'
  and branches.code = 'm54b_sql_gd';

insert into public.stock_picking_requests (
  request_number, order_id, branch_id, status, version, created_by, idempotency_key
)
select
  'm54b-sql-pk', orders.id, branches.id, 'ready_for_dispatch', 1,
  (select id from fixture where name = 'godown'), 'm54b-sql-pk-key'
from public.orders, public.branches
where orders.order_number = 'm54b-sql-ord'
  and branches.code = 'm54b_sql_gd';

insert into public.stock_dispatch_requests (
  request_number, order_id, picking_request_id, branch_id, status, version,
  assigned_to, assigned_by, assigned_at, created_by, idempotency_key,
  request_fingerprint, stock_consumed, posted_transaction_id, dispatched_at, dispatched_by
)
select
  'm54b-sql-dsp', orders.id, stock_picking_requests.id, branches.id, 'in_transit', 1,
  (select id from fixture where name = 'driver'),
  (select id from fixture where name = 'godown'), now(),
  (select id from fixture where name = 'godown'),
  'm54b-sql-dsp-key', 'm54b-sql-dsp-fp', true, gen_random_uuid(), now(),
  (select id from fixture where name = 'godown')
from public.orders, public.stock_picking_requests, public.branches
where orders.order_number = 'm54b-sql-ord'
  and stock_picking_requests.request_number = 'm54b-sql-pk'
  and branches.code = 'm54b_sql_gd';

set session_replication_role = origin;

select pg_temp.as_user('godown');
do $$
declare
  listed jsonb;
  branch uuid;
begin
  select id into branch from public.branches where code = 'm54b_sql_gd';
  listed := public.list_damage_report_sources('refill_supply', branch, null, 1, 20);
  if jsonb_array_length(listed -> 'items') is distinct from 1 then
    raise exception 'GM inbound sources must stay godown-scoped: %', listed;
  end if;
  if listed -> 'items' -> 0 ->> 'label' is distinct from 'm54b-sql-rcv' then
    raise exception 'unexpected inbound source %', listed;
  end if;

  listed := public.list_damage_report_sources('storage', branch, null, 1, 20);
  if listed -> 'items' -> 0 ->> 'kind' is distinct from 'godown' then
    raise exception 'storage source must be the authorized godown';
  end if;
  if jsonb_array_length(listed -> 'catalogs' -> 'products') is distinct from 1 then
    raise exception 'storage products must come from on-hand balances: %', listed -> 'catalogs';
  end if;
end $$;

select pg_temp.as_user('keeper');
do $$
declare
  listed jsonb;
  branch uuid;
begin
  select id into branch from public.branches where code = 'm54b_sql_gd';
  listed := public.list_damage_report_sources('unloading', branch, null, 1, 20);
  if jsonb_array_length(listed -> 'items') < 1 then
    raise exception 'store keeper must see inbound sources';
  end if;
  begin
    perform public.list_damage_report_sources('storage', branch, null, 1, 20);
    raise exception 'store keeper must not list storage sources';
  exception
    when insufficient_privilege then null;
  end;
end $$;

select pg_temp.as_user('driver');
do $$
declare
  listed jsonb;
  branch uuid;
begin
  select id into branch from public.branches where code = 'm54b_sql_gd';
  begin
    perform public.list_damage_report_sources('storage', branch, null, 1, 20);
    raise exception 'driver must not list storage sources';
  exception
    when insufficient_privilege then null;
  end;
  listed := public.list_damage_report_sources('transit', branch, null, 1, 20);
  if jsonb_array_length(listed -> 'items') is distinct from 1 then
    raise exception 'driver must see assigned consumed dispatch only: %', listed;
  end if;
end $$;

select pg_temp.as_user('sales');
do $$
declare
  branch uuid;
begin
  select id into branch from public.branches where code = 'm54b_sql_gd';
  begin
    perform public.list_damage_report_sources('refill_supply', branch, null, 1, 20);
    raise exception 'salesperson must not list damage sources';
  exception
    when insufficient_privilege then null;
  end;
end $$;

select pg_temp.as_user('keeper');
do $$
declare
  created jsonb;
  updated jsonb;
  branch uuid;
  receipt uuid;
  receipt_line uuid;
  product uuid;
  line_payload jsonb;
begin
  select id into branch from public.branches where code = 'm54b_sql_gd';
  select id into receipt from public.stock_receipts where receipt_number = 'm54b-sql-rcv';
  select stock_receipt_lines.id, stock_receipt_lines.product_id
  into receipt_line, product
  from public.stock_receipt_lines
  where stock_receipt_lines.receipt_id = receipt
  limit 1;

  created := public.create_damage_report(
    'unloading',
    branch,
    jsonb_build_array(jsonb_build_object(
      'product_id', product,
      'quantity_cases', 1,
      'damage_reason', 'torn wrap',
      'receipt_line_id', receipt_line
    )),
    'm54b-sql-update-key',
    'original notes',
    receipt
  );
  if created ->> 'status' is distinct from 'draft' then
    raise exception 'keeper inbound draft was not created: %', created;
  end if;

  line_payload := jsonb_build_array(jsonb_build_object(
    'product_id', product,
    'quantity_cases', 1,
    'damage_reason', 'torn wrap',
    'receipt_line_id', receipt_line
  ));
  updated := public.update_damage_report(
    (created ->> 'id')::uuid,
    (created ->> 'version')::integer,
    line_payload,
    'edited notes',
    receipt
  );
  if updated ->> 'notes' is distinct from 'edited notes' then
    raise exception 'draft update did not persist notes: %', updated;
  end if;
  if (updated ->> 'version')::integer
    is distinct from (created ->> 'version')::integer + 1
  then
    raise exception 'draft update did not bump version: %', updated;
  end if;
end $$;

select pg_temp.as_user('godown');
do $$
declare
  listed jsonb;
  branch uuid;
  crate uuid;
  product uuid;
  created jsonb;
  jpeg bytea := decode('ffd8ffd9', 'hex');
  png bytea := decode(
    '89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a49444154789c6360000002000100ffff03000006000557bf0d0000000049454e44ae426082',
    'hex'
  );
  photo jsonb;
begin
  select id into branch from public.branches where code = 'm54b_sql_gd';
  listed := public.list_damage_report_sources('shop_return', branch, null, 1, 50, null, 1);
  if (listed -> 'catalogs' ->> 'products_total')::integer < 211 then
    raise exception 'shop catalog must count products beyond 200: %', listed -> 'catalogs';
  end if;
  if jsonb_array_length(listed -> 'catalogs' -> 'products') is distinct from 50 then
    raise exception 'shop catalog page must stay bounded: %', listed -> 'catalogs';
  end if;
  listed := public.list_damage_report_sources(
    'shop_return', branch, null, 1, 50, 'zzz_m54b_p_205', 1
  );
  if listed -> 'catalogs' -> 'products' -> 0 ->> 'sku' is distinct from 'zzz_m54b_p_205' then
    raise exception 'shop catalog search must reach product 205: %', listed -> 'catalogs';
  end if;

  select crates.id into crate from public.crates where crates.code = 'm54b_sql_c';
  select products.id into product from public.products where products.sku = 'm54b_sql_sku';
  created := public.create_damage_report(
    'storage',
    branch,
    jsonb_build_array(jsonb_build_object(
      'product_id', product,
      'quantity_cases', 1,
      'damage_reason', 'crushed',
      'crate_id', crate
    )),
    'm54b-sql-photo-key',
    'photo tests'
  );

  photo := public.create_damage_photo_upload((created ->> 'id')::uuid, 'missing object');
  begin
    perform public.finalize_damage_photo_upload((photo ->> 'id')::uuid, encode(jpeg, 'base64'));
    raise exception 'missing storage object must not finalize';
  exception
    when sqlstate '23514' then null;
  end;

  photo := public.create_damage_photo_upload((created ->> 'id')::uuid, 'spoofed');
  insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
  values (
    'stock-damage-evidence', photo ->> 'path', auth.uid(), auth.uid()::text,
    jsonb_build_object('size', 999, 'mimetype', 'image/png', 'eTag', 'deadbeef')
  );
  begin
    perform public.finalize_damage_photo_upload((photo ->> 'id')::uuid, encode(jpeg, 'base64'));
    raise exception 'spoofed catalog must not finalize';
  exception
    when sqlstate '23514' then null;
  end;

  photo := public.create_damage_photo_upload((created ->> 'id')::uuid, 'mismatch');
  insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
  values (
    'stock-damage-evidence', photo ->> 'path', auth.uid(), auth.uid()::text,
    jsonb_build_object(
      'size', octet_length(jpeg),
      'mimetype', 'image/jpeg',
      'eTag', encode(extensions.digest(jpeg, 'md5'), 'hex')
    )
  );
  begin
    perform public.finalize_damage_photo_upload((photo ->> 'id')::uuid, encode(png, 'base64'));
    raise exception 'mismatched payload must not finalize';
  exception
    when sqlstate '23514' then null;
  end;

  -- Matching catalog eTag without actual Storage bytes must fail closed.
  -- HTTP integration covers the real-upload success and replay path.
  photo := public.create_damage_photo_upload((created ->> 'id')::uuid, 'catalog only');
  insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
  values (
    'stock-damage-evidence', photo ->> 'path', auth.uid(), auth.uid()::text,
    jsonb_build_object(
      'size', octet_length(jpeg),
      'mimetype', 'image/jpeg',
      'eTag', encode(extensions.digest(jpeg, 'md5'), 'hex')
    )
  );
  begin
    perform public.finalize_damage_photo_upload((photo ->> 'id')::uuid, encode(jpeg, 'base64'));
    raise exception 'catalog metadata must not prove stored bytes';
  exception
    when sqlstate '23514' then null;
  end;

  photo := public.create_damage_photo_upload((created ->> 'id')::uuid, 'wrong user');
  insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
  values (
    'stock-damage-evidence', photo ->> 'path', auth.uid(), auth.uid()::text,
    jsonb_build_object(
      'size', octet_length(jpeg),
      'mimetype', 'image/jpeg',
      'eTag', encode(extensions.digest(jpeg, 'md5'), 'hex')
    )
  );
  perform set_config(
    'request.jwt.claim.sub',
    (select id::text from fixture where name = 'keeper'),
    true
  );
  begin
    perform public.finalize_damage_photo_upload((photo ->> 'id')::uuid, encode(jpeg, 'base64'));
    raise exception 'wrong uploader must not finalize';
  exception
    when insufficient_privilege then null;
  end;
end $$;

select pg_temp.as_user('admin');
do $$
declare
  branch uuid;
begin
  select id into branch from public.branches where code = 'm54b_sql_gd';
  begin
    perform public.list_damage_report_sources('storage', branch, null, 1, 20);
    raise exception 'admin monitor must not list operational damage sources';
  exception
    when insufficient_privilege then null;
  end;
end $$;

-- FORCE RLS: SECURITY DEFINER still requires explicit create-auth.
set local row_security = on;
select pg_temp.as_user('sales');
do $$
declare
  branch uuid;
begin
  select id into branch from public.branches where code = 'm54b_sql_gd';
  begin
    perform public.list_damage_report_sources('shop_return', branch, null, 1, 20);
    raise exception 'FORCE RLS must not leak shop-return sources';
  exception
    when insufficient_privilege then null;
  end;
end $$;

reset role;

do $$
declare
  hold_ready text;
  dual_write text;
  aggregate_only text;
begin
  select value #>> '{}' into hold_ready
  from public.app_configuration where key = 'damage.stock_hold_ready';
  select value #>> '{}' into dual_write
  from public.app_configuration where key = 'stock.lots.dual_write_enabled';
  select value #>> '{}' into aggregate_only
  from public.app_configuration where key = 'stock.lots.aggregate_only_blocked';
  if hold_ready is distinct from 'false'
    or dual_write is distinct from 'false'
    or aggregate_only is distinct from 'false'
  then
    raise exception 'cutover flags changed: % % %', hold_ready, dual_write, aggregate_only;
  end if;
end $$;

rollback;
