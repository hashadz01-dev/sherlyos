-- M7.5E.1 payload extras: return version, eligibility, and list labels.
-- Does not issue GST credit notes or write stock.

create or replace function app_private.invoice_note_payload(target uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  header public.invoice_notes;
  identity jsonb;
  shop public.shops;
  dispatch public.stock_dispatch_requests;
  order_row public.orders;
  payload jsonb;
begin
  select * into header from public.invoice_notes where invoice_notes.id = target;
  if not found then
    raise exception 'invoice note not found' using errcode = 'P0002';
  end if;

  identity := app_private.read_company_print_identity();
  select * into shop from public.shops where shops.id = header.shop_id;
  select * into dispatch from public.stock_dispatch_requests where stock_dispatch_requests.id = header.dispatch_id;
  select * into order_row from public.orders where orders.id = header.order_id;

  payload := jsonb_build_object(
    'id', header.id,
    'note_number', header.note_number,
    'status', header.status,
    'version', header.version,
    'idempotency_key', header.idempotency_key,
    'dispatch_id', header.dispatch_id,
    'dispatch_number', dispatch.request_number,
    'order_id', header.order_id,
    'order_number', order_row.order_number,
    'shop_id', header.shop_id,
    'shop', jsonb_build_object(
      'id', shop.id,
      'name', shop.name,
      'address', shop.address
    ),
    'branch_id', header.branch_id,
    'as_of_date', header.as_of_date,
    'dispatch_confirmed_at', header.dispatch_confirmed_at,
    'currency_code', header.currency_code,
    'billed_cases', header.billed_cases,
    'billed_quantity', header.billed_quantity,
    'subtotal_amount', header.subtotal_amount,
    'tax_amount', header.tax_amount,
    'grand_total', header.grand_total,
    'amount_in_words', app_private.amount_in_words_inr(header.grand_total),
    'remarks', header.remarks,
    'watermark', 'DRAFT INVOICE NOTE — NOT A TAX INVOICE',
    'legal_issuance_blocked', true,
    'has_legal_seal', false,
    'company', identity,
    'statutory', public.assess_invoice_finalization_readiness(header.id),
    'submitted_at', header.submitted_at,
    'reviewed_at', header.reviewed_at,
    'cancelled_at', header.cancelled_at,
    'created_at', header.created_at,
    'lines', coalesce((
      select jsonb_agg(line_payload order by (line_payload ->> 'line_no')::integer)
      from (
        select jsonb_build_object(
          'id', invoice_note_lines.id,
          'line_no', invoice_note_lines.line_no,
          'order_line_id', invoice_note_lines.order_line_id,
          'product_id', invoice_note_lines.product_id,
          'lot_id', invoice_note_lines.lot_id,
          'crate_id', invoice_note_lines.crate_id,
          'product_sku', invoice_note_lines.product_sku,
          'product_name', invoice_note_lines.product_name,
          'shipped_cases', invoice_note_lines.shipped_cases,
          'billing_unit', invoice_note_lines.billing_unit,
          'billed_units_per_case', invoice_note_lines.billed_units_per_case,
          'billed_quantity', invoice_note_lines.billed_quantity,
          'unit_amount', invoice_note_lines.unit_amount,
          'line_amount', invoice_note_lines.line_amount,
          'price_scope', invoice_note_lines.price_scope,
          'price_effective_from', invoice_note_lines.price_effective_from,
          'price_effective_to', invoice_note_lines.price_effective_to,
          'tax_amount', 0
        ) as line_payload
        from public.invoice_note_lines
        where invoice_note_lines.invoice_note_id = header.id
      ) lines
    ), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(event_payload order by event_payload ->> 'created_at')
      from (
        select jsonb_build_object(
          'id', invoice_note_events.id,
          'event_type', invoice_note_events.event_type,
          'from_status', invoice_note_events.from_status,
          'to_status', invoice_note_events.to_status,
          'note_version', invoice_note_events.note_version,
          'created_at', invoice_note_events.created_at,
          'actor_id', invoice_note_events.actor_id
        ) as event_payload
        from public.invoice_note_events
        where invoice_note_events.invoice_note_id = header.id
      ) events
    ), '[]'::jsonb),
    'credit_note_candidates', coalesce((
      select jsonb_agg(return_payload)
      from (
        select jsonb_build_object(
          'return_id', stock_delivery_returns.id,
          'return_number', stock_delivery_returns.return_number,
          'status', stock_delivery_returns.status,
          'version', stock_delivery_returns.version,
          'issuable', false,
          'credit_eligible', stock_delivery_returns.status in ('posted', 'closed_missing'),
          'existing_adjustment_id', (
            select invoice_credit_adjustments.id
            from public.invoice_credit_adjustments
            where invoice_credit_adjustments.return_id = stock_delivery_returns.id
              and invoice_credit_adjustments.status in ('preview', 'blocked')
            limit 1
          ),
          'reason', 'Internal credit-adjustment preview only. GST credit notes are not issued.'
        ) as return_payload
        from public.stock_delivery_returns
        where stock_delivery_returns.dispatch_id = header.dispatch_id
      ) returns
    ), '[]'::jsonb)
  );

  return payload;
end;
$$;

create or replace function public.list_credit_adjustments(
  p_status text default null,
  p_branch_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app_private.can_manage_credit_adjustment() then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_status is not null and p_status not in ('preview', 'blocked') then
    raise exception 'credit-adjustment status is not valid' using errcode = '23514';
  end if;
  return coalesce((
    select jsonb_agg(item order by item ->> 'created_at' desc)
    from (
      select jsonb_build_object(
        'id', invoice_credit_adjustments.id,
        'adjustment_number', invoice_credit_adjustments.adjustment_number,
        'status', invoice_credit_adjustments.status,
        'watermark', invoice_credit_adjustments.watermark,
        'return_id', invoice_credit_adjustments.return_id,
        'return_number', stock_delivery_returns.return_number,
        'invoice_note_id', invoice_credit_adjustments.invoice_note_id,
        'invoice_note_number', invoice_notes.note_number,
        'shop_id', invoice_credit_adjustments.shop_id,
        'shop_name', shops.name,
        'branch_id', invoice_credit_adjustments.branch_id,
        'credited_cases', invoice_credit_adjustments.credited_cases,
        'adjustment_total', invoice_credit_adjustments.adjustment_total,
        'tax_preview_state', invoice_credit_adjustments.tax_preview_state,
        'legal_issuance_blocked', true,
        'created_at', invoice_credit_adjustments.created_at
      ) as item
      from public.invoice_credit_adjustments
      join public.stock_delivery_returns
        on stock_delivery_returns.id = invoice_credit_adjustments.return_id
      join public.invoice_notes
        on invoice_notes.id = invoice_credit_adjustments.invoice_note_id
      join public.shops
        on shops.id = invoice_credit_adjustments.shop_id
      where app_private.can_work_at_branch(invoice_credit_adjustments.branch_id)
        and (p_status is null or invoice_credit_adjustments.status = p_status)
        and (p_branch_id is null or invoice_credit_adjustments.branch_id = p_branch_id)
    ) listed
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.list_credit_adjustments(text, uuid) from public, anon;
grant execute on function public.list_credit_adjustments(text, uuid) to authenticated;

notify pgrst, 'reload schema';
