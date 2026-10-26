-- M5.4E local exceptional request/approval/posting proofs.
-- Rolls back. Does not flip damage.stock_hold_ready or lot cutover flags.
-- Shared Docker flags: run sequentially with other M5.2–M5.4E SQL/HTTP/concurrency
-- suites. Session advisory lock serializes against 4E HTTP/concurrency.
select pg_advisory_lock(hashtext('sherlyos.m5.stock_flag_tests'));
begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);
grant select on fixture to authenticated, anon, service_role;

create temp table m54e_req (
  name text primary key,
  id uuid not null
);
grant all on m54e_req to authenticated;

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
  fixture.id, 'authenticated', 'authenticated',
  fixture.name || '.m54esql@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M54E SQL Admin', true)
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
    target, target::text || '/' || gen_random_uuid()::text,
    (select id from fixture where name = 'godown'), 'image/jpeg', 4, clock_timestamp()
  );
end;
$$;

set session_replication_role = replica;

insert into public.branches (code, name, is_active)
values
  ('m54e_sql_gd', 'M54E SQL Godown', true),
  ('m54e_sql_other', 'M54E SQL Other', true),
  ('m54e_sql_dead', 'M54E SQL Inactive', false);

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code = 'm54e_sql_gd'
  and fixture.name in ('admin', 'godown', 'verifier', 'keeper', 'driver');

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select (select id from fixture where name = 'other'), branches.id,
  (select id from fixture where name = 'admin')
from public.branches where code = 'm54e_sql_other';

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select (select id from fixture where name = 'verifier'), branches.id,
  (select id from fixture where name = 'admin')
from public.branches where code = 'm54e_sql_dead';

insert into public.zones (branch_id, code, name, is_active)
select id, 'm54e_sql_z', 'M54E Zone', true from public.branches where code = 'm54e_sql_gd';
insert into public.zones (branch_id, code, name, is_active)
select id, 'm54e_sql_qrn', 'Quarantine', true
from public.branches where code = 'm54e_sql_gd';
insert into public.zones (branch_id, code, name, is_active)
select id, 'm54e_sql_z2', 'Other Zone', true from public.branches where code = 'm54e_sql_other';

insert into public.crates (zone_id, code, name, is_active)
select id, 'm54e_sql_c', 'M54E Crate', true from public.zones where code = 'm54e_sql_z';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm54e_sql_qc', 'Quarantine crate', true
from public.zones where code = 'm54e_sql_qrn';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm54e_sql_c2', 'Other Crate', true from public.zones where code = 'm54e_sql_z2';

insert into public.products (sku, name, is_active) values ('m54e_sql_sku', 'M54E SQL Product', true);
insert into public.shops (name, is_active) values ('M54E SQL Shop', true);

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
)
select
  report_number, 'storage', branches.id, 'verified', 3,
  (select id from fixture where name = 'godown'),
  (select id from fixture where name = 'verifier'), now(),
  report_number || '-key', report_number || '-fp', report_number
from public.branches
cross join (values
  ('m54e-sql-des'),
  ('m54e-sql-sup'),
  ('m54e-sql-wo'),
  ('m54e-sql-dup'),
  ('m54e-sql-stale'),
  ('m54e-sql-noev'),
  ('m54e-sql-noh'),
  ('m54e-sql-rej')
) r(report_number)
where branches.code = 'm54e_sql_gd';

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
)
select
  'm54e-sql-dead', 'storage', branches.id, 'verified', 3,
  (select id from fixture where name = 'godown'),
  (select id from fixture where name = 'verifier'), now(),
  'm54e-sql-dead-key', 'm54e-sql-dead-fp', 'inactive godown'
from public.branches where code = 'm54e_sql_dead';

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes, shop_id,
  rejected_at, rejected_by, rejection_reason
)
select
  'm54e-sql-sr', 'shop_return', branches.id, 'rejected', 3,
  (select id from fixture where name = 'godown'),
  'm54e-sql-sr-key', 'm54e-sql-sr-fp', 'rejected shop return', shops.id,
  now(), (select id from fixture where name = 'verifier'), 'not accepted'
from public.branches, public.shops
where branches.code = 'm54e_sql_gd' and shops.name = 'M54E SQL Shop';

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'm54e-sql-in', 'refill_supply', branches.id, 'verified', 3,
  (select id from fixture where name = 'godown'),
  'm54e-sql-in-key', 'm54e-sql-in-fp', 'inbound'
from public.branches where code = 'm54e_sql_gd';

insert into public.damage_report_lines (
  damage_report_id, product_id, crate_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id,
  case when damage_reports.report_number = 'm54e-sql-sr' then qc.id else crates.id end,
  2, 'crushed'
from public.damage_reports
join public.products on products.sku = 'm54e_sql_sku'
join public.crates on crates.code = 'm54e_sql_c'
join public.crates qc on qc.code = 'm54e_sql_qc'
where damage_reports.report_number like 'm54e-sql-%';

insert into public.damage_stock_holds (
  damage_report_id, damage_report_line_id, product_id, crate_id,
  quantity_cases, hold_kind, status
)
select
  damage_reports.id, damage_report_lines.id, products.id,
  damage_report_lines.crate_id, 2,
  case when damage_reports.scenario = 'shop_return' then 'quarantine_intake' else 'on_hand_deduction' end,
  'active'
from public.damage_reports
join public.damage_report_lines on damage_report_lines.damage_report_id = damage_reports.id
join public.products on products.sku = 'm54e_sql_sku'
where damage_reports.report_number in (
  'm54e-sql-des', 'm54e-sql-sup', 'm54e-sql-wo', 'm54e-sql-dup',
  'm54e-sql-stale', 'm54e-sql-sr', 'm54e-sql-noev', 'm54e-sql-rej',
  'm54e-sql-dead'
);

select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54e-sql-des'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54e-sql-sup'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54e-sql-wo'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54e-sql-dup'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54e-sql-stale'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54e-sql-sr'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54e-sql-in'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54e-sql-noh'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54e-sql-rej'));
select pg_temp.stamp_evidence((select id from public.damage_reports where report_number = 'm54e-sql-dead'));

set session_replication_role = origin;

select pg_temp.as_user('admin');
set local role authenticated;
select public.post_opening_stock(
  (select id from public.products where sku = 'm54e_sql_sku'),
  (select id from public.crates where code = 'm54e_sql_c'),
  30, 'm54e-sql-open', 'M54E SQL opening'
);
select public.post_opening_stock(
  (select id from public.products where sku = 'm54e_sql_sku'),
  (select id from public.crates where code = 'm54e_sql_qc'),
  10, 'm54e-sql-open-q', 'M54E SQL quarantine opening'
);
reset role;
set session_replication_role = replica;
update public.zones set location_role = 'quarantine' where code = 'm54e_sql_qrn';
update public.crates set location_role = 'quarantine' where code = 'm54e_sql_qc';
set session_replication_role = origin;
select pg_temp.as_user('admin');
set local role authenticated;

do $$
begin
  if exists (
    select 1 from public.app_configuration
    where key = 'damage.stock_hold_ready' and value = 'true'::jsonb
  ) then
    raise exception 'damage.stock_hold_ready must remain false';
  end if;
end $$;

-- Unauthorized roles cannot request.
select pg_temp.as_user('keeper');
set local role authenticated;
do $$
begin
  perform public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-des'),
    3, 'destroy', 'need destroy', 'm54e-req-keeper'
  );
  raise exception 'keeper request must fail';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('admin');
do $$
begin
  perform public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-des'),
    3, 'destroy', 'admin request', 'm54e-req-admin'
  );
  raise exception 'admin request must fail';
exception
  when insufficient_privilege then null;
end $$;

-- Inbound has no on-hand stock.
select pg_temp.as_user('verifier');
do $$
begin
  perform public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-in'),
    3, 'destroy', 'inbound destroy', 'm54e-req-in'
  );
  raise exception 'inbound request must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%no on-hand stock%' then raise; end if;
end $$;

-- Authorized destroy request + same-key replay.
do $$
declare
  payload jsonb;
  replay jsonb;
  req_id uuid;
begin
  payload := public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-des'),
    3, 'destroy', 'destroy damaged soap', 'm54e-req-des'
  );
  replay := public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-des'),
    1, 'destroy', 'destroy damaged soap', 'm54e-req-des'
  );
  req_id := (payload -> 'exceptional_requests' -> 0 ->> 'id')::uuid;
  insert into m54e_req (name, id) values ('des', req_id)
  on conflict (name) do update set id = excluded.id;
  if payload -> 'exceptional_requests' -> 0 ->> 'status' is distinct from 'requested' then
    raise exception 'request status missing';
  end if;
  if replay is null then
    raise exception 'request replay missing';
  end if;
end $$;

-- Duplicate open request is rejected.
do $$
begin
  perform public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-des'),
    3, 'return_supplier', 'second open', 'm54e-req-des-2'
  );
  raise exception 'second open request must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%already open%' then raise; end if;
end $$;

-- Admin cannot execute. GM cannot approve.
select pg_temp.as_user('admin');
do $$
declare
  req uuid;
begin
  select id into req from m54e_req where name = 'des';
  perform public.post_exceptional_damage_disposition(req, 1, 'm54e-post-admin');
  raise exception 'admin post must fail';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('verifier');
do $$
declare
  req uuid;
begin
  select id into req from m54e_req where name = 'des';
  perform public.approve_exceptional_damage_disposition(req, 1);
  raise exception 'gm approve must fail';
exception
  when insufficient_privilege then null;
end $$;

-- Admin approval + stale-version completed identification.
select pg_temp.as_user('admin');
do $$
declare
  req uuid;
  payload jsonb;
  replay jsonb;
begin
  select id into req from m54e_req where name = 'des';
  payload := public.approve_exceptional_damage_disposition(req, 1);
  replay := public.approve_exceptional_damage_disposition(req, 1);
  if payload -> 'exceptional_requests' -> 0 ->> 'status' is distinct from 'approved' then
    raise exception 'approve failed';
  end if;
  if replay is null then
    raise exception 'approve replay missing';
  end if;
end $$;

-- Missing evidence / missing holds / inactive godown.
select pg_temp.as_user('verifier');
do $$
begin
  perform public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-noev'),
    3, 'destroy', 'no evidence', 'm54e-req-noev'
  );
  raise exception 'missing evidence request must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%photographic evidence%' then raise; end if;
end $$;

do $$
begin
  perform public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-noh'),
    3, 'destroy', 'no holds', 'm54e-req-noh'
  );
  raise exception 'missing holds request must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%no isolated%' then raise; end if;
end $$;

do $$
begin
  perform public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-dead'),
    3, 'destroy', 'inactive godown', 'm54e-req-dead'
  );
  raise exception 'inactive godown request must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%inactive%' then raise; end if;
  when insufficient_privilege then
    null;
end $$;

-- Execution before approval is denied on a separate request.
select pg_temp.as_user('verifier');
do $$
declare
  payload jsonb;
  req uuid;
begin
  payload := public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-stale'),
    3, 'destroy', 'wait for approval', 'm54e-req-stale'
  );
  req := (payload -> 'exceptional_requests' -> 0 ->> 'id')::uuid;
  insert into m54e_req (name, id) values ('stale', req)
  on conflict (name) do update set id = excluded.id;
end $$;

do $$
declare
  req uuid;
begin
  select id into req from m54e_req where name = 'stale';
  perform public.post_exceptional_damage_disposition(req, 1, 'm54e-post-early');
  raise exception 'unapproved post must fail';
exception
  when insufficient_privilege then
    if sqlerrm not like '%not approved%' then raise; end if;
end $$;

-- Open exceptional request blocks ordinary write-off.
do $$
begin
  perform public.post_ordinary_damage_writeoff(
    (select id from public.damage_reports where report_number = 'm54e-sql-stale'),
    3, 'm54e-wo-stale'
  );
  raise exception 'ordinary write-off during open exceptional must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%already open%' then raise; end if;
end $$;

-- Admin rejection + completed identification.
select pg_temp.as_user('verifier');
do $$
declare
  payload jsonb;
  req uuid;
  replay jsonb;
begin
  payload := public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-rej'),
    3, 'return_supplier', 'maybe return', 'm54e-req-rej'
  );
  req := (payload -> 'exceptional_requests' -> 0 ->> 'id')::uuid;
  insert into m54e_req (name, id) values ('rej', req)
  on conflict (name) do update set id = excluded.id;
  perform pg_temp.as_user('admin');
  payload := public.reject_exceptional_damage_disposition(req, 1, 'not justified');
  replay := public.reject_exceptional_damage_disposition(req, 99, '');
  if payload -> 'exceptional_requests' -> 0 ->> 'status' is distinct from 'rejected' then
    raise exception 'reject failed';
  end if;
  if replay is null then
    raise exception 'reject replay missing';
  end if;
end $$;

select pg_temp.as_user('verifier');
do $$
declare
  req uuid;
begin
  select id into req from m54e_req where name = 'rej';
  perform public.post_exceptional_damage_disposition(req, 2, 'm54e-post-rej');
  raise exception 'rejected request must not post';
exception
  when insufficient_privilege then
    if sqlerrm not like '%not approved%' then raise; end if;
end $$;

-- Destroy posting + lost HTTP + stale version + different key.
select pg_temp.as_user('verifier');
do $$
declare
  req uuid;
  payload jsonb;
  lost jsonb;
  stale jsonb;
  other jsonb;
  tx_count integer;
  hold_status text;
  on_hand integer;
begin
  select id into req from m54e_req where name = 'des';
  payload := public.post_exceptional_damage_disposition(req, 2, 'm54e-post-des');
  lost := public.post_exceptional_damage_disposition(req, 2, 'm54e-post-des');
  stale := public.post_exceptional_damage_disposition(req, 1, 'm54e-post-des');
  other := public.post_exceptional_damage_disposition(req, 99, 'm54e-post-des-b');
  select count(*) into tx_count
  from public.stock_transactions
  where damage_report_id = (select id from public.damage_reports where report_number = 'm54e-sql-des')
    and damage_posting_kind = 'exceptional_writeoff';
  if tx_count <> 1 then
    raise exception 'destroy must be exact-once, tx=%', tx_count;
  end if;
  select status into hold_status
  from public.damage_stock_holds
  where damage_report_id = (select id from public.damage_reports where report_number = 'm54e-sql-des');
  if hold_status is distinct from 'written_off' then
    raise exception 'destroy hold status=%', hold_status;
  end if;
  select quantity into on_hand
  from public.stock_balances
  join public.crates on crates.id = stock_balances.crate_id
  join public.products on products.id = stock_balances.product_id
  where crates.code = 'm54e_sql_c' and products.sku = 'm54e_sql_sku';
  if on_hand < 0 then
    raise exception 'negative on-hand after destroy';
  end if;
  if payload is null or lost is null or stale is null or other is null then
    raise exception 'destroy replay missing';
  end if;
end $$;

-- Supplier return keeps stock unavailable.
select pg_temp.as_user('verifier');
do $$
declare
  payload jsonb;
  req uuid;
begin
  payload := public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-sup'),
    3, 'return_supplier', 'return crushed soap', 'm54e-req-sup'
  );
  req := (payload -> 'exceptional_requests' -> 0 ->> 'id')::uuid;
  insert into m54e_req (name, id) values ('sup', req)
  on conflict (name) do update set id = excluded.id;
  perform pg_temp.as_user('admin');
  perform public.approve_exceptional_damage_disposition(req, 1);
  perform pg_temp.as_user('verifier');
  payload := public.post_exceptional_damage_disposition(req, 2, 'm54e-post-sup');
  if (select status from public.damage_stock_holds
      where damage_report_id = (select id from public.damage_reports where report_number = 'm54e-sql-sup'))
     is distinct from 'returned_supplier' then
    raise exception 'supplier return hold not marked';
  end if;
  if exists (
    select 1 from public.stock_transactions
    where damage_report_id = (select id from public.damage_reports where report_number = 'm54e-sql-sup')
      and transaction_type is distinct from 'ADJUSTMENT'
  ) then
    raise exception 'supplier return must be adjustment';
  end if;
end $$;

-- Rejected shop-return quarantine can be destroyed, not restocked.
select pg_temp.as_user('verifier');
do $$
declare
  payload jsonb;
  req uuid;
  remaining integer;
begin
  payload := public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-sr'),
    3, 'destroy', 'destroy rejected return', 'm54e-req-sr'
  );
  req := (payload -> 'exceptional_requests' -> 0 ->> 'id')::uuid;
  insert into m54e_req (name, id) values ('sr', req)
  on conflict (name) do update set id = excluded.id;
  perform pg_temp.as_user('admin');
  perform public.approve_exceptional_damage_disposition(req, 1);
  perform pg_temp.as_user('verifier');
  perform public.post_exceptional_damage_disposition(req, 2, 'm54e-post-sr');
  select count(*) into remaining
  from public.damage_stock_holds
  where damage_report_id = (select id from public.damage_reports where report_number = 'm54e-sql-sr')
    and status in ('active', 'transferred');
  if remaining <> 0 then
    raise exception 'rejected shop-return still active after destroy';
  end if;
end $$;

-- Ordinary write-off blocks exceptional request.
select pg_temp.as_user('verifier');
do $$
begin
  perform public.post_ordinary_damage_writeoff(
    (select id from public.damage_reports where report_number = 'm54e-sql-wo'),
    3, 'm54e-wo'
  );
  perform public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-wo'),
    3, 'destroy', 'after ordinary', 'm54e-req-wo'
  );
  raise exception 'exceptional after ordinary must fail';
exception
  when sqlstate '23514' then
    if sqlerrm not like '%ordinary write-off%' and sqlerrm not like '%no isolated%' then
      raise;
    end if;
end $$;

-- Cross-godown list denial.
select pg_temp.as_user('other');
do $$
declare
  listed jsonb;
begin
  listed := public.list_exceptional_damage_requests(1, 50, null, null, null, null, null, null, null);
  if listed -> 'items' @> jsonb_build_array(jsonb_build_object('report_number', 'm54e-sql-des')) then
    raise exception 'other godown listed home request';
  end if;
end $$;

-- Admin queue sees requests.
select pg_temp.as_user('admin');
do $$
declare
  listed jsonb;
begin
  listed := public.list_exceptional_damage_requests(1, 50, null, 'posted', 'destroy', null, 'm54e-sql-des', null, null);
  if (listed ->> 'total')::integer < 1 then
    raise exception 'admin queue missed posted destroy';
  end if;
end $$;

select pg_temp.as_user('sales');
do $$
begin
  perform public.list_exceptional_damage_requests();
  raise exception 'sales list must fail';
exception
  when insufficient_privilege then null;
end $$;

-- Reused request key is a different operation, not a completed replay.
select pg_temp.as_user('verifier');
do $$
begin
  perform public.request_exceptional_damage_disposition(
    (select id from public.damage_reports where report_number = 'm54e-sql-dup'),
    3, 'destroy', 'reuse other report key', 'm54e-req-des'
  );
  raise exception 'foreign request key must fail';
exception
  when insufficient_privilege then null;
end $$;

-- Ledger counts below run as postgres so RLS cannot hide rows from an
-- unauthorized caller and produce a false zero.
reset role;
create temp table m54e_tx (name text primary key, n integer not null);
insert into m54e_tx (name, n)
select 'des', count(*)
from public.stock_transactions
where damage_report_id = (select id from public.damage_reports where report_number = 'm54e-sql-des')
  and damage_posting_kind = 'exceptional_writeoff';
do $$
begin
  if (select n from m54e_tx where name = 'des') <> 1 then
    raise exception 'destroy ledger missing before replay-security checks';
  end if;
end $$;

-- Cross-godown completed post replay must not disclose or re-post.
select pg_temp.as_user('other');
set local role authenticated;
do $$
declare
  req uuid;
begin
  select id into req from m54e_req where name = 'des';
  perform public.post_exceptional_damage_disposition(req, 2, 'stolen-post');
  raise exception 'cross-godown post replay must fail';
exception
  when insufficient_privilege then null;
end $$;
reset role;
do $$
declare
  tx_after integer;
begin
  select count(*) into tx_after
  from public.stock_transactions
  where damage_report_id = (select id from public.damage_reports where report_number = 'm54e-sql-des')
    and damage_posting_kind = 'exceptional_writeoff';
  if tx_after is distinct from (select n from m54e_tx where name = 'des') then
    raise exception 'cross-godown replay posted stock';
  end if;
end $$;

-- Permission revocation blocks completed-operation replay.
reset role;
delete from public.user_roles
where user_id = (select id from fixture where name = 'verifier');
select pg_temp.as_user('verifier');
set local role authenticated;
do $$
declare
  req uuid;
begin
  select id into req from m54e_req where name = 'des';
  perform public.post_exceptional_damage_disposition(req, 2, 'm54e-post-des');
  raise exception 'revoked verify replay must fail';
exception
  when insufficient_privilege then null;
end $$;
reset role;
do $$
declare
  tx_after integer;
begin
  select count(*) into tx_after
  from public.stock_transactions
  where damage_report_id = (select id from public.damage_reports where report_number = 'm54e-sql-des')
    and damage_posting_kind = 'exceptional_writeoff';
  if tx_after is distinct from (select n from m54e_tx where name = 'des') then
    raise exception 'revoked replay posted stock';
  end if;
end $$;
reset role;
insert into public.user_roles (user_id, role_id, assigned_by)
select (select id from fixture where name = 'verifier'), roles.id,
  (select id from fixture where name = 'admin')
from public.roles where roles.code = 'godown_manager'
on conflict do nothing;

-- Lost assignment blocks completed-operation replay.
delete from public.user_branch_assignments
where user_id = (select id from fixture where name = 'verifier')
  and branch_id = (select id from public.branches where code = 'm54e_sql_gd');
select pg_temp.as_user('verifier');
set local role authenticated;
do $$
declare
  req uuid;
begin
  select id into req from m54e_req where name = 'des';
  perform public.post_exceptional_damage_disposition(req, 2, 'm54e-post-des');
  raise exception 'unassigned replay must fail';
exception
  when insufficient_privilege then null;
end $$;
reset role;
insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select (select id from fixture where name = 'verifier'), branches.id,
  (select id from fixture where name = 'admin')
from public.branches where code = 'm54e_sql_gd'
on conflict do nothing;

-- Deactivation after posting: replay is read-only (denied for inactive
-- assignment) and must not create a second ledger row. New posting fails.
select pg_temp.as_user('admin');
set local role authenticated;
do $$
begin
  perform public.set_branch_active(
    (select id from public.branches where code = 'm54e_sql_gd'),
    false
  );
end $$;

select pg_temp.as_user('verifier');
do $$
declare
  req uuid;
begin
  select id into req from m54e_req where name = 'des';
  perform public.post_exceptional_damage_disposition(req, 2, 'm54e-post-des');
  raise exception 'inactive replay must not succeed for assigned GM';
exception
  when insufficient_privilege then null;
  when sqlstate '23514' then
    if sqlerrm not like '%inactive%' then raise; end if;
end $$;
reset role;
do $$
declare
  tx_after integer;
begin
  select count(*) into tx_after
  from public.stock_transactions
  where damage_report_id = (select id from public.damage_reports where report_number = 'm54e-sql-des')
    and damage_posting_kind = 'exceptional_writeoff';
  if tx_after is distinct from (select n from m54e_tx where name = 'des') or tx_after <> 1 then
    raise exception 'deactivated replay changed ledger tx=%', tx_after;
  end if;
end $$;

select pg_temp.as_user('admin');
do $$
declare
  req uuid;
begin
  select id into req from m54e_req where name = 'stale';
  perform public.approve_exceptional_damage_disposition(req, 1);
end $$;

select pg_temp.as_user('verifier');
set local role authenticated;
do $$
declare
  req uuid;
begin
  select id into req from m54e_req where name = 'stale';
  perform public.post_exceptional_damage_disposition(req, 2, 'm54e-post-stale-dead');
  raise exception 'inactive new post must fail';
exception
  when insufficient_privilege then null;
  when sqlstate '23514' then
    if sqlerrm not like '%inactive%' then raise; end if;
end $$;
reset role;
do $$
declare
  tx_count integer;
begin
  select count(*) into tx_count
  from public.stock_transactions
  where damage_report_id = (select id from public.damage_reports where report_number = 'm54e-sql-stale')
    and damage_posting_kind = 'exceptional_writeoff';
  if tx_count <> 0 then
    raise exception 'inactive new post wrote ledger tx=%', tx_count;
  end if;
end $$;

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
