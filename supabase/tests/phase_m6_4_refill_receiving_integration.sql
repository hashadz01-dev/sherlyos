-- M6.4 REF-07. Optional refill-to-receipt linkage and read-only reconciliation.
-- Rolls back. Stock posts only through existing verify_stock_receipt.
-- Does not flip damage.stock_hold_ready or lot cutover flags.
select pg_advisory_lock(hashtext('sherlyos.m6.refill_tests'));
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
  ('other_acct', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('keeper_b', gen_random_uuid()),
  ('delivery', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id, 'authenticated', 'authenticated',
  fixture.name || '.m64sql@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', fixture.name), now(), now()
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
      values ((select id from fixture where name = 'admin'), 'M64 SQL Admin', true)
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
  when 'accounts' then 'accounts'
  when 'other_acct' then 'accounts'
  when 'godown' then 'godown_manager'
  when 'keeper' then 'store_keeper'
  when 'keeper_b' then 'store_keeper'
  when 'delivery' then 'delivery_person'
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

do $$
begin
  if (select value from public.app_configuration where key = 'damage.stock_hold_ready') <> 'false'::jsonb
    or (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled') <> 'false'::jsonb
    or (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked') <> 'false'::jsonb
  then
    raise exception 'operational flags must remain false';
  end if;

  if has_table_privilege('authenticated', 'public.stock_receipts', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_balances', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_transactions', 'INSERT') then
    raise exception 'authenticated must not insert stock writers';
  end if;
end $$;

set session_replication_role = replica;

insert into public.branches (code, name, is_active)
values
  ('m64_sql_gd', 'M64 SQL Godown', true),
  ('m64_sql_other', 'M64 SQL Other', true);

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code = 'm64_sql_gd'
  and fixture.name in ('accounts', 'godown', 'keeper', 'delivery');

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code = 'm64_sql_other'
  and fixture.name in ('other_acct', 'keeper_b');

insert into public.zones (branch_id, code, name, is_active)
select id, 'm64_sql_z', 'M64 Zone', true from public.branches where code = 'm64_sql_gd';
insert into public.zones (branch_id, code, name, is_active)
select id, 'm64_sql_z_b', 'M64 Zone B', true from public.branches where code = 'm64_sql_other';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm64_sql_c', 'M64 Crate', true from public.zones where code = 'm64_sql_z';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm64_sql_c_b', 'M64 Crate B', true from public.zones where code = 'm64_sql_z_b';

insert into public.suppliers (name, is_active)
values ('M64 SQL Brand', true), ('M64 SQL Other Brand', true);

insert into public.products (sku, name, is_active, supplier_id)
select 'm64_sql_a', 'M64 Product A', true, suppliers.id
from public.suppliers where suppliers.name = 'M64 SQL Brand';
insert into public.products (sku, name, is_active, supplier_id)
select 'm64_sql_b', 'M64 Product B', true, suppliers.id
from public.suppliers where suppliers.name = 'M64 SQL Brand';
insert into public.products (sku, name, is_active, supplier_id)
select 'm64_sql_c', 'M64 Extra SKU', true, suppliers.id
from public.suppliers where suppliers.name = 'M64 SQL Brand';

insert into public.stock_balances (crate_id, product_id, quantity)
select crates.id, products.id, 0
from public.crates, public.products
where crates.code = 'm64_sql_c' and products.sku in ('m64_sql_a', 'm64_sql_b');

set session_replication_role = origin;

create temp table stock_snapshot as
select
  (select count(*) from public.stock_transactions) as transactions,
  (select count(*) from public.stock_ledger) as ledger,
  (select coalesce(sum(quantity), 0) from public.stock_balances) as balance_qty;

create or replace function pg_temp.line(target_sku text, counted integer, damaged integer, crate_code text default 'm64_sql_c')
returns jsonb
language sql as $$
  select jsonb_build_object(
    'product_id', products.id,
    'destination_crate_id', crates.id,
    'document_cases', counted,
    'counted_cases', counted,
    'damaged_cases', damaged
  )
  from public.products, public.crates
  where products.sku = target_sku and crates.code = crate_code;
$$;

create or replace function pg_temp.approve_request(key text, qty_a integer, qty_b integer)
returns jsonb
language plpgsql as $$
declare
  created jsonb;
  submitted jsonb;
  approved jsonb;
  gd uuid;
  brand uuid;
  product_a uuid;
  product_b uuid;
  lines jsonb;
begin
  select id into gd from public.branches where code = 'm64_sql_gd';
  select id into brand from public.suppliers where name = 'M64 SQL Brand';
  select products.id into product_a from public.products where products.sku = 'm64_sql_a';
  select products.id into product_b from public.products where products.sku = 'm64_sql_b';
  lines := jsonb_build_array(
    jsonb_build_object('product_id', product_a, 'requested_cases', qty_a),
    jsonb_build_object('product_id', product_b, 'requested_cases', qty_b)
  );
  perform pg_temp.as_user('accounts');
  created := public.create_stock_refill_request(brand, gd, lines, key || '-c', null);
  submitted := public.submit_stock_refill_request(
    (created ->> 'id')::uuid, (created ->> 'version')::integer, key || '-s'
  );
  perform pg_temp.as_user('admin');
  approved := public.approve_stock_refill_request(
    (submitted ->> 'id')::uuid, (submitted ->> 'version')::integer, key || '-a', null
  );
  return approved;
end;
$$;

create or replace function pg_temp.receive(
  who text,
  refill uuid,
  document text,
  items jsonb
)
returns jsonb
language plpgsql as $$
declare
  gd uuid;
  brand uuid;
  created jsonb;
begin
  select destination_godown_id, supplier_id into gd, brand
  from public.stock_refill_requests where id = refill;
  perform pg_temp.as_user(who);
  created := public.create_stock_receipt(
    gd, brand, document, (clock_timestamp() at time zone 'utc')::date, null, items, refill
  );
  return created;
end;
$$;

do $$
declare
  approved jsonb;
  first jsonb;
  second jsonb;
  held jsonb;
  cancelled jsonb;
  unlinked jsonb;
  reserved jsonb;
  recon jsonb;
  posted integer;
  summary jsonb;
  request_id uuid;
  extra uuid;
  other_brand uuid;
  other_gd uuid;
  crate_b uuid;
  product_c uuid;
  before_tx integer;
  after_tx integer;
begin
  approved := pg_temp.approve_request('m64-main', 100, 60);
  request_id := (approved ->> 'id')::uuid;
  if approved -> 'receiving' -> 'summary' ->> 'completion_label' is distinct from 'not_started' then
    raise exception 'approved request must start not_started';
  end if;
  if (select count(*) from public.stock_transactions) <> (select transactions from stock_snapshot) then
    raise exception 'approval posted stock';
  end if;

  -- Accounts cannot create receipts.
  begin
    perform pg_temp.receive('accounts', request_id, 'm64-acct', jsonb_build_array(pg_temp.line('m64_sql_a', 1, 0)));
    raise exception 'accounts must not create receipts';
  exception
    when sqlstate '42501' then null;
  end;

  -- Unapproved link denied.
  perform pg_temp.as_user('accounts');
  extra := (public.create_stock_refill_request(
    (select id from public.suppliers where name = 'M64 SQL Brand'),
    (select id from public.branches where code = 'm64_sql_gd'),
    jsonb_build_array(jsonb_build_object(
      'product_id', (select id from public.products where sku = 'm64_sql_a'),
      'requested_cases', 2
    )),
    'm64-draft-c', null
  ) ->> 'id')::uuid;
  begin
    perform pg_temp.receive('keeper', extra, 'm64-draft', jsonb_build_array(pg_temp.line('m64_sql_a', 1, 0)));
    raise exception 'draft refill must not link';
  exception
    when sqlstate '42501' then null;
  end;

  -- Cross-godown keeper denied.
  begin
    perform pg_temp.receive('keeper_b', request_id, 'm64-xgd', jsonb_build_array(pg_temp.line('m64_sql_a', 1, 0, 'm64_sql_c_b')));
    raise exception 'cross-godown link must fail';
  exception
    when sqlstate '42501' then null;
  end;

  -- Supplier mismatch.
  select id into other_brand from public.suppliers where name = 'M64 SQL Other Brand';
  select id into other_gd from public.branches where code = 'm64_sql_gd';
  perform pg_temp.as_user('keeper');
  begin
    perform public.create_stock_receipt(
      other_gd, other_brand, 'm64-xsup', (clock_timestamp() at time zone 'utc')::date, null,
      jsonb_build_array(pg_temp.line('m64_sql_a', 1, 0)), request_id
    );
    raise exception 'cross-supplier link must fail';
  exception
    when sqlstate '42501' then null;
  end;

  -- Extra SKU denied.
  select id into product_c from public.products where sku = 'm64_sql_c';
  begin
    perform pg_temp.receive(
      'keeper', request_id, 'm64-extra',
      jsonb_build_array(
        pg_temp.line('m64_sql_a', 1, 0),
        jsonb_build_object(
          'product_id', product_c,
          'destination_crate_id', (select id from public.crates where code = 'm64_sql_c'),
          'document_cases', 1,
          'counted_cases', 1,
          'damaged_cases', 0
        )
      )
    );
    raise exception 'extra SKU must fail';
  exception
    when sqlstate '23514' then null;
  end;

  -- Linked excess on this receipt vs requested.
  begin
    perform pg_temp.receive(
      'keeper', request_id, 'm64-over',
      jsonb_build_array(pg_temp.line('m64_sql_a', 101, 0), pg_temp.line('m64_sql_b', 1, 0))
    );
    raise exception 'over-request create must fail';
  exception
    when sqlstate '23514' then null;
  end;

  -- Cumulative reservation: open drafts consume remaining requested cases.
  reserved := pg_temp.receive(
    'keeper', request_id, 'm64-reserve',
    jsonb_build_array(pg_temp.line('m64_sql_a', 70, 0))
  );
  begin
    perform pg_temp.receive(
      'keeper', request_id, 'm64-reserve-over',
      jsonb_build_array(pg_temp.line('m64_sql_a', 40, 0))
    );
    raise exception 'second draft must not exceed remaining requested cases';
  exception
    when sqlstate '23514' then null;
  end;
  perform pg_temp.as_user('keeper');
  perform public.cancel_stock_receipt((reserved ->> 'id')::uuid, 'release reservation');

  -- First partial with damage. Accepted A=39 (40-1), B=20.
  first := pg_temp.receive(
    'keeper', request_id, 'm64-first',
    jsonb_build_array(pg_temp.line('m64_sql_a', 40, 1), pg_temp.line('m64_sql_b', 20, 0))
  );
  if first ->> 'status' is distinct from 'draft' then
    raise exception 'create must stay draft';
  end if;
  if first ->> 'refill_request_id' is distinct from request_id::text then
    raise exception 'linkage missing on create';
  end if;
  perform pg_temp.as_user('keeper');
  first := public.submit_stock_receipt((first ->> 'id')::uuid);
  recon := public.get_stock_refill_receiving_reconciliation(request_id);
  if (recon -> 'receiving' -> 'summary' ->> 'pending_receipt_cases')::integer <> 60 then
    raise exception 'pending counted cases expected 60, got %',
      recon -> 'receiving' -> 'summary' ->> 'pending_receipt_cases';
  end if;
  if (recon -> 'receiving' -> 'summary' ->> 'accepted_cases')::integer <> 0 then
    raise exception 'unverified receipt must not count as accepted';
  end if;

  perform pg_temp.as_user('godown');
  first := public.verify_stock_receipt((first ->> 'id')::uuid, 'm64-verify-first');
  if first ->> 'status' is distinct from 'posted' then
    raise exception 'first verify failed';
  end if;

  -- Duplicate verify recovers.
  if (public.verify_stock_receipt((first ->> 'id')::uuid, 'm64-verify-first') ->> 'status') is distinct from 'posted' then
    raise exception 'verify replay failed';
  end if;
  select count(*) into posted
  from public.stock_transactions
  where receipt_id = (first ->> 'id')::uuid;
  if posted <> 2 then
    raise exception 'exact-once expected 2 ledger txs for two SKUs, got %', posted;
  end if;

  recon := public.get_stock_refill_receiving_reconciliation(request_id);
  summary := recon -> 'receiving' -> 'summary';
  if (summary ->> 'accepted_cases')::integer <> 59
    or (summary ->> 'outstanding_cases')::integer <> 101
    or (summary ->> 'damaged_cases')::integer <> 1
    or summary ->> 'completion_label' is distinct from 'partially_received'
  then
    raise exception 'first recon mismatch %', summary;
  end if;

  -- Held receipt excluded from accepted.
  held := pg_temp.receive(
    'keeper', request_id, 'm64-held',
    jsonb_build_array(pg_temp.line('m64_sql_a', 5, 0))
  );
  perform pg_temp.as_user('keeper');
  held := public.submit_stock_receipt((held ->> 'id')::uuid);
  perform pg_temp.as_user('godown');
  held := public.hold_stock_receipt((held ->> 'id')::uuid, 'count again');
  recon := public.get_stock_refill_receiving_reconciliation(request_id);
  if (recon -> 'receiving' -> 'summary' ->> 'accepted_cases')::integer <> 59 then
    raise exception 'held receipt must not add accepted';
  end if;
  if (recon -> 'receiving' -> 'summary' ->> 'pending_receipt_cases')::integer <> 5 then
    raise exception 'held counted cases must be pending';
  end if;

  -- Cancelled excluded.
  cancelled := pg_temp.receive(
    'keeper', request_id, 'm64-cancel',
    jsonb_build_array(pg_temp.line('m64_sql_a', 3, 0))
  );
  perform pg_temp.as_user('keeper');
  cancelled := public.cancel_stock_receipt((cancelled ->> 'id')::uuid, 'wrong van');
  recon := public.get_stock_refill_receiving_reconciliation(request_id);
  if (recon -> 'receiving' -> 'summary' ->> 'accepted_cases')::integer <> 59 then
    raise exception 'cancelled receipt must not add accepted';
  end if;

  -- Second verified partial: A +30, B +25.
  second := pg_temp.receive(
    'keeper', request_id, 'm64-second',
    jsonb_build_array(pg_temp.line('m64_sql_a', 30, 0), pg_temp.line('m64_sql_b', 25, 0))
  );
  perform pg_temp.as_user('keeper');
  second := public.submit_stock_receipt((second ->> 'id')::uuid);
  perform pg_temp.as_user('godown');
  second := public.verify_stock_receipt((second ->> 'id')::uuid, 'm64-verify-second');

  recon := public.get_stock_refill_receiving_reconciliation(request_id);
  summary := recon -> 'receiving' -> 'summary';
  -- requested 160, accepted 59+55=114, outstanding 46, damaged 1
  if (summary ->> 'requested_cases')::integer <> 160
    or (summary ->> 'accepted_cases')::integer <> 114
    or (summary ->> 'outstanding_cases')::integer <> 46
    or (summary ->> 'excess_cases')::integer <> 0
    or (summary ->> 'damaged_cases')::integer <> 1
    or summary ->> 'completion_label' is distinct from 'partially_received'
  then
    raise exception 'second recon mismatch %', summary;
  end if;

  if (select (line ->> 'accepted_cases')::integer
      from jsonb_array_elements(recon -> 'receiving' -> 'lines') line
      where line ->> 'product_sku' = 'm64_sql_a') <> 69 then
    raise exception 'product A accepted expected 69';
  end if;
  if (select (line ->> 'outstanding_cases')::integer
      from jsonb_array_elements(recon -> 'receiving' -> 'lines') line
      where line ->> 'product_sku' = 'm64_sql_a') <> 31 then
    raise exception 'product A outstanding expected 31';
  end if;

  -- Request stays approved. No auto-complete.
  if (select status from public.stock_refill_requests where id = request_id) is distinct from 'approved' then
    raise exception 'refill status must remain approved';
  end if;

  -- Unlinked receiving still works and does not attach historically.
  select id into crate_b from public.crates where code = 'm64_sql_c';
  perform pg_temp.as_user('keeper');
  unlinked := public.create_stock_receipt(
    (select id from public.branches where code = 'm64_sql_gd'),
    (select id from public.suppliers where name = 'M64 SQL Brand'),
    'm64-unlinked',
    (clock_timestamp() at time zone 'utc')::date,
    null,
    jsonb_build_array(pg_temp.line('m64_sql_a', 2, 0))
  );
  if unlinked ->> 'refill_request_id' is not null then
    raise exception 'unlinked receipt was attached';
  end if;
  unlinked := public.submit_stock_receipt((unlinked ->> 'id')::uuid);
  perform pg_temp.as_user('godown');
  unlinked := public.verify_stock_receipt((unlinked ->> 'id')::uuid, 'm64-verify-unlinked');
  recon := public.get_stock_refill_receiving_reconciliation(request_id);
  if (recon -> 'receiving' -> 'summary' ->> 'accepted_cases')::integer <> 114 then
    raise exception 'unlinked posted qty must not enter refill accepted';
  end if;

  -- Posted receipts cannot be relinked (update is draft-only).
  begin
    perform pg_temp.as_user('keeper');
    perform public.update_stock_receipt(
      (first ->> 'id')::uuid,
      (select id from public.branches where code = 'm64_sql_gd'),
      (select id from public.suppliers where name = 'M64 SQL Brand'),
      'm64-first',
      (clock_timestamp() at time zone 'utc')::date,
      null,
      jsonb_build_array(pg_temp.line('m64_sql_a', 40, 1), pg_temp.line('m64_sql_b', 20, 0)),
      null
    );
    raise exception 'posted receipt must not relink';
  exception
    when sqlstate '42501' then null;
  end;

  -- Inactive godown: historical recon readable; new link blocked.
  update public.branches set is_active = false where code = 'm64_sql_gd';
  perform pg_temp.as_user('accounts');
  recon := public.get_stock_refill_request(request_id);
  if (recon -> 'receiving' -> 'summary' ->> 'accepted_cases')::integer <> 114 then
    raise exception 'historical refill recon hidden after deactivate';
  end if;
  begin
    perform pg_temp.receive('keeper', request_id, 'm64-inactive', jsonb_build_array(pg_temp.line('m64_sql_a', 1, 0)));
    raise exception 'inactive godown must block new linked receipts';
  exception
    when sqlstate '42501' then null;
  end;
  update public.branches set is_active = true where code = 'm64_sql_gd';

  -- Cross-godown accounts cannot read recon.
  perform pg_temp.as_user('other_acct');
  begin
    perform public.get_stock_refill_receiving_reconciliation(request_id);
    raise exception 'cross-godown recon must fail';
  exception
    when sqlstate '42501' then null;
  end;

  -- GM cannot approve refill.
  perform pg_temp.as_user('godown');
  begin
    perform public.approve_stock_refill_request(extra, 1, 'm64-gm-apr', null);
    raise exception 'gm must not approve refill';
  exception
    when sqlstate '42501' then null;
  end;

  select transactions into before_tx from stock_snapshot;
  select count(*) into after_tx from public.stock_transactions;
  if after_tx < before_tx + 5 then
    -- first 2 SKUs + second 2 SKUs + unlinked 1 = 5 RECEIPT txs
    raise exception 'expected at least 5 receipt transactions, got % vs %', after_tx, before_tx;
  end if;
end $$;

do $$
begin
  if (select value from public.app_configuration where key = 'damage.stock_hold_ready') <> 'false'::jsonb
    or (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled') <> 'false'::jsonb
    or (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked') <> 'false'::jsonb
  then
    raise exception 'flags flipped during M6.4 SQL';
  end if;
end $$;

rollback;
select pg_advisory_unlock(hashtext('sherlyos.m6.refill_tests'));
