-- M5.5 module-closure accounting, RLS, and read-model identity proofs.
-- Rolls back. Does not flip damage.stock_hold_ready or lot cutover flags.
-- Shared Docker flags: run sequentially with other M5 SQL/HTTP/concurrency suites.
select pg_advisory_lock(hashtext('sherlyos.m5.stock_flag_tests'));
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
  ('other', gen_random_uuid()),
  ('sales', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id, 'authenticated', 'authenticated',
  fixture.name || '.m55sql@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M55 SQL Admin', true)
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
  when 'other' then 'godown_manager'
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

-- Catalog and FORCE RLS must remain on every damage table.
do $$
declare
  missing text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into missing
  from (values
    ('damage_reports'),
    ('damage_report_lines'),
    ('damage_report_events'),
    ('damage_evidence'),
    ('damage_stock_holds'),
    ('damage_exceptional_requests')
  ) t(relname)
  join pg_class c on c.relname = t.relname
  join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
  where not c.relrowsecurity or not c.relforcerowsecurity;
  if missing is not null then
    raise exception 'damage tables missing FORCE RLS: %', missing;
  end if;

  if has_table_privilege('authenticated', 'public.stock_balances', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_ledger', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_transactions', 'INSERT')
     or has_table_privilege('authenticated', 'public.damage_stock_holds', 'INSERT') then
    raise exception 'authenticated must not insert stock or damage holds';
  end if;
end $$;

set session_replication_role = replica;

insert into public.branches (code, name, is_active)
values
  ('m55_sql_gd', 'M55 SQL Godown', true),
  ('m55_sql_other', 'M55 SQL Other', true);

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code = 'm55_sql_gd'
  and fixture.name in ('admin', 'godown');

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select (select id from fixture where name = 'other'), branches.id,
  (select id from fixture where name = 'admin')
from public.branches where code = 'm55_sql_other';

insert into public.zones (branch_id, code, name, is_active)
select id, 'm55_sql_z', 'M55 Zone', true from public.branches where code = 'm55_sql_gd';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm55_sql_c', 'M55 Crate', true from public.zones where code = 'm55_sql_z';
insert into public.products (sku, name, is_active) values ('m55_sql_sku', 'M55 SQL Product', true);
insert into public.shops (name, is_active) values ('M55 SQL Shop', true);
insert into public.stock_balances (crate_id, product_id, quantity)
select crates.id, products.id, 20
from public.crates, public.products
where crates.code = 'm55_sql_c' and products.sku = 'm55_sql_sku';

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
)
select
  report_number, 'storage', branches.id, 'verified', 3,
  (select id from fixture where name = 'godown'),
  (select id from fixture where name = 'godown'), now(),
  report_number || '-key', report_number || '-fp', report_number
from public.branches
cross join (values ('m55-sql-ord'), ('m55-sql-des'), ('m55-sql-act')) r(report_number)
where branches.code = 'm55_sql_gd';

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes, shop_id,
  rejected_at, rejected_by, rejection_reason
)
select
  'm55-sql-sup', 'shop_return', branches.id, 'rejected', 3,
  (select id from fixture where name = 'godown'),
  'm55-sql-sup-key', 'm55-sql-sup-fp', 'returned supplier', shops.id,
  now(), (select id from fixture where name = 'godown'), 'not accepted'
from public.branches, public.shops
where branches.code = 'm55_sql_gd' and shops.name = 'M55 SQL Shop';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id,
  case damage_reports.report_number
    when 'm55-sql-ord' then 3
    when 'm55-sql-des' then 2
    when 'm55-sql-sup' then 4
    else 5
  end,
  'crushed'
from public.damage_reports
join public.products on products.sku = 'm55_sql_sku'
join public.crates on crates.code = 'm55_sql_c'
where damage_reports.report_number like 'm55-sql-%';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id,
  damage_report_lines.crate_id, damage_report_lines.quantity_cases,
  case when damage_reports.scenario = 'shop_return' then 'quarantine_intake' else 'on_hand_deduction' end,
  case damage_reports.report_number
    when 'm55-sql-ord' then 'written_off'
    when 'm55-sql-des' then 'written_off'
    when 'm55-sql-sup' then 'returned_supplier'
    else 'active'
  end
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm55_sql_sku'
where damage_reports.report_number like 'm55-sql-%';

insert into public.damage_report_events (
  damage_report_id, actor_id, action, previous_status, next_status
)
select damage_reports.id, (select id from fixture where name = 'godown'),
  'ordinary_writeoff', 'verified', 'verified'
from public.damage_reports where report_number = 'm55-sql-ord';

insert into public.damage_report_events (
  damage_report_id, actor_id, action, previous_status, next_status
)
select damage_reports.id, (select id from fixture where name = 'godown'),
  'exceptional_posted', 'verified', 'verified'
from public.damage_reports where report_number in ('m55-sql-des', 'm55-sql-sup');

-- Approved-but-unposted request: authorization only, no ledger.
insert into public.damage_exceptional_requests (
  damage_report_id, disposition_kind, status, version,
  request_reason, requested_by, requested_at,
  decided_by, decided_at, decision_reason, request_idempotency_key
)
select
  damage_reports.id, 'destroy', 'approved', 2,
  'pending execution', (select id from fixture where name = 'godown'), now(),
  (select id from fixture where name = 'admin'), now(), 'authorized',
  'm55-sql-act-ex-key'
from public.damage_reports where report_number = 'm55-sql-act';

set session_replication_role = origin;

select pg_temp.as_user('godown');
set local role authenticated;

do $$
declare
  dash jsonb;
  q jsonb;
  hold_active integer;
  txn_on_approved integer;
begin
  select coalesce(sum(quantity_cases), 0)::integer into hold_active
  from public.damage_stock_holds
  join public.damage_reports on damage_reports.id = damage_stock_holds.damage_report_id
  where damage_reports.report_number like 'm55-sql-%'
    and damage_stock_holds.status in ('active', 'transferred');

  dash := public.get_damage_dashboard();
  if (dash #>> '{totals,ordinary_writeoff_cases}')::integer is distinct from 3 then
    raise exception 'ordinary posted identity failed: %', dash -> 'totals';
  end if;
  if (dash #>> '{totals,exceptional_writeoff_cases}')::integer is distinct from 2 then
    raise exception 'exceptional destroy counted as ordinary or missing: %', dash -> 'totals';
  end if;
  if (dash #>> '{totals,returned_supplier_cases}')::integer is distinct from 4 then
    raise exception 'returned supplier identity failed: %', dash -> 'totals';
  end if;
  if (dash #>> '{totals,active_hold_cases}')::integer is distinct from hold_active then
    raise exception 'dashboard current unavailable drifted from holds: dash=% hold=%',
      dash -> 'totals', hold_active;
  end if;
  if (dash #>> '{totals,active_hold_cases}')::integer is distinct from 5 then
    raise exception 'posted history leaked into current unavailable: %', dash -> 'totals';
  end if;

  q := public.list_damage_quarantine_inventory();
  if (q #>> '{totals,current_unavailable_cases}')::integer is distinct from 5 then
    raise exception 'quarantine current unavailable leaked posted history: %', q -> 'totals';
  end if;

  select count(*) into txn_on_approved
  from public.stock_transactions
  where damage_report_id = (select id from public.damage_reports where report_number = 'm55-sql-act');
  if txn_on_approved <> 0 then
    raise exception 'approved exceptional request must not post ledger: %', txn_on_approved;
  end if;

  if exists (select 1 from public.stock_balances where quantity < 0) then
    raise exception 'negative inventory present';
  end if;
end $$;

-- Authenticated clients cannot DML stock or damage rows.
do $$
begin
  insert into public.stock_balances (crate_id, product_id, quantity)
  select crates.id, products.id, 1
  from public.crates, public.products
  where crates.code = 'm55_sql_c' and products.sku = 'm55_sql_sku';
  raise exception 'authenticated inserted stock_balances';
exception
  when unique_violation then
    raise exception 'authenticated reached stock_balances unique instead of revoke';
  when insufficient_privilege then null;
  when sqlstate '42501' then null;
end $$;

do $$
begin
  update public.damage_reports set notes = 'tamper'
  where report_number = 'm55-sql-act';
  raise exception 'authenticated updated damage_reports';
exception
  when insufficient_privilege then null;
  when sqlstate '42501' then null;
end $$;

-- Private isolation helper stays revoked from authenticated.
do $$
begin
  perform app_private.apply_damage_stock_isolation(
    (select id from public.damage_reports where report_number = 'm55-sql-act')
  );
  raise exception 'authenticated executed apply_damage_stock_isolation';
exception
  when undefined_function then null;
  when insufficient_privilege then null;
  when sqlstate '42501' then null;
end $$;

reset role;
select pg_temp.as_user('other');
set local role authenticated;
do $$
declare
  dash jsonb;
begin
  dash := public.get_damage_dashboard();
  if coalesce((dash #>> '{totals,ordinary_writeoff_cases}')::integer, 0) <> 0
     or coalesce((dash #>> '{totals,active_hold_cases}')::integer, 0) <> 0 then
    raise exception 'cross-godown dashboard leaked: %', dash -> 'totals';
  end if;
end $$;

reset role;
select pg_temp.as_user('sales');
set local role authenticated;
do $$
begin
  perform public.get_damage_dashboard();
  raise exception 'salesperson executed get_damage_dashboard';
exception
  when insufficient_privilege then null;
end $$;

reset role;
select pg_temp.as_user('godown');
set local role authenticated;
do $$
declare
  payload jsonb;
begin
  payload := public.create_damage_report(
    'storage',
    (select id from public.branches where code = 'm55_sql_gd'),
    jsonb_build_array(jsonb_build_object(
      'product_id', (select id from public.products where sku = 'm55_sql_sku'),
      'crate_id', (select id from public.crates where code = 'm55_sql_c'),
      'quantity_cases', 1,
      'damage_reason', 'crushed'
    )),
    'm55-sql-ready',
    'fail closed storage'
  );
  begin
    perform public.submit_damage_report(
      (payload ->> 'id')::uuid,
      (payload ->> 'version')::integer,
      'm55-sql-ready-sub'
    );
    raise exception 'storage submit must fail closed while readiness is false';
  exception
    when check_violation then null;
    when sqlstate '23514' then null;
  end;
end $$;

reset role;
do $$
begin
  if exists (
    select 1 from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    ) and value = 'true'::jsonb
  ) then
    raise exception 'cutover flags must remain false';
  end if;
end $$;

rollback;
select pg_advisory_unlock(hashtext('sherlyos.m5.stock_flag_tests'));
