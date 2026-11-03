-- DMG-01 inbound remaining: 10 counted / 8 accepted / 2 damaged.
-- Rolls back. Does not flip cutover flags or rewrite posted UAT receipts.
-- Run: Get-Content supabase/tests/phase_m5_inbound_receipt_damage.sql | docker exec -i supabase_db_sherlyos psql -U postgres -d postgres -v ON_ERROR_STOP=1

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
  fixture.name || '.m5inbound@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M5 inbound admin', true)
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
  perform set_config('role', 'authenticated', true);
end;
$$;

set session_replication_role = replica;

insert into public.branches (code, name, is_active)
values ('m5in_gd', 'M5 inbound godown', true);

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code = 'm5in_gd'
  and fixture.name in ('admin', 'godown', 'keeper');

insert into public.zones (branch_id, code, name, is_active)
select id, 'm5in_z', 'M5 inbound zone', true from public.branches where code = 'm5in_gd';

insert into public.crates (zone_id, code, name, is_active)
select id, 'm5in_c', 'M5 inbound crate', true from public.zones where code = 'm5in_z';

insert into public.products (sku, name, is_active)
values ('m5in_sku', 'M5 inbound product', true);

insert into public.suppliers (name, is_active)
values ('M5 inbound supplier', true);

insert into public.stock_balances (crate_id, product_id, quantity)
select crates.id, products.id, 8
from public.crates, public.products
where crates.code = 'm5in_c'
  and products.sku = 'm5in_sku';

insert into public.stock_receipts (
  receipt_number, godown_id, supplier_id, document_reference,
  normalized_document_reference, received_date, status, created_by,
  verified_by, verified_at, posted_at, posting_idempotency_key, posting_fingerprint
)
select
  'm5in-sql-rcv',
  branches.id,
  suppliers.id,
  'M5IN-DOC',
  'm5in-doc',
  current_date,
  'posted',
  (select id from fixture where name = 'keeper'),
  (select id from fixture where name = 'godown'),
  now(),
  now(),
  'm5in-sql-rcv-post',
  'm5in-sql-rcv-fp'
from public.branches, public.suppliers
where branches.code = 'm5in_gd'
  and suppliers.name = 'M5 inbound supplier';

insert into public.stock_receipt_lines (
  receipt_id, product_id, destination_crate_id, document_cases, counted_cases, damaged_cases
)
select stock_receipts.id, products.id, crates.id, 10, 10, 2
from public.stock_receipts, public.products, public.crates
where stock_receipts.receipt_number = 'm5in-sql-rcv'
  and products.sku = 'm5in_sku'
  and crates.code = 'm5in_c';

set session_replication_role = origin;

do $$
declare
  accepted integer;
begin
  select stock_receipt_lines.accepted_cases into accepted
  from public.stock_receipt_lines
  join public.stock_receipts on stock_receipts.id = stock_receipt_lines.receipt_id
  where stock_receipts.receipt_number = 'm5in-sql-rcv';
  if accepted is distinct from 8 then
    raise exception 'accepted cases must be 8, got %', accepted;
  end if;
end $$;

select pg_temp.as_user('keeper');
do $$
declare
  created jsonb;
  updated jsonb;
  listed jsonb;
  remaining integer;
  branch uuid;
  receipt uuid;
  receipt_line uuid;
  product uuid;
  line_payload jsonb;
begin
  select id into branch from public.branches where code = 'm5in_gd';
  select id into receipt from public.stock_receipts where receipt_number = 'm5in-sql-rcv';
  select stock_receipt_lines.id, stock_receipt_lines.product_id
  into receipt_line, product
  from public.stock_receipt_lines
  where stock_receipt_lines.receipt_id = receipt;

  listed := public.list_damage_report_sources('refill_supply', branch, null, 1, 20);
  remaining := ((listed -> 'items' -> 0 -> 'lines' -> 0 ->> 'remaining_cases')::integer);
  if remaining is distinct from 2 then
    raise exception 'unclaimed remaining must be 2, got %', listed;
  end if;

  begin
    perform public.create_damage_report(
      'refill_supply', branch,
      jsonb_build_array(jsonb_build_object(
        'product_id', product,
        'quantity_cases', 10,
        'damage_reason', 'crushed carton',
        'receipt_line_id', receipt_line
      )),
      'm5in-qty-10', null, receipt
    );
    raise exception 'quantity 10 must fail against 2 damaged cases';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%exceeds the receipt line%' then
        raise;
      end if;
  end;

  begin
    perform public.create_damage_report(
      'refill_supply', branch,
      jsonb_build_array(jsonb_build_object(
        'product_id', product,
        'quantity_cases', 3,
        'damage_reason', 'crushed carton',
        'receipt_line_id', receipt_line
      )),
      'm5in-qty-3', null, receipt
    );
    raise exception 'quantity 3 must fail against 2 damaged cases';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%exceeds the receipt line%' then
        raise;
      end if;
  end;

  created := public.create_damage_report(
    'refill_supply',
    branch,
    jsonb_build_array(jsonb_build_object(
      'product_id', product,
      'quantity_cases', 2,
      'damage_reason', 'crushed carton',
      'receipt_line_id', receipt_line
    )),
    'm5in-qty-2',
    'first inbound claim',
    receipt
  );
  if created ->> 'status' is distinct from 'draft' then
    raise exception 'first DMG-01 draft was not created: %', created;
  end if;
  if created ->> 'id' is null then
    raise exception 'saving a draft must return a report id: %', created;
  end if;

  listed := public.list_damage_report_sources('refill_supply', branch, null, 1, 20);
  remaining := ((listed -> 'items' -> 0 -> 'lines' -> 0 ->> 'remaining_cases')::integer);
  if remaining is distinct from 0 then
    raise exception 'list remaining must include this draft and be 0, got %', listed;
  end if;

  line_payload := jsonb_build_array(jsonb_build_object(
    'product_id', product,
    'quantity_cases', 2,
    'damage_reason', 'crushed carton',
    'receipt_line_id', receipt_line
  ));
  updated := public.update_damage_report(
    (created ->> 'id')::uuid,
    (created ->> 'version')::integer,
    line_payload,
    'still two cases',
    receipt
  );
  if (updated -> 'lines' -> 0 ->> 'quantity_cases')::integer is distinct from 2 then
    raise exception 'own draft update must keep 2 cases: %', updated;
  end if;

  begin
    perform public.create_damage_report(
      'refill_supply', branch,
      jsonb_build_array(jsonb_build_object(
        'product_id', product,
        'quantity_cases', 2,
        'damage_reason', 'second claim',
        'receipt_line_id', receipt_line
      )),
      'm5in-qty-2-b', null, receipt
    );
    raise exception 'second report must not claim already reserved damaged cases';
  exception
    when sqlstate '23514' then
      if sqlerrm not like '%exceeds the receipt line%' then
        raise;
      end if;
  end;
end $$;

select pg_temp.as_user('godown');
do $$
declare
  listed jsonb;
begin
  listed := public.list_damage_reports(1, 50, (select id from public.branches where code = 'm5in_gd'), 'draft', 'refill_supply', null, null, null);
  if jsonb_array_length(listed -> 'items') < 1 then
    raise exception 'godown manager must see the inbound draft: %', listed;
  end if;
end $$;

reset role;

do $$
declare
  on_hand integer;
  txn_count integer;
  receipt uuid;
  receipt_line uuid;
  draft uuid;
begin
  select id into receipt from public.stock_receipts where receipt_number = 'm5in-sql-rcv';
  select stock_receipt_lines.id into receipt_line
  from public.stock_receipt_lines
  where stock_receipt_lines.receipt_id = receipt;
  select id into draft
  from public.damage_reports
  where idempotency_key = 'm5in-qty-2';

  if app_private.damage_open_receipt_qty(receipt_line, draft) is distinct from 0 then
    raise exception 'editing this draft must not double-count its own 2 cases';
  end if;
  if app_private.damage_open_receipt_qty(receipt_line, null) is distinct from 2 then
    raise exception 'open claims including the draft must be 2';
  end if;

  select quantity into on_hand
  from public.stock_balances
  join public.crates on crates.id = stock_balances.crate_id
  join public.products on products.id = stock_balances.product_id
  where crates.code = 'm5in_c'
    and products.sku = 'm5in_sku';
  if on_hand is distinct from 8 then
    raise exception 'accepted inventory must stay 8, got %', on_hand;
  end if;

  select count(*) into txn_count
  from public.stock_transactions
  where stock_transactions.receipt_id = receipt;
  if txn_count is distinct from 0 then
    raise exception 'inbound damage draft must not write stock transactions: %', txn_count;
  end if;
end $$;

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
