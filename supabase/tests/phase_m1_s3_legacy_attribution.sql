-- M1-S3 legacy lot attribution. Disposable. Rolls back.
-- Does not contact the development cloud or leave cutover flags on.

begin;

create temp table s3_fixture (
  name text primary key,
  id uuid not null
);

create temp table s3_refs (
  name text primary key,
  id uuid not null
);

grant select on s3_fixture to authenticated;
grant select, insert, update, delete on s3_refs to authenticated;

insert into s3_fixture (name, id)
values
  ('admin', gen_random_uuid()),
  ('admin2', gen_random_uuid()),
  ('godown', gen_random_uuid()),
  ('godown_b', gen_random_uuid()),
  ('keeper', gen_random_uuid()),
  ('sales', gen_random_uuid());

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  s3_fixture.id,
  'authenticated',
  'authenticated',
  s3_fixture.name || '.m1s3@example.com',
  extensions.crypt('local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', s3_fixture.name),
  now(),
  now()
from s3_fixture;

insert into public.profiles (id, full_name, is_active)
select id, name, true from s3_fixture
on conflict (id) do update set is_active = true;

insert into public.user_roles (user_id, role_id, assigned_by)
select s3_fixture.id, roles.id, (select id from s3_fixture where name = 'admin')
from s3_fixture
join public.roles on roles.code = case s3_fixture.name
  when 'admin' then 'admin'
  when 'admin2' then 'admin'
  when 'godown' then 'godown_manager'
  when 'godown_b' then 'godown_manager'
  when 'keeper' then 'store_keeper'
  when 'sales' then 'salesperson'
end
on conflict do nothing;

create or replace function public.m1s3_claim(actor text)
returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claims',
    (select json_build_object('sub', id, 'role', 'authenticated')::text
     from s3_fixture where name = actor),
    true
  );
end;
$$;

create or replace function public.m1s3_line(target uuid, sku text)
returns uuid
language sql
as $$
  select stock_lot_reconciliation_lines.id
  from public.stock_lot_reconciliation_lines
  join public.products on products.id = stock_lot_reconciliation_lines.product_id
  where stock_lot_reconciliation_lines.session_id = target
    and products.sku = m1s3_line.sku;
$$;

create or replace function public.m1s3_version(target uuid)
returns integer
language sql
as $$
  select version from public.stock_lot_reconciliations where id = target;
$$;

do $$
begin
  if exists (select 1 from public.stock_lots)
    or exists (select 1 from public.stock_legacy_lot_seeds)
  then
    raise exception 'M1-S3 SQL test requires empty local lot tables';
  end if;
  if coalesce((select value from public.app_configuration where key = 'stock.lots.dual_write_enabled'), 'false'::jsonb)
     is distinct from 'false'::jsonb
    or coalesce((select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked'), 'false'::jsonb)
     is distinct from 'false'::jsonb
  then
    raise exception 'M1-S3 SQL test requires cutover flags false/false';
  end if;
end;
$$;

select public.m1s3_claim('admin');
set local role authenticated;

insert into s3_refs (name, id)
values
  ('branch_a', public.create_branch('m1s3_a', 'M1 S3 A')),
  ('branch_b', public.create_branch('m1s3_b', 'M1 S3 B'));

insert into s3_refs (name, id)
values
  ('zone_a', public.create_zone((select id from s3_refs where name = 'branch_a'), 'm1s3za', 'Zone A', null)),
  ('zone_b', public.create_zone((select id from s3_refs where name = 'branch_b'), 'm1s3zb', 'Zone B', null));

insert into s3_refs (name, id)
values
  ('crate_a1', public.create_crate((select id from s3_refs where name = 'zone_a'), 'm1s3ca1', 'Crate A1', null)),
  ('crate_a2', public.create_crate((select id from s3_refs where name = 'zone_a'), 'm1s3ca2', 'Crate A2', null)),
  ('crate_a3', public.create_crate((select id from s3_refs where name = 'zone_a'), 'm1s3ca3', 'Crate A3', null)),
  ('crate_b', public.create_crate((select id from s3_refs where name = 'zone_b'), 'm1s3cb', 'Crate B', null)),
  ('soap', public.create_product('m1s3-soap', 'M1 S3 Soap', null, null)),
  ('oil', public.create_product('m1s3-oil', 'M1 S3 Oil', null, null)),
  ('found', public.create_product('m1s3-found', 'M1 S3 Found', null, null));

select public.assign_user_branch((select id from s3_fixture where name = 'godown'), (select id from s3_refs where name = 'branch_a'));
select public.assign_user_branch((select id from s3_fixture where name = 'godown_b'), (select id from s3_refs where name = 'branch_b'));
select public.assign_user_branch((select id from s3_fixture where name = 'keeper'), (select id from s3_refs where name = 'branch_a'));
select public.assign_user_branch((select id from s3_fixture where name = 'sales'), (select id from s3_refs where name = 'branch_a'));

select public.set_product_expiry_policy((select id from s3_refs where name = 'soap'), 'expiry_controlled');
select public.set_product_expiry_policy((select id from s3_refs where name = 'oil'), 'non_expiring');
select public.set_product_expiry_policy((select id from s3_refs where name = 'found'), 'expiry_controlled');

select public.post_opening_stock((select id from s3_refs where name = 'soap'), (select id from s3_refs where name = 'crate_a1'), 6, 'm1s3-open-soap', null);
select public.post_opening_stock((select id from s3_refs where name = 'oil'), (select id from s3_refs where name = 'crate_a1'), 4, 'm1s3-open-oil', null);
select public.post_opening_stock((select id from s3_refs where name = 'soap'), (select id from s3_refs where name = 'crate_a2'), 3, 'm1s3-open-soap-2', null);
select public.post_opening_stock((select id from s3_refs where name = 'soap'), (select id from s3_refs where name = 'crate_a3'), 2, 'm1s3-open-soap-3', null);
select public.post_opening_stock((select id from s3_refs where name = 'soap'), (select id from s3_refs where name = 'crate_b'), 2, 'm1s3-open-soap-b', null);

create temp table s3_inventory as
select
  (select count(*) from public.stock_balances) as balance_rows,
  (select coalesce(sum(quantity), 0) from public.stock_balances) as balance_qty,
  (select count(*) from public.stock_ledger) as ledger_rows,
  (select coalesce(sum(quantity), 0) from public.stock_ledger) as ledger_net;

insert into s3_refs (name, id)
select
  'session_main',
  (public.create_lot_reconciliation(
    (select id from s3_refs where name = 'branch_a'),
    array[
      (select id from s3_refs where name = 'crate_a1'),
      (select id from s3_refs where name = 'crate_a2')
    ],
    'm1s3-create-main',
    'mixed crates'
  ) ->> 'id')::uuid;

insert into s3_refs (name, id)
select
  'session_found',
  (public.create_lot_reconciliation(
    (select id from s3_refs where name = 'branch_a'),
    array[(select id from s3_refs where name = 'crate_a3')],
    'm1s3-create-found',
    null
  ) ->> 'id')::uuid;

select public.m1s3_claim('godown');

do $$
declare
  session uuid := (select id from s3_refs where name = 'session_main');
  payload jsonb;
  version integer;
begin
  payload := public.get_lot_reconciliation(session);
  version := (payload ->> 'version')::integer;
  payload := public.save_lot_reconciliation_count(
    session, version,
    (select id from s3_refs where name = 'crate_a1'),
    (select id from s3_refs where name = 'soap'),
    6
  );
  version := (payload ->> 'version')::integer;
  payload := public.save_lot_reconciliation_lots(
    session, version, public.m1s3_line(session, 'm1s3-soap'),
    '[
      {"manufacturer_lot_code":"SOAP-A","expiry_date":"2028-01-01","expiry_unknown":false,"identity_unknown":false,"quantity":4,"condition":"available"},
      {"identity_unknown":true,"expiry_unknown":true,"quantity":2,"condition":"available"}
    ]'::jsonb
  );
  version := (payload ->> 'version')::integer;
  payload := public.save_lot_reconciliation_count(
    session, version,
    (select id from s3_refs where name = 'crate_a1'),
    (select id from s3_refs where name = 'oil'),
    4
  );
  version := (payload ->> 'version')::integer;
  payload := public.save_lot_reconciliation_lots(
    session, version, public.m1s3_line(session, 'm1s3-oil'),
    '[{"identity_unknown":true,"expiry_unknown":true,"quantity":4,"condition":"available"}]'::jsonb
  );
  version := (payload ->> 'version')::integer;
  payload := public.save_lot_reconciliation_count(
    session, version,
    (select id from s3_refs where name = 'crate_a2'),
    (select id from s3_refs where name = 'soap'),
    3
  );
  version := (payload ->> 'version')::integer;
  payload := public.save_lot_reconciliation_lots(
    session, version,
    (
      select stock_lot_reconciliation_lines.id
      from public.stock_lot_reconciliation_lines
      where session_id = session
        and crate_id = (select id from s3_refs where name = 'crate_a2')
        and product_id = (select id from s3_refs where name = 'soap')
    ),
    '[{"manufacturer_lot_code":"SOAP-A","expiry_date":"2028-01-01","expiry_unknown":false,"identity_unknown":false,"quantity":3,"condition":"available"}]'::jsonb
  );
  version := (payload ->> 'version')::integer;
  perform public.submit_lot_reconciliation(session, version, 'm1s3-submit-main');
end;
$$;

do $$
declare
  session uuid := (select id from s3_refs where name = 'session_found');
  payload jsonb;
  version integer;
begin
  payload := public.get_lot_reconciliation(session);
  version := (payload ->> 'version')::integer;
  payload := public.save_lot_reconciliation_count(
    session, version,
    (select id from s3_refs where name = 'crate_a3'),
    (select id from s3_refs where name = 'soap'),
    2
  );
  version := (payload ->> 'version')::integer;
  payload := public.save_lot_reconciliation_lots(
    session, version, public.m1s3_line(session, 'm1s3-soap'),
    '[{"manufacturer_lot_code":"SOAP-C","expiry_date":"2028-06-01","expiry_unknown":false,"identity_unknown":false,"quantity":2,"condition":"available"}]'::jsonb
  );
  version := (payload ->> 'version')::integer;
  payload := public.add_lot_reconciliation_found_product(
    session, version,
    (select id from s3_refs where name = 'crate_a3'),
    (select id from s3_refs where name = 'found')
  );
  version := (payload ->> 'version')::integer;
  payload := public.save_lot_reconciliation_count(
    session, version,
    (select id from s3_refs where name = 'crate_a3'),
    (select id from s3_refs where name = 'found'),
    0
  );
  version := (payload ->> 'version')::integer;
  perform public.submit_lot_reconciliation(session, version, 'm1s3-submit-found');
end;
$$;

select public.m1s3_claim('admin2');

do $$
begin
  perform public.approve_lot_reconciliation(
    (select id from s3_refs where name = 'session_main'),
    public.m1s3_version((select id from s3_refs where name = 'session_main')),
    'matched mixed lots',
    'm1s3-approve-main'
  );
  perform public.approve_lot_reconciliation(
    (select id from s3_refs where name = 'session_found'),
    public.m1s3_version((select id from s3_refs where name = 'session_found')),
    'found product present',
    'm1s3-approve-found'
  );
end;
$$;

-- T08 unauthorized role cannot read readiness or apply
select public.m1s3_claim('keeper');
do $$
begin
  perform public.get_lot_attribution_readiness((select id from s3_refs where name = 'session_main'));
  raise exception 'T08 keeper readiness was accepted';
exception
  when insufficient_privilege then null;
end;
$$;

select public.m1s3_claim('godown');
do $$
begin
  perform public.apply_legacy_lot_attribution(
    (select id from s3_refs where name = 'session_main'),
    public.m1s3_version((select id from s3_refs where name = 'session_main')),
    'm1s3-gm-apply'
  );
  raise exception 'T08 GM apply was accepted';
exception
  when insufficient_privilege then null;
end;
$$;

-- T09 cross-branch GM cannot apply
select public.m1s3_claim('godown_b');
do $$
begin
  perform public.apply_legacy_lot_attribution(
    (select id from s3_refs where name = 'session_main'),
    public.m1s3_version((select id from s3_refs where name = 'session_main')),
    'm1s3-cross-apply'
  );
  raise exception 'T09 cross-branch apply was accepted';
exception
  when insufficient_privilege then null;
end;
$$;

select public.m1s3_claim('admin');

-- T14 missing legacy stock / attribution before seed
do $$
declare
  readiness jsonb;
begin
  readiness := public.get_lot_attribution_readiness((select id from s3_refs where name = 'session_main'));
  if readiness ->> 'eligible' is distinct from 'false' then
    raise exception 'T14 readiness should be blocked before seed';
  end if;
  if readiness -> 'blockers' ->> 0 not like '%seed%' then
    raise exception 'T14 expected seed blocker, got %', readiness;
  end if;
  begin
    perform public.apply_legacy_lot_attribution(
      (select id from s3_refs where name = 'session_main'),
      public.m1s3_version((select id from s3_refs where name = 'session_main')),
      'm1s3-apply-before-seed'
    );
    raise exception 'T14 apply before seed was accepted';
  exception
    when check_violation then
      if sqlerrm not like '%seed%' then
        raise;
      end if;
  end;
end;
$$;

-- T01 successful local seed
do $$
declare
  seeded jsonb;
begin
  seeded := public.seed_legacy_stock_lots();
  if coalesce((seeded ->> 'seeded')::integer, 0) < 5 then
    raise exception 'T01 expected to seed fixture grains, got %', seeded;
  end if;
  if seeded ->> 'aggregate_only_blocked' is distinct from 'true' then
    raise exception 'T01 seed did not block aggregate-only posting';
  end if;
end;
$$;

-- T20 cutover: dual-write already enabled blocks apply (savepoint so flags revert)
reset role;
savepoint dual_write_probe;
update public.app_configuration
set value = 'true'::jsonb
where key = 'stock.lots.dual_write_enabled';
select public.m1s3_claim('admin');
set local role authenticated;
do $$
begin
  perform public.apply_legacy_lot_attribution(
    (select id from s3_refs where name = 'session_main'),
    public.m1s3_version((select id from s3_refs where name = 'session_main')),
    'm1s3-apply-dual-write'
  );
  raise exception 'T20 apply with dual-write enabled was accepted';
exception
  when check_violation then
    if sqlerrm not like '%dual-write%' then
      raise;
    end if;
end;
$$;
reset role;
rollback to savepoint dual_write_probe;
select public.m1s3_claim('admin');
set local role authenticated;

-- Found-product session is approved but not eligible
do $$
declare
  readiness jsonb;
begin
  readiness := public.get_lot_attribution_readiness((select id from s3_refs where name = 'session_found'));
  if readiness ->> 'eligible' is distinct from 'false' then
    raise exception 'found-product session should not be eligible';
  end if;
  begin
    perform public.apply_legacy_lot_attribution(
      (select id from s3_refs where name = 'session_found'),
      public.m1s3_version((select id from s3_refs where name = 'session_found')),
      'm1s3-apply-found'
    );
    raise exception 'found-product apply was accepted';
  exception
    when check_violation then
      if sqlerrm not like '%found-product%' then
        raise;
      end if;
  end;
end;
$$;

-- T11 missing classification
reset role;
update public.products
set expiry_policy = null
where id = (select id from s3_refs where name = 'oil');
select public.m1s3_claim('admin');
set local role authenticated;
do $$
begin
  perform public.apply_legacy_lot_attribution(
    (select id from s3_refs where name = 'session_main'),
    public.m1s3_version((select id from s3_refs where name = 'session_main')),
    'm1s3-apply-unclassified'
  );
  raise exception 'T11 unclassified apply was accepted';
exception
  when check_violation then
    if sqlerrm not like '%Unclassified%' then
      raise;
    end if;
end;
$$;
reset role;
update public.products
set expiry_policy = 'non_expiring'
where id = (select id from s3_refs where name = 'oil');
select public.m1s3_claim('admin');
set local role authenticated;

-- T10 stale approved evidence. Replica role skips the aggregate/ledger
-- trigger only inside this savepoint so we can simulate freeze drift.
reset role;
savepoint stale_probe;
set local session_replication_role = replica;
update public.stock_balances
set quantity = 7
where crate_id = (select id from s3_refs where name = 'crate_a1')
  and product_id = (select id from s3_refs where name = 'soap');
set local session_replication_role = origin;
select public.m1s3_claim('admin');
set local role authenticated;
do $$
begin
  perform public.apply_legacy_lot_attribution(
    (select id from s3_refs where name = 'session_main'),
    public.m1s3_version((select id from s3_refs where name = 'session_main')),
    'm1s3-apply-stale'
  );
  raise exception 'T10 stale apply was accepted';
exception
  when check_violation then
    if sqlerrm not like '%no longer matches%' then
      raise;
    end if;
end;
$$;
reset role;
rollback to savepoint stale_probe;
select public.m1s3_claim('admin');
set local role authenticated;

-- T12 incorrect lot totals via tamper
reset role;
select set_config('app.lot_reconciliation_write', 'on', true);
update public.stock_lot_reconciliation_lot_entries
set quantity = 5
where line_id = public.m1s3_line((select id from s3_refs where name = 'session_main'), 'm1s3-oil');
select public.m1s3_claim('admin');
set local role authenticated;
do $$
begin
  perform public.apply_legacy_lot_attribution(
    (select id from s3_refs where name = 'session_main'),
    public.m1s3_version((select id from s3_refs where name = 'session_main')),
    'm1s3-apply-lot-total'
  );
  raise exception 'T12 mismatched lot totals were accepted';
exception
  when check_violation then
    if sqlerrm not like '%Lot evidence%' and sqlerrm not like '%conserve%' then
      raise;
    end if;
end;
$$;
reset role;
select set_config('app.lot_reconciliation_write', 'on', true);
update public.stock_lot_reconciliation_lot_entries
set quantity = 4
where line_id = public.m1s3_line((select id from s3_refs where name = 'session_main'), 'm1s3-oil');
select public.m1s3_claim('admin');
set local role authenticated;

-- T15 negative / mismatched lot balances
reset role;
select app_private.begin_lot_balance_write('seed');
update public.stock_lot_balances slb
set quantity = 5
from public.stock_legacy_lot_seeds seeds
where seeds.lot_id = slb.lot_id
  and seeds.crate_id = (select id from s3_refs where name = 'crate_a1')
  and seeds.product_id = (select id from s3_refs where name = 'soap');
select app_private.end_lot_balance_write();
select public.m1s3_claim('admin');
set local role authenticated;
do $$
begin
  perform public.apply_legacy_lot_attribution(
    (select id from s3_refs where name = 'session_main'),
    public.m1s3_version((select id from s3_refs where name = 'session_main')),
    'm1s3-apply-mismatch'
  );
  raise exception 'T15 mismatched balances were accepted';
exception
  when check_violation then
    if sqlerrm not like '%legacy-unattributed%' and sqlerrm not like '%no longer matches%' then
      raise;
    end if;
end;
$$;
reset role;
select app_private.begin_lot_balance_write('seed');
update public.stock_lot_balances slb
set quantity = 6
from public.stock_legacy_lot_seeds seeds
where seeds.lot_id = slb.lot_id
  and seeds.crate_id = (select id from s3_refs where name = 'crate_a1')
  and seeds.product_id = (select id from s3_refs where name = 'soap');
select app_private.end_lot_balance_write();
select public.m1s3_claim('admin');
set local role authenticated;

-- T16 atomic rollback: missing marker on one grain must not split others
reset role;
delete from public.stock_legacy_lot_seeds
where crate_id = (select id from s3_refs where name = 'crate_a1')
  and product_id = (select id from s3_refs where name = 'oil');
select public.m1s3_claim('admin');
set local role authenticated;
do $$
declare
  soap_lots integer;
begin
  begin
    perform public.apply_legacy_lot_attribution(
      (select id from s3_refs where name = 'session_main'),
      public.m1s3_version((select id from s3_refs where name = 'session_main')),
      'm1s3-apply-partial'
    );
    raise exception 'T16 partial apply was accepted';
  exception
    when check_violation then
      if sqlerrm not like '%seeded%' then
        raise;
      end if;
  end;
  select count(*)::integer
  into soap_lots
  from public.stock_lot_balances
  join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
  where stock_lot_balances.crate_id = (select id from s3_refs where name = 'crate_a1')
    and stock_lots.product_id = (select id from s3_refs where name = 'soap');
  if soap_lots <> 1 then
    raise exception 'T16 soap lots were partially attributed (% )', soap_lots;
  end if;
  if (select status from public.stock_lot_reconciliations where id = (select id from s3_refs where name = 'session_main'))
     is distinct from 'approved'
  then
    raise exception 'T16 session did not stay approved';
  end if;
end;
$$;
reset role;
insert into public.stock_legacy_lot_seeds (crate_id, product_id, lot_id, quantity, seeded_by)
select
  (select id from s3_refs where name = 'crate_a1'),
  (select id from s3_refs where name = 'oil'),
  stock_lot_balances.lot_id,
  stock_lot_balances.quantity,
  (select id from s3_fixture where name = 'admin')
from public.stock_lot_balances
join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
where stock_lot_balances.crate_id = (select id from s3_refs where name = 'crate_a1')
  and stock_lots.product_id = (select id from s3_refs where name = 'oil');
select public.m1s3_claim('admin');
set local role authenticated;

-- Clients cannot write lot tables
do $$
begin
  insert into public.stock_lots (
    product_id, branch_id, status, origin
  ) values (
    (select id from s3_refs where name = 'soap'),
    (select id from s3_refs where name = 'branch_a'),
    'available',
    'legacy_reconciliation'
  );
  raise exception 'client stock_lots insert was accepted';
exception
  when insufficient_privilege then null;
end;
$$;

-- T02/T03/T04/T13/T18/T19/T21 successful attribution
do $$
declare
  payload jsonb;
  soap_lot_id uuid;
  soap_a1 integer;
  soap_a2 integer;
  oil_status text;
  unknown_lots integer;
  ledger_rows integer;
  ledger_net integer;
  balance_qty integer;
begin
  select count(*), coalesce(sum(quantity), 0)
  into ledger_rows, ledger_net
  from public.stock_ledger;
  select coalesce(sum(quantity), 0) into balance_qty from public.stock_balances;

  payload := public.get_lot_attribution_readiness((select id from s3_refs where name = 'session_main'));
  if payload ->> 'eligible' is distinct from 'true' then
    raise exception 'T02 readiness should be eligible, got %', payload;
  end if;
  if (payload ->> 'known_quantity')::integer <> 7
    or (payload ->> 'unknown_quantity')::integer <> 6
  then
    raise exception 'T03 known/unknown quantities %, %', payload ->> 'known_quantity', payload ->> 'unknown_quantity';
  end if;

  payload := public.apply_legacy_lot_attribution(
    (select id from s3_refs where name = 'session_main'),
    public.m1s3_version((select id from s3_refs where name = 'session_main')),
    'm1s3-apply-main'
  );
  if payload ->> 'status' is distinct from 'applied' then
    raise exception 'T02 status %, expected applied', payload ->> 'status';
  end if;
  if jsonb_array_length(payload -> 'attributions') <> 3 then
    raise exception 'T04 expected 3 grain attributions';
  end if;

  select stock_lots.id
  into soap_lot_id
  from public.stock_lots
  where manufacturer_lot_code = 'SOAP-A'
    and product_id = (select id from s3_refs where name = 'soap')
    and status = 'available';
  if soap_lot_id is null then
    raise exception 'T13 SOAP-A lot was not created';
  end if;
  if (
    select count(*) from public.stock_lots
    where manufacturer_lot_code = 'SOAP-A'
      and product_id = (select id from s3_refs where name = 'soap')
  ) <> 1 then
    raise exception 'T13 duplicate manufacturer lot created';
  end if;

  select quantity into soap_a1
  from public.stock_lot_balances
  where lot_id = soap_lot_id
    and crate_id = (select id from s3_refs where name = 'crate_a1');
  select quantity into soap_a2
  from public.stock_lot_balances
  where lot_id = soap_lot_id
    and crate_id = (select id from s3_refs where name = 'crate_a2');
  if soap_a1 <> 4 or soap_a2 <> 3 then
    raise exception 'T04 SOAP-A crate balances % / %', soap_a1, soap_a2;
  end if;

  select stock_lots.status
  into oil_status
  from public.stock_lot_balances
  join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
  join public.stock_legacy_lot_seeds seeds
    on seeds.lot_id = stock_lots.id
   and seeds.crate_id = stock_lot_balances.crate_id
  where stock_lot_balances.crate_id = (select id from s3_refs where name = 'crate_a1')
    and stock_lots.product_id = (select id from s3_refs where name = 'oil');
  if oil_status is distinct from 'legacy_unattributed' then
    raise exception 'T03 oil unknown remainder status %', oil_status;
  end if;

  select count(*)::integer
  into unknown_lots
  from public.stock_lots
  where product_id = (select id from s3_refs where name = 'oil')
    and manufacturer_lot_code is not null;
  if unknown_lots <> 0 then
    raise exception 'T21 unexpected oil manufacturer lots';
  end if;

  if (select coalesce(sum(quantity), 0) from public.stock_balances) is distinct from balance_qty then
    raise exception 'T18 aggregate quantity changed';
  end if;
  if (select count(*) from public.stock_ledger) is distinct from ledger_rows
    or (select coalesce(sum(quantity), 0) from public.stock_ledger) is distinct from ledger_net
  then
    raise exception 'T19 ledger was rewritten';
  end if;
  if exists (
    select 1
    from public.stock_balances sb
    left join (
      select slb.crate_id, sl.product_id, sum(slb.quantity) as lot_qty
      from public.stock_lot_balances slb
      join public.stock_lots sl on sl.id = slb.lot_id
      group by 1, 2
    ) lots on lots.crate_id = sb.crate_id and lots.product_id = sb.product_id
    where sb.quantity > 0
      and coalesce(lots.lot_qty, 0) is distinct from sb.quantity
  ) then
    raise exception 'T18 grain conservation failed';
  end if;
  if exists (
    select 1 from public.app_configuration
    where key = 'stock.lots.dual_write_enabled' and value = 'true'::jsonb
  ) then
    raise exception 'T20 dual-write was activated';
  end if;
end;
$$;

-- T05 idempotent retry (same key and different key)
do $$
declare
  first uuid;
  second uuid;
  lots_before integer;
  lots_after integer;
begin
  select count(*) into lots_before from public.stock_lots;
  first := (public.apply_legacy_lot_attribution(
    (select id from s3_refs where name = 'session_main'),
    public.m1s3_version((select id from s3_refs where name = 'session_main')),
    'm1s3-apply-main'
  ) ->> 'id')::uuid;
  second := (public.apply_legacy_lot_attribution(
    (select id from s3_refs where name = 'session_main'),
    public.m1s3_version((select id from s3_refs where name = 'session_main')) - 1,
    'm1s3-apply-main-retry'
  ) ->> 'id')::uuid;
  select count(*) into lots_after from public.stock_lots;
  if first is distinct from second or lots_after <> lots_before then
    raise exception 'T05 idempotent retry created extra lots';
  end if;
end;
$$;

-- T17 audit evidence
do $$
begin
  if not exists (
    select 1 from public.stock_lot_reconciliation_events
    where session_id = (select id from s3_refs where name = 'session_main')
      and event_type = 'applied'
  ) then
    raise exception 'T17 missing applied event';
  end if;
  if not exists (
    select 1 from public.audit_logs
    where action = 'apply_legacy_lot_attribution'
      and entity_id = (select id from s3_refs where name = 'session_main')
  ) then
    raise exception 'T17 missing audit row';
  end if;
end;
$$;

-- T22 failed apply recovery already proved by T16; session_main now applied.
-- Crate hold released so a new session may use those crates.
do $$
begin
  if exists (
    select 1 from public.stock_lot_reconciliation_scope_crates
    where session_id = (select id from s3_refs where name = 'session_main')
      and holds_scope
  ) then
    raise exception 'applied session still holds crates';
  end if;
end;
$$;

-- PT409 on a still-approved session (found) with a stale version
do $$
begin
  perform public.apply_legacy_lot_attribution(
    (select id from s3_refs where name = 'session_found'),
    public.m1s3_version((select id from s3_refs where name = 'session_found')) - 1,
    'm1s3-found-stale-version'
  );
  raise exception 'stale version apply was accepted';
exception
  when sqlstate 'PT409' then null;
  when check_violation then
    -- found-product blocker is also acceptable if version matched after lock
    if sqlerrm not like '%found-product%' then
      raise;
    end if;
end;
$$;

rollback;

select 'phase_m1_s3_legacy_attribution passed' as result;
