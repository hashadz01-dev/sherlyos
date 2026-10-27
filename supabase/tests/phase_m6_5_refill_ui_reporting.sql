-- M6.5 read-only refill queue/reporting. Rolls back. Zero stock writers.
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
  ('godown', gen_random_uuid()),
  ('keeper', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id, 'authenticated', 'authenticated',
  fixture.name || '.m65sql@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M65 SQL Admin', true)
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
end;
$$;

set session_replication_role = replica;

insert into public.branches (code, name, is_active)
values ('m65_sql_gd', 'M65 SQL Godown', true), ('m65_sql_hist', 'M65 Historical', false);

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code in ('m65_sql_gd', 'm65_sql_hist')
  and fixture.name in ('accounts', 'godown', 'keeper', 'admin');

insert into public.zones (branch_id, code, name, is_active)
select id, 'm65_sql_z', 'M65 Zone', true from public.branches where code = 'm65_sql_gd';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm65_sql_c', 'M65 Crate', true from public.zones where code = 'm65_sql_z';
insert into public.suppliers (name, is_active) values ('M65 SQL Brand', true);
insert into public.products (sku, name, is_active, supplier_id)
select 'm65_sql_a', 'M65 Product A', true, suppliers.id
from public.suppliers where suppliers.name = 'M65 SQL Brand';

set session_replication_role = origin;

create temp table stock_snapshot as
select
  (select count(*) from public.stock_transactions) as transactions,
  (select coalesce(sum(quantity), 0) from public.stock_balances) as balance_qty;

create or replace function pg_temp.approve_request(key text, qty integer, godown_code text)
returns jsonb
language plpgsql as $$
declare
  created jsonb;
  submitted jsonb;
  approved jsonb;
begin
  perform pg_temp.as_user('accounts');
  created := public.create_stock_refill_request(
    (select id from public.suppliers where name = 'M65 SQL Brand'),
    (select id from public.branches where code = godown_code),
    jsonb_build_array(jsonb_build_object(
      'product_id', (select id from public.products where sku = 'm65_sql_a'),
      'requested_cases', qty
    )),
    key || '-c',
    null
  );
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

do $$
declare
  live jsonb;
  sent jsonb;
  draft jsonb;
  listed jsonb;
  report jsonb;
  exported jsonb;
  recon jsonb;
  before_tx integer;
begin
  select transactions into before_tx from stock_snapshot;

  -- Historical inactive godown: approve while active, then deactivate.
  update public.branches set is_active = true where code = 'm65_sql_hist';
  live := pg_temp.approve_request('m65-live', 20, 'm65_sql_gd');
  sent := pg_temp.approve_request('m65-sent', 8, 'm65_sql_hist');
  perform pg_temp.as_user('accounts');
  sent := public.record_stock_refill_supplier_communication(
    (sent ->> 'id')::uuid,
    (sent ->> 'version')::integer,
    'email',
    clock_timestamp(),
    'm65-send',
    'PO-65',
    null
  );
  update public.branches set is_active = false where code = 'm65_sql_hist';

  perform pg_temp.as_user('keeper');
  draft := public.create_stock_receipt(
    (select id from public.branches where code = 'm65_sql_gd'),
    (select id from public.suppliers where name = 'M65 SQL Brand'),
    'm65-draft-van',
    (clock_timestamp() at time zone 'utc')::date,
    null,
    jsonb_build_array(jsonb_build_object(
      'product_id', (select id from public.products where sku = 'm65_sql_a'),
      'destination_crate_id', (select id from public.crates where code = 'm65_sql_c'),
      'document_cases', 5,
      'counted_cases', 5,
      'damaged_cases', 0
    )),
    (live ->> 'id')::uuid
  );

  perform pg_temp.as_user('accounts');
  recon := public.get_stock_refill_receiving_reconciliation((live ->> 'id')::uuid);
  if (recon -> 'receiving' -> 'summary' ->> 'draft_reserved_cases')::integer is distinct from 5 then
    raise exception 'draft reservation missing: %', recon;
  end if;
  if (recon -> 'receiving' -> 'summary' ->> 'accepted_cases')::integer is distinct from 0 then
    raise exception 'draft must not count as accepted';
  end if;
  if (recon -> 'receiving' -> 'summary' ->> 'reserved_cases')::integer is distinct from 5 then
    raise exception 'reserved must include the draft';
  end if;

  listed := public.list_stock_refill_requests(
    1, 25, 'approved', null, null, null, 'sent', null, null, null, null, null
  );
  if (listed ->> 'total')::integer <> 1 then
    raise exception 'sent filter should return one request, got %', listed;
  end if;

  listed := public.list_stock_refill_requests(
    1, 25, null, null, null, null, null, null, null, 'not_started', null, null
  );
  if (listed ->> 'total')::integer < 1 then
    raise exception 'receiving filter returned no rows';
  end if;

  listed := public.list_stock_refill_requests(1, 1, null, null, null, null, null, null, null, null, null, null);
  if jsonb_array_length(listed -> 'items') <> 1 or (listed ->> 'total')::integer < 2 then
    raise exception 'pagination missing: %', listed;
  end if;

  report := public.list_stock_refill_report(
    1, 50, null, (select id from public.branches where code = 'm65_sql_hist'),
    null, null, null, null, null, null, null, null
  );
  if (report ->> 'total_count')::integer <> 1 then
    raise exception 'inactive godown report missing: %', report;
  end if;
  if (report -> 'rows' -> 0 ->> 'godown_active')::boolean is not false then
    raise exception 'historical godown must stay labeled inactive';
  end if;

  exported := public.export_stock_refill_report();
  if position('request_number' in exported ->> 'csv') = 0 then
    raise exception 'export csv missing header';
  end if;

  begin
    perform pg_temp.as_user('keeper');
    perform public.list_stock_refill_report();
    raise exception 'keeper must not read refill report';
  exception
    when sqlstate '42501' then null;
  end;

  begin
    perform pg_temp.as_user('godown');
    perform public.list_stock_refill_requests();
    raise exception 'godown manager must not list refill requests';
  exception
    when sqlstate '42501' then null;
  end;

  if (select count(*) from public.stock_transactions) <> before_tx then
    raise exception 'M6.5 reporting posted stock';
  end if;

  if (select value from public.app_configuration where key = 'damage.stock_hold_ready') <> 'false'::jsonb
    or (select value from public.app_configuration where key = 'stock.lots.dual_write_enabled') <> 'false'::jsonb
    or (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked') <> 'false'::jsonb
  then
    raise exception 'flags flipped during M6.5 SQL';
  end if;
end $$;

rollback;
select pg_advisory_unlock(hashtext('sherlyos.m6.refill_tests'));
