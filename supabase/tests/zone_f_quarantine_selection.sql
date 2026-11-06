-- NOT RUN. Execute only after 20261106150000_zone_f_quarantine.sql is approved
-- and applied. The fixture godown is created and removed inside one rolled-back
-- transaction. Do not point this script at protected UAT stock.
--
-- Two-session capacity contention cannot be proven in this single transaction.
-- After the function exists, run that case from two connections:
--   1. Both begin.
--   2. Both set the damage-stock trusted GUC through the application path.
--   3. Both call select_zone_f_crate for 3 cases while F-01 has 47.
--   4. The second call must block, then return F-02 or raise the capacity error
--      if F-02 also cannot hold 3. The combined posted quantity must not exceed 50.

begin;

do $tests$
declare
  fixture uuid;
  zone_f uuid;
  first_crate uuid;
  selected uuid;
begin
  insert into public.branches (code, name)
  values ('zone_f_fixture', 'Zone F fixture')
  returning id into fixture;

  perform app_private.enable_trusted_guc('app.quarantine_location_write');
  perform app_private.enable_trusted_guc('app.damage_stock_write');

  insert into public.zones (branch_id, code, name, location_role)
  values (fixture, 'F', 'Zone F', 'quarantine')
  returning id into zone_f;

  insert into public.crates (zone_id, code, name, location_role, capacity_cases)
  values
    (zone_f, 'F-01', 'Crate 01', 'quarantine', 50),
    (zone_f, 'F-02', 'Crate 02', 'quarantine', 50),
    (zone_f, 'F-03', 'Crate 03', 'quarantine', 50),
    (zone_f, 'F-04', 'Crate 04', 'quarantine', 50);

  select id into first_crate from public.crates where zone_id = zone_f and code = 'F-01';

  selected := app_private.select_zone_f_crate(fixture, 5);
  if selected is distinct from first_crate then
    raise exception 'expected F-01 when every crate is empty';
  end if;

  -- Do not insert stock_balances directly. stock_balances_match_ledger rejects
  -- a balance that has no matching ledger. The occupied cases below have to be
  -- posted through the quarantine intake path on this fixture godown:
  --   F-01 = 48, then 5 cases must select F-02.
  --   F-01..F-04 = 50, then 1 case must raise
  --   'no quarantine crate can accept the requested quantity'.
  -- A direct update of protected UAT stock is not a valid setup.
end;
$tests$;

rollback;
