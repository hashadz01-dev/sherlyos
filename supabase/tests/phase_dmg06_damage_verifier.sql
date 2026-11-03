-- DMG-06 restricted damage_verifier role + disposition split.
-- Rolls back. Does not flip operational flags. Isolated fixture users only.
-- Run (m82c only):
--   Get-Content supabase/tests/phase_dmg06_damage_verifier.sql -Raw |
--     docker exec -i supabase_db_sherlyos_m82c psql -U postgres -d postgres -v ON_ERROR_STOP=1
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
  ('gm', gen_random_uuid()),
  ('verifier', gen_random_uuid()),
  ('reporter', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id, 'authenticated', 'authenticated',
  fixture.name || '.dmg06v@example.com',
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
      values ((select id from fixture where name = 'admin'), 'DMG06V Admin', true)
      on conflict (id) do update set is_active = true;
      insert into public.user_roles (user_id, role_id, assigned_by)
      select (select id from fixture where name = 'admin'), roles.id,
        (select id from fixture where name = 'admin')
      from public.roles where roles.code = 'admin'
      on conflict do nothing;
  end;
end $$;

insert into public.profiles (id, full_name, is_active)
select fixture.id, 'DMG06V ' || fixture.name, true
from fixture where name <> 'admin'
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select fixture.id, roles.id, (select id from fixture where name = 'admin')
from fixture
join public.roles on roles.code = case fixture.name
  when 'gm' then 'godown_manager'
  when 'verifier' then 'damage_verifier'
  when 'reporter' then 'godown_manager'
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

create or replace function pg_temp.stamp_evidence(target uuid, uploader text)
returns void language plpgsql as $$
begin
  insert into public.damage_evidence (
    damage_report_id, storage_path, uploaded_by, mime_type, file_size, verified_at
  )
  values (
    target,
    target::text || '/' || gen_random_uuid()::text,
    (select id from fixture where name = uploader),
    'image/jpeg',
    4,
    clock_timestamp()
  );
end;
$$;

-- Bypass write guards while seeding headers for auth-focused asserts.
set session_replication_role = replica;

insert into public.branches (code, name, is_active)
values
  ('dmg06v_a', 'DMG06V Godown A', true),
  ('dmg06v_b', 'DMG06V Godown B', true);

-- Verifier assigned only to godown A (no *.godowns.all).
insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select
  (select id from fixture where name = 'verifier'),
  branches.id,
  (select id from fixture where name = 'admin')
from public.branches where code = 'dmg06v_a';

-- GM fixture gets both godowns so verification/disposition regression works even
-- on disposable DBs that have not yet applied godown_manager.godowns.all.
insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select
  (select id from fixture where name = 'gm'),
  branches.id,
  (select id from fixture where name = 'admin')
from public.branches where code in ('dmg06v_a', 'dmg06v_b');

insert into public.shops (name, is_active)
values ('DMG06V Shop', true);

insert into public.products (sku, name, is_active)
values ('dmg06v_sku', 'DMG06V Product', true);

-- Inbound submitted reports: no stock-hold requirement for verify.
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'dmg06v-a', 'refill_supply', branches.id, 'submitted', 1,
  (select id from fixture where name = 'reporter'),
  'dmg06v-a-key', 'dmg06v-a-fp', 'godown A verify'
from public.branches where code = 'dmg06v_a';

insert into public.damage_report_lines (
  damage_report_id, product_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, 1, 'crushed'
from public.damage_reports, public.products
where damage_reports.report_number = 'dmg06v-a' and products.sku = 'dmg06v_sku';

select pg_temp.stamp_evidence(
  (select id from public.damage_reports where report_number = 'dmg06v-a'),
  'reporter'
);

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'dmg06v-b', 'refill_supply', branches.id, 'submitted', 1,
  (select id from fixture where name = 'reporter'),
  'dmg06v-b-key', 'dmg06v-b-fp', 'other godown'
from public.branches where code = 'dmg06v_b';

insert into public.damage_report_lines (
  damage_report_id, product_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, 1, 'crushed'
from public.damage_reports, public.products
where damage_reports.report_number = 'dmg06v-b' and products.sku = 'dmg06v_sku';

select pg_temp.stamp_evidence(
  (select id from public.damage_reports where report_number = 'dmg06v-b'),
  'reporter'
);

insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  idempotency_key, request_fingerprint, notes
)
select
  'dmg06v-self', 'refill_supply', branches.id, 'submitted', 1,
  (select id from fixture where name = 'verifier'),
  'dmg06v-self-key', 'dmg06v-self-fp', 'self verify'
from public.branches where code = 'dmg06v_a';

insert into public.damage_report_lines (
  damage_report_id, product_id, quantity_cases, damage_reason
)
select damage_reports.id, products.id, 1, 'crushed'
from public.damage_reports, public.products
where damage_reports.report_number = 'dmg06v-self' and products.sku = 'dmg06v_sku';

select pg_temp.stamp_evidence(
  (select id from public.damage_reports where report_number = 'dmg06v-self'),
  'verifier'
);

-- Verified storage header for disposition permission asserts (no holds).
insert into public.damage_reports (
  report_number, scenario, godown_id, status, version, reporter_user_id,
  verifier_user_id, verified_at, idempotency_key, request_fingerprint, notes
)
select
  'dmg06v-disp', 'storage', branches.id, 'verified', 2,
  (select id from fixture where name = 'reporter'),
  (select id from fixture where name = 'gm'),
  clock_timestamp(),
  'dmg06v-disp-key', 'dmg06v-disp-fp', 'disposition gate'
from public.branches where code = 'dmg06v_a';

set session_replication_role = origin;

do $$
declare
  branch_a uuid := (select id from public.branches where code = 'dmg06v_a');
  branch_b uuid := (select id from public.branches where code = 'dmg06v_b');
  report_a uuid;
  report_b uuid;
  report_self uuid;
  report_disp uuid;
  version_a integer;
  version_b integer;
  version_self integer;
  version_disp integer;
begin
  if not exists (select 1 from public.roles where code = 'damage_verifier') then
    raise exception 'damage_verifier role missing';
  end if;
  if not exists (select 1 from public.permissions where code = 'damage.disposition') then
    raise exception 'damage.disposition permission missing';
  end if;

  -- Role matrix: verifier has read+verify only; no disposition / record / godowns.all.
  perform pg_temp.as_user('verifier');
  if app_private.has_permission('damage.disposition') then
    raise exception 'verifier must not have damage.disposition';
  end if;
  if app_private.has_permission('damage.record') then
    raise exception 'verifier must not have damage.record';
  end if;
  if app_private.has_permission('godown_manager.godowns.all') then
    raise exception 'verifier must not have godowns.all';
  end if;
  if not app_private.has_permission('damage.verify') then
    raise exception 'verifier missing damage.verify';
  end if;
  if not app_private.has_permission('damage.read') then
    raise exception 'verifier missing damage.read';
  end if;
  if not app_private.can_work_at_branch(branch_a) then
    raise exception 'verifier should work at assigned godown A';
  end if;
  if app_private.can_work_at_branch(branch_b) then
    raise exception 'verifier must not work at godown B';
  end if;

  -- Existing GM keeps disposition + verify. Company-wide godowns.all is asserted
  -- only when that permission exists (prerequisite migration may lag on m82c).
  perform pg_temp.as_user('gm');
  if not app_private.has_permission('damage.disposition') then
    raise exception 'GM missing damage.disposition after split';
  end if;
  if exists (
    select 1 from public.permissions where code = 'godown_manager.godowns.all'
  ) and not app_private.has_permission('godown_manager.godowns.all') then
    raise exception 'GM lost company-wide godown scope';
  end if;
  if not app_private.has_permission('damage.verify') then
    raise exception 'GM missing damage.verify';
  end if;

  select id, version into report_a, version_a
  from public.damage_reports where report_number = 'dmg06v-a';
  select id, version into report_b, version_b
  from public.damage_reports where report_number = 'dmg06v-b';
  select id, version into report_self, version_self
  from public.damage_reports where report_number = 'dmg06v-self';
  select id, version into report_disp, version_disp
  from public.damage_reports where report_number = 'dmg06v-disp';

  -- Godown-A verification allowed for verifier.
  perform pg_temp.as_user('verifier');
  perform public.verify_damage_report(report_a, version_a);

  -- Other-godown verification denied.
  begin
    perform public.verify_damage_report(report_b, version_b);
    raise exception 'other-godown verify should fail';
  exception
    when sqlstate '42501' then null;
  end;

  -- Self-verification denied.
  begin
    perform public.verify_damage_report(report_self, version_self);
    raise exception 'self-verify should fail';
  exception
    when sqlstate '42501' then null;
  end;

  -- Stock-changing dispositions denied for damage_verifier (permission gate).
  begin
    perform public.post_ordinary_damage_writeoff(report_disp, version_disp, 'dmg06v-wo');
    raise exception 'verifier write-off should fail';
  exception
    when sqlstate '42501' then null;
  end;

  begin
    perform public.transfer_verified_damage_to_quarantine(
      report_disp, version_disp, 'dmg06v-qrn'
    );
    raise exception 'verifier quarantine transfer should fail';
  exception
    when sqlstate '42501' then null;
  end;

  begin
    perform public.request_exceptional_damage_disposition(
      report_disp, version_disp, 'destroy', 'should fail', 'dmg06v-ex'
    );
    raise exception 'verifier exceptional request should fail';
  exception
    when sqlstate '42501' then null;
  end;

  begin
    perform public.post_exceptional_damage_disposition(
      report_disp, version_disp, 'dmg06v-ex-post'
    );
    raise exception 'verifier exceptional execute should fail';
  exception
    when sqlstate '42501' then null;
  end;

  -- GM disposition auth still passes the permission gate (later readiness may 23514).
  perform pg_temp.as_user('gm');
  begin
    perform public.post_ordinary_damage_writeoff(report_disp, version_disp, 'dmg06v-gm-wo');
  exception
    when sqlstate '42501' then
      raise exception 'GM write-off must not fail on permission';
    when others then
      null;
  end;

  begin
    perform public.request_exceptional_damage_disposition(
      report_disp, version_disp, 'destroy', 'gm may request', 'dmg06v-gm-ex'
    );
  exception
    when sqlstate '42501' then
      raise exception 'GM exceptional request must not fail on permission';
    when others then
      null;
  end;

  begin
    perform public.transfer_verified_damage_to_quarantine(
      report_disp, version_disp, 'dmg06v-gm-qrn'
    );
  exception
    when sqlstate '42501' then
      raise exception 'GM quarantine transfer must not fail on permission';
    when others then
      null;
  end;

  -- GM can still verify a foreign submitted report at godown B (godowns.all).
  perform public.verify_damage_report(report_b, version_b);

  raise notice 'phase_dmg06_damage_verifier PASS';
end;
$$;

rollback;
select pg_advisory_unlock(hashtext('sherlyos.m5.stock_flag_tests'));
