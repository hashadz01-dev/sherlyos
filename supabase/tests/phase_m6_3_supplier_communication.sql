-- M6.3 REF-05/REF-06. Manual send, acknowledgement, dispatch.
-- Rolls back. Zero stock. Does not flip damage/lot flags.
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
  ('keeper', gen_random_uuid()),
  ('delivery', gen_random_uuid()),
  ('sales', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id, 'authenticated', 'authenticated',
  fixture.name || '.m63sql@example.com',
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
      values ((select id from fixture where name = 'admin'), 'M63 SQL Admin', true)
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
  when 'keeper' then 'store_keeper'
  when 'delivery' then 'delivery_person'
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

do $$
declare
  missing text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into missing
  from (values
    ('stock_refill_supplier_communications'),
    ('stock_refill_supplier_dispatches')
  ) t(relname)
  join pg_class c on c.relname = t.relname
  join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
  where not c.relrowsecurity or not c.relforcerowsecurity;
  if missing is not null then
    raise exception 'M6.3 tables missing FORCE RLS: %', missing;
  end if;

  if has_table_privilege('authenticated', 'public.stock_refill_supplier_communications', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_refill_supplier_dispatches', 'INSERT')
     or has_table_privilege('authenticated', 'public.stock_balances', 'INSERT') then
    raise exception 'authenticated must not insert M6.3 or stock writers';
  end if;
end $$;

set session_replication_role = replica;

insert into public.branches (code, name, is_active)
values
  ('m63_sql_gd', 'M63 SQL Godown', true),
  ('m63_sql_other', 'M63 SQL Other', true);

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select fixture.id, branches.id, (select id from fixture where name = 'admin')
from fixture
cross join public.branches
where branches.code = 'm63_sql_gd'
  and fixture.name in ('accounts', 'accounts2', 'godown', 'keeper', 'delivery', 'sales');

insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
select (select id from fixture where name = 'other_acct'), branches.id,
  (select id from fixture where name = 'admin')
from public.branches where code = 'm63_sql_other';

insert into public.zones (branch_id, code, name, is_active)
select id, 'm63_sql_z', 'M63 Zone', true from public.branches where code = 'm63_sql_gd';
insert into public.crates (zone_id, code, name, is_active)
select id, 'm63_sql_c', 'M63 Crate', true from public.zones where code = 'm63_sql_z';

insert into public.suppliers (name, is_active)
values ('M63 SQL Brand', true);

insert into public.products (sku, name, is_active, supplier_id)
select 'm63_sql_sku', 'M63 SQL Soap', true, suppliers.id
from public.suppliers where suppliers.name = 'M63 SQL Brand';

insert into public.stock_balances (crate_id, product_id, quantity)
select crates.id, products.id, 21
from public.crates, public.products
where crates.code = 'm63_sql_c' and products.sku = 'm63_sql_sku';

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
  (select count(*) from public.stock_receipts) as receipts,
  (
    select coalesce(sum(stock_balances.quantity), 0)
    from public.stock_balances
    join public.crates on crates.id = stock_balances.crate_id
    where crates.location_role = 'quarantine'
  ) as quarantine_qty;

create or replace function pg_temp.approve_request(key text)
returns jsonb
language plpgsql as $$
declare
  created jsonb;
  submitted jsonb;
  approved jsonb;
  gd uuid;
  brand uuid;
  product_id uuid;
  lines jsonb;
begin
  select id into gd from public.branches where code = 'm63_sql_gd';
  select id into brand from public.suppliers where name = 'M63 SQL Brand';
  select products.id into product_id from public.products where products.sku = 'm63_sql_sku';
  lines := jsonb_build_array(jsonb_build_object('product_id', product_id, 'requested_cases', 4));
  perform pg_temp.as_user('accounts');
  created := public.create_stock_refill_request(brand, gd, lines, key || '-c', null);
  submitted := public.submit_stock_refill_request(
    (created ->> 'id')::uuid, (created ->> 'version')::integer, key || '-s'
  );
  perform pg_temp.as_user('admin');
  approved := public.approve_stock_refill_request(
    (submitted ->> 'id')::uuid, (submitted ->> 'version')::integer, key || '-a', null
  );
  perform pg_temp.as_user('accounts');
  return approved;
end;
$$;

do $$
begin
  insert into public.stock_refill_supplier_communications (
    refill_request_id, supplier_id, destination_godown_id, channel,
    communicated_at, recorded_by, send_idempotency_key, send_fingerprint
  )
  select
    gen_random_uuid(), suppliers.id, branches.id, 'phone', now(),
    (select id from fixture where name = 'accounts'),
    'direct-send', 'fp'
  from public.suppliers, public.branches
  where suppliers.name = 'M63 SQL Brand' and branches.code = 'm63_sql_gd';
  raise exception 'direct communication insert must be blocked';
exception
  when sqlstate '42501' then null;
end $$;

do $$
declare
  approved jsonb;
  sent jsonb;
  replay jsonb;
  ack jsonb;
  declined jsonb;
  dispatch jsonb;
  corrected jsonb;
  gd uuid;
  other_gd uuid;
  brand uuid;
  listed jsonb;
  who text;
begin
  select id into gd from public.branches where code = 'm63_sql_gd';
  select id into other_gd from public.branches where code = 'm63_sql_other';
  select id into brand from public.suppliers where name = 'M63 SQL Brand';

  approved := pg_temp.approve_request('m63sql-happy');
  if approved ->> 'communication_status' is distinct from 'not_sent' then
    raise exception 'approved request must start unsent';
  end if;

  -- Admin / GM / keeper / delivery / sales cannot send.
  foreach who in array array['admin', 'godown', 'keeper', 'delivery', 'sales']
  loop
    perform pg_temp.as_user(who);
    begin
      perform public.record_stock_refill_supplier_communication(
        (approved ->> 'id')::uuid,
        (approved ->> 'version')::integer,
        'whatsapp',
        now(),
        'm63sql-deny-' || who,
        null,
        null
      );
      raise exception '% must not record supplier communication', who;
    exception
      when sqlstate '42501' then null;
    end;
  end loop;

  -- Cross-godown Accounts cannot send.
  perform pg_temp.as_user('other_acct');
  begin
    perform public.record_stock_refill_supplier_communication(
      (approved ->> 'id')::uuid,
      (approved ->> 'version')::integer,
      'phone',
      now(),
      'm63sql-cross',
      null,
      null
    );
    raise exception 'cross-godown accounts must not send';
  exception
    when sqlstate '42501' then null;
  end;

  -- Draft / submitted / rejected cannot send.
  perform pg_temp.as_user('accounts');
  approved := pg_temp.approve_request('m63sql-ok');
  sent := public.record_stock_refill_supplier_communication(
    (approved ->> 'id')::uuid,
    (approved ->> 'version')::integer,
    'email',
    now(),
    'm63sql-send',
    'ext-1',
    'called brand desk'
  );
  if sent ->> 'communication_status' is distinct from 'sent'
     or sent -> 'communication' ->> 'channel' is distinct from 'email'
     or sent ->> 'acknowledgement_status' is distinct from 'pending'
     or sent ->> 'status' is distinct from 'approved' then
    raise exception 'send must attest without changing approval status';
  end if;
  if (
    select count(*) from public.stock_refill_request_events
    where refill_request_id = (sent ->> 'id')::uuid
      and action = 'sent_to_supplier'
  ) <> 1 then
    raise exception 'send must write one sent event';
  end if;

  -- Lost-response replay: same actor, same key, same payload.
  replay := public.record_stock_refill_supplier_communication(
    (approved ->> 'id')::uuid,
    (approved ->> 'version')::integer,
    'email',
    (sent -> 'communication' ->> 'communicated_at')::timestamptz,
    'm63sql-send',
    'ext-1',
    'called brand desk'
  );
  if replay ->> 'id' is distinct from sent ->> 'id' then
    raise exception 'send replay must return the original request';
  end if;
  if (
    select count(*) from public.stock_refill_supplier_communications
    where refill_request_id = (sent ->> 'id')::uuid
  ) <> 1 then
    raise exception 'send replay must not insert a second communication';
  end if;
  if (
    select count(*) from public.stock_refill_request_events
    where refill_request_id = (sent ->> 'id')::uuid
      and action = 'sent_to_supplier'
  ) <> 1 then
    raise exception 'send replay must not duplicate events';
  end if;

  -- Conflicting payload, same key.
  begin
    perform public.record_stock_refill_supplier_communication(
      (approved ->> 'id')::uuid,
      (sent ->> 'version')::integer,
      'phone',
      now(),
      'm63sql-send',
      'other',
      null
    );
    raise exception 'conflicting send payload must fail';
  exception
    when sqlstate '23505' then null;
  end;

  -- Duplicate send with a different key.
  begin
    perform public.record_stock_refill_supplier_communication(
      (approved ->> 'id')::uuid,
      (sent ->> 'version')::integer,
      'phone',
      now(),
      'm63sql-send-2',
      null,
      null
    );
    raise exception 'second send must fail';
  exception
    when sqlstate '23505' then null;
    when sqlstate 'PT409' then null;
  end;

  -- Foreign actor same send key must be 42501 without payload.
  perform pg_temp.as_user('accounts2');
  begin
    perform public.record_stock_refill_supplier_communication(
      (approved ->> 'id')::uuid,
      (sent ->> 'version')::integer,
      'email',
      (sent -> 'communication' ->> 'communicated_at')::timestamptz,
      'm63sql-send',
      'ext-1',
      'called brand desk'
    );
    raise exception 'foreign send key must not disclose';
  exception
    when sqlstate '42501' then null;
  end;

  -- Acknowledgement and dispatch on the happy path.
  perform pg_temp.as_user('accounts');
  ack := public.record_stock_refill_supplier_acknowledgement(
    (sent ->> 'id')::uuid,
    (sent ->> 'version')::integer,
    'acknowledged',
    now(),
    'm63sql-ack',
    'ack-ref',
    'ok',
    null
  );
  if ack ->> 'acknowledgement_status' is distinct from 'acknowledged' then
    raise exception 'acknowledgement did not persist';
  end if;
  replay := public.record_stock_refill_supplier_acknowledgement(
    (sent ->> 'id')::uuid,
    (sent ->> 'version')::integer,
    'acknowledged',
    (ack -> 'communication' ->> 'acknowledgement_at')::timestamptz,
    'm63sql-ack',
    'ack-ref',
    'ok',
    null
  );
  if (
    select count(*) from public.stock_refill_request_events
    where refill_request_id = (sent ->> 'id')::uuid
      and action = 'supplier_acknowledged'
  ) <> 1 then
    raise exception 'ack replay must not duplicate events';
  end if;

  dispatch := public.record_stock_refill_supplier_dispatch(
    (ack ->> 'id')::uuid,
    (ack ->> 'version')::integer,
    current_date,
    'm63sql-disp',
    'DN-1',
    current_date + 2,
    'Carrier',
    'TN-9',
    'TRK-1',
    'left plant'
  );
  if dispatch ->> 'dispatch_status' is distinct from 'recorded'
     or dispatch ->> 'expected_arrival_on' is null then
    raise exception 'dispatch did not persist';
  end if;
  if dispatch ->> 'status' is distinct from 'approved' then
    raise exception 'dispatch must not change approval status';
  end if;

  corrected := public.record_stock_refill_supplier_dispatch(
    (dispatch ->> 'id')::uuid,
    (dispatch ->> 'version')::integer,
    current_date,
    'm63sql-disp-fix',
    'DN-1B',
    current_date + 3,
    'Carrier',
    'TN-9',
    'TRK-1',
    'eta updated'
  );
  if corrected -> 'dispatch' ->> 'supplier_dispatch_reference' is distinct from 'DN-1B' then
    raise exception 'dispatch correction did not update the current row';
  end if;
  if (
    select count(*) from public.stock_refill_request_events
    where refill_request_id = (dispatch ->> 'id')::uuid
      and action in ('supplier_dispatch_recorded', 'supplier_dispatch_corrected')
  ) <> 2 then
    raise exception 'dispatch correction must keep the original event';
  end if;

  -- Decline blocks dispatch and does not revert Admin approval.
  approved := pg_temp.approve_request('m63sql-decl');
  perform pg_temp.as_user('accounts');
  sent := public.record_stock_refill_supplier_communication(
    (approved ->> 'id')::uuid,
    (approved ->> 'version')::integer,
    'phone',
    now(),
    'm63sql-decl-s',
    null,
    null
  );
  declined := public.record_stock_refill_supplier_acknowledgement(
    (sent ->> 'id')::uuid,
    (sent ->> 'version')::integer,
    'declined',
    now(),
    'm63sql-decl-a',
    null,
    null,
    'no stock at plant'
  );
  if declined ->> 'status' is distinct from 'approved'
     or declined ->> 'acknowledgement_status' is distinct from 'declined' then
    raise exception 'decline must keep Admin approval immutable';
  end if;
  begin
    perform public.record_stock_refill_supplier_dispatch(
      (declined ->> 'id')::uuid,
      (declined ->> 'version')::integer,
      current_date,
      'm63sql-decl-d',
      null, null, null, null, null, null
    );
    raise exception 'declined request must not record dispatch';
  exception
    when sqlstate '42501' then null;
  end;

  -- Audited acknowledgement correction restores dispatch eligibility.
  ack := public.record_stock_refill_supplier_acknowledgement(
    (declined ->> 'id')::uuid,
    (declined ->> 'version')::integer,
    'acknowledged',
    now(),
    'm63sql-decl-fix',
    'later-ok',
    null,
    null
  );
  if ack ->> 'acknowledgement_status' is distinct from 'acknowledged' then
    raise exception 'acknowledgement correction did not restore acknowledged';
  end if;
  dispatch := public.record_stock_refill_supplier_dispatch(
    (ack ->> 'id')::uuid,
    (ack ->> 'version')::integer,
    current_date,
    'm63sql-decl-d2',
    null, null, null, null, null, null
  );
  if dispatch ->> 'dispatch_status' is distinct from 'recorded' then
    raise exception 'dispatch after acknowledgement correction must succeed';
  end if;

  -- Not approved / rejected cannot send.
  perform pg_temp.as_user('accounts');
  approved := public.create_stock_refill_request(
    brand, gd,
    jsonb_build_array(jsonb_build_object(
      'product_id', (select products.id from public.products where sku = 'm63_sql_sku'),
      'requested_cases', 1
    )),
    'm63sql-draft-c',
    null
  );
  begin
    perform public.record_stock_refill_supplier_communication(
      (approved ->> 'id')::uuid, (approved ->> 'version')::integer,
      'email', now(), 'm63sql-draft-s', null, null
    );
    raise exception 'draft must not send';
  exception
    when sqlstate '42501' then null;
  end;
  approved := public.submit_stock_refill_request(
    (approved ->> 'id')::uuid, (approved ->> 'version')::integer, 'm63sql-draft-sub'
  );
  perform pg_temp.as_user('admin');
  approved := public.reject_stock_refill_request(
    (approved ->> 'id')::uuid, (approved ->> 'version')::integer, 'not needed', 'm63sql-rej'
  );
  perform pg_temp.as_user('accounts');
  begin
    perform public.record_stock_refill_supplier_communication(
      (approved ->> 'id')::uuid, (approved ->> 'version')::integer,
      'email', now(), 'm63sql-rej-s', null, null
    );
    raise exception 'rejected must not send';
  exception
    when sqlstate '42501' then null;
  end;

  -- Inactive godown: historical GET remains; new send fails.
  approved := pg_temp.approve_request('m63sql-dead');
  perform pg_temp.as_user('admin');
  perform public.set_branch_active(gd, false);
  perform pg_temp.as_user('accounts');
  replay := public.get_stock_refill_request((approved ->> 'id')::uuid);
  if replay ->> 'id' is distinct from approved ->> 'id' then
    raise exception 'historical GET must survive inactive godown';
  end if;
  begin
    perform public.record_stock_refill_supplier_communication(
      (approved ->> 'id')::uuid, (approved ->> 'version')::integer,
      'phone', now(), 'm63sql-dead-s', null, null
    );
    raise exception 'send must fail on inactive godown';
  exception
    when sqlstate '23514' then null;
    when sqlstate '42501' then null;
  end;
  perform pg_temp.as_user('admin');
  perform public.set_branch_active(gd, true);

  -- Assignment removal blocks completed-send replay.
  approved := pg_temp.approve_request('m63sql-unassign');
  perform pg_temp.as_user('accounts');
  sent := public.record_stock_refill_supplier_communication(
    (approved ->> 'id')::uuid, (approved ->> 'version')::integer,
    'whatsapp', now(), 'm63sql-unassign-s', null, null
  );
  delete from public.user_branch_assignments
  where user_id = (select id from fixture where name = 'accounts')
    and branch_id = gd;
  begin
    perform public.record_stock_refill_supplier_communication(
      (approved ->> 'id')::uuid, (sent ->> 'version')::integer,
      'whatsapp', (sent -> 'communication' ->> 'communicated_at')::timestamptz,
      'm63sql-unassign-s', null, null
    );
    raise exception 'replay after assignment removal must fail';
  exception
    when sqlstate '42501' then null;
  end;
  insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
  select (select id from fixture where name = 'accounts'), gd,
    (select id from fixture where name = 'admin');

  -- Permission revocation blocks replay.
  perform pg_temp.as_user('accounts');
  begin
    perform public.record_stock_refill_supplier_communication(
      (sent ->> 'id')::uuid, (sent ->> 'version')::integer,
      'whatsapp', (sent -> 'communication' ->> 'communicated_at')::timestamptz,
      'm63sql-unassign-s', null, null
    );
  exception
    when sqlstate '23505' then null;
    when sqlstate 'PT409' then null;
  end;
  delete from public.user_roles
  where user_id = (select id from fixture where name = 'accounts')
    and role_id = (select id from public.roles where code = 'accounts');
  begin
    perform public.record_stock_refill_supplier_communication(
      (sent ->> 'id')::uuid, (sent ->> 'version')::integer,
      'whatsapp', (sent -> 'communication' ->> 'communicated_at')::timestamptz,
      'm63sql-unassign-s', null, null
    );
    raise exception 'replay after permission revocation must fail';
  exception
    when sqlstate '42501' then null;
  end;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select (select id from fixture where name = 'accounts'), roles.id,
    (select id from fixture where name = 'admin')
  from public.roles where roles.code = 'accounts';

  -- operations.monitor is still not a refill grant.
  insert into public.user_roles (user_id, role_id, assigned_by)
  select (select id from fixture where name = 'sales'), roles.id,
    (select id from fixture where name = 'admin')
  from public.roles where roles.code = 'admin'
  on conflict do nothing;
  delete from public.user_roles
  where user_id = (select id from fixture where name = 'sales');
  insert into public.role_permissions (role_id, permission_id)
  select r.id, p.id
  from public.roles r, public.permissions p
  where r.code = 'salesperson' and p.code = 'operations.monitor'
  on conflict do nothing;
  insert into public.user_roles (user_id, role_id, assigned_by)
  select (select id from fixture where name = 'sales'), roles.id,
    (select id from fixture where name = 'admin')
  from public.roles where roles.code = 'salesperson';
  perform pg_temp.as_user('sales');
  begin
    perform public.list_stock_refill_requests();
    raise exception 'monitor-only salesperson must not list refill';
  exception
    when sqlstate '42501' then null;
  end;

  perform pg_temp.as_user('accounts');
  listed := public.list_stock_refill_requests();
  if listed ->> 'total' is null then
    raise exception 'accounts list must succeed';
  end if;

  if has_function_privilege(
    'authenticated',
    'app_private.enable_refill_write()',
    'execute'
  ) then
    raise exception 'mutation helper must remain revoked';
  end if;
end $$;

reset role;
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
       or s.quarantine_qty is distinct from (
         select coalesce(sum(stock_balances.quantity), 0)
         from public.stock_balances
         join public.crates on crates.id = stock_balances.crate_id
         where crates.location_role = 'quarantine'
       )
  ) then
    raise exception 'M6.3 mutations must have zero stock effects';
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
select pg_advisory_unlock(hashtext('sherlyos.m6.refill_tests'));
