-- DMG-06 salesperson shop-return lifecycle (local disposable).
-- Submit does not post stock. GM custody then independent verify posts intake once.
-- Rolls back. Does not flip operational flags.
-- Run when local supabase is up:
--   Get-Content supabase/tests/phase_dmg06_salesperson_shop_return.sql -Raw |
--     docker exec -i supabase_db_sherlyos psql -U postgres -d postgres -v ON_ERROR_STOP=1

select pg_advisory_lock(hashtext('sherlyos.m5.stock_flag_tests'));
begin;

create temp table fixture (
  name text primary key,
  id uuid not null
);

insert into fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('sales', gen_random_uuid()),
  ('gm', gen_random_uuid()),
  ('verifier', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id, 'authenticated', 'authenticated',
  fixture.name || '.dmg06s@example.com',
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
      values ((select id from fixture where name = 'admin'), 'DMG06S Admin', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select (select id from fixture where name = 'admin'), roles.id,
        (select id from fixture where name = 'admin')
      from public.roles where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.profiles (id, full_name, is_active)
select fixture.id, 'DMG06S ' || fixture.name, true
from fixture where name <> 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles on roles.code = case fixture.name
  when 'sales' then 'salesperson'
  when 'gm' then 'godown_manager'
  when 'verifier' then 'damage_verifier'
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

insert into public.branches (code, name, is_active)
values ('dmg06s_g1', 'DMG06S Godown', true);

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select
  (select id from fixture where name = 'gm'),
  branches.id,
  (select id from fixture where name = 'admin')
from public.branches where code = 'dmg06s_g1';

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select
  (select id from fixture where name = 'verifier'),
  branches.id,
  (select id from fixture where name = 'admin')
from public.branches where code = 'dmg06s_g1';

insert into public.shops (name, is_active)
values ('DMG06S Shop', true), ('DMG06S Other Shop', true);

insert into public.shop_salesperson_assignments (shop_id, salesperson_id, assigned_by)
select shops.id, (select id from fixture where name = 'sales'),
  (select id from fixture where name = 'admin')
from public.shops where shops.name = 'DMG06S Shop';

insert into public.products (sku, name, is_active)
values ('dmg06s_sku', 'DMG06S Product', true);

-- Isolation ready only inside this rolled-back transaction (no cloud flag change).
-- Quarantine crate is created by ensure_godown_quarantine_crate during verify.
set session_replication_role = replica;
update public.app_configuration set value = 'true'::jsonb
where key in (
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked',
  'damage.stock_hold_ready'
);
set session_replication_role = origin;

-- Permission grants present
do $$
begin
  if not exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'salesperson'
      and permissions.code = 'damage.shop_return.record'
  ) then
    raise exception 'salesperson missing damage.shop_return.record';
  end if;
  if exists (
    select 1
    from public.role_permissions
    join public.roles on roles.id = role_permissions.role_id
    join public.permissions on permissions.id = role_permissions.permission_id
    where roles.code = 'salesperson'
      and permissions.code in (
        'damage.record', 'damage.verify', 'damage.disposition', 'damage.dispose'
      )
  ) then
    raise exception 'salesperson must not gain warehouse damage permissions';
  end if;
end $$;

-- Salesperson can create shop_return for assigned shop
select pg_temp.as_user('sales');
select public.create_damage_report(
  'shop_return',
  (select id from public.branches where code = 'dmg06s_g1'),
  jsonb_build_array(jsonb_build_object(
    'product_id', (select id from public.products where sku = 'dmg06s_sku'),
    'quantity_cases', 1,
    'damage_reason', 'leakage'
  )),
  'dmg06s-create-1',
  'salesperson claim',
  null, null, null, null,
  (select id from public.shops where name = 'DMG06S Shop')
);

-- Unauthorized shop rejected
do $$
begin
  begin
    perform public.create_damage_report(
      'shop_return',
      (select id from public.branches where code = 'dmg06s_g1'),
      jsonb_build_array(jsonb_build_object(
        'product_id', (select id from public.products where sku = 'dmg06s_sku'),
        'quantity_cases', 1,
        'damage_reason', 'leakage'
      )),
      'dmg06s-create-bad-shop',
      null, null, null, null, null,
      (select id from public.shops where name = 'DMG06S Other Shop')
    );
    raise exception 'unauthorized shop should fail';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Other scenarios rejected for salesperson
do $$
begin
  begin
    perform public.create_damage_report(
      'storage',
      (select id from public.branches where code = 'dmg06s_g1'),
      jsonb_build_array(jsonb_build_object(
        'product_id', (select id from public.products where sku = 'dmg06s_sku'),
        'quantity_cases', 1,
        'damage_reason', 'leakage',
        'crate_id', null
      )),
      'dmg06s-create-storage',
      null, null, null, null, null, null
    );
    raise exception 'storage should fail for salesperson';
  exception
    when sqlstate '42501' then null;
    when sqlstate '23514' then null;
  end;
end $$;

-- Finalize evidence + submit (no stock holds)
insert into public.damage_evidence (
  damage_report_id, storage_path, uploaded_by, mime_type, file_size, verified_at
)
select damage_reports.id,
  damage_reports.id::text || '/' || gen_random_uuid()::text,
  (select id from fixture where name = 'sales'),
  'image/jpeg', 4, clock_timestamp()
from public.damage_reports
where damage_reports.idempotency_key = 'dmg06s-create-1';

select public.submit_damage_report(
  (select id from public.damage_reports where idempotency_key = 'dmg06s-create-1'),
  (select version from public.damage_reports where idempotency_key = 'dmg06s-create-1'),
  'dmg06s-submit-1'
);

do $$
declare
  hold_count integer;
begin
  select count(*) into hold_count
  from public.damage_stock_holds
  where damage_report_id = (
    select id from public.damage_reports where idempotency_key = 'dmg06s-create-1'
  );
  if hold_count <> 0 then
    raise exception 'salesperson submit must not create stock holds';
  end if;
end $$;

-- Salesperson cannot confirm custody
do $$
begin
  begin
    perform public.confirm_shop_return_custody(
      (select id from public.damage_reports where idempotency_key = 'dmg06s-create-1'),
      (select version from public.damage_reports where idempotency_key = 'dmg06s-create-1')
    );
    raise exception 'salesperson custody should fail';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- Verify blocked until custody
select pg_temp.as_user('verifier');
do $$
begin
  begin
    perform public.verify_damage_report(
      (select id from public.damage_reports where idempotency_key = 'dmg06s-create-1'),
      (select version from public.damage_reports where idempotency_key = 'dmg06s-create-1')
    );
    raise exception 'verify without custody should fail';
  exception
    when sqlstate '23514' then null;
  end;
end $$;

-- GM confirms custody (no stock yet)
select pg_temp.as_user('gm');
select public.confirm_shop_return_custody(
  (select id from public.damage_reports where idempotency_key = 'dmg06s-create-1'),
  (select version from public.damage_reports where idempotency_key = 'dmg06s-create-1')
);

do $$
declare
  hold_count integer;
begin
  select count(*) into hold_count
  from public.damage_stock_holds
  where damage_report_id = (
    select id from public.damage_reports where idempotency_key = 'dmg06s-create-1'
  );
  if hold_count <> 0 then
    raise exception 'custody must not create stock holds';
  end if;
end $$;

-- Independent verify posts quarantine intake exactly once (flags enabled in this tx only).
select pg_temp.as_user('verifier');
select public.verify_damage_report(
  (select id from public.damage_reports where idempotency_key = 'dmg06s-create-1'),
  (select version from public.damage_reports where idempotency_key = 'dmg06s-create-1')
);

do $$
declare
  intake_count integer;
  status text;
  saleable integer;
begin
  select count(*) into intake_count
  from public.damage_stock_holds
  where damage_report_id = (
    select id from public.damage_reports where idempotency_key = 'dmg06s-create-1'
  )
    and hold_kind = 'quarantine_intake'
    and damage_stock_holds.status = 'active';
  if intake_count <> 1 then
    raise exception 'expected exactly one quarantine intake hold, got %', intake_count;
  end if;

  select damage_reports.status into status
  from public.damage_reports
  where idempotency_key = 'dmg06s-create-1';
  if status is distinct from 'verified' then
    raise exception 'expected verified, got %', status;
  end if;

  select coalesce(sum(stock_balances.quantity), 0)::integer into saleable
  from public.stock_balances
  join public.crates on crates.id = stock_balances.crate_id
  where stock_balances.product_id = (select id from public.products where sku = 'dmg06s_sku')
    and crates.location_role is distinct from 'quarantine';
  if saleable <> 0 then
    raise exception 'saleable stock changed unexpectedly: %', saleable;
  end if;

  perform app_private.apply_damage_stock_isolation(
    (select id from public.damage_reports where idempotency_key = 'dmg06s-create-1')
  );

  select count(*) into intake_count
  from public.damage_stock_holds
  where damage_report_id = (
    select id from public.damage_reports where idempotency_key = 'dmg06s-create-1'
  )
    and hold_kind = 'quarantine_intake';
  if intake_count <> 1 then
    raise exception 'quarantine intake duplicated: %', intake_count;
  end if;
end $$;

rollback;
select pg_advisory_unlock(hashtext('sherlyos.m5.stock_flag_tests'));
