-- M6.4 correction. Cumulative linked-receipt reservation without a new stock writer.
-- verify_stock_receipt is unchanged. Unlinked Branch 03 receiving is unchanged.
-- Does not flip damage.stock_hold_ready or lot cutover flags.
--
-- Lock order for linked create/update:
--   refill request FOR UPDATE
--   then existing replace_receipt_lines / prepare_stock_locations
-- Verify still never locks the refill header, so this does not invert
-- receipt → supplier → products → locations.

create or replace function app_private.assert_refill_receipt_header(
  target_request uuid,
  target_godown uuid,
  target_supplier uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  request public.stock_refill_requests;
begin
  if target_request is null then
    return;
  end if;

  -- Exclusive lock serializes linked creates against the same request.
  -- Taken before location grains. Compatible with verify, which never
  -- locks stock_refill_requests.
  select * into request
  from public.stock_refill_requests
  where stock_refill_requests.id = target_request
  for update;

  if request.id is null then
    raise exception 'refill request was not found' using errcode = '42501';
  end if;

  if request.status is distinct from 'approved' then
    raise exception 'refill request is not approved' using errcode = '42501';
  end if;

  if request.supplier_id is distinct from target_supplier
    or request.destination_godown_id is distinct from target_godown
  then
    raise exception 'refill request supplier or godown does not match'
      using errcode = '42501';
  end if;

  perform app_private.assert_operational_active_branch(target_godown);
end;
$$;

create or replace function app_private.assert_refill_receipt_quantities(target_receipt uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_receipts;
begin
  select * into selected
  from public.stock_receipts
  where stock_receipts.id = target_receipt;

  if selected.refill_request_id is null then
    return;
  end if;

  if exists (
    select 1
    from public.stock_receipt_lines
    left join public.stock_refill_request_lines
      on stock_refill_request_lines.refill_request_id = selected.refill_request_id
     and stock_refill_request_lines.product_id = stock_receipt_lines.product_id
    where stock_receipt_lines.receipt_id = selected.id
      and stock_refill_request_lines.id is null
  ) then
    raise exception 'linked receipt lines must be products on the refill request'
      using errcode = '23514';
  end if;

  -- Reserve accepted cases from every non-cancelled linked receipt, including
  -- drafts and unverified rows. Cancelled receipts free capacity. Posted
  -- inventory is still written only by verify_stock_receipt.
  if exists (
    select 1
    from public.stock_receipt_lines current_line
    join public.stock_refill_request_lines request_line
      on request_line.refill_request_id = selected.refill_request_id
     and request_line.product_id = current_line.product_id
    where current_line.receipt_id = selected.id
      and current_line.accepted_cases + coalesce((
        select sum(other_line.accepted_cases)
        from public.stock_receipts other_receipt
        join public.stock_receipt_lines other_line
          on other_line.receipt_id = other_receipt.id
        where other_receipt.refill_request_id = selected.refill_request_id
          and other_receipt.status is distinct from 'cancelled'
          and other_receipt.id is distinct from selected.id
          and other_line.product_id = current_line.product_id
      ), 0) > request_line.requested_cases
  ) then
    raise exception 'linked receipt would exceed requested cases'
      using errcode = '23514';
  end if;
end;
$$;

-- Re-check reservation at submit. Does not lock the refill header (receipt is
-- already locked). Does not post stock.
create or replace function public.submit_stock_receipt(target_receipt uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_receipts;
begin
  perform app_private.assert_permission('receiving.execute');
  selected := app_private.lock_stock_receipt(target_receipt);

  if selected.created_by is distinct from auth.uid()
    or selected.status is distinct from 'draft'
    or not app_private.can_work_at_branch(selected.godown_id) then
    raise exception 'receipt cannot be submitted' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.stock_receipt_lines
    where stock_receipt_lines.receipt_id = selected.id
  ) then
    raise exception 'a receipt needs at least one line' using errcode = '23514';
  end if;

  perform app_private.assert_refill_receipt_quantities(selected.id);

  update public.stock_receipts
  set status = 'submitted'
  where stock_receipts.id = selected.id;

  perform app_private.write_audit(
    auth.uid(),
    'submit_stock_receipt',
    'stock_receipts',
    selected.id,
    '{}'::jsonb
  );

  return app_private.stock_receipt_payload(selected.id);
end;
$$;

revoke all on function public.submit_stock_receipt(uuid) from public, anon, service_role;
grant execute on function public.submit_stock_receipt(uuid) to authenticated;

comment on function app_private.assert_refill_receipt_quantities(uuid) is
  'M6.4 linked-workflow reservation. Counts non-cancelled accepted cases. Zero stock.';

notify pgrst, 'reload schema';
