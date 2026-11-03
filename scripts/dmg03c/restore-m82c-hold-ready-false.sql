-- Restore disposable m82c hold-ready to false after UAT.
-- Does not flip dual-write / aggregate-only (left as found on this stack).

update public.app_configuration
set value = 'false'::jsonb
where key = 'damage.stock_hold_ready';

select key, value #>> '{}' as val
from public.app_configuration
where key in (
  'damage.stock_hold_ready',
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked'
)
order by 1;
