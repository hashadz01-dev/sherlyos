-- Shops have no code column. Payload must not reference one.

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
    'statutory', public.assess_invoice_finalization_readiness(),
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
          'issuable', false,
          'reason', 'Credit notes are documented only until accountant-approved issuance exists (I5).'
        ) as return_payload
        from public.stock_delivery_returns
        where stock_delivery_returns.dispatch_id = header.dispatch_id
      ) returns
    ), '[]'::jsonb)
  );

  return payload;
end;
$$;
