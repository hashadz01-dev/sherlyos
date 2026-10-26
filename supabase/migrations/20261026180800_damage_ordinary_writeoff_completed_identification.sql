-- M5.4D recovery: identify a completed ordinary write-off before the version
-- check. Lost HTTP after a successful post left clients with a stale
-- expected_version; assert_damage_version ran first, so replay failed even
-- though no new stock posting would occur.
-- Local only. Does not flip damage.stock_hold_ready or lot cutover flags.
-- New postings still require the current expected_version.

create or replace function public.post_ordinary_damage_writeoff(
  target_report uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  posted uuid;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);

  -- Completed identification is not a new posting. Permission + report lock
  -- (can_view) is enough to return the current payload without asserting
  -- version, godown activity, or disposition readiness.
  select stock_transactions.id into posted
  from public.stock_transactions
  where stock_transactions.damage_report_id = selected.id
    and stock_transactions.damage_posting_kind = 'ordinary_writeoff';
  if found then
    return app_private.damage_report_payload(selected.id);
  end if;

  perform app_private.assert_damage_version(selected, expected_version);

  -- Snapshot without locking the branch row. consume_damage_holds then
  -- lock_damage_stock_grains (products → locations) matches confirm_dispatch.
  if not exists (
    select 1
    from public.branches
    where branches.id = selected.godown_id
      and branches.is_active
  ) then
    raise exception 'godown is inactive' using errcode = '23514';
  end if;
  if not app_private.can_work_at_branch(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_damage_disposition_ready(selected);

  if app_private.has_permission('damage.dispose')
    and not app_private.has_permission('damage.verify')
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.damage_exceptional_requests
    where damage_report_id = selected.id
      and status in ('requested', 'approved')
  ) then
    raise exception 'an exceptional disposition is already open' using errcode = '23514';
  end if;

  posted := app_private.consume_damage_holds(
    selected.id, 'written_off', 'ordinary_writeoff', 'Ordinary damage write-off'
  );

  perform app_private.record_damage_event(
    selected.id, 'ordinary_writeoff', selected.status, selected.status,
    jsonb_build_object('transaction_id', posted, 'idempotency_key', idempotency_key)
  );
  perform app_private.write_audit(
    auth.uid(), 'post_ordinary_damage_writeoff', 'damage_reports', selected.id,
    jsonb_build_object('transaction_id', posted)
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

revoke all on function public.post_ordinary_damage_writeoff(uuid, integer, text)
  from public, anon, service_role;
grant execute on function public.post_ordinary_damage_writeoff(uuid, integer, text)
  to authenticated;

comment on function public.post_ordinary_damage_writeoff(uuid, integer, text) is
  'Ordinary write-off. Completed postings replay without version. New postings still require the current expected_version. Snapshots godown activity, then locks products before locations. Exact-once by posting kind.';
