-- M5.4D local GM verification and ordinary write-off proofs.
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
  ('verifier', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('driver', gen_random_uuid()),
  ('sales', gen_random_uuid()),
  ('other', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  fixture.name || '.m54dsql@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M54D SQL Admin', true)
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
  when 'verifier' then 'godown_manager'
  when 'keeper' then 'store_keeper'
  when 'driver' then 'delivery_person'
  when 'sales' then 'salesperson'
  when 'other' then 'godown_manager'
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

create or replace function pg_temp.stamp_evidence(target uuid)
returns void language plpgsql as $$
begin
  insert into public.damage_evidence (
    damage_report_id, storage_path, uploaded_by, mime_type, file_size, verified_at
  )
  values (
    target,
    target::text || '/' || gen_random_uuid()::text,
    (select id from fixture where name = 'godown'),
    'image/jpeg',
    4,
    clock_timestamp()
  );
end;
$$;

set session_replication_role = replica;

insert into public.branches (code, name, is_active)
values
  ('m54d_sql_gd', 'M54D SQL Godown', true),
  ('m54d_sql_other', 'M54D SQL Other', true),
  ('m54d_sql_dead', 'M54D SQL Inactive', false);

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code = 'm54d_sql_gd'
  and fixture.name in ('admin', 'godown', 'verifier', 'keeper', 'driver');

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select (select id from fixture where name = 'other'), branches.id,
  (select id from fixture where name = 'admin')
from public.branches where code = 'm54d_sql_other';

-- Assigned to the inactive godown so inactive checks raise 23514, not 42501.
insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select (select id from fixture where name = 'verifier'), branches.id,
  (select id from fixture where name = 'admin')
from public.branches where code = 'm54d_sql_dead';

insert into public.zones (branch_id, code, name, is_active)
select id, 'm54d_sql_z', 'M54D Zone', true from public.branches where code = 'm54d_sql_gd';
insert into public.zones (branch_id, code, name, is_active, location_role)
select id, 'm54d_sql_qrn', 'Quarantine', true, 'quarantine'
from public.branches where code = 'm54d_sql_gd';
insert into public.zones (branch_id, code, name, is_active)
select id, 'm54d_sql_z2', 'M54D Other Zone', true from public.branches where code = 'm54d_sql_other';
insert into public.zones (branch_id, code, name, is_active)
select id, 'm54d_sql_zd', 'M54D Dead Zone', true from public.branches where code = 'm54d_sql_dead';

insert into public.crates (zone_id, code, name, is_active)
select id, 'm54d_sql_c', 'M54D Crate', true from public.zones where code = 'm54d_sql_z';
insert into public.crates (zone_id, code, name, is_active, location_role)
select id, 'm54d_sql_qc', 'Quarantine crate', true, 'quarantine'
from public.zones where code = 'm54d_sql_qrn';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm54d_sql_c2', 'M54D Other Crate', true from public.zones where code = 'm54d_sql_z2';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm54d_sql_cd', 'M54D Dead Crate', true from public.zones where code = 'm54d_sql_zd';

insert into public.products (sku, name, is_active)
values ('m54d_sql_sku', 'M54D SQL Product', true);

insert into public.shops (name, is_active)
values ('M54D SQL Shop', true);

-- Submitted inbound eligible for verification (reporter = godown, verifier = verifier).
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54d-sql-in', 'refill_supply', branches.id, 'submitted', 2,
  (select id from fixture where name = 'godown'),
  'm54d-sql-in-key', 'm54d-sql-in-fp', 'inbound verify'
from public.branches where code = 'm54d_sql_gd';

insert into public.damage_report_lines (
  damage_report_id, product_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, 2, 'crushed'
from public.damage_reports, public.products
where damage_reports.report_number = 'm54d-sql-in' and products.sku = 'm54d_sql_sku';

-- Missing evidence inbound.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54d-sql-noev', 'refill_supply', branches.id, 'submitted', 2,
  (select id from fixture where name = 'godown'),
  'm54d-sql-noev-key', 'm54d-sql-noev-fp', 'no evidence'
from public.branches where code = 'm54d_sql_gd';

insert into public.damage_report_lines (
  damage_report_id, product_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, 1, 'wet'
from public.damage_reports, public.products
where damage_reports.report_number = 'm54d-sql-noev' and products.sku = 'm54d_sql_sku';

insert into public.damage_evidence (
  damage_report_id, storage_path, uploaded_by, mime_type, file_size, verified_at
)
select damage_reports.id, damage_reports.id::text || '/' || gen_random_uuid()::text,
  (select id from fixture where name = 'godown'), 'image/jpeg', 4, null
from public.damage_reports where report_number = 'm54d-sql-noev';

-- Return candidate inbound.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54d-sql-ret', 'refill_supply', branches.id, 'submitted', 2,
  (select id from fixture where name = 'keeper'),
  'm54d-sql-ret-key', 'm54d-sql-ret-fp', 'return me'
from public.branches where code = 'm54d_sql_gd';

insert into public.damage_report_lines (
  damage_report_id, product_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, 1, 'wet'
from public.damage_reports, public.products
where damage_reports.report_number = 'm54d-sql-ret' and products.sku = 'm54d_sql_sku';

-- Shop-return submitted with quarantine intake (cannot return; reject keeps hold).
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes, shop_id
)
select
  'm54d-sql-sr', 'shop_return', branches.id, 'submitted', 2,
  (select id from fixture where name = 'godown'),
  'm54d-sql-sr-key', 'm54d-sql-sr-fp', 'shop return', shops.id
from public.branches, public.shops
where branches.code = 'm54d_sql_gd' and shops.name = 'M54D SQL Shop';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 2, 'expired'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54d-sql-sr'
  and products.sku = 'm54d_sql_sku'
  and crates.code = 'm54d_sql_qc';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id, crates.id,
  2, 'quarantine_intake', 'active'
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54d_sql_sku'
join public.crates on crates.code = 'm54d_sql_qc'
where damage_reports.report_number = 'm54d-sql-sr';

-- Storage submitted without holds: isolation blocks verify.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54d-sql-iso', 'storage', branches.id, 'submitted', 2,
  (select id from fixture where name = 'godown'),
  'm54d-sql-iso-key', 'm54d-sql-iso-fp', 'no holds'
from public.branches where code = 'm54d_sql_gd';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 1, 'crushed'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54d-sql-iso'
  and products.sku = 'm54d_sql_sku'
  and crates.code = 'm54d_sql_c';

-- Verified storage ready for ordinary write-off.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
)
select
  'm54d-sql-wo', 'storage', branches.id, 'verified', 3,
  (select id from fixture where name = 'godown'),
  (select id from fixture where name = 'verifier'),
  now(),
  'm54d-sql-wo-key', 'm54d-sql-wo-fp', 'write off'
from public.branches where code = 'm54d_sql_gd';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 2, 'crushed'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54d-sql-wo'
  and products.sku = 'm54d_sql_sku'
  and crates.code = 'm54d_sql_c';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id, crates.id,
  2, 'on_hand_deduction', 'active'
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54d_sql_sku'
join public.crates on crates.code = 'm54d_sql_c'
where damage_reports.report_number = 'm54d-sql-wo';

-- Other-godown submitted inbound.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54d-sql-xgd', 'refill_supply', branches.id, 'submitted', 2,
  (select id from fixture where name = 'other'),
  'm54d-sql-xgd-key', 'm54d-sql-xgd-fp', 'other godown'
from public.branches where code = 'm54d_sql_other';

insert into public.damage_report_lines (
  damage_report_id, product_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, 1, 'wet'
from public.damage_reports, public.products
where damage_reports.report_number = 'm54d-sql-xgd' and products.sku = 'm54d_sql_sku';

-- Inactive godown verified storage.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
)
select
  'm54d-sql-dead', 'storage', branches.id, 'verified', 3,
  (select id from fixture where name = 'godown'),
  (select id from fixture where name = 'verifier'),
  now(),
  'm54d-sql-dead-key', 'm54d-sql-dead-fp', 'inactive'
from public.branches where code = 'm54d_sql_dead';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 1, 'crushed'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54d-sql-dead'
  and products.sku = 'm54d_sql_sku'
  and crates.code = 'm54d_sql_cd';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id, crates.id,
  1, 'on_hand_deduction', 'active'
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54d_sql_sku'
join public.crates on crates.code = 'm54d_sql_cd'
where damage_reports.report_number = 'm54d-sql-dead';

-- Second verified storage: new posting still requires current expected_version.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
)
select
  'm54d-sql-wo2', 'storage', branches.id, 'verified', 3,
  (select id from fixture where name = 'godown'),
  (select id from fixture where name = 'verifier'),
  now(),
  'm54d-sql-wo2-key', 'm54d-sql-wo2-fp', 'write off stale new'
from public.branches where code = 'm54d_sql_gd';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 2, 'crushed'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54d-sql-wo2'
  and products.sku = 'm54d_sql_sku'
  and crates.code = 'm54d_sql_c';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id, crates.id,
  2, 'on_hand_deduction', 'active'
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54d_sql_sku'
join public.crates on crates.code = 'm54d_sql_c'
where damage_reports.report_number = 'm54d-sql-wo2';

-- Storage submitted with matching holds: return must release the logical hold.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54d-sql-st-ret', 'storage', branches.id, 'submitted', 2,
  (select id from fixture where name = 'keeper'),
  'm54d-sql-st-ret-key', 'm54d-sql-st-ret-fp', 'storage return'
from public.branches where code = 'm54d_sql_gd';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 2, 'crushed'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54d-sql-st-ret'
  and products.sku = 'm54d_sql_sku'
  and crates.code = 'm54d_sql_c';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id, crates.id,
  2, 'on_hand_deduction', 'active'
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54d_sql_sku'
join public.crates on crates.code = 'm54d_sql_c'
where damage_reports.report_number = 'm54d-sql-st-ret';

-- Isolation quantity mismatch: line 2, hold 1.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54d-sql-mismatch', 'storage', branches.id, 'submitted', 2,
  (select id from fixture where name = 'godown'),
  'm54d-sql-mismatch-key', 'm54d-sql-mismatch-fp', 'qty mismatch'
from public.branches where code = 'm54d_sql_gd';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 2, 'crushed'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54d-sql-mismatch'
  and products.sku = 'm54d_sql_sku'
  and crates.code = 'm54d_sql_c';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id, crates.id,
  1, 'on_hand_deduction', 'active'
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54d_sql_sku'
join public.crates on crates.code = 'm54d_sql_c'
where damage_reports.report_number = 'm54d-sql-mismatch';

-- Custody confirmed but still draft: verify must fail on status.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes, shop_id,
  physical_custody_confirmed_at, physical_custody_confirmed_by
)
select
  'm54d-sql-custody', 'shop_return', branches.id, 'draft', 1,
  (select id from fixture where name = 'godown'),
  'm54d-sql-custody-key', 'm54d-sql-custody-fp', 'custody only', shops.id,
  now(), (select id from fixture where name = 'godown')
from public.branches, public.shops
where branches.code = 'm54d_sql_gd' and shops.name = 'M54D SQL Shop';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 1, 'expired'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54d-sql-custody'
  and products.sku = 'm54d_sql_sku'
  and crates.code = 'm54d_sql_qc';

-- Submitted inbound on the inactive godown.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54d-sql-dead-v', 'refill_supply', branches.id, 'submitted', 2,
  (select id from fixture where name = 'godown'),
  'm54d-sql-dead-v-key', 'm54d-sql-dead-v-fp', 'inactive verify'
from public.branches where code = 'm54d_sql_dead';

insert into public.damage_report_lines (
  damage_report_id, product_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, 1, 'wet'
from public.damage_reports, public.products
where damage_reports.report_number = 'm54d-sql-dead-v' and products.sku = 'm54d_sql_sku';

select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54d-sql-in'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54d-sql-ret'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54d-sql-sr'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54d-sql-iso'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54d-sql-wo'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54d-sql-wo2'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54d-sql-st-ret'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54d-sql-mismatch'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54d-sql-custody'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54d-sql-dead-v'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54d-sql-xgd'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54d-sql-dead'));

set session_replication_role = origin;

select pg_temp.as_user('admin');
set local role authenticated;
select public.post_opening_stock(
  (select id from public.products where sku = 'm54d_sql_sku'),
  (select id from public.crates where code = 'm54d_sql_c'),
  20,
  'm54d-sql-open',
  'M54D SQL opening'
);

do $$
declare
  ready boolean;
begin
  select (value = 'true'::jsonb) into ready
  from public.app_configuration where key = 'damage.stock_hold_ready';
  if ready then
    raise exception 'damage.stock_hold_ready must remain false';
  end if;
end $$;

-- Store keeper cannot verify.
select pg_temp.as_user('keeper');
set local role authenticated;
do $$
begin
  perform public.verify_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-in'), 2
  );
  raise exception 'store keeper must not verify';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('driver');
do $$
begin
  perform public.verify_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-in'), 2
  );
  raise exception 'driver must not verify';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('sales');
do $$
begin
  perform public.verify_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-in'), 2
  );
  raise exception 'sales must not verify';
exception
  when insufficient_privilege then null;
end $$;

-- Direct RPC self-verification denial (not UI-hidden).
select pg_temp.as_user('godown');
do $$
begin
  perform public.verify_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-in'), 2
  );
  raise exception 'self-verify must fail';
exception
  when insufficient_privilege then
    if sqlerrm not like '%reporter cannot verify%' then raise; end if;
end $$;

select pg_temp.as_user('godown');
do $$
begin
  perform public.reject_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-sr'),
    2, 'self reject'
  );
  raise exception 'reporter reject must fail';
exception
  when insufficient_privilege then
    if sqlerrm not like '%reporter cannot verify%' then raise; end if;
end $$;

-- Missing evidence.
select pg_temp.as_user('verifier');
do $$
begin
  perform public.verify_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-noev'), 2
  );
  raise exception 'unfinalized evidence must not verify';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%photographic evidence%' then raise; end if;
end $$;

-- Isolation required and missing.
do $$
begin
  perform public.verify_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-iso'), 2
  );
  raise exception 'storage without holds must not verify';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%stock isolation is not ready%' then raise; end if;
end $$;

-- Isolation quantity mismatch.
do $$
begin
  perform public.verify_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-mismatch'), 2
  );
  raise exception 'mismatched isolation quantities must not verify';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%cannot exceed isolated quantities%' then raise; end if;
end $$;

-- Custody confirmed but not submitted.
do $$
begin
  perform public.verify_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-custody'), 1
  );
  raise exception 'custody-only draft must not verify';
exception
  when insufficient_privilege then
    if sqlerrm not like '%cannot be verified%' then raise; end if;
end $$;

-- Inactive godown verification. can_work_at_branch requires is_active, so
-- lock_damage_report denies GM callers with 42501 before the unlocked snapshot.
do $$
begin
  perform public.verify_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-dead-v'), 2
  );
  raise exception 'inactive godown verify must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%inactive%' then raise; end if;
  when insufficient_privilege then null;
end $$;

-- Stale version.
do $$
begin
  perform public.verify_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-in'), 1
  );
  raise exception 'stale verify must fail';
exception
  when sqlstate 'PT409' then null;
  when sqlstate 'P0001' then
    if sqlerrm not like '%changed by someone else%' and sqlerrm not like '%stale%' then
      raise;
    end if;
end $$;

-- Authorized inbound verification.
do $$
declare
  payload jsonb;
begin
  payload := public.verify_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-in'), 2
  );
  if payload ->> 'status' is distinct from 'verified' then
    raise exception 'inbound verify failed status=%', payload ->> 'status';
  end if;
  if payload ->> 'verifier_name' is null then
    raise exception 'verifier name missing from payload';
  end if;
  if payload ->> 'verified_at' is null then
    raise exception 'verified_at missing from payload';
  end if;
  if (select count(*) from public.stock_transactions
      where damage_report_id = (payload ->> 'id')::uuid) <> 0 then
    raise exception 'verify must not post stock';
  end if;
end $$;

-- Invalid status after verify.
do $$
begin
  perform public.verify_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-in'), 3
  );
  raise exception 'verified report must not verify again';
exception
  when insufficient_privilege then
    if sqlerrm not like '%cannot be verified%' then raise; end if;
end $$;

-- Return inbound.
do $$
declare
  payload jsonb;
begin
  payload := public.return_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-ret'),
    2, 'need more photos'
  );
  if payload ->> 'status' is distinct from 'returned' then
    raise exception 'return failed';
  end if;
  if payload ->> 'return_reason' is distinct from 'need more photos' then
    raise exception 'return reason missing';
  end if;
end $$;

-- Shop-return cannot return.
do $$
begin
  perform public.return_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-sr'),
    2, 'send back'
  );
  raise exception 'shop-return return must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%cannot return to draft%' then raise; end if;
end $$;

-- Reject shop-return keeps quarantine intake.
do $$
declare
  payload jsonb;
  remaining integer;
begin
  payload := public.reject_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-sr'),
    2, 'not accepted'
  );
  if payload ->> 'status' is distinct from 'rejected' then
    raise exception 'reject failed';
  end if;
  select count(*) into remaining
  from public.damage_stock_holds
  where damage_report_id = (select id from public.damage_reports where report_number = 'm54d-sql-sr')
    and hold_kind = 'quarantine_intake'
    and status = 'active';
  if remaining <> 1 then
    raise exception 'rejected shop-return quarantine must remain, remaining=%', remaining;
  end if;
  if exists (
    select 1 from public.stock_transactions
    where damage_report_id = (select id from public.damage_reports where report_number = 'm54d-sql-sr')
  ) then
    raise exception 'reject must not post stock';
  end if;
end $$;

-- Return storage releases logical holds and does not return stock to saleable via ledger.
do $$
declare
  payload jsonb;
  remaining integer;
  ledger_count integer;
  on_hand_before integer;
  on_hand_after integer;
begin
  select quantity into on_hand_before
  from public.stock_balances
  join public.crates on crates.id = stock_balances.crate_id
  join public.products on products.id = stock_balances.product_id
  where crates.code = 'm54d_sql_c' and products.sku = 'm54d_sql_sku';

  payload := public.return_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-st-ret'),
    2, 'need crate photos'
  );
  if payload ->> 'status' is distinct from 'returned' then
    raise exception 'storage return failed';
  end if;
  if payload ->> 'return_reason' is distinct from 'need crate photos' then
    raise exception 'storage return reason missing';
  end if;
  select count(*) into remaining
  from public.damage_stock_holds
  where damage_report_id = (select id from public.damage_reports where report_number = 'm54d-sql-st-ret')
    and status = 'active';
  if remaining <> 0 then
    raise exception 'returned storage holds must release, remaining=%', remaining;
  end if;
  select count(*) into remaining
  from public.damage_stock_holds
  where damage_report_id = (select id from public.damage_reports where report_number = 'm54d-sql-st-ret')
    and status = 'released'
    and hold_kind = 'on_hand_deduction';
  if remaining <> 1 then
    raise exception 'returned storage hold must be released, got %', remaining;
  end if;
  select count(*) into ledger_count
  from public.stock_transactions
  where damage_report_id = (select id from public.damage_reports where report_number = 'm54d-sql-st-ret');
  if ledger_count <> 0 then
    raise exception 'return must not post stock, tx=%', ledger_count;
  end if;
  select quantity into on_hand_after
  from public.stock_balances
  join public.crates on crates.id = stock_balances.crate_id
  join public.products on products.id = stock_balances.product_id
  where crates.code = 'm54d_sql_c' and products.sku = 'm54d_sql_sku';
  if on_hand_after is distinct from on_hand_before then
    raise exception 'return must not change on-hand % -> %', on_hand_before, on_hand_after;
  end if;
end $$;

-- Admin cannot ordinary write-off.
select pg_temp.as_user('admin');
do $$
begin
  perform public.post_ordinary_damage_writeoff(
    (select id from public.damage_reports where report_number = 'm54d-sql-wo'),
    3, 'm54d-wo-admin'
  );
  raise exception 'admin ordinary write-off must fail';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('keeper');
do $$
begin
  perform public.post_ordinary_damage_writeoff(
    (select id from public.damage_reports where report_number = 'm54d-sql-wo'),
    3, 'm54d-wo-keeper'
  );
  raise exception 'keeper write-off must fail';
exception
  when insufficient_privilege then null;
end $$;

-- Cross-godown denial.
select pg_temp.as_user('other');
do $$
begin
  perform public.verify_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-in'), 3
  );
  raise exception 'cross-godown verify must fail';
exception
  when insufficient_privilege then null;
end $$;

do $$
declare
  listed jsonb;
begin
  listed := public.list_damage_reports(1, 50, null, 'submitted', null, null, null, null);
  if listed -> 'items' @> jsonb_build_array(jsonb_build_object('report_number', 'm54d-sql-in')) then
    raise exception 'other godown listed home inbound';
  end if;
end $$;

-- Inactive godown write-off. Same can_work_at_branch is_active gate as verify.
select pg_temp.as_user('verifier');
do $$
begin
  perform public.post_ordinary_damage_writeoff(
    (select id from public.damage_reports where report_number = 'm54d-sql-dead'),
    3, 'm54d-wo-dead'
  );
  raise exception 'inactive godown write-off must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%inactive%' then raise; end if;
  when insufficient_privilege then null;
end $$;

-- Authorized ordinary write-off + lost-response / stale-version / different-key replay.
select pg_temp.as_user('verifier');
do $$
declare
  payload jsonb;
  lost jsonb;
  stale jsonb;
  replay jsonb;
  refreshed jsonb;
  tx_count integer;
  ledger_sum numeric;
  hold_status text;
  on_hand integer;
begin
  payload := public.post_ordinary_damage_writeoff(
    (select id from public.damage_reports where report_number = 'm54d-sql-wo'),
    3, 'm54d-wo-gm'
  );
  -- Lost HTTP: original key, current version.
  lost := public.post_ordinary_damage_writeoff(
    (select id from public.damage_reports where report_number = 'm54d-sql-wo'),
    3, 'm54d-wo-gm'
  );
  -- Original key with a stale expected_version must identify completion.
  stale := public.post_ordinary_damage_writeoff(
    (select id from public.damage_reports where report_number = 'm54d-sql-wo'),
    2, 'm54d-wo-gm'
  );
  -- Different key after success still returns the same posting.
  replay := public.post_ordinary_damage_writeoff(
    (select id from public.damage_reports where report_number = 'm54d-sql-wo'),
    99, 'm54d-wo-gm-other-key'
  );
  refreshed := public.get_damage_report(
    (select id from public.damage_reports where report_number = 'm54d-sql-wo')
  );
  select count(*) into tx_count
  from public.stock_transactions
  where damage_report_id = (select id from public.damage_reports where report_number = 'm54d-sql-wo')
    and damage_posting_kind = 'ordinary_writeoff';
  if tx_count <> 1 then
    raise exception 'ordinary write-off must be exact-once, tx=%', tx_count;
  end if;
  select coalesce(sum(stock_ledger.quantity), 0) into ledger_sum
  from public.stock_ledger
  join public.stock_transactions
    on stock_transactions.id = stock_ledger.transaction_id
  where stock_transactions.damage_report_id =
    (select id from public.damage_reports where report_number = 'm54d-sql-wo')
    and stock_transactions.damage_posting_kind = 'ordinary_writeoff';
  if ledger_sum is distinct from -2 then
    raise exception 'write-off ledger must be -2, got %', ledger_sum;
  end if;
  select status into hold_status
  from public.damage_stock_holds
  where damage_report_id = (select id from public.damage_reports where report_number = 'm54d-sql-wo');
  if hold_status is distinct from 'written_off' then
    raise exception 'hold not consumed, status=%', hold_status;
  end if;
  select quantity into on_hand
  from public.stock_balances
  join public.crates on crates.id = stock_balances.crate_id
  join public.products on products.id = stock_balances.product_id
  where crates.code = 'm54d_sql_c' and products.sku = 'm54d_sql_sku';
  if on_hand < 0 then
    raise exception 'negative on-hand after write-off';
  end if;
  if payload is null or lost is null or stale is null or replay is null then
    raise exception 'write-off payload missing';
  end if;
  if refreshed ->> 'id' is null then
    raise exception 'refresh after write-off missing payload';
  end if;
end $$;

-- A new posting still requires the current expected_version.
do $$
begin
  perform public.post_ordinary_damage_writeoff(
    (select id from public.damage_reports where report_number = 'm54d-sql-wo2'),
    1, 'm54d-wo2-stale'
  );
  raise exception 'stale version must fail for a new write-off';
exception
  when sqlstate 'PT409' then null;
  when sqlstate 'P0001' then
    if sqlerrm not like '%changed by someone else%' and sqlerrm not like '%stale%' then
      raise;
    end if;
end $$;

do $$
declare
  tx_count integer;
begin
  select count(*) into tx_count
  from public.stock_transactions
  where damage_report_id = (select id from public.damage_reports where report_number = 'm54d-sql-wo2')
    and damage_posting_kind = 'ordinary_writeoff';
  if tx_count <> 0 then
    raise exception 'stale new write-off posted stock, tx=%', tx_count;
  end if;
end $$;

-- List facts for the verification queue.
select pg_temp.as_user('verifier');
do $$
declare
  listed jsonb;
  inbound jsonb;
begin
  listed := public.list_damage_reports(1, 25, null, null, 'refill_supply', 'm54d-sql-in', null, null);
  if (listed ->> 'total')::integer < 1 then
    raise exception 'list search missed inbound';
  end if;
  inbound := listed -> 'items' -> 0;
  if inbound ->> 'has_finalized_evidence' is distinct from 'true' then
    raise exception 'list missing finalized evidence fact';
  end if;
  if inbound ->> 'reporter_user_id' is null then
    raise exception 'list missing reporter id';
  end if;
end $$;

do $$
declare
  ready boolean;
  dual boolean;
  blocked boolean;
begin
  select (value = 'true'::jsonb) into ready
  from public.app_configuration where key = 'damage.stock_hold_ready';
  select (value = 'true'::jsonb) into dual
  from public.app_configuration where key = 'stock.lots.dual_write_enabled';
  select (value = 'true'::jsonb) into blocked
  from public.app_configuration where key = 'stock.lots.aggregate_only_blocked';
  if ready or dual or blocked then
    raise exception 'cutover flags must remain false';
  end if;
end $$;

rollback;
