-- Cleanup Phase 4.2C local browser fixtures only.

alter table public.delivery_note_events disable trigger delivery_note_events_append_only;
alter table public.delivery_note_lines disable trigger delivery_note_lines_immutable;
alter table public.order_events disable trigger order_events_append_only;
alter table public.orders disable trigger orders_assign_number;

delete from public.delivery_note_events
where delivery_note_id in (
  select id from public.delivery_notes
  where shop_id in (select id from public.shops where name = 'Phase 42C Browser Shop')
     or branch_id in (select id from public.branches where code like 'phase42c_browser_%')
     or idempotency_key like 'p42c-browser-%'
);

delete from public.delivery_note_lines
where delivery_note_id in (
  select id from public.delivery_notes
  where shop_id in (select id from public.shops where name = 'Phase 42C Browser Shop')
     or branch_id in (select id from public.branches where code like 'phase42c_browser_%')
     or idempotency_key like 'p42c-browser-%'
);

delete from public.delivery_notes
where shop_id in (select id from public.shops where name = 'Phase 42C Browser Shop')
   or branch_id in (select id from public.branches where code like 'phase42c_browser_%')
   or idempotency_key like 'p42c-browser-%';

delete from public.order_events
where order_id in (
  select id from public.orders
  where shop_id in (select id from public.shops where name = 'Phase 42C Browser Shop')
     or branch_id in (select id from public.branches where code like 'phase42c_browser_%')
     or idempotency_key like 'p42c-browser-%'
);

delete from public.order_lines
where order_id in (
  select id from public.orders
  where shop_id in (select id from public.shops where name = 'Phase 42C Browser Shop')
     or branch_id in (select id from public.branches where code like 'phase42c_browser_%')
     or idempotency_key like 'p42c-browser-%'
);

delete from public.orders
where shop_id in (select id from public.shops where name = 'Phase 42C Browser Shop')
   or branch_id in (select id from public.branches where code like 'phase42c_browser_%')
   or idempotency_key like 'p42c-browser-%';

alter table public.delivery_note_events enable trigger delivery_note_events_append_only;
alter table public.delivery_note_lines enable trigger delivery_note_lines_immutable;
alter table public.order_events enable trigger order_events_append_only;
alter table public.orders enable trigger orders_assign_number;

alter table public.stock_ledger disable trigger stock_ledger_append_only;
alter table public.stock_transactions disable trigger stock_transactions_append_only;
alter table public.stock_balances disable trigger stock_balances_match_ledger;

delete from public.stock_ledger
where product_id in (select id from public.products where sku = 'p42c-browser-soap');
delete from public.stock_transactions
where product_id in (select id from public.products where sku = 'p42c-browser-soap')
   or idempotency_key like 'p42c-browser-%';
delete from public.stock_balances
where product_id in (select id from public.products where sku = 'p42c-browser-soap');

alter table public.stock_balances enable trigger stock_balances_match_ledger;
alter table public.stock_transactions enable trigger stock_transactions_append_only;
alter table public.stock_ledger enable trigger stock_ledger_append_only;

delete from public.shop_salesperson_assignments
where shop_id in (select id from public.shops where name = 'Phase 42C Browser Shop');

delete from public.user_branch_assignments
where user_id in (select id from auth.users where email like '%.phase42cbrowser@example.com');

delete from public.user_roles
where user_id in (select id from auth.users where email like '%.phase42cbrowser@example.com');

delete from public.crates where code = 'b42cc';
delete from public.zones where code = 'b42cz';
delete from public.products where sku = 'p42c-browser-soap';
delete from public.shops where name = 'Phase 42C Browser Shop';
delete from public.branches where code like 'phase42c_browser_%';

delete from public.app_configuration
where key in ('company.legal_name', 'company.registered_address')
  and description = 'Local browser test identity only.';

delete from auth.identities
where user_id in (select id from auth.users where email like '%.phase42cbrowser@example.com');

delete from public.profiles
where id in (select id from auth.users where email like '%.phase42cbrowser@example.com');

delete from auth.users where email like '%.phase42cbrowser@example.com';

drop function if exists public.phase42c_browser_claim(text);
