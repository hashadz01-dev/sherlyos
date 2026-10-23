-- Release M2 concurrency leftovers. Local Docker only. Restores cutover flags.
set session_replication_role = replica;
select set_config('app.picking_write', 'on', true);

update public.stock_reservations
set status = 'released'
where picking_request_id in (
  select id from public.stock_picking_requests
  where created_by in (select id from auth.users where email like '%m2c@example.com')
);

update public.stock_picking_requests
set
  status = 'cancelled',
  cancelled_by = created_by,
  cancelled_at = coalesce(cancelled_at, clock_timestamp()),
  cancellation_reason = coalesce(cancellation_reason, 'm2c cleanup')
where created_by in (select id from auth.users where email like '%m2c@example.com')
  and status is distinct from 'cancelled';

update public.stock_ledger
set lot_id = null
where product_id in (select id from public.products where sku like 'm2c_%');

delete from public.stock_balances
where product_id in (select id from public.products where sku like 'm2c_%');

delete from public.stock_lot_balances
where lot_id in (
  select stock_lots.id
  from public.stock_lots
  join public.products on products.id = stock_lots.product_id
  where products.sku like 'm2c_%'
);

delete from public.stock_lots
where product_id in (select id from public.products where sku like 'm2c_%');

update public.app_configuration
set value = 'false'::jsonb
where key in ('stock.lots.dual_write_enabled', 'stock.lots.aggregate_only_blocked');

set session_replication_role = origin;
