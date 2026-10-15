alter table public.stock_ledger disable trigger stock_ledger_append_only;
alter table public.stock_transactions disable trigger stock_transactions_append_only;
alter table public.stock_balances disable trigger stock_balances_match_ledger;
delete from public.stock_ledger
where product_id in (select id from public.products where sku like 'p31-race-%');
delete from public.stock_balances
where product_id in (select id from public.products where sku like 'p31-race-%');
delete from public.stock_transactions
where product_id in (select id from public.products where sku like 'p31-race-%');
alter table public.stock_balances enable trigger stock_balances_match_ledger;
alter table public.stock_transactions enable trigger stock_transactions_append_only;
alter table public.stock_ledger enable trigger stock_ledger_append_only;
do $$
begin
  if exists (
    select 1
    from pg_trigger
    where tgname in (
      'stock_ledger_append_only',
      'stock_transactions_append_only',
      'stock_balances_match_ledger'
    )
      and tgenabled <> 'O'
  ) then
    raise exception 'append-only triggers were left disabled';
  end if;
end $$;
update public.stock_receipts
set status = 'draft'
where godown_id = (select id from public.branches where code = 'phase31_race')
  and status <> 'draft';
delete from public.stock_receipt_lines
where receipt_id in (
  select id from public.stock_receipts
  where godown_id = (select id from public.branches where code = 'phase31_race')
);
delete from public.stock_receipts
where godown_id = (select id from public.branches where code = 'phase31_race');
delete from public.crates
where zone_id in (
  select zones.id from public.zones
  join public.branches on branches.id = zones.branch_id
  where branches.code = 'phase31_race'
);
delete from public.zones
where branch_id = (select id from public.branches where code = 'phase31_race');
delete from public.user_branch_assignments
where branch_id = (select id from public.branches where code = 'phase31_race');
delete from public.branches where code = 'phase31_race';
delete from public.products where sku like 'p31-race-%';
delete from public.suppliers where name like 'Phase 31 Race%';
delete from auth.users where email like '%.phase31race@example.com';
drop function if exists public.phase31_hold_duplicate();
drop function if exists public.phase31_hold_supplier_off();
drop function if exists public.phase31_hold_product_off();
drop function if exists public.phase31_hold_zone_off();
drop function if exists public.phase31_hold_zone_post();
drop function if exists public.phase31_hold_crate_off();
drop function if exists public.phase31_hold_crate_post();
drop function if exists public.phase31_hold_add();
drop function if exists public.phase31_hold_cancel();
drop function if exists public.phase31_hold_edit();
drop function if exists public.phase31_hold_verify();
drop function if exists public.phase31_claim(text);
