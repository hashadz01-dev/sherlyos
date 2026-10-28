-- M7.5D.1 preview-only driver / accounts handover documents.
-- Replaces get_invoice_note_preview. STABLE. Does not write notes, tax
-- snapshots, stock, dispatch, or statutory numbers. Not issuance.

create or replace function public.get_invoice_note_preview(
  p_invoice_note_id uuid,
  p_copy text default 'driver'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  requested text := coalesce(nullif(btrim(p_copy), ''), 'driver');
  family text;
  copy_label text;
  payload jsonb;
  header public.invoice_notes;
  shop public.shops;
  branch public.branches;
  seller_hit integer := 0;
  customer_hit integer := 0;
  seller jsonb;
  customer jsonb;
  tax jsonb;
  line jsonb;
  lines jsonb := '[]'::jsonb;
  hsn_code text;
  financial_state text;
  preview_mark text := U&'DRAFT INVOICE PREVIEW \2014 NOT A TAX INVOICE';
  seal_mark text := U&'NO LEGAL SEAL \2014 DRAFT PREVIEW ONLY';
  tax_mark text := U&'TAX CALCULATION PREVIEW \2014 NOT A TAX INVOICE';
begin
  if requested not in ('driver', 'accounts', 'recipient', 'transporter') then
    raise exception 'invoice copy must be driver or accounts'
      using errcode = '23514';
  end if;

  family := case
    when requested in ('driver', 'recipient', 'transporter') then 'driver'
    else 'accounts'
  end;
  copy_label := case requested
    when 'recipient' then 'RECIPIENT COPY'
    when 'transporter' then 'TRANSPORTER / DRIVER COPY'
    when 'driver' then 'DRIVER / DELIVERY HANDOVER COPY'
    else 'ACCOUNTS / FINANCIAL PREVIEW COPY'
  end;

  if family = 'accounts' then
    if not (
      app_private.has_permission('invoice_notes.prepare')
      or app_private.has_permission('invoices.review')
    ) then
      raise exception 'permission denied' using errcode = '42501';
    end if;
  end if;

  payload := public.get_invoice_note(p_invoice_note_id);

  select * into header
  from public.invoice_notes
  where invoice_notes.id = p_invoice_note_id;
  if not found then
    raise exception 'invoice note not found' using errcode = 'P0002';
  end if;

  if header.status = 'cancelled' then
    raise exception 'cancelled invoice notes cannot be printed'
      using errcode = '23514';
  end if;

  select * into shop from public.shops where shops.id = header.shop_id;
  select * into branch from public.branches where branches.id = header.branch_id;

  payload := payload || jsonb_build_object(
    'copy', requested,
    'copy_family', family,
    'copy_label', copy_label,
    'document_kind', family,
    'watermark', preview_mark,
    'legal_seal_caption', seal_mark,
    'generated_at', clock_timestamp(),
    'legal_invoice_number', null,
    'godown', jsonb_build_object(
      'id', branch.id,
      'code', branch.code,
      'name', branch.name
    ),
    'shop', jsonb_build_object(
      'id', shop.id,
      'name', shop.name,
      'address', shop.address,
      'phone', shop.phone
    ),
    'signature_block', jsonb_build_object(
      'shown', false,
      'reason', 'Signature and seal appear only on a finalized tax invoice.'
    )
  );

  if family = 'driver' then
    -- Operational handover only. Prices, GST, and statutory IDs stay off this copy.
    lines := coalesce(payload -> 'lines', '[]'::jsonb);
    payload := payload
      - 'subtotal_amount'
      - 'grand_total'
      - 'amount_in_words'
      - 'tax_amount'
      - 'events'
      - 'credit_note_candidates'
      - 'statutory';
    payload := jsonb_set(payload, '{company}', coalesce(payload -> 'company', '{}'::jsonb) - 'tax_id');
    payload := jsonb_set(payload, '{has_legal_seal}', 'false'::jsonb);
    payload := jsonb_set(payload, '{legal_issuance_blocked}', 'true'::jsonb);
    payload := jsonb_set(
      payload,
      '{lines}',
      coalesce((
        select jsonb_agg(
          elem
            - 'unit_amount'
            - 'line_amount'
            - 'price_scope'
            - 'price_effective_from'
            - 'price_effective_to'
            - 'tax_amount'
            - 'price_id'
          order by (elem ->> 'line_no')::integer
        )
        from jsonb_array_elements(lines) as elem
      ), '[]'::jsonb)
    );
    payload := payload || jsonb_build_object(
      'handover_acknowledgement', jsonb_build_object(
        'driver_signature_label', 'Driver signature (acknowledgement only)',
        'receiver_signature_label', 'Receiver signature (acknowledgement only)',
        'note', 'This copy is not a tax invoice and does not authorize stock or payment.'
      ),
      'financial_preview_state', 'omitted_for_driver_copy',
      'source', jsonb_build_object(
        'invoice_note_id', header.id,
        'invoice_note_version', header.version,
        'dispatch_id', header.dispatch_id,
        'quantities_from', 'invoice_note_lines',
        'prices_from', null
      )
    );
    return payload;
  end if;

  if header.status is distinct from 'reviewed' then
    raise exception 'accounts financial preview requires a reviewed invoice note'
      using errcode = '23514';
  end if;

  select count(*) into seller_hit
  from public.statutory_seller_identities seller
  where seller.status = 'verified'
    and seller.effective_from <= header.as_of_date
    and (seller.effective_to is null or seller.effective_to >= header.as_of_date);

  if seller_hit = 1 then
    select jsonb_build_object(
      'available', true,
      'legal_name', seller.legal_name,
      'registered_address', seller.registered_address,
      'gstin', seller.gstin,
      'state_code', seller.state_code
    )
    into seller
    from public.statutory_seller_identities seller
    where seller.status = 'verified'
      and seller.effective_from <= header.as_of_date
      and (seller.effective_to is null or seller.effective_to >= header.as_of_date);
  else
    seller := jsonb_build_object(
      'available', false,
      'reason', case
        when seller_hit = 0 then 'No verified seller identity covers this dispatch date.'
        else 'Verified seller identity is ambiguous for this dispatch date.'
      end
    );
  end if;

  select count(*) into customer_hit
  from public.shop_tax_identities shop_tax
  where shop_tax.shop_id = header.shop_id
    and shop_tax.status = 'verified'
    and shop_tax.effective_from <= header.as_of_date
    and (shop_tax.effective_to is null or shop_tax.effective_to >= header.as_of_date);

  if customer_hit = 1 then
    select jsonb_build_object(
      'available', true,
      'billing_name', shop_tax.billing_name,
      'billing_address', shop_tax.billing_address,
      'gstin', shop_tax.gstin,
      'registration_status', shop_tax.registration_status
    )
    into customer
    from public.shop_tax_identities shop_tax
    where shop_tax.shop_id = header.shop_id
      and shop_tax.status = 'verified'
      and shop_tax.effective_from <= header.as_of_date
      and (shop_tax.effective_to is null or shop_tax.effective_to >= header.as_of_date);
  else
    customer := jsonb_build_object(
      'available', false,
      'shop_name', shop.name,
      'shop_address', shop.address,
      'reason', case
        when customer_hit = 0 then 'No verified customer tax identity covers this dispatch date.'
        else 'Verified customer tax identity is ambiguous for this dispatch date.'
      end
    );
  end if;

  tax := public.get_invoice_tax_preview(p_invoice_note_id);
  if coalesce((tax ->> 'calculated')::boolean, false) is not true then
    financial_state := 'tax_unavailable';
  elsif coalesce((tax ->> 'stale')::boolean, false) then
    financial_state := 'tax_stale';
  else
    financial_state := 'tax_preview';
  end if;

  -- Pin HSN from the tax-preview snapshot only. Never invent a code.
  lines := '[]'::jsonb;
  for line in
    select value
    from jsonb_array_elements(coalesce(payload -> 'lines', '[]'::jsonb))
    order by (value ->> 'line_no')::integer
  loop
    hsn_code := null;
    if tax -> 'lines' is not null then
      select elem ->> 'hsn_sac_code'
      into hsn_code
      from jsonb_array_elements(tax -> 'lines') as elem
      where elem ->> 'invoice_note_line_id' = line ->> 'id'
      limit 1;
    end if;
    if hsn_code is not null and btrim(hsn_code) <> '' then
      line := line || jsonb_build_object('hsn_sac_code', hsn_code);
    end if;
    lines := lines || jsonb_build_array(line);
  end loop;

  payload := jsonb_set(payload, '{lines}', lines);
  payload := payload - 'events' - 'credit_note_candidates';
  payload := payload || jsonb_build_object(
    'seller_identity', seller,
    'customer_identity', customer,
    'tax_preview', tax,
    'financial_preview_state', financial_state,
    'tax_preview_watermark', tax_mark,
    'source', jsonb_build_object(
      'invoice_note_id', header.id,
      'invoice_note_version', header.version,
      'dispatch_id', header.dispatch_id,
      'quantities_from', 'invoice_note_lines',
      'prices_from', 'invoice_note_lines',
      'tax_from', case
        when financial_state = 'tax_unavailable' then null
        else 'invoice_tax_previews'
      end,
      'tax_preview_id', tax -> 'id'
    )
  );

  return payload;
end;
$$;

comment on function public.get_invoice_note_preview(uuid, text) is
  'Preview-only driver or accounts handover. Uses reviewed invoice-note and tax-preview snapshots. Never issues a tax invoice.';

notify pgrst, 'reload schema';
