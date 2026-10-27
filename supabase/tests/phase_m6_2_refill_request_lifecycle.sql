-- M6.2 refill request lifecycle (REF-01–REF-04).
-- Rolls back. Zero stock effects. Does not flip damage/lot flags.
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
  ('accounts2', gen_random_uuid()),
  ('other_acct', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('sales', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id, 'authenticated', 'authenticated',
  fixture.name || '.m62sql@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M62 SQL Admin', true)
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
  when 'accounts2' then 'accounts'
  when 'other_acct' then 'accounts'
  when 'godown' then 'godown_manager'
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

-- Catalog FORCE RLS and least-privilege grants.
do $$
declare
  missing text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into missing
  from (values
    ('stock_refill_requests'),
    ('stock_refill_request_lines'),
    ('stock_refill_request_events')
  ) t(relname)
  join pg_class c on c.relname = t.relname
  join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
  where not c.relrowsecurity or not c.relforcerowsecurity;
  if missing is not null then
    raise exception 'refill tables missing FORCE RLS: %', missing;
  end if;

  if has_table_privilege('authenticated', 'public.stock_refill_requests', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_refill_request_lines', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_refill_request_events', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_balances', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_ledger', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_transactions', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_reservations', 'INSERT')
     or has_table_privilege('authenticated', 'public.damage_stock_holds', 'INSERT') then
    raise exception 'authenticated must not insert refill or stock writers';
  end if;
end $$;

set session_replication_role = replica;

insert into public.branches (code, name, is_active)
values
  ('m62_sql_gd', 'M62 SQL Godown', true),
  ('m62_sql_other', 'M62 SQL Other', true),
  ('m62_sql_dead', 'M62 SQL Inactive', false);

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code = 'm62_sql_gd'
  and fixture.name in ('accounts', 'accounts2', 'godown');

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select (select id from fixture where name = 'other_acct'), branches.id,
  (select id from fixture where name = 'admin')
from public.branches where code = 'm62_sql_other';

insert into public.zones (branch_id, code, name, is_active)
select id, 'm62_sql_z', 'M62 Zone', true from public.branches where code = 'm62_sql_gd';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm62_sql_c', 'M62 Crate', true from public.zones where code = 'm62_sql_z';

insert into public.suppliers (name, is_active)
values
  ('M62 SQL Brand', true),
  ('M62 SQL Other Brand', true),
  ('M62 SQL Inactive Brand', false);

insert into public.products (sku, name, is_active, supplier_id)
select 'm62_sql_sku', 'M62 SQL Soap', true, suppliers.id
from public.suppliers where suppliers.name = 'M62 SQL Brand';
insert into public.products (sku, name, is_active, supplier_id)
select 'm62_sql_other_sku', 'M62 SQL Other Soap', true, suppliers.id
from public.suppliers where suppliers.name = 'M62 SQL Other Brand';
insert into public.products (sku, name, is_active, supplier_id)
select 'm62_sql_dead_sku', 'M62 SQL Dead Soap', false, suppliers.id
from public.suppliers where suppliers.name = 'M62 SQL Brand';

-- Seed a live balance so refill mutations can be proven stock-neutral.
insert into public.stock_balances (crate_id, product_id, quantity)
select crates.id, products.id, 17
from public.crates, public.products
where crates.code = 'm62_sql_c' and products.sku = 'm62_sql_sku';

set session_replication_role = origin;

create temp table stock_snapshot as
select
  (select count(*) from public.stock_transactions) as transactions,
  (select count(*) from public.stock_ledger) as ledger,
  (select coalesce(sum(quantity), 0) from public.stock_balances) as balance_qty,
  (select count(*) from public.stock_lots) as lots,
  (select coalesce(sum(quantity), 0) from public.stock_lot_balances) as lot_qty,
  (select count(*) from public.stock_reservations) as reservations,
  (select count(*) from public.damage_stock_holds) as holds,
  (select count(*) from public.stock_receipts) as receipts;

-- Direct table writes must fail without the trusted GUC.
do $$
begin
  insert into public.stock_refill_requests (
    request_number, supplier_id, destination_godown_id, created_by,
    idempotency_key, request_fingerprint
  )
  select
    'RF-DIRECT', suppliers.id, branches.id,
    (select id from fixture where name = 'accounts'),
    'direct-key', 'fp'
  from public.suppliers, public.branches
  where suppliers.name = 'M62 SQL Brand' and branches.code = 'm62_sql_gd';
  raise exception 'direct refill insert must be blocked';
exception
  when sqlstate '42501' then null;
end $$;

-- Admin cannot create (no refill.request). Accounts can.
do $$
declare
  payload jsonb;
  replay jsonb;
  updated jsonb;
  submitted jsonb;
  held jsonb;
  resubmitted jsonb;
  approved jsonb;
  rejected jsonb;
  listed jsonb;
  lines jsonb;
  other_lines jsonb;
  gd uuid;
  other_gd uuid;
  dead_gd uuid;
  brand uuid;
  other_brand uuid;
  product_id uuid;
  other_product_id uuid;
  dead_product_id uuid;
begin
  select id into gd from public.branches where code = 'm62_sql_gd';
  select id into other_gd from public.branches where code = 'm62_sql_other';
  select id into dead_gd from public.branches where code = 'm62_sql_dead';
  select id into brand from public.suppliers where name = 'M62 SQL Brand';
  select id into other_brand from public.suppliers where name = 'M62 SQL Other Brand';
  select products.id into product_id from public.products where products.sku = 'm62_sql_sku';
  select products.id into other_product_id from public.products where products.sku = 'm62_sql_other_sku';
  select products.id into dead_product_id from public.products where products.sku = 'm62_sql_dead_sku';
  lines := jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 3));
  other_lines := jsonb_build_array(jsonb_build_object('product_id', other_product_id, 'requested_cases', 2));

  perform pg_temp.as_user('admin');
  begin
    perform public.create_stock_refill_request(brand, gd, lines, 'm62sql-adm-create', null);
    raise exception 'admin must not create refill requests';
  exception
    when sqlstate '42501' then null;
  end;

  perform pg_temp.as_user('godown');
  begin
    perform public.list_stock_refill_requests();
    raise exception 'godown manager must not list refill requests';
  exception
    when sqlstate '42501' then null;
  end;

  perform pg_temp.as_user('sales');
  begin
    perform public.create_stock_refill_request(brand, gd, lines, 'm62sql-sales-create', null);
    raise exception 'salesperson must not create refill requests';
  exception
    when sqlstate '42501' then null;
  end;

  -- Wrong godown, wrong brand SKU, inactive SKU, inactive supplier, inactive godown.
  perform pg_temp.as_user('accounts');
  begin
    perform public.create_stock_refill_request(brand, other_gd, lines, 'm62sql-wrong-gd', null);
    raise exception 'accounts must not create for an unassigned godown';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.create_stock_refill_request(brand, dead_gd, lines, 'm62sql-dead-gd', null);
    raise exception 'inactive godown must fail create';
  exception
    when sqlstate '42501' then null;
    when sqlstate '23514' then null;
  end;
  begin
    perform public.create_stock_refill_request(brand, gd, other_lines, 'm62sql-wrong-sku', null);
    raise exception 'SKU must belong to the selected supplier';
  exception
    when sqlstate '23514' then null;
  end;
  begin
    perform public.create_stock_refill_request(
      brand, gd,
      jsonb_build_array(jsonb_build_object('product_id', dead_product_id, 'requested_cases', 1)),
      'm62sql-dead-sku', null
    );
    raise exception 'inactive SKU must fail';
  exception
    when sqlstate '23514' then null;
  end;
  begin
    perform public.create_stock_refill_request(
      (select id from public.suppliers where name = 'M62 SQL Inactive Brand'),
      gd, lines, 'm62sql-dead-brand', null
    );
    raise exception 'inactive supplier must fail';
  exception
    when sqlstate '23514' then null;
  end;
  begin
    perform public.create_stock_refill_request(
      brand, gd,
      jsonb_build_array(
        jsonb_build_object('product_id', product_id, 'requested_cases', 1),
        jsonb_build_object('product_id', product_id, 'requested_cases', 2)
      ),
      'm62sql-dup-sku', null
    );
    raise exception 'duplicate SKUs must fail';
  exception
    when sqlstate '23514' then null;
  end;

  payload := public.create_stock_refill_request(
    brand, gd, lines, 'm62sql-create-key', 'first draft'
  );
  if payload ->> 'status' <> 'draft' then
    raise exception 'create must start as draft: %', payload ->> 'status';
  end if;
  if payload ->> 'request_number' !~ '^RF-[0-9]{8}-[0-9]{6}$' then
    raise exception 'request number shape invalid: %', payload ->> 'request_number';
  end if;

  replay := public.create_stock_refill_request(
    brand, gd, lines, 'm62sql-create-key', 'first draft'
  );
  if replay ->> 'id' is distinct from payload ->> 'id' then
    raise exception 'create idempotency must replay the same request';
  end if;
  begin
    perform public.create_stock_refill_request(
      brand, gd,
      jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 9)),
      'm62sql-create-key', 'different fingerprint'
    );
    raise exception 'fingerprint mismatch must fail';
  exception
    when unique_violation then null;
    when sqlstate '23505' then null;
  end;

  listed := public.list_stock_refill_requests(1, 25, 'draft', gd, brand, 'RF-');
  if (listed ->> 'total')::integer < 1 then
    raise exception 'accounts list must include the draft';
  end if;

  -- Second Accounts user on the same godown cannot edit/submit another creator's draft.
  perform pg_temp.as_user('accounts2');
  begin
    perform public.update_stock_refill_request(
      (payload ->> 'id')::uuid, (payload ->> 'version')::integer,
      brand, gd, lines, 'hijack'
    );
    raise exception 'non-creator must not edit';
  exception
    when sqlstate '42501' then null;
  end;

  perform pg_temp.as_user('accounts');
  updated := public.update_stock_refill_request(
    (payload ->> 'id')::uuid, (payload ->> 'version')::integer,
    brand, gd,
    jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 5)),
    'revised draft'
  );
  if (updated ->> 'version')::integer <> (payload ->> 'version')::integer + 1 then
    raise exception 'update must bump version';
  end if;
  begin
    perform public.update_stock_refill_request(
      (payload ->> 'id')::uuid, (payload ->> 'version')::integer,
      brand, gd, lines, 'stale'
    );
    raise exception 'stale update must conflict';
  exception
    when sqlstate 'PT409' then null;
  end;

  submitted := public.submit_stock_refill_request(
    (updated ->> 'id')::uuid, (updated ->> 'version')::integer, 'm62sql-submit-key'
  );
  if submitted ->> 'status' <> 'submitted' then
    raise exception 'submit must move to submitted';
  end if;
  replay := public.submit_stock_refill_request(
    (updated ->> 'id')::uuid, (updated ->> 'version')::integer, 'm62sql-submit-key'
  );
  if replay ->> 'id' is distinct from submitted ->> 'id'
     or replay ->> 'status' <> 'submitted' then
    raise exception 'submit replay must return the submitted request';
  end if;

  -- Hold, then Accounts edits and resubmits.
  perform pg_temp.as_user('admin');
  begin
    perform public.hold_stock_refill_request(
      (submitted ->> 'id')::uuid, (submitted ->> 'version')::integer,
      '', 'm62sql-hold-empty'
    );
    raise exception 'hold requires a reason';
  exception
    when sqlstate '23514' then null;
  end;
  held := public.hold_stock_refill_request(
    (submitted ->> 'id')::uuid, (submitted ->> 'version')::integer,
    'need fewer cases', 'm62sql-hold-key'
  );
  if held ->> 'status' <> 'held' then
    raise exception 'hold must return held';
  end if;

  perform pg_temp.as_user('accounts');
  updated := public.update_stock_refill_request(
    (held ->> 'id')::uuid, (held ->> 'version')::integer,
    brand, gd,
    jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 2)),
    'held revision'
  );
  resubmitted := public.submit_stock_refill_request(
    (updated ->> 'id')::uuid, (updated ->> 'version')::integer, 'm62sql-resub-key'
  );
  if resubmitted ->> 'status' <> 'submitted' then
    raise exception 'resubmit must return submitted';
  end if;
  if not exists (
    select 1 from public.stock_refill_request_events
    where refill_request_id = (resubmitted ->> 'id')::uuid
      and action = 'resubmitted'
  ) then
    raise exception 'resubmit must record a resubmitted event';
  end if;

  perform pg_temp.as_user('admin');
  approved := public.approve_stock_refill_request(
    (resubmitted ->> 'id')::uuid, (resubmitted ->> 'version')::integer,
    'm62sql-approve-key', 'authorized to send later'
  );
  if approved ->> 'status' <> 'approved' then
    raise exception 'approve must return approved';
  end if;
  replay := public.approve_stock_refill_request(
    (resubmitted ->> 'id')::uuid, (resubmitted ->> 'version')::integer,
    'm62sql-approve-key', 'authorized to send later'
  );
  if replay ->> 'status' <> 'approved' then
    raise exception 'approve replay must stay approved';
  end if;

  -- Approved is immutable in M6.2.
  perform pg_temp.as_user('accounts');
  begin
    perform public.update_stock_refill_request(
      (approved ->> 'id')::uuid, (approved ->> 'version')::integer,
      brand, gd, lines, 'after approve'
    );
    raise exception 'approved request must not be editable';
  exception
    when sqlstate '42501' then null;
  end;
  perform pg_temp.as_user('admin');
  begin
    perform public.reject_stock_refill_request(
      (approved ->> 'id')::uuid, (approved ->> 'version')::integer,
      'too late', 'm62sql-reject-after-approve'
    );
    raise exception 'approved request must not be rejected';
  exception
    when sqlstate '42501' then null;
  end;

  -- Separate request: reject is terminal.
  perform pg_temp.as_user('accounts');
  payload := public.create_stock_refill_request(brand, gd, lines, 'm62sql-reject-create', null);
  submitted := public.submit_stock_refill_request(
    (payload ->> 'id')::uuid, (payload ->> 'version')::integer, 'm62sql-reject-sub'
  );
  perform pg_temp.as_user('admin');
  rejected := public.reject_stock_refill_request(
    (submitted ->> 'id')::uuid, (submitted ->> 'version')::integer,
    'out of season', 'm62sql-reject-key'
  );
  if rejected ->> 'status' <> 'rejected' then
    raise exception 'reject must return rejected';
  end if;
  perform pg_temp.as_user('accounts');
  begin
    perform public.submit_stock_refill_request(
      (rejected ->> 'id')::uuid, (rejected ->> 'version')::integer, 'm62sql-reject-resub'
    );
    raise exception 'rejected request must be terminal';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.update_stock_refill_request(
      (rejected ->> 'id')::uuid, (rejected ->> 'version')::integer,
      brand, gd, lines, 'revive'
    );
    raise exception 'rejected request must not be editable';
  exception
    when sqlstate '42501' then null;
  end;

  -- Other-godown Accounts cannot read this request.
  perform pg_temp.as_user('other_acct');
  begin
    perform public.get_stock_refill_request((approved ->> 'id')::uuid);
    raise exception 'cross-godown accounts must not read refill';
  exception
    when sqlstate '42501' then null;
  end;

  -- Admin list sees both godowns; Accounts sees only assigned.
  perform pg_temp.as_user('other_acct');
  payload := public.create_stock_refill_request(
    brand, other_gd,
    jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 1)),
    'm62sql-other-create', null
  );
  -- sku belongs to brand, other_gd is assigned to other_acct — product/supplier OK.
  perform pg_temp.as_user('accounts');
  listed := public.list_stock_refill_requests();
  if exists (
    select 1
    from jsonb_array_elements(listed -> 'items') item
    where item ->> 'id' = payload ->> 'id'
  ) then
    raise exception 'accounts must not list another godown request';
  end if;
  perform pg_temp.as_user('admin');
  listed := public.list_stock_refill_requests();
  if (listed ->> 'total')::integer < 2 then
    raise exception 'admin list must include both godowns';
  end if;

  -- Same key, different actor: 42501, not a fingerprint leak.
  perform pg_temp.as_user('accounts2');
  begin
    perform public.create_stock_refill_request(
      brand, gd, lines, 'm62sql-create-key', 'first draft'
    );
    raise exception 'foreign actor must not replay another creator key';
  exception
    when sqlstate '42501' then null;
  end;
  begin
    perform public.create_stock_refill_request(
      brand, gd,
      jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 9)),
      'm62sql-create-key', 'different fingerprint'
    );
    raise exception 'foreign actor must not learn fingerprint mismatch';
  exception
    when sqlstate '42501' then null;
  end;

  -- Lost-response retry: same actor, same key, same payload, no second row.
  perform pg_temp.as_user('accounts');
  payload := public.create_stock_refill_request(brand, gd, lines, 'm62sql-lost-c', null);
  replay := public.create_stock_refill_request(brand, gd, lines, 'm62sql-lost-c', null);
  if replay ->> 'id' is distinct from payload ->> 'id' then
    raise exception 'lost-response retry must identify the original request';
  end if;
  if (
    select count(*) from public.stock_refill_requests
    where idempotency_key = 'm62sql-lost-c'
  ) <> 1 then
    raise exception 'lost-response retry must not insert a second request';
  end if;

  -- Duplicate submit replay must not add a second submitted event.
  payload := public.create_stock_refill_request(brand, gd, lines, 'm62sql-dup-sub-c', null);
  submitted := public.submit_stock_refill_request(
    (payload ->> 'id')::uuid, (payload ->> 'version')::integer, 'm62sql-dup-sub'
  );
  perform public.submit_stock_refill_request(
    (payload ->> 'id')::uuid, (payload ->> 'version')::integer, 'm62sql-dup-sub'
  );
  if (
    select count(*) from public.stock_refill_request_events
    where refill_request_id = (payload ->> 'id')::uuid
      and action = 'submitted'
  ) <> 1 then
    raise exception 'submit replay must not duplicate submitted events';
  end if;

  -- Inactive godown: historical GET remains; submit fails closed.
  payload := public.create_stock_refill_request(brand, gd, lines, 'm62sql-hist-c', null);
  perform pg_temp.as_user('admin');
  perform public.set_branch_active(gd, false);
  perform pg_temp.as_user('accounts');
  replay := public.get_stock_refill_request((payload ->> 'id')::uuid);
  if replay ->> 'id' is distinct from payload ->> 'id' then
    raise exception 'historical GET must survive godown deactivation';
  end if;
  begin
    perform public.submit_stock_refill_request(
      (payload ->> 'id')::uuid, (payload ->> 'version')::integer, 'm62sql-hist-sub'
    );
    raise exception 'submit must fail on inactive godown';
  exception
    when sqlstate '23514' then null;
    when sqlstate '42501' then null;
  end;
  perform pg_temp.as_user('admin');
  perform public.set_branch_active(gd, true);

  -- Assignment removal blocks current-auth replay.
  perform pg_temp.as_user('accounts');
  payload := public.create_stock_refill_request(brand, gd, lines, 'm62sql-unassign-c', null);
  delete from public.user_branch_assignments
  where user_id = (select id from fixture where name = 'accounts')
    and branch_id = gd;
  begin
    perform public.create_stock_refill_request(brand, gd, lines, 'm62sql-unassign-c', null);
    raise exception 'replay after assignment removal must fail';
  exception
    when sqlstate '42501' then null;
  end;
  insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
  select (select id from fixture where name = 'accounts'), gd,
    (select id from fixture where name = 'admin');

  -- Permission revocation blocks create replay immediately.
  payload := public.create_stock_refill_request(brand, gd, lines, 'm62sql-revoke-c', null);
  delete from public.user_roles
  where user_id = (select id from fixture where name = 'accounts')
    and role_id = (select id from public.roles where code = 'accounts');
  begin
    perform public.create_stock_refill_request(brand, gd, lines, 'm62sql-revoke-c', null);
    raise exception 'replay after permission revocation must fail';
  exception
    when sqlstate '42501' then null;
  end;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select (select id from fixture where name = 'accounts'), roles.id,
    (select id from fixture where name = 'admin')
  from public.roles where roles.code = 'accounts';

  -- operations.monitor alone is not a refill grant.
  insert into public.role_permissions (role_id, permission_id)
  select roles.id, permissions.id
  from public.roles, public.permissions
  where roles.code = 'salesperson'
    and permissions.code = 'operations.monitor'
  on conflict do nothing;
  perform pg_temp.as_user('sales');
  begin
    perform public.list_stock_refill_requests();
    raise exception 'operations.monitor must not list refill requests';
  exception
    when sqlstate '42501' then null;
  end;
end $$;

-- RLS SELECT isolation for salesperson.
set local role authenticated;
select pg_temp.as_user('sales');
do $$
begin
  if exists (select 1 from public.stock_refill_requests) then
    raise exception 'salesperson must not select refill rows';
  end if;
  if app_private.can_view_refill_at_godown((select id from public.branches where code = 'm62_sql_gd')) then
    raise exception 'can_view_refill_at_godown must not grant salesperson access';
  end if;
  if has_function_privilege('authenticated', 'app_private.enable_refill_write()', 'execute')
     or has_function_privilege('authenticated', 'app_private.replace_refill_lines(uuid, jsonb)', 'execute')
     or has_function_privilege('authenticated', 'app_private.record_refill_event(uuid, text, text, text, text, integer)', 'execute') then
    raise exception 'private refill mutation helpers must stay revoked';
  end if;
end $$;
reset role;

-- Zero stock effects after the full Accounts/Admin lifecycle.
do $$
begin
  if exists (
    select 1
    from stock_snapshot s
    where s.transactions is distinct from (select count(*) from public.stock_transactions)
       or s.ledger is distinct from (select count(*) from public.stock_ledger)
       or s.balance_qty is distinct from (select coalesce(sum(quantity), 0) from public.stock_balances)
       or s.lots is distinct from (select count(*) from public.stock_lots)
       or s.lot_qty is distinct from (select coalesce(sum(quantity), 0) from public.stock_lot_balances)
       or s.reservations is distinct from (select count(*) from public.stock_reservations)
       or s.holds is distinct from (select count(*) from public.damage_stock_holds)
       or s.receipts is distinct from (select count(*) from public.stock_receipts)
  ) then
    raise exception 'M6.2 refill mutations must have zero stock effects';
  end if;
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
select pg_advisory_unlock(hashtext('sherlyos.m6.refill_tests'));
