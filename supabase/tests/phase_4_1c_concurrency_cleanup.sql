-- Cleanup Phase 4.1C concurrency fixtures.

alter table public.order_events disable trigger order_events_append_only;
alter table public.orders disable trigger orders_assign_number;

delete from public.order_events
where order_id in (
  select id from public.orders
  where idempotency_key like 'p41c-race%'
);

delete from public.order_lines
where order_id in (
  select id from public.orders
  where idempotency_key like 'p41c-race%'
);

delete from public.orders
where idempotency_key like 'p41c-race%';

alter table public.order_events enable trigger order_events_append_only;
alter table public.orders enable trigger orders_assign_number;

alter table public.stock_ledger disable trigger stock_ledger_append_only;
alter table public.stock_transactions disable trigger stock_transactions_append_only;
alter table public.stock_balances disable trigger stock_balances_match_ledger;

delete from public.stock_ledger
where product_id in (select id from public.products where sku = 'p41c-race-sku');
delete from public.stock_transactions
where product_id in (select id from public.products where sku = 'p41c-race-sku');
delete from public.stock_lot_balances
where lot_id in (
  select id from public.stock_lots
  where product_id in (select id from public.products where sku = 'p41c-race-sku')
);
delete from public.stock_lots
where product_id in (select id from public.products where sku = 'p41c-race-sku');
delete from public.stock_balances
where product_id in (select id from public.products where sku = 'p41c-race-sku');
set session_replication_role = replica;
update public.app_configuration
set value = 'false'::jsonb
where key in (
  'damage.stock_hold_ready',
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked'
);
set session_replication_role = origin;

alter table public.stock_balances enable trigger stock_balances_match_ledger;
alter table public.stock_transactions enable trigger stock_transactions_append_only;
alter table public.stock_ledger enable trigger stock_ledger_append_only;

delete from public.shop_salesperson_assignments
where salesperson_id in (
  select id from auth.users where email like '%.phase41crace@example.com'
)
or shop_id in (select id from public.shops where name = 'Phase 41C Race Shop');

delete from public.user_branch_assignments
where user_id in (
  select id from auth.users where email like '%.phase41crace@example.com'
);

delete from public.user_roles
where user_id in (
  select id from auth.users where email like '%.phase41crace@example.com'
);

delete from public.crates
where code in ('rc1', 'rc2')
  and zone_id in (select id from public.zones where code in ('R', 'R2') and branch_id in (
    select id from public.branches where code = 'p41c_race_a'
  ));

delete from public.zones
where code in ('R', 'R2')
  and branch_id in (select id from public.branches where code = 'p41c_race_a');

delete from public.products where sku = 'p41c-race-sku';
delete from public.shops where name = 'Phase 41C Race Shop';
delete from public.branches where code = 'p41c_race_a';

delete from auth.users where email like '%.phase41crace@example.com';

drop table if exists public.phase41c_race_target cascade;
drop function if exists public.phase41c_claim(text);
