-- Removes the disposable Phase 3.2 concurrency fixture.
alter table public.stock_verification_evidence disable trigger stock_verification_evidence_guard;
alter table public.stock_verification_counts disable trigger stock_verification_counts_guard;
alter table public.stock_verification_lines disable trigger stock_verification_lines_guard;
alter table public.stock_verification_snapshot_entries disable trigger stock_verification_snapshot_guard;
alter table public.stock_verification_scopes disable trigger stock_verification_scopes_guard;
alter table public.stock_verifications disable trigger stock_verifications_guard;

do $$
begin
  perform set_config('storage.allow_delete_query', 'true', true);
  delete from storage.objects
  where bucket_id = 'stock-verification-evidence'
    and name in (
      select storage_path from public.stock_verification_evidence
      where verification_id in (
        select id from public.stock_verifications
        where godown_id = (select id from public.branches where code = 'phase32_race')
      )
    );
end;
$$;

delete from public.stock_verification_evidence
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase32_race')
);
delete from public.stock_verification_counts
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase32_race')
);
delete from public.stock_verification_lines
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase32_race')
);
delete from public.stock_verification_snapshot_entries
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase32_race')
);
delete from public.stock_verification_scopes
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase32_race')
);
delete from public.stock_verifications
where godown_id = (select id from public.branches where code = 'phase32_race');

alter table public.stock_verification_evidence enable trigger stock_verification_evidence_guard;
alter table public.stock_verification_counts enable trigger stock_verification_counts_guard;
alter table public.stock_verification_lines enable trigger stock_verification_lines_guard;
alter table public.stock_verification_snapshot_entries enable trigger stock_verification_snapshot_guard;
alter table public.stock_verification_scopes enable trigger stock_verification_scopes_guard;
alter table public.stock_verifications enable trigger stock_verifications_guard;

alter table public.stock_ledger disable trigger stock_ledger_append_only;
alter table public.stock_transactions disable trigger stock_transactions_append_only;
alter table public.stock_balances disable trigger stock_balances_match_ledger;
delete from public.stock_ledger
where product_id in (select id from public.products where sku like 'p32-race-%');
delete from public.stock_balances
where product_id in (select id from public.products where sku like 'p32-race-%');
delete from public.stock_transactions
where product_id in (select id from public.products where sku like 'p32-race-%');
alter table public.stock_balances enable trigger stock_balances_match_ledger;
alter table public.stock_transactions enable trigger stock_transactions_append_only;
alter table public.stock_ledger enable trigger stock_ledger_append_only;

update public.stock_receipts
set status = 'draft'
where godown_id = (select id from public.branches where code = 'phase32_race')
  and status <> 'draft';
delete from public.stock_receipt_lines
where receipt_id in (
  select id from public.stock_receipts
  where godown_id = (select id from public.branches where code = 'phase32_race')
);
delete from public.stock_receipts
where godown_id = (select id from public.branches where code = 'phase32_race');
delete from public.crates
where zone_id in (
  select zones.id from public.zones
  join public.branches on branches.id = zones.branch_id
  where branches.code = 'phase32_race'
);
delete from public.zones
where branch_id = (select id from public.branches where code = 'phase32_race');
delete from public.user_branch_assignments
where branch_id = (select id from public.branches where code = 'phase32_race');
delete from public.branches where code = 'phase32_race';
delete from public.products where sku in ('p32-race-soap', 'p32-race-other');
delete from public.suppliers where name = 'Phase 32 Race Supplier';
delete from public.user_roles
where user_id in (select id from auth.users where email like '%.phase32race@example.com');
delete from auth.users where email like '%.phase32race@example.com';

drop function if exists public.phase32_post_other();
drop function if exists public.phase32_hold_receipt_locations();
drop function if exists public.phase32_hold_close_locations();
drop function if exists public.phase32_hold_product_row();
drop function if exists public.phase32_hold_transfer();
drop function if exists public.phase32_hold_recount();
drop function if exists public.phase32_hold_crate();
drop function if exists public.phase32_hold_product();
drop function if exists public.phase32_hold_locations();
drop function if exists public.phase32_hold_close();
drop function if exists public.phase32_hold_count();
drop function if exists public.phase32_hold_start();
drop function if exists public.phase32_stage_pending();
drop function if exists public.phase32_prepare_receipt();
drop function if exists public.phase32_prepare_open(boolean);
drop function if exists public.phase32_prepare_counted(boolean, boolean);
drop function if exists public.phase32_attach_photo(uuid);
drop function if exists public.phase32_open_id();
drop function if exists public.phase32_clear_open();
drop function if exists public.phase32_claim(text);
