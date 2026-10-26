-- M5.4C local custody, quarantine-list, and transfer eligibility tests.
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
  fixture.name || '.m54csql@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M54C SQL Admin', true)
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
  ('m54c_sql_gd', 'M54C SQL Godown', true),
  ('m54c_sql_other', 'M54C SQL Other', true),
  ('m54c_sql_dead', 'M54C SQL Inactive', false);

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code in ('m54c_sql_gd', 'm54c_sql_dead')
  and fixture.name in ('admin', 'godown', 'keeper', 'driver');

insert into public.zones (branch_id, code, name, is_active)
select id, 'm54c_sql_z', 'M54C Zone', true from public.branches where code = 'm54c_sql_gd';
insert into public.zones (branch_id, code, name, is_active, location_role)
select id, 'm54c_sql_qrn', 'Quarantine', true, 'quarantine' from public.branches where code = 'm54c_sql_gd';
insert into public.zones (branch_id, code, name, is_active)
select id, 'm54c_sql_z2', 'M54C Other Zone', true from public.branches where code = 'm54c_sql_other';
insert into public.zones (branch_id, code, name, is_active)
select id, 'm54c_sql_zd', 'M54C Dead Zone', true from public.branches where code = 'm54c_sql_dead';

insert into public.crates (zone_id, code, name, is_active)
select id, 'm54c_sql_c', 'M54C Crate', true from public.zones where code = 'm54c_sql_z';
insert into public.crates (zone_id, code, name, is_active, location_role)
select id, 'm54c_sql_qc', 'Quarantine crate', true, 'quarantine'
from public.zones where code = 'm54c_sql_qrn';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm54c_sql_c2', 'M54C Other Crate', true from public.zones where code = 'm54c_sql_z2';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm54c_sql_cd', 'M54C Dead Crate', true from public.zones where code = 'm54c_sql_zd';

insert into public.products (sku, name, is_active)
values ('m54c_sql_sku', 'M54C SQL Product', true);

insert into public.shops (name, is_active)
values ('M54C SQL Shop', true);

insert into public.stock_balances (crate_id, product_id, quantity)
select crates.id, products.id, 10
from public.crates, public.products
where crates.code = 'm54c_sql_c' and products.sku = 'm54c_sql_sku';

set session_replication_role = origin;

-- Readiness must stay false.
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

select pg_temp.as_user('godown');

do $$
declare
  branch uuid;
  shop uuid;
  product uuid;
  crate uuid;
  payload jsonb;
  report_id uuid;
  events integer;
begin
  select id into branch from public.branches where code = 'm54c_sql_gd';
  select id into shop from public.shops where name = 'M54C SQL Shop';
  select id into product from public.products where sku = 'm54c_sql_sku';
  select id into crate from public.crates where code = 'm54c_sql_c';

  payload := public.create_damage_report(
    'shop_return',
    branch,
    jsonb_build_array(jsonb_build_object(
      'product_id', product,
      'crate_id', crate,
      'quantity_cases', 2,
      'damage_reason', 'expired'
    )),
    'm54c-sql-sr',
    'shop return custody',
    null, null, null, null, shop
  );
  report_id := (payload ->> 'id')::uuid;
  perform set_config('sherlyos.sr_id', report_id::text, true);
  perform set_config('sherlyos.sr_version', (payload ->> 'version'), true);

  if payload ->> 'physical_custody_confirmed' = 'true' then
    raise exception 'new shop-return must start unconfirmed';
  end if;
end $$;

-- Store keeper cannot confirm shop-return custody (needs damage.verify).
select pg_temp.as_user('keeper');
do $$
begin
  perform public.confirm_shop_return_custody(
    current_setting('sherlyos.sr_id')::uuid,
    current_setting('sherlyos.sr_version')::integer
  );
  raise exception 'store keeper must not confirm shop-return custody';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('driver');
do $$
begin
  perform public.confirm_shop_return_custody(
    current_setting('sherlyos.sr_id')::uuid,
    current_setting('sherlyos.sr_version')::integer
  );
  raise exception 'driver must not confirm shop-return custody';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('godown');
do $$
declare
  payload jsonb;
  again jsonb;
  events integer;
  dash jsonb;
begin
  payload := public.confirm_shop_return_custody(
    current_setting('sherlyos.sr_id')::uuid,
    current_setting('sherlyos.sr_version')::integer
  );
  if payload ->> 'physical_custody_confirmed' is distinct from 'true' then
    raise exception 'custody confirm did not stamp confirmation';
  end if;
  if payload ->> 'physical_custody_confirmed_by_name' is null then
    raise exception 'custody actor name missing from payload';
  end if;
  if payload ->> 'physical_custody_confirmed_at' is null then
    raise exception 'custody timestamp missing from payload';
  end if;
  if payload ->> 'shop_name' is distinct from 'M54C SQL Shop' then
    raise exception 'shop name missing from payload: %', payload ->> 'shop_name';
  end if;
  if payload ->> 'status' is distinct from 'draft' then
    raise exception 'custody must not submit the report, status=%', payload ->> 'status';
  end if;

  again := public.confirm_shop_return_custody(
    current_setting('sherlyos.sr_id')::uuid,
    (payload ->> 'version')::integer
  );
  select count(*) into events
  from public.damage_report_events
  where damage_report_id = current_setting('sherlyos.sr_id')::uuid
    and action = 'custody_confirmed';
  if events is distinct from 1 then
    raise exception 'custody confirm is not idempotent, events=%', events;
  end if;

  dash := public.get_damage_dashboard();
  if jsonb_array_length(coalesce(dash -> 'queues' -> 'awaiting_custody', '[]'::jsonb)) <> 0 then
    raise exception 'confirmed shop-return still in custody queue';
  end if;
end $$;

-- Isolation fixtures for the quarantine list. Replica bypasses write guards.
set session_replication_role = replica;

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes, shop_id
)
select
  'm54c-sql-qrn', 'shop_return', branches.id, 'rejected', 2,
  (select id from fixture where name = 'godown'),
  'm54c-sql-qrn-key', 'm54c-sql-qrn-fp', 'rejected still quarantined',
  shops.id
from public.branches, public.shops
where branches.code = 'm54c_sql_gd' and shops.name = 'M54C SQL Shop';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 2, 'expired'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54c-sql-qrn'
  and products.sku = 'm54c_sql_sku'
  and crates.code = 'm54c_sql_qc';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id, crates.id,
  2, 'quarantine_intake', 'active'
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54c_sql_sku'
join public.crates on crates.code = 'm54c_sql_qc'
where damage_reports.report_number = 'm54c-sql-qrn';

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54c-sql-hold', 'storage', branches.id, 'verified', 3,
  (select id from fixture where name = 'godown'),
  'm54c-sql-hold-key', 'm54c-sql-hold-fp', 'logical hold'
from public.branches where code = 'm54c_sql_gd';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 1, 'crushed'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54c-sql-hold'
  and products.sku = 'm54c_sql_sku'
  and crates.code = 'm54c_sql_c';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id, crates.id,
  1, 'on_hand_deduction', 'active'
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54c_sql_sku'
join public.crates on crates.code = 'm54c_sql_c'
where damage_reports.report_number = 'm54c-sql-hold';

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54c-sql-other', 'storage', branches.id, 'verified', 1,
  (select id from fixture where name = 'admin'),
  'm54c-sql-other-key', 'm54c-sql-other-fp', 'other godown'
from public.branches where code = 'm54c_sql_other';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 4, 'crushed'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54c-sql-other'
  and products.sku = 'm54c_sql_sku'
  and crates.code = 'm54c_sql_c2';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id, crates.id,
  4, 'on_hand_deduction', 'active'
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54c_sql_sku'
join public.crates on crates.code = 'm54c_sql_c2'
where damage_reports.report_number = 'm54c-sql-other';

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54c-sql-dead', 'storage', branches.id, 'verified', 1,
  (select id from fixture where name = 'godown'),
  'm54c-sql-dead-key', 'm54c-sql-dead-fp', 'inactive transfer'
from public.branches where code = 'm54c_sql_dead';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 1, 'crushed'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54c-sql-dead'
  and products.sku = 'm54c_sql_sku'
  and crates.code = 'm54c_sql_cd';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id, crates.id,
  1, 'on_hand_deduction', 'active'
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54c_sql_sku'
join public.crates on crates.code = 'm54c_sql_cd'
where damage_reports.report_number = 'm54c-sql-dead';

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54c-sql-wo', 'storage', branches.id, 'verified', 1,
  (select id from fixture where name = 'godown'),
  'm54c-sql-wo-key', 'm54c-sql-wo-fp', 'written off'
from public.branches where code = 'm54c_sql_gd';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 5, 'crushed'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54c-sql-wo'
  and products.sku = 'm54c_sql_sku'
  and crates.code = 'm54c_sql_c';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id, crates.id,
  5, 'on_hand_deduction', 'written_off'
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54c_sql_sku'
join public.crates on crates.code = 'm54c_sql_c'
where damage_reports.report_number = 'm54c-sql-wo';

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54c-sql-xfer', 'storage', branches.id, 'verified', 1,
  (select id from fixture where name = 'godown'),
  'm54c-sql-xfer-key', 'm54c-sql-xfer-fp', 'transferred'
from public.branches where code = 'm54c_sql_gd';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 3, 'crushed'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54c-sql-xfer'
  and products.sku = 'm54c_sql_sku'
  and crates.code = 'm54c_sql_qc';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id, crates.id,
  3, 'on_hand_deduction', 'transferred'
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54c_sql_sku'
join public.crates on crates.code = 'm54c_sql_qc'
where damage_reports.report_number = 'm54c-sql-xfer';

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54c-sql-resv', 'loading', branches.id, 'verified', 1,
  (select id from fixture where name = 'godown'),
  'm54c-sql-resv-key', 'm54c-sql-resv-fp', 'reservation converted'
from public.branches where code = 'm54c_sql_gd';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, crates.id, 2, 'crushed'
from public.damage_reports, public.products, public.crates
where damage_reports.report_number = 'm54c-sql-resv'
  and products.sku = 'm54c_sql_sku'
  and crates.code = 'm54c_sql_c';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id, crates.id,
  2, 'reservation_conversion', 'active'
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54c_sql_sku'
join public.crates on crates.code = 'm54c_sql_c'
where damage_reports.report_number = 'm54c-sql-resv';

set session_replication_role = origin;

select pg_temp.as_user('godown');
do $$
declare
  listed jsonb;
  paged jsonb;
  classes text;
  scoped jsonb;
  totals jsonb;
  page_cases integer;
begin
  listed := public.list_damage_quarantine_inventory();
  if (listed ->> 'total')::integer < 5 then
    raise exception 'godown quarantine list too small: %', listed;
  end if;
  if exists (
    select 1 from jsonb_array_elements(listed -> 'items') item
    where item ->> 'report_number' in ('m54c-sql-other', 'm54c-sql-dead')
  ) then
    raise exception 'godown list leaked other or inactive godown';
  end if;

  select string_agg(item ->> 'isolation_class', ',')
  into classes
  from jsonb_array_elements(listed -> 'items') item;
  if classes not like '%shop_return_intake%' then
    raise exception 'missing shop-return intake class: %', classes;
  end if;
  if classes not like '%logical_hold%' then
    raise exception 'missing logical hold class: %', classes;
  end if;
  if classes not like '%reservation_converted%' then
    raise exception 'missing reservation conversion class: %', classes;
  end if;
  if classes not like '%transferred_quarantine%' then
    raise exception 'missing transferred quarantine class: %', classes;
  end if;
  if classes not like '%written_off%' then
    raise exception 'missing written-off class: %', classes;
  end if;

  totals := listed -> 'totals';
  -- 2 intake + 1 logical + 3 transferred + 2 reservation = 8. Written-off 5 is excluded.
  if (totals ->> 'current_unavailable_cases')::integer is distinct from 8 then
    raise exception 'current unavailable must exclude written-off: %', totals;
  end if;
  if (totals ->> 'written_off_cases')::integer is distinct from 5 then
    raise exception 'written-off cases missing from historical total: %', totals;
  end if;
  if (totals ->> 'logical_hold_cases')::integer is distinct from 1 then
    raise exception 'logical hold cases wrong: %', totals;
  end if;
  if (totals ->> 'shop_return_intake_cases')::integer is distinct from 2 then
    raise exception 'shop-return intake cases wrong: %', totals;
  end if;
  if (totals ->> 'transferred_quarantine_cases')::integer is distinct from 3 then
    raise exception 'transferred quarantine cases wrong: %', totals;
  end if;
  if (totals ->> 'reservation_converted_cases')::integer is distinct from 2 then
    raise exception 'reservation converted cases wrong: %', totals;
  end if;
  if (totals ->> 'hold_rows')::integer is distinct from (listed ->> 'total')::integer then
    raise exception 'hold_rows must match total';
  end if;

  paged := public.list_damage_quarantine_inventory(1, 1);
  if jsonb_array_length(paged -> 'items') is distinct from 1 then
    raise exception 'page size 1 must return one row: %', paged;
  end if;
  if (paged ->> 'total')::integer is distinct from (listed ->> 'total')::integer then
    raise exception 'pagination must not shrink hold-row total';
  end if;
  if (paged -> 'totals' ->> 'current_unavailable_cases')::integer
    is distinct from (totals ->> 'current_unavailable_cases')::integer
  then
    raise exception 'pagination must not shrink class totals: % vs %', paged -> 'totals', totals;
  end if;
  select (item ->> 'quantity_cases')::integer
  into page_cases
  from jsonb_array_elements(paged -> 'items') item
  limit 1;
  if (paged ->> 'total')::integer > 1
    and page_cases is not distinct from (paged -> 'totals' ->> 'current_unavailable_cases')::integer
  then
    raise exception 'page quantity must not equal filter-wide unavailable when more holds exist';
  end if;

  scoped := public.list_damage_quarantine_inventory(
    1, 50, (select id from public.branches where code = 'm54c_sql_other')
  );
  if (scoped ->> 'total')::integer is distinct from 0 then
    raise exception 'godown filter must not reveal unassigned branch';
  end if;
end $$;

select pg_temp.as_user('admin');
do $$
declare
  listed jsonb;
begin
  listed := public.list_damage_quarantine_inventory(
    1, 50, (select id from public.branches where code = 'm54c_sql_dead')
  );
  if not exists (
    select 1 from jsonb_array_elements(listed -> 'items') item
    where item ->> 'report_number' = 'm54c-sql-dead'
      and item ->> 'godown_active' = 'false'
  ) then
    raise exception 'admin must still see authorized inactive godown holds: %', listed;
  end if;
end $$;

select pg_temp.as_user('driver');
do $$
begin
  perform public.list_damage_quarantine_inventory();
  raise exception 'driver must not list quarantine inventory';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('sales');
do $$
begin
  perform public.list_damage_quarantine_inventory();
  raise exception 'salesperson must not list quarantine inventory';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('godown');
do $$
begin
  perform public.transfer_verified_damage_to_quarantine(
    (select id from public.damage_reports where report_number = 'm54c-sql-dead'),
    1,
    'm54c-sql-dead-xfer'
  );
  raise exception 'inactive godown transfer must fail';
exception
  when insufficient_privilege then null;
  when check_violation then null;
  when sqlstate '23514' then null;
end $$;

do $$
declare
  ready text;
begin
  select value::text into ready
  from public.app_configuration where key = 'damage.stock_hold_ready';
  if ready is distinct from 'false' then
    raise exception 'readiness flag changed: %', ready;
  end if;
end $$;

rollback;
