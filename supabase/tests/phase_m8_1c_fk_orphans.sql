-- Read-only orphan counts for the 16 M8.1B restore VALIDATE failures.
-- Does not drop constraints or delete rows.

select 'damage_report_events.damage_report_id' as constraint_ref, count(*) as orphans
from public.damage_report_events c
left join public.damage_reports p on p.id = c.damage_report_id
where c.damage_report_id is not null and p.id is null
union all
select 'damage_report_lines.crate_id', count(*)
from public.damage_report_lines c
left join public.crates p on p.id = c.crate_id
where c.crate_id is not null and p.id is null
union all
select 'damage_report_lines.lot_id', count(*)
from public.damage_report_lines c
left join public.stock_lots p on p.id = c.lot_id
where c.lot_id is not null and p.id is null
union all
select 'damage_report_lines.product_id', count(*)
from public.damage_report_lines c
left join public.products p on p.id = c.product_id
where c.product_id is not null and p.id is null
union all
select 'damage_reports.godown_id', count(*)
from public.damage_reports c
left join public.branches p on p.id = c.godown_id
where c.godown_id is not null and p.id is null
union all
select 'damage_stock_holds.lot_id', count(*)
from public.damage_stock_holds c
left join public.stock_lots p on p.id = c.lot_id
where c.lot_id is not null and p.id is null
union all
select 'damage_stock_holds.source_reservation_id', count(*)
from public.damage_stock_holds c
left join public.stock_reservations p on p.id = c.source_reservation_id
where c.source_reservation_id is not null and p.id is null
union all
select 'invoice_credit_adjustment_lines.return_lot_id', count(*)
from public.invoice_credit_adjustment_lines c
left join public.stock_delivery_return_lots p on p.id = c.return_lot_id
where c.return_lot_id is not null and p.id is null
union all
select 'order_lines.product_id', count(*)
from public.order_lines c
left join public.products p on p.id = c.product_id
where c.product_id is not null and p.id is null
union all
select 'orders.originating_shipment_id', count(*)
from public.orders c
left join public.order_shipments p on p.id = c.originating_shipment_id
where c.originating_shipment_id is not null and p.id is null
union all
select 'stock_adjustment_line_lot_allocations.lot_id', count(*)
from public.stock_adjustment_line_lot_allocations c
left join public.stock_lots p on p.id = c.lot_id
where c.lot_id is not null and p.id is null
union all
select 'stock_dispatch_requests.posted_transaction_id', count(*)
from public.stock_dispatch_requests c
left join public.stock_transactions p on p.id = c.posted_transaction_id
where c.posted_transaction_id is not null and p.id is null
union all
select 'stock_lot_aware_applications.transaction_id', count(*)
from public.stock_lot_aware_applications c
left join public.stock_transactions p on p.id = c.transaction_id
where c.transaction_id is not null and p.id is null
union all
select 'stock_receipt_lines.product_id', count(*)
from public.stock_receipt_lines c
left join public.products p on p.id = c.product_id
where c.product_id is not null and p.id is null
union all
select 'stock_transactions.destination_crate_id', count(*)
from public.stock_transactions c
left join public.crates p on p.id = c.destination_crate_id
where c.destination_crate_id is not null and p.id is null
union all
select 'stock_transactions.product_id', count(*)
from public.stock_transactions c
left join public.products p on p.id = c.product_id
where c.product_id is not null and p.id is null;
