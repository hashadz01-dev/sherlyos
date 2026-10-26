-- M5.4F dashboard/quarantine posted-total reconciliation and fail-closed submit.
-- Rolls back. Does not flip damage.stock_hold_ready or lot cutover flags.
-- Shared Docker flags: run sequentially with other M5.2–M5.4F SQL/HTTP/concurrency
-- suites. Session advisory lock serializes against those suites.
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
  fixture.name || '.m54fsql@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M54F SQL Admin', true)
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

set session_replication_role = replica;

insert into public.branches (code, name, is_active)
values
  ('m54f_sql_gd', 'M54F SQL Godown', true),
  ('m54f_sql_other', 'M54F SQL Other', true);

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code = 'm54f_sql_gd'
  and fixture.name in ('admin', 'godown');

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select (select id from fixture where name = 'other'), branches.id,
  (select id from fixture where name = 'admin')
from public.branches where code = 'm54f_sql_other';

insert into public.zones (branch_id, code, name, is_active)
select id, 'm54f_sql_z', 'M54F Zone', true from public.branches where code = 'm54f_sql_gd';
insert into public.zones (branch_id, code, name, is_active)
select id, 'm54f_sql_qrn', 'Quarantine', true
from public.branches where code = 'm54f_sql_gd';
insert into public.zones (branch_id, code, name, is_active)
select id, 'm54f_sql_z2', 'Other Zone', true from public.branches where code = 'm54f_sql_other';

insert into public.crates (zone_id, code, name, is_active)
select id, 'm54f_sql_c', 'M54F Crate', true from public.zones where code = 'm54f_sql_z';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm54f_sql_qc', 'Quarantine crate', true
from public.zones where code = 'm54f_sql_qrn';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm54f_sql_c2', 'Other Crate', true from public.zones where code = 'm54f_sql_z2';

insert into public.products (sku, name, is_active) values ('m54f_sql_sku', 'M54F SQL Product', true);
insert into public.shops (name, is_active) values ('M54F SQL Shop', true);

-- Ordinary write-off: written_off + ordinary_writeoff event.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
)
select
  'm54f-sql-ord', 'storage', branches.id, 'verified', 3,
  (select id from fixture where name = 'godown'),
  (select id from fixture where name = 'godown'), now(),
  'm54f-sql-ord-key', 'm54f-sql-ord-fp', 'ordinary posted'
from public.branches where code = 'm54f_sql_gd';

-- Exceptional destroy: written_off + exceptional_posted event. Must not count as ordinary.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
)
select
  'm54f-sql-des', 'storage', branches.id, 'verified', 3,
  (select id from fixture where name = 'godown'),
  (select id from fixture where name = 'godown'), now(),
  'm54f-sql-des-key', 'm54f-sql-des-fp', 'exceptional destroy posted'
from public.branches where code = 'm54f_sql_gd';

-- Return-to-supplier: returned_supplier holds. Not current unavailable.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes, shop_id,
  rejected_at, rejected_by, rejection_reason
)
select
  'm54f-sql-sup', 'shop_return', branches.id, 'rejected', 3,
  (select id from fixture where name = 'godown'),
  'm54f-sql-sup-key', 'm54f-sql-sup-fp', 'returned supplier', shops.id,
  now(), (select id from fixture where name = 'godown'), 'not accepted'
from public.branches, public.shops
where branches.code = 'm54f_sql_gd' and shops.name = 'M54F SQL Shop';

-- Current isolation still unavailable.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
)
select
  'm54f-sql-act', 'storage', branches.id, 'verified', 3,
  (select id from fixture where name = 'godown'),
  (select id from fixture where name = 'godown'), now(),
  'm54f-sql-act-key', 'm54f-sql-act-fp', 'still held'
from public.branches where code = 'm54f_sql_gd';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id,
  case when damage_reports.report_number = 'm54f-sql-sup' then qc.id else crates.id end,
  case damage_reports.report_number
    when 'm54f-sql-ord' then 3
    when 'm54f-sql-des' then 2
    when 'm54f-sql-sup' then 4
    else 5
  end,
  'crushed'
from public.damage_reports
join public.products on products.sku = 'm54f_sql_sku'
join public.crates on crates.code = 'm54f_sql_c'
join public.crates qc on qc.code = 'm54f_sql_qc'
where damage_reports.report_number like 'm54f-sql-%';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id,
  damage_report_lines.crate_id, damage_report_lines.quantity_cases,
  case when damage_reports.scenario = 'shop_return' then 'quarantine_intake' else 'on_hand_deduction' end,
  case damage_reports.report_number
    when 'm54f-sql-ord' then 'written_off'
    when 'm54f-sql-des' then 'written_off'
    when 'm54f-sql-sup' then 'returned_supplier'
    else 'active'
  end
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54f_sql_sku'
where damage_reports.report_number like 'm54f-sql-%';

insert into public.damage_report_events (
  damage_report_id, actor_id, action, previous_status, next_status
)
select damage_reports.id, (select id from fixture where name = 'godown'),
  'ordinary_writeoff', 'verified', 'verified'
from public.damage_reports where report_number = 'm54f-sql-ord';

insert into public.damage_report_events (
  damage_report_id, actor_id, action, previous_status, next_status
)
select damage_reports.id, (select id from fixture where name = 'godown'),
  'exceptional_posted', 'verified', 'verified'
from public.damage_reports where report_number in ('m54f-sql-des', 'm54f-sql-sup');

set session_replication_role = origin;

select pg_temp.as_user('godown');
set local role authenticated;

do $$
declare
  dash jsonb;
  q jsonb;
begin
  dash := public.get_damage_dashboard();
  if (dash #>> '{totals,ordinary_writeoff_cases}')::integer is distinct from 3 then
    raise exception 'ordinary posted total expected 3: %', dash -> 'totals';
  end if;
  if (dash #>> '{totals,exceptional_writeoff_cases}')::integer is distinct from 2 then
    raise exception 'exceptional destroy must not count as ordinary: %', dash -> 'totals';
  end if;
  if (dash #>> '{totals,returned_supplier_cases}')::integer is distinct from 4 then
    raise exception 'returned supplier total expected 4: %', dash -> 'totals';
  end if;
  if (dash #>> '{totals,active_hold_cases}')::integer is distinct from 5 then
    raise exception 'current unavailable must exclude posted history: %', dash -> 'totals';
  end if;
  if (dash #>> '{totals,quarantined_cases}')::integer <> 0 then
    raise exception 'returned supplier must not sit in current quarantined: %', dash -> 'totals';
  end if;

  q := public.list_damage_quarantine_inventory();
  if (q #>> '{totals,returned_supplier_cases}')::integer is distinct from 4 then
    raise exception 'quarantine returned_supplier expected 4: %', q -> 'totals';
  end if;
  if (q #>> '{totals,written_off_cases}')::integer is distinct from 5 then
    raise exception 'quarantine written_off expected 5: %', q -> 'totals';
  end if;
  if (q #>> '{totals,current_unavailable_cases}')::integer is distinct from 5 then
    raise exception 'quarantine current unavailable must exclude posted history: %', q -> 'totals';
  end if;
end $$;

-- Cross-godown GM must not see this godown's posted totals.
reset role;
select pg_temp.as_user('other');
set local role authenticated;
do $$
declare
  dash jsonb;
begin
  dash := public.get_damage_dashboard();
  if coalesce((dash #>> '{totals,ordinary_writeoff_cases}')::integer, 0) <> 0
     or coalesce((dash #>> '{totals,exceptional_writeoff_cases}')::integer, 0) <> 0
     or coalesce((dash #>> '{totals,returned_supplier_cases}')::integer, 0) <> 0
     or coalesce((dash #>> '{totals,active_hold_cases}')::integer, 0) <> 0 then
    raise exception 'cross-godown dashboard leaked posted totals: %', dash -> 'totals';
  end if;
end $$;

reset role;
select pg_temp.as_user('sales');
set local role authenticated;
do $$
begin
  perform public.get_damage_dashboard();
  raise exception 'salesperson must not execute get_damage_dashboard';
exception
  when insufficient_privilege then null;
end $$;

-- Isolation-required submit stays fail-closed while readiness is false.
reset role;
select pg_temp.as_user('godown');
set local role authenticated;
do $$
declare
  payload jsonb;
  report_id uuid;
begin
  payload := public.create_damage_report(
    'storage',
    (select id from public.branches where code = 'm54f_sql_gd'),
    jsonb_build_array(jsonb_build_object(
      'product_id', (select id from public.products where sku = 'm54f_sql_sku'),
      'crate_id', (select id from public.crates where code = 'm54f_sql_c'),
      'quantity_cases', 1,
      'damage_reason', 'crushed'
    )),
    'm54f-sql-ready',
    'fail closed storage'
  );
  report_id := (payload ->> 'id')::uuid;
  begin
    perform public.submit_damage_report(report_id, (payload ->> 'version')::integer, 'm54f-sql-ready-sub');
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
