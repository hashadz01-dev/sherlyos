-- Isolated M8.2D lot cutover. Owner gate on sherlyos_m82c only.
-- Schema requires dual-write and aggregate_only_blocked together (M8.1C procedure).
-- damage.stock_hold_ready stays false. SHORT_SHIPMENT_OPERATIONAL stays a source constant.

do $$
declare
  sysid bigint;
  updated integer;
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
  then
    raise exception 'M8.2C cutover refused: damage.stock_hold_ready must stay false';
  end if;

  update public.app_configuration
  set value = 'true'::jsonb
  where key in (
    'stock.lots.dual_write_enabled',
    'stock.lots.aggregate_only_blocked'
  );
  get diagnostics updated = row_count;
  if updated <> 2 then
    raise exception 'expected to update two lot flags, updated %', updated;
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
