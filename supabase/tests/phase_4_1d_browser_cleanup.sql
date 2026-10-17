-- Cleanup Phase 4.1D local browser fixtures only.

alter table public.order_events disable trigger order_events_append_only;
alter table public.orders disable trigger orders_assign_number;

delete from public.order_events
where order_id in (
  select id from public.orders
  where shop_id in (select id from public.shops where name = 'Phase 41D Browser Shop')
     or branch_id in (select id from public.branches where code = 'phase41d_browser')
);

delete from public.order_lines
where order_id in (
  select id from public.orders
  where shop_id in (select id from public.shops where name = 'Phase 41D Browser Shop')
     or branch_id in (select id from public.branches where code = 'phase41d_browser')
);

delete from public.orders
where shop_id in (select id from public.shops where name = 'Phase 41D Browser Shop')
   or branch_id in (select id from public.branches where code = 'phase41d_browser');

alter table public.order_events enable trigger order_events_append_only;
alter table public.orders enable trigger orders_assign_number;

alter table public.stock_ledger disable trigger stock_ledger_append_only;
alter table public.stock_transactions disable trigger stock_transactions_append_only;
alter table public.stock_balances disable trigger stock_balances_match_ledger;

delete from public.stock_ledger
where product_id in (select id from public.products where sku = 'p41d-browser-soap');
delete from public.stock_transactions
where product_id in (select id from public.products where sku = 'p41d-browser-soap');
delete from public.stock_balances
where product_id in (select id from public.products where sku = 'p41d-browser-soap');

alter table public.stock_balances enable trigger stock_balances_match_ledger;
alter table public.stock_transactions enable trigger stock_transactions_append_only;
alter table public.stock_ledger enable trigger stock_ledger_append_only;

delete from public.shop_salesperson_assignments
where shop_id in (select id from public.shops where name = 'Phase 41D Browser Shop');

delete from public.user_branch_assignments
where user_id in (select id from auth.users where email like '%.phase41dbrowser@example.com');

delete from public.user_roles
where user_id in (select id from auth.users where email like '%.phase41dbrowser@example.com');

delete from public.crates where code = 'b41c';
delete from public.zones where code = 'b41z';
delete from public.products where sku = 'p41d-browser-soap';
delete from public.shops where name = 'Phase 41D Browser Shop';
delete from public.branches where code = 'phase41d_browser';

delete from auth.identities
where user_id in (select id from auth.users where email like '%.phase41dbrowser@example.com');

delete from auth.users where email like '%.phase41dbrowser@example.com';

drop function if exists public.phase41d_browser_claim(text);
