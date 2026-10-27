-- M6.6 module-closure proofs. Rolls back. Disposable m66%.
-- Walks REF-01–07 scenarios A–J. verify_stock_receipt is the only stock writer.
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
  ('sales', gen_random_uuid()),
  ('delivery', gen_random_uuid()),
  ('monitor', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id, 'authenticated', 'authenticated',
  fixture.name || '.m66sql@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M66 SQL Admin', true)
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

insert into public.roles (code, name, description)
values ('m66_monitor', 'M66 monitor-only', 'Temporary M6.6 monitor-only proof')
on conflict (code) do nothing;
insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'operations.monitor'
where roles.code = 'm66_monitor'
on conflict do nothing;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles on roles.code = case fixture.name
  when 'accounts' then 'accounts'
  when 'other_acct' then 'accounts'
  when 'godown' then 'godown_manager'
  when 'keeper' then 'store_keeper'
  when 'sales' then 'salesperson'
  when 'delivery' then 'delivery_person'
  when 'monitor' then 'm66_monitor'
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
  if has_table_privilege('authenticated', 'public.stock_refill_requests', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_balances', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_transactions', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_ledger', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_reservations', 'INSERT')
     or has_table_privilege('authenticated', 'public.damage_stock_holds', 'INSERT') then
    raise exception 'authenticated must not insert stock or refill writers';
  end if;
  if not (
    select relrowsecurity and relforcerowsecurity from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'stock_refill_requests'
  ) then
    raise exception 'stock_refill_requests must use FORCE RLS';
  end if;
  if pg_get_functiondef('public.verify_stock_receipt(uuid,text)'::regprocedure) like '%stock_refill%' then
    raise exception 'verify_stock_receipt must not mention refill';
  end if;
  if pg_get_functiondef('app_private.assert_refill_receipt_header(uuid,uuid,uuid)'::regprocedure)
     not ilike '%for update%' then
    raise exception 'linked create must lock refill FOR UPDATE';
  end if;
end $$;

set session_replication_role = replica;

insert into public.branches (code, name, is_active)
values ('m66_sql_gd', 'M66 SQL Godown', true), ('m66_sql_other', 'M66 Other', true);
insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code = 'm66_sql_gd'
  and fixture.name in ('accounts', 'godown', 'keeper', 'delivery', 'admin', 'monitor');
insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code = 'm66_sql_other' and fixture.name = 'other_acct';
insert into public.zones (branch_id, code, name, is_active)
select id, 'm66_sql_z', 'M66 Zone', true from public.branches where code = 'm66_sql_gd';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm66_sql_c', 'M66 Crate', true from public.zones where code = 'm66_sql_z';
insert into public.suppliers (name, is_active) values ('M66 SQL Brand', true);
insert into public.products (sku, name, is_active, supplier_id)
select 'm66_sql_a', 'M66 A', true, id from public.suppliers where name = 'M66 SQL Brand';
insert into public.products (sku, name, is_active, supplier_id)
select 'm66_sql_b', 'M66 B', true, id from public.suppliers where name = 'M66 SQL Brand';
insert into public.stock_balances (crate_id, product_id, quantity)
select crates.id, products.id, 0
from public.crates, public.products
where crates.code = 'm66_sql_c' and products.sku in ('m66_sql_a', 'm66_sql_b');

set session_replication_role = origin;

create temp table stock_snapshot as
select
  (select count(*) from public.stock_transactions) as transactions,
  (select count(*) from public.stock_ledger) as ledger,
  (select coalesce(sum(quantity), 0) from public.stock_balances) as balance_qty,
  (select count(*) from public.stock_lots) as lots,
  (select count(*) from public.stock_reservations) as reservations,
  (select count(*) from public.damage_stock_holds) as holds;

create or replace function pg_temp.line(target_sku text, counted integer, damaged integer)
returns jsonb language sql as $$
  select jsonb_build_object(
    'product_id', products.id,
    'destination_crate_id', crates.id,
    'document_cases', counted,
    'counted_cases', counted,
    'damaged_cases', damaged
  )
  from public.products, public.crates
  where products.sku = target_sku and crates.code = 'm66_sql_c';
$$;

create or replace function pg_temp.assert_no_stock()
returns void language plpgsql as $$
begin
  if (select count(*) from public.stock_transactions) <> (select transactions from stock_snapshot)
     or (select count(*) from public.stock_ledger) <> (select ledger from stock_snapshot)
     or (select coalesce(sum(quantity), 0) from public.stock_balances) <> (select balance_qty from stock_snapshot)
     or (select count(*) from public.stock_lots) <> (select lots from stock_snapshot)
     or (select count(*) from public.stock_reservations) <> (select reservations from stock_snapshot)
     or (select count(*) from public.damage_stock_holds) <> (select holds from stock_snapshot)
  then
    raise exception 'refill workflow posted stock before verify';
  end if;
end;
$$;

create or replace function pg_temp.approve_request(key text, qty_a integer, qty_b integer)
returns jsonb language plpgsql as $$
declare
  created jsonb;
  submitted jsonb;
begin
  perform pg_temp.as_user('accounts');
  created := public.create_stock_refill_request(
    (select id from public.suppliers where name = 'M66 SQL Brand'),
    (select id from public.branches where code = 'm66_sql_gd'),
    jsonb_build_array(
      jsonb_build_object('product_id', (select id from public.products where sku = 'm66_sql_a'), 'requested_cases', qty_a),
      jsonb_build_object('product_id', (select id from public.products where sku = 'm66_sql_b'), 'requested_cases', qty_b)
    ),
    key || '-c',
    null
  );
  submitted := public.submit_stock_refill_request(
    (created ->> 'id')::uuid, (created ->> 'version')::integer, key || '-s'
  );
  perform pg_temp.as_user('admin');
  return public.approve_stock_refill_request(
    (submitted ->> 'id')::uuid, (submitted ->> 'version')::integer, key || '-a', null
  );
end;
$$;

do $$
declare
  request jsonb;
  held jsonb;
  rejected jsonb;
  sent jsonb;
  ack jsonb;
  dispatch jsonb;
  declined jsonb;
  first jsonb;
  second jsonb;
  draft jsonb;
  unlinked jsonb;
  recon jsonb;
  listed jsonb;
  report jsonb;
  exported jsonb;
  request_id uuid;
  first_tx integer;
  replay jsonb;
  events integer;
begin
  -- Scenario C: hold → revise → resubmit → approve.
  perform pg_temp.as_user('accounts');
  held := public.create_stock_refill_request(
    (select id from public.suppliers where name = 'M66 SQL Brand'),
    (select id from public.branches where code = 'm66_sql_gd'),
    jsonb_build_array(jsonb_build_object(
      'product_id', (select id from public.products where sku = 'm66_sql_a'),
      'requested_cases', 4
    )),
    'm66-hold-c', null
  );
  held := public.submit_stock_refill_request((held ->> 'id')::uuid, (held ->> 'version')::integer, 'm66-hold-s');
  perform pg_temp.as_user('admin');
  held := public.hold_stock_refill_request((held ->> 'id')::uuid, (held ->> 'version')::integer, 'fix qty', 'm66-hold-h');
  perform pg_temp.as_user('accounts');
  held := public.update_stock_refill_request(
    (held ->> 'id')::uuid, (held ->> 'version')::integer,
    (select id from public.suppliers where name = 'M66 SQL Brand'),
    (select id from public.branches where code = 'm66_sql_gd'),
    jsonb_build_array(jsonb_build_object(
      'product_id', (select id from public.products where sku = 'm66_sql_a'),
      'requested_cases', 6
    )),
    'revised'
  );
  held := public.submit_stock_refill_request((held ->> 'id')::uuid, (held ->> 'version')::integer, 'm66-hold-rs');
  if held ->> 'status' is distinct from 'submitted' then
    raise exception 'resubmit failed';
  end if;
  perform pg_temp.as_user('admin');
  held := public.approve_stock_refill_request((held ->> 'id')::uuid, (held ->> 'version')::integer, 'm66-hold-a', null);
  if held ->> 'status' is distinct from 'approved' then
    raise exception 'held path did not approve';
  end if;
  perform pg_temp.assert_no_stock();

  -- Scenario D: reject is terminal. No send, no receiving link.
  perform pg_temp.as_user('accounts');
  rejected := public.create_stock_refill_request(
    (select id from public.suppliers where name = 'M66 SQL Brand'),
    (select id from public.branches where code = 'm66_sql_gd'),
    jsonb_build_array(jsonb_build_object(
      'product_id', (select id from public.products where sku = 'm66_sql_a'),
      'requested_cases', 2
    )),
    'm66-rej-c', null
  );
  rejected := public.submit_stock_refill_request((rejected ->> 'id')::uuid, (rejected ->> 'version')::integer, 'm66-rej-s');
  perform pg_temp.as_user('admin');
  rejected := public.reject_stock_refill_request((rejected ->> 'id')::uuid, (rejected ->> 'version')::integer, 'no budget', 'm66-rej-r');
  perform pg_temp.as_user('accounts');
  begin
    perform public.record_stock_refill_supplier_communication(
      (rejected ->> 'id')::uuid, (rejected ->> 'version')::integer, 'email', now(), 'm66-rej-send', null, null
    );
    raise exception 'rejected request must not send';
  exception
    when sqlstate '42501' then null;
  end;
  perform pg_temp.as_user('keeper');
  begin
    perform public.create_stock_receipt(
      (select id from public.branches where code = 'm66_sql_gd'),
      (select id from public.suppliers where name = 'M66 SQL Brand'),
      'm66-rej-rc', (now() at time zone 'utc')::date, null,
      jsonb_build_array(pg_temp.line('m66_sql_a', 1, 0)),
      (rejected ->> 'id')::uuid
    );
    raise exception 'rejected request must not link receiving';
  exception
    when sqlstate '42501' then null;
  end;
  perform pg_temp.assert_no_stock();

  -- Scenario A + E decline path separately, then A success path.
  declined := pg_temp.approve_request('m66-decl', 3, 3);
  perform pg_temp.as_user('accounts');
  sent := public.record_stock_refill_supplier_communication(
    (declined ->> 'id')::uuid, (declined ->> 'version')::integer, 'phone', now(), 'm66-decl-s', null, null
  );
  declined := public.record_stock_refill_supplier_acknowledgement(
    (sent ->> 'id')::uuid, (sent ->> 'version')::integer, 'declined', now(), 'm66-decl-a', null, null, 'plant empty'
  );
  begin
    perform public.record_stock_refill_supplier_dispatch(
      (declined ->> 'id')::uuid, (declined ->> 'version')::integer, current_date, 'm66-decl-d', null, null, null, null, null, null
    );
    raise exception 'decline must block dispatch';
  exception
    when sqlstate '42501' then null;
  end;
  declined := public.record_stock_refill_supplier_acknowledgement(
    (declined ->> 'id')::uuid, (declined ->> 'version')::integer, 'acknowledged', now(), 'm66-decl-fix', 'OK', null, null
  );
  if declined ->> 'acknowledgement_status' is distinct from 'acknowledged' then
    raise exception 'ack correction failed';
  end if;
  perform pg_temp.assert_no_stock();

  -- Scenario A standard replenishment.
  request := pg_temp.approve_request('m66-std', 10, 8);
  request_id := (request ->> 'id')::uuid;
  perform pg_temp.assert_no_stock();
  perform pg_temp.as_user('admin');
  begin
    perform public.record_stock_refill_supplier_communication(
      request_id, (request ->> 'version')::integer, 'email', now(), 'm66-admin-send', null, null
    );
    raise exception 'admin must not send';
  exception
    when sqlstate '42501' then null;
  end;
  perform pg_temp.as_user('accounts');
  sent := public.record_stock_refill_supplier_communication(
    request_id, (request ->> 'version')::integer, 'whatsapp', now(), 'm66-std-s', 'WA-1', null
  );
  ack := public.record_stock_refill_supplier_acknowledgement(
    request_id, (sent ->> 'version')::integer, 'acknowledged', now(), 'm66-std-a', 'ACK-1', null, null
  );
  dispatch := public.record_stock_refill_supplier_dispatch(
    request_id, (ack ->> 'version')::integer, current_date, 'm66-std-d', 'DN-66', current_date + 1, 'Van', null, null, null
  );
  perform pg_temp.assert_no_stock();
  if (
    select count(*) from public.stock_refill_request_events
    where refill_request_id = request_id
      and action in ('created', 'submitted', 'approved', 'sent_to_supplier', 'supplier_acknowledged', 'supplier_dispatch_recorded')
  ) <> 6 then
    raise exception 'scenario A missing audit events';
  end if;

  -- Scenario G: draft reserves, cancel releases.
  perform pg_temp.as_user('keeper');
  draft := public.create_stock_receipt(
    (select id from public.branches where code = 'm66_sql_gd'),
    (select id from public.suppliers where name = 'M66 SQL Brand'),
    'm66-draft', (now() at time zone 'utc')::date, null,
    jsonb_build_array(pg_temp.line('m66_sql_a', 7, 0), pg_temp.line('m66_sql_b', 1, 0)),
    request_id
  );
  perform pg_temp.assert_no_stock();
  recon := public.get_stock_refill_receiving_reconciliation(request_id);
  if (recon -> 'receiving' -> 'summary' ->> 'draft_reserved_cases')::integer <> 8
     or (recon -> 'receiving' -> 'summary' ->> 'accepted_cases')::integer <> 0 then
    raise exception 'draft reservation mismatch %', recon -> 'receiving' -> 'summary';
  end if;
  begin
    perform public.create_stock_receipt(
      (select id from public.branches where code = 'm66_sql_gd'),
      (select id from public.suppliers where name = 'M66 SQL Brand'),
      'm66-draft-over', (now() at time zone 'utc')::date, null,
      jsonb_build_array(pg_temp.line('m66_sql_a', 4, 0)),
      request_id
    );
    raise exception 'draft must reserve remaining A capacity';
  exception
    when sqlstate '23514' then null;
  end;
  perform public.cancel_stock_receipt((draft ->> 'id')::uuid, 'wrong van');
  recon := public.get_stock_refill_receiving_reconciliation(request_id);
  if (recon -> 'receiving' -> 'summary' ->> 'reserved_cases')::integer <> 0 then
    raise exception 'cancel must release reservation';
  end if;
  perform pg_temp.assert_no_stock();

  -- Scenario F + B: damaged excluded, two verified partials.
  first := public.create_stock_receipt(
    (select id from public.branches where code = 'm66_sql_gd'),
    (select id from public.suppliers where name = 'M66 SQL Brand'),
    'm66-first', (now() at time zone 'utc')::date, null,
    jsonb_build_array(pg_temp.line('m66_sql_a', 6, 1), pg_temp.line('m66_sql_b', 3, 0)),
    request_id
  );
  first := public.submit_stock_receipt((first ->> 'id')::uuid);
  perform pg_temp.assert_no_stock();
  perform pg_temp.as_user('accounts');
  begin
    perform public.verify_stock_receipt((first ->> 'id')::uuid, 'm66-verify-first');
    raise exception 'accounts must not verify';
  exception
    when sqlstate '42501' then null;
  end;
  perform pg_temp.as_user('godown');
  first := public.verify_stock_receipt((first ->> 'id')::uuid, 'm66-verify-first');
  replay := public.verify_stock_receipt((first ->> 'id')::uuid, 'm66-verify-first');
  if replay ->> 'status' is distinct from 'posted' then
    raise exception 'verify replay failed';
  end if;
  select count(*) into first_tx from public.stock_transactions where receipt_id = (first ->> 'id')::uuid;
  if first_tx <> 2 then
    raise exception 'exact-once expected 2 txs, got %', first_tx;
  end if;
  recon := public.get_stock_refill_receiving_reconciliation(request_id);
  -- accepted A=5 (6-1 damage), B=3 → 8. outstanding 10-5 + 8-3 = 10.
  if (recon -> 'receiving' -> 'summary' ->> 'accepted_cases')::integer <> 8
     or (recon -> 'receiving' -> 'summary' ->> 'damaged_cases')::integer <> 1
     or (recon -> 'receiving' -> 'summary' ->> 'outstanding_cases')::integer <> 10 then
    raise exception 'first posted recon mismatch %', recon -> 'receiving' -> 'summary';
  end if;

  perform pg_temp.as_user('keeper');
  second := public.create_stock_receipt(
    (select id from public.branches where code = 'm66_sql_gd'),
    (select id from public.suppliers where name = 'M66 SQL Brand'),
    'm66-second', (now() at time zone 'utc')::date, null,
    jsonb_build_array(pg_temp.line('m66_sql_a', 5, 0), pg_temp.line('m66_sql_b', 5, 0)),
    request_id
  );
  second := public.submit_stock_receipt((second ->> 'id')::uuid);
  -- Scenario J stale submit version: second submit of posted/submitted receipt is 42501.
  begin
    perform public.submit_stock_receipt((second ->> 'id')::uuid);
    raise exception 'second submit of submitted receipt must fail';
  exception
    when sqlstate '42501' then null;
  end;
  perform pg_temp.as_user('godown');
  second := public.verify_stock_receipt((second ->> 'id')::uuid, 'm66-verify-second');
  recon := public.get_stock_refill_receiving_reconciliation(request_id);
  if (recon -> 'receiving' -> 'summary' ->> 'accepted_cases')::integer <> 18
     or recon -> 'receiving' -> 'summary' ->> 'completion_label' is distinct from 'fully_received' then
    raise exception 'two partials should fully receive, got %', recon -> 'receiving' -> 'summary';
  end if;

  -- Reporting consistency: queue, recon, report, export.
  perform pg_temp.as_user('accounts');
  listed := public.list_stock_refill_requests(1, 50, null, null, null, request ->> 'request_number');
  report := public.list_stock_refill_report(1, 50, null, null, null, request ->> 'request_number');
  if (listed -> 'items' -> 0 ->> 'accepted_cases')::integer
       is distinct from (recon -> 'receiving' -> 'summary' ->> 'accepted_cases')::integer
     or (report -> 'rows' -> 0 ->> 'accepted_cases')::integer
       is distinct from (recon -> 'receiving' -> 'summary' ->> 'accepted_cases')::integer then
    raise exception 'queue/report/recon accepted mismatch';
  end if;
  exported := public.export_stock_refill_report(null, null, null, request ->> 'request_number');
  if position(request ->> 'request_number' in exported ->> 'csv') = 0 then
    raise exception 'export missing request number';
  end if;

  -- Scenario I unlinked receiving still posts.
  perform pg_temp.as_user('keeper');
  unlinked := public.create_stock_receipt(
    (select id from public.branches where code = 'm66_sql_gd'),
    (select id from public.suppliers where name = 'M66 SQL Brand'),
    'm66-unlinked', (now() at time zone 'utc')::date, null,
    jsonb_build_array(pg_temp.line('m66_sql_a', 1, 0)),
    null
  );
  unlinked := public.submit_stock_receipt((unlinked ->> 'id')::uuid);
  perform pg_temp.as_user('godown');
  unlinked := public.verify_stock_receipt((unlinked ->> 'id')::uuid, 'm66-unlinked-verify');
  recon := public.get_stock_refill_receiving_reconciliation(request_id);
  if (recon -> 'receiving' -> 'summary' ->> 'accepted_cases')::integer <> 18 then
    raise exception 'unlinked receipt must not add refill accepted';
  end if;

  -- Scenario H: deactivate godown. Historical read stays. New send/receive blocked.
  update public.branches set is_active = false where code = 'm66_sql_gd';
  perform pg_temp.as_user('accounts');
  if (public.get_stock_refill_request(request_id) ->> 'id') is null then
    raise exception 'historical refill get must remain';
  end if;
  begin
    perform public.record_stock_refill_supplier_communication(
      request_id, 99, 'email', now(), 'm66-inactive-send', null, null
    );
    raise exception 'inactive godown must block send';
  exception
    when sqlstate '42501' then null;
  end;
  perform pg_temp.as_user('keeper');
  begin
    perform public.create_stock_receipt(
      (select id from public.branches where code = 'm66_sql_gd'),
      (select id from public.suppliers where name = 'M66 SQL Brand'),
      'm66-inactive-rc', (now() at time zone 'utc')::date, null,
      jsonb_build_array(pg_temp.line('m66_sql_a', 1, 0)),
      request_id
    );
    raise exception 'inactive godown must block linked create';
  exception
    when sqlstate '42501' then null;
  end;
  update public.branches set is_active = true where code = 'm66_sql_gd';

  -- Cross-godown / other roles.
  perform pg_temp.as_user('other_acct');
  begin
    perform public.get_stock_refill_request(request_id);
    raise exception 'cross-godown get must fail';
  exception
    when sqlstate '42501' then null;
  end;
  perform pg_temp.as_user('sales');
  begin
    perform public.list_stock_refill_requests();
    raise exception 'salesperson must not list refill';
  exception
    when sqlstate '42501' then null;
  end;
  perform pg_temp.as_user('delivery');
  begin
    perform public.list_stock_refill_report();
    raise exception 'delivery must not read refill report';
  exception
    when sqlstate '42501' then null;
  end;
  perform pg_temp.as_user('monitor');
  begin
    perform public.list_stock_refill_requests();
    raise exception 'operations.monitor must not list refill';
  exception
    when sqlstate '42501' then null;
  end;
  perform pg_temp.as_user('godown');
  begin
    perform public.list_stock_refill_requests();
    raise exception 'gm must not list refill without refill permissions';
  exception
    when sqlstate '42501' then null;
  end;

  -- Assignment removal: next statement denied, including replay.
  delete from public.user_branch_assignments
  where user_id = (select id from fixture where name = 'accounts')
    and branch_id = (select id from public.branches where code = 'm66_sql_gd');
  perform pg_temp.as_user('accounts');
  begin
    perform public.get_stock_refill_request(request_id);
    raise exception 'removed assignment must deny get';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.record_stock_refill_supplier_communication(
      request_id, (dispatch ->> 'version')::integer, 'whatsapp', now(), 'm66-std-s', 'WA-1', null
    );
    raise exception 'removed assignment must deny send replay';
  exception
    when sqlstate '42501' then null;
  end;

  select count(*) into events
  from public.stock_refill_request_events
  where refill_request_id = request_id and action = 'sent_to_supplier';
  if events <> 1 then
    raise exception 'send replay after revoke must not add events';
  end if;

  if (select value from public.app_configuration where key = 'damage.stock_hold_ready') <> 'false'::jsonb
     or (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled') <> 'false'::jsonb
     or (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked') <> 'false'::jsonb then
    raise exception 'flags flipped during M6.6 SQL';
  end if;
end $$;

rollback;
select pg_advisory_unlock(hashtext('sherlyos.m6.refill_tests'));
