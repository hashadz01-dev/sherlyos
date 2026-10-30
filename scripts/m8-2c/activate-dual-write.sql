-- M8.2C isolated dual-write activation. Owner gate.
-- Enables stock.lots.dual_write_enabled only.
-- Leaves damage.stock_hold_ready and stock.lots.aggregate_only_blocked false.
-- Does not change SHORT_SHIPMENT_OPERATIONAL (source constant).

do $$
declare
  sysid bigint;
begin
  if current_setting('app.m82c_seed_approved', true) is distinct from 'on' then
    raise exception 'M8.2C cutover refused: missing app.m82c_seed_approved=on';
  end if;

  select system_identifier into sysid from pg_control_system();
  if sysid in (7699785797738577957, 7702023892197691429) then
    raise exception 'M8.2C cutover refused owner or m81c database (%)', sysid;
  end if;

  if (select value from public.app_configuration where key = 'damage.stock_hold_ready')
       is distinct from 'false'::jsonb
     or (select value from public.app_configuration where key = 'stock.lots.aggregate_only_blocked')
       is distinct from 'false'::jsonb
  then
    raise exception 'M8.2C cutover refused: companion flags must stay false';
  end if;

  update public.app_configuration
  set value = 'true'::jsonb
  where key = 'stock.lots.dual_write_enabled';

  if not found then
    raise exception 'stock.lots.dual_write_enabled row missing';
  end if;
end $$;

select key, value
from public.app_configuration
where key in (
  'damage.stock_hold_ready',
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked'
)
order by key;
