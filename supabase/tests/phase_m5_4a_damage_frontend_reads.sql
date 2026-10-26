-- M5.4A local read-contract security and date-pagination tests.
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
  ('driver2', gen_random_uuid()),
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
  fixture.name || '.m54asql@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M54A SQL Admin', true)
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
  when 'driver2' then 'delivery_person'
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
values ('m54a_sql_gd', 'M54A SQL Godown', true);

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code = 'm54a_sql_gd'
  and fixture.name in ('admin', 'godown', 'keeper', 'driver');

insert into public.zones (branch_id, code, name, is_active)
select id, 'm54a_sql_z', 'M54A SQL Zone', true from public.branches where code = 'm54a_sql_gd';

insert into public.crates (zone_id, code, name, is_active)
select id, 'm54a_sql_c', 'M54A SQL Crate', true from public.zones where code = 'm54a_sql_z';

insert into public.products (sku, name, is_active)
values ('m54a_sql_sku', 'M54A SQL Product', true);

insert into public.shops (name, is_active)
values ('M54A SQL Shop', true);

insert into public.orders (
  order_number, shop_id, branch_id, status, source, version, created_by,
  idempotency_key, verified_by, verified_at, submitted_by, submitted_at
)
select
  'm54a-sql-ord', shops.id, branches.id, 'verified', 'accounts', 1,
  (select id from fixture where name = 'admin'),
  'm54a-sql-ord-key', (select id from fixture where name = 'admin'), now(),
  (select id from fixture where name = 'admin'), now()
from public.shops, public.branches
where shops.name = 'M54A SQL Shop' and branches.code = 'm54a_sql_gd';

insert into public.stock_picking_requests (
  request_number, order_id, branch_id, status, version, created_by, idempotency_key
)
select
  'm54a-sql-pk', orders.id, orders.branch_id, 'ready_for_dispatch', 1,
  (select id from fixture where name = 'godown'), 'm54a-sql-pk-key'
from public.orders where order_number = 'm54a-sql-ord';

insert into public.stock_dispatch_requests (
  request_number, order_id, picking_request_id, branch_id, status, version,
  assigned_to, assigned_by, assigned_at, created_by, idempotency_key, request_fingerprint
)
select
  'm54a-sql-dsp', orders.id, stock_picking_requests.id, orders.branch_id, 'in_transit', 1,
  (select id from fixture where name = 'driver'),
  (select id from fixture where name = 'godown'),
  now(),
  (select id from fixture where name = 'godown'),
  'm54a-sql-dsp-key',
  'm54a-sql-dsp-fp'
from public.orders
join public.stock_picking_requests on stock_picking_requests.order_id = orders.id
where orders.order_number = 'm54a-sql-ord';

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes, submitted_at, submitted_by, created_at
)
select
  'm54a-sql-store', 'storage', branches.id, 'submitted', 1,
  (select id from fixture where name = 'keeper'),
  'm54a-sql-store-key', 'm54a-sql-store-fp', 'storage fixture', now(),
  (select id from fixture where name = 'keeper'),
  timestamptz '2026-10-20 12:00:00+00'
from public.branches where code = 'm54a_sql_gd';

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id, dispatch_id,
  idempotency_key, request_fingerprint, notes, submitted_at, submitted_by, created_at
)
select
  'm54a-sql-trn', 'transit', branches.id, 'submitted', 1,
  (select id from fixture where name = 'driver'),
  stock_dispatch_requests.id,
  'm54a-sql-trn-key', 'm54a-sql-trn-fp', 'transit fixture', now(),
  (select id from fixture where name = 'driver'),
  timestamptz '2026-10-20 13:00:00+00'
from public.branches
join public.stock_dispatch_requests on stock_dispatch_requests.branch_id = branches.id
where branches.code = 'm54a_sql_gd'
  and stock_dispatch_requests.request_number = 'm54a-sql-dsp';

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes, submitted_at, submitted_by, created_at
)
select
  'm54a-sql-p' || to_char(gs, 'FM00'),
  'storage',
  branches.id,
  'submitted',
  1,
  (select id from fixture where name = 'keeper'),
  'm54a-sql-p' || to_char(gs, 'FM00') || '-key',
  'm54a-sql-p' || to_char(gs, 'FM00') || '-fp',
  'paged fixture',
  now(),
  (select id from fixture where name = 'keeper'),
  timestamptz '2026-09-01 12:00:00+00' + (gs || ' minutes')::interval
from public.branches
cross join generate_series(1, 26) as gs
where branches.code = 'm54a_sql_gd';

insert into public.damage_evidence (
  id, damage_report_id, storage_path, mime_type, uploaded_by, uploaded_at, verified_at, note
)
select
  ev_id,
  damage_reports.id,
  damage_reports.id::text || '/' || ev_id::text,
  'image/jpeg',
  (select id from fixture where name = 'keeper'),
  now(),
  now(),
  'finalized'
from public.damage_reports
cross join (select gen_random_uuid() as ev_id) ids
where report_number = 'm54a-sql-store';

insert into public.damage_evidence (
  id, damage_report_id, storage_path, mime_type, uploaded_by, uploaded_at, note
)
select
  ev_id,
  damage_reports.id,
  damage_reports.id::text || '/' || ev_id::text,
  'image/jpeg',
  (select id from fixture where name = 'keeper'),
  now(),
  'not finalized'
from public.damage_reports
cross join (select gen_random_uuid() as ev_id) ids
where report_number = 'm54a-sql-store';

select set_config(
  'sherlyos.store_id',
  (select id::text from public.damage_reports where report_number = 'm54a-sql-store'),
  true
);
select set_config(
  'sherlyos.trn_id',
  (select id::text from public.damage_reports where report_number = 'm54a-sql-trn'),
  true
);
select set_config(
  'sherlyos.final_ev',
  (
    select id::text from public.damage_evidence
    where damage_report_id = current_setting('sherlyos.store_id')::uuid
      and verified_at is not null
  ),
  true
);
select set_config(
  'sherlyos.draft_ev',
  (
    select id::text from public.damage_evidence
    where damage_report_id = current_setting('sherlyos.store_id')::uuid
      and verified_at is null
  ),
  true
);

set session_replication_role = origin;

do $$
begin
  if not exists (
    select 1 from pg_class
    join pg_namespace on pg_namespace.oid = pg_class.relnamespace
    where pg_namespace.nspname = 'public'
      and pg_class.relname = 'damage_reports'
      and pg_class.relforcerowsecurity
  ) then
    raise exception 'damage_reports must FORCE RLS';
  end if;
end $$;

set local role authenticated;

-- Server-side date filter must change totals and page occupancy together.
select pg_temp.as_user('godown');
do $$
declare
  page1 jsonb;
  page2 jsonb;
begin
  page1 := public.list_damage_reports(1, 10, null, null, null, null, '2026-09-01', '2026-09-01');
  page2 := public.list_damage_reports(2, 10, null, null, null, null, '2026-09-01', '2026-09-01');
  if (page1 ->> 'total')::integer is distinct from 26 then
    raise exception 'date filter total must be 26, got %', page1 ->> 'total';
  end if;
  if jsonb_array_length(page1 -> 'items') is distinct from 10 then
    raise exception 'page 1 must contain 10 rows';
  end if;
  if jsonb_array_length(page2 -> 'items') is distinct from 10 then
    raise exception 'page 2 must contain 10 rows';
  end if;
  if (page1 -> 'items' -> 0 ->> 'id') is not distinct from (page2 -> 'items' -> 0 ->> 'id') then
    raise exception 'page 2 must not repeat page 1 rows';
  end if;
end $$;

-- Assigned driver sees only the transit report, never storage history.
select pg_temp.as_user('driver');
do $$
declare
  listed jsonb;
  dash jsonb;
  payload jsonb;
  evidence jsonb;
begin
  listed := public.list_damage_reports();
  if (listed ->> 'total')::integer is distinct from 1 then
    raise exception 'driver list must be transit-only, got %', listed ->> 'total';
  end if;
  if listed -> 'items' -> 0 ->> 'report_number' is distinct from 'm54a-sql-trn' then
    raise exception 'driver list leaked a non-transit report';
  end if;

  dash := public.get_damage_dashboard();
  if (dash #>> '{totals,reports}')::integer is distinct from 1 then
    raise exception 'driver dashboard must not count unauthorized reports: %', dash;
  end if;

  payload := public.get_damage_report(current_setting('sherlyos.trn_id')::uuid);
  if payload ->> 'scenario' is distinct from 'transit' then
    raise exception 'driver detail must be the assigned transit report';
  end if;

  begin
    perform public.get_damage_report(current_setting('sherlyos.store_id')::uuid);
    raise exception 'driver must not read a storage report';
  exception
    when insufficient_privilege then null;
  end;

  evidence := payload -> 'evidence';
  if jsonb_typeof(evidence) is distinct from 'array' then
    evidence := '[]'::jsonb;
  end if;
end $$;

-- Unassigned driver and sales cannot use the dashboard or photo locator.
select pg_temp.as_user('driver2');
do $$
begin
  perform public.get_damage_report(current_setting('sherlyos.trn_id')::uuid);
  raise exception 'unassigned driver must not read another transit report';
exception
  when insufficient_privilege then null;
end $$;

select pg_temp.as_user('sales');
do $$
declare
  visible integer;
  evidence_id uuid;
begin
  select count(*) into visible from public.damage_reports;
  if visible <> 0 then
    raise exception 'salesperson must not see damage rows through RLS: %', visible;
  end if;

  begin
    perform public.get_damage_dashboard();
    raise exception 'salesperson must not execute get_damage_dashboard';
  exception
    when insufficient_privilege then null;
  end;

  select damage_evidence.id into evidence_id
  from public.damage_evidence
  where damage_evidence.id = current_setting('sherlyos.final_ev')::uuid;
  if evidence_id is not null then
    raise exception 'salesperson must not read evidence metadata through RLS';
  end if;

  begin
    perform public.get_damage_photo_url(current_setting('sherlyos.final_ev')::uuid);
    raise exception 'salesperson must not locate damage photos';
  exception
    when insufficient_privilege then null;
  end;
end $$;

-- Finalized evidence locator requires report ACL. Draft evidence is omitted
-- from payload and rejected by get_damage_photo_url.
select pg_temp.as_user('godown');
do $$
declare
  payload jsonb;
  finalized uuid;
  draft uuid;
  located jsonb;
begin
  payload := public.get_damage_report(current_setting('sherlyos.store_id')::uuid);
  if jsonb_array_length(coalesce(payload -> 'evidence', '[]'::jsonb)) is distinct from 1 then
    raise exception 'payload must expose finalized evidence only: %', payload -> 'evidence';
  end if;
  if payload -> 'evidence' -> 0 ->> 'finalized' is distinct from 'true' then
    raise exception 'payload evidence must be finalized';
  end if;
  if payload -> 'evidence' -> 0 ? 'storage_path' then
    raise exception 'payload must not include storage_path';
  end if;

  finalized := current_setting('sherlyos.final_ev')::uuid;
  draft := current_setting('sherlyos.draft_ev')::uuid;

  located := public.get_damage_photo_url(finalized);
  if located ->> 'bucket' is distinct from 'stock-damage-evidence' then
    raise exception 'photo locator must stay on the private bucket';
  end if;
  if located ->> 'path' is null or located ? 'signed_url' then
    raise exception 'photo locator must return a private path, not a URL';
  end if;

  begin
    perform public.get_damage_photo_url(draft);
    raise exception 'draft evidence must not be locatable';
  exception
    when insufficient_privilege then null;
  end;
end $$;

select pg_temp.as_user('driver');
do $$
begin
  begin
    perform public.get_damage_photo_url(current_setting('sherlyos.final_ev')::uuid);
    raise exception 'driver must not locate storage-report evidence';
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
  if hold_ready is distinct from 'false' then
    raise exception 'damage.stock_hold_ready must stay false';
  end if;
  if dual_write is distinct from 'false' or aggregate_only is distinct from 'false' then
    raise exception 'lot cutover flags must stay false';
  end if;
end $$;

rollback;
