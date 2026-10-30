-- M8.2C isolation guards. Read-only except the session GUC check.
-- Refuses the owner local cluster and the M8.1C cutover replica.

do $$
declare
  sysid bigint;
  dual text;
  blocked text;
  damage text;
begin
  select system_identifier into sysid from pg_control_system();
  if sysid = 7699785797738577957 then
    raise exception 'M8.2C guards refused the owner database';
  end if;
  if sysid = 7702023892197691429 then
    raise exception 'M8.2C guards refused the m81c cutover replica';
  end if;

  select value::text into dual
  from public.app_configuration
  where key = 'stock.lots.dual_write_enabled';
  select value::text into blocked
  from public.app_configuration
  where key = 'stock.lots.aggregate_only_blocked';
  select value::text into damage
  from public.app_configuration
  where key = 'damage.stock_hold_ready';

  if blocked is distinct from 'false' then
    raise exception 'aggregate_only_blocked must stay false for M8.2C UAT';
  end if;
  if damage is distinct from 'false' then
    raise exception 'damage.stock_hold_ready must stay false for M8.2C UAT';
  end if;

  if exists (
    select 1 from public.invoice_financial_years where legal_allocation_enabled
    union all
    select 1 from public.invoice_number_series where legal_allocation_enabled
    union all
    select 1 from public.invoice_credit_note_number_series where legal_allocation_enabled
  ) then
    raise exception 'legal allocation must stay off';
  end if;
end $$;

select 'M8.2C isolation guards PASS' as status;
select system_identifier from pg_control_system();
select key, value
from public.app_configuration
where key in (
  'damage.stock_hold_ready',
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked'
)
order by key;
