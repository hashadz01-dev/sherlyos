-- Removes the disposable Phase 3.3 concurrency fixture.

alter table public.stock_adjustment_events disable trigger stock_adjustment_events_guard;
alter table public.stock_adjustment_lines disable trigger stock_adjustment_lines_guard;
alter table public.stock_adjustment_requests disable trigger stock_adjustment_requests_guard;

update public.stock_adjustment_requests
set
  status = 'draft',
  exceptional = null,
  approved_by = null,
  approved_at = null,
  posted_by = null,
  posted_at = null,
  posted_transaction_id = null
where godown_id = (select id from public.branches where code = 'phase33_race');

alter table public.stock_verification_snapshot_entries disable trigger stock_verification_snapshot_guard;
delete from public.stock_verification_snapshot_entries
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase33_race')
);
alter table public.stock_verification_snapshot_entries enable trigger stock_verification_snapshot_guard;

alter table public.stock_ledger disable trigger stock_ledger_append_only;
alter table public.stock_transactions disable trigger stock_transactions_append_only;
alter table public.stock_balances disable trigger stock_balances_match_ledger;

delete from public.stock_ledger
where transaction_id in (
  select id from public.stock_transactions
  where adjustment_request_id in (
    select id from public.stock_adjustment_requests
    where godown_id = (select id from public.branches where code = 'phase33_race')
  )
  or product_id = (select id from public.products where sku = 'p33-race-soap')
);
delete from public.stock_transactions
where adjustment_request_id in (
  select id from public.stock_adjustment_requests
  where godown_id = (select id from public.branches where code = 'phase33_race')
)
or product_id = (select id from public.products where sku = 'p33-race-soap');
delete from public.stock_balances
where product_id = (select id from public.products where sku = 'p33-race-soap');

alter table public.stock_balances enable trigger stock_balances_match_ledger;
alter table public.stock_transactions enable trigger stock_transactions_append_only;
alter table public.stock_ledger enable trigger stock_ledger_append_only;

delete from public.stock_adjustment_events
where request_id in (
  select id from public.stock_adjustment_requests
  where godown_id = (select id from public.branches where code = 'phase33_race')
);
delete from public.stock_adjustment_lines
where request_id in (
  select id from public.stock_adjustment_requests
  where godown_id = (select id from public.branches where code = 'phase33_race')
);
delete from public.stock_adjustment_requests
where godown_id = (select id from public.branches where code = 'phase33_race');

alter table public.stock_adjustment_events enable trigger stock_adjustment_events_guard;
alter table public.stock_adjustment_lines enable trigger stock_adjustment_lines_guard;
alter table public.stock_adjustment_requests enable trigger stock_adjustment_requests_guard;

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
        where godown_id = (select id from public.branches where code = 'phase33_race')
      )
    );
end;
$$;

delete from public.stock_verification_evidence
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase33_race')
);
delete from public.stock_verification_counts
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase33_race')
);
delete from public.stock_verification_lines
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase33_race')
);
delete from public.stock_verification_snapshot_entries
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase33_race')
);
delete from public.stock_verification_scopes
where verification_id in (
  select id from public.stock_verifications
  where godown_id = (select id from public.branches where code = 'phase33_race')
);
delete from public.stock_verifications
where godown_id = (select id from public.branches where code = 'phase33_race');

alter table public.stock_verification_evidence enable trigger stock_verification_evidence_guard;
alter table public.stock_verification_counts enable trigger stock_verification_counts_guard;
alter table public.stock_verification_lines enable trigger stock_verification_lines_guard;
alter table public.stock_verification_snapshot_entries enable trigger stock_verification_snapshot_guard;
alter table public.stock_verification_scopes enable trigger stock_verification_scopes_guard;
alter table public.stock_verifications enable trigger stock_verifications_guard;

update public.stock_receipts
set status = 'draft'
where godown_id = (select id from public.branches where code = 'phase33_race')
  and status <> 'draft';
delete from public.stock_receipt_lines
where receipt_id in (
  select id from public.stock_receipts
  where godown_id = (select id from public.branches where code = 'phase33_race')
);
delete from public.stock_receipts
where godown_id = (select id from public.branches where code = 'phase33_race');

delete from public.crates
where zone_id in (
  select zones.id from public.zones
  join public.branches on branches.id = zones.branch_id
  where branches.code = 'phase33_race'
);
delete from public.zones
where branch_id = (select id from public.branches where code = 'phase33_race');
delete from public.user_branch_assignments
where branch_id = (select id from public.branches where code = 'phase33_race');
delete from public.branches where code = 'phase33_race';
delete from public.products where sku = 'p33-race-soap';
delete from public.suppliers where name = 'Phase 33 Race Supplier';
delete from public.user_roles
where user_id in (select id from auth.users where email like '%.phase33race@example.com');
delete from auth.users where email like '%.phase33race@example.com';

drop table if exists public.phase33_race_target;
drop function if exists public.phase33_stale_after_transfer();
drop function if exists public.phase33_stale_after_receipt();
drop function if exists public.phase33_other_key();
drop function if exists public.phase33_same_key();
drop function if exists public.phase33_assert_books();
drop function if exists public.phase33_hold_claim();
drop function if exists public.phase33_hold_locations_post();
drop function if exists public.phase33_hold_approve();
drop function if exists public.phase33_hold_post();
drop function if exists public.phase33_prepare(text);
drop function if exists public.phase33_close_short();
drop function if exists public.phase33_attach_photo(uuid);
drop function if exists public.phase33_claim(text);

do $$
begin
  if exists (
    select 1
    from pg_trigger
    where tgname in (
      'stock_ledger_append_only',
      'stock_transactions_append_only',
      'stock_balances_match_ledger',
      'stock_adjustment_events_guard',
      'stock_adjustment_lines_guard',
      'stock_adjustment_requests_guard'
    )
      and tgenabled <> 'O'
  ) then
    raise exception 'append-only or adjustment guard trigger was left disabled';
  end if;
  if exists (select 1 from public.branches where code = 'phase33_race')
    or exists (select 1 from public.products where sku = 'p33-race-soap')
    or exists (select 1 from auth.users where email like '%.phase33race@example.com')
    or exists (select 1 from public.stock_balances where quantity < 0) then
    raise exception 'phase 3.3 concurrency fixture remained';
  end if;
end;
$$;
