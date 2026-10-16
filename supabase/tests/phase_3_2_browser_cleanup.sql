-- Removes the disposable Phase 3.2 browser fixture.
do $$
begin
  perform set_config('storage.allow_delete_query', 'true', true);
  delete from storage.objects
  where bucket_id = 'stock-verification-evidence'
    and name in (
      select storage_path from public.stock_verification_evidence
      where verification_id in (
        select id from public.stock_verifications
        where godown_id = (select id from public.branches where code = 'phase32_browser')
      )
    );
end;
$$;

alter table public.stock_verification_evidence disable trigger stock_verification_evidence_guard;
alter table public.stock_verification_counts disable trigger stock_verification_counts_guard;
alter table public.stock_verification_lines disable trigger stock_verification_lines_guard;
alter table public.stock_verification_snapshot_entries disable trigger stock_verification_snapshot_guard;
alter table public.stock_verification_scopes disable trigger stock_verification_scopes_guard;
alter table public.stock_verifications disable trigger stock_verifications_guard;

delete from public.stock_verification_evidence
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase32_browser')
);
delete from public.stock_verification_counts
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase32_browser')
);
delete from public.stock_verification_lines
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase32_browser')
);
delete from public.stock_verification_snapshot_entries
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase32_browser')
);
delete from public.stock_verification_scopes
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase32_browser')
);
delete from public.stock_verifications
where godown_id = (select id from public.branches where code = 'phase32_browser');

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
where product_id in (select id from public.products where sku = 'p32-browser-soap');
delete from public.stock_balances
where product_id in (select id from public.products where sku = 'p32-browser-soap');
delete from public.stock_transactions
where product_id in (select id from public.products where sku = 'p32-browser-soap');
alter table public.stock_balances enable trigger stock_balances_match_ledger;
alter table public.stock_transactions enable trigger stock_transactions_append_only;
alter table public.stock_ledger enable trigger stock_ledger_append_only;

delete from public.crates
where zone_id in (
  select zones.id from public.zones
  join public.branches on branches.id = zones.branch_id
  where branches.code = 'phase32_browser'
);
delete from public.zones
where branch_id = (select id from public.branches where code = 'phase32_browser');
delete from public.user_branch_assignments
where branch_id = (select id from public.branches where code = 'phase32_browser');
delete from public.branches where code = 'phase32_browser';
delete from public.products where sku = 'p32-browser-soap';
delete from public.user_roles
where user_id in (select id from auth.users where email like '%.phase32browser@example.com');
delete from auth.users where email like '%.phase32browser@example.com';

drop function if exists public.phase32_browser_claim(text);
