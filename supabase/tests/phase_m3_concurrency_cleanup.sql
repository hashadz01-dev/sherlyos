-- Restores cutover flags after M3 concurrency. Disposable fixtures remain unused.
update public.app_configuration
set value = 'false'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');
