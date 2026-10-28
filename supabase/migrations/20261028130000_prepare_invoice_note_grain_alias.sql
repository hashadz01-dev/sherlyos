-- PL/pgSQL record named `grain` was substituted into SQL that also aliased
-- dispatch_return_source_grains as grain, so prepare failed with 55000.

create or replace function public.prepare_invoice_note(
  p_dispatch_id uuid,
  p_idempotency_key text,
  p_expected_version integer,
  p_remarks text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  dispatch public.stock_dispatch_requests;
  order_row public.orders;
  existing public.invoice_notes;
  created public.invoice_notes;
  grain_row record;
  resolved record;
  product_row public.products;
  line_no integer := 0;
  billed_qty numeric(14, 4);
  line_amount numeric(14, 2);
  total_cases integer := 0;
  total_qty numeric(14, 4) := 0;
  total_amount numeric(14, 2) := 0;
  quantity_fp text;
  price_fp text;
  cleaned_key text;
  cleaned_remarks text;
begin
  perform app_private.assert_permission('invoice_notes.prepare');
  perform set_config('app.invoice_write', 'on', true);

  cleaned_key := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  if cleaned_key is null then
    raise exception 'idempotency key is required' using errcode = '23514';
  end if;
  cleaned_remarks := nullif(btrim(coalesce(p_remarks, '')), '');

  select * into dispatch
  from public.stock_dispatch_requests
  where stock_dispatch_requests.id = p_dispatch_id
  for update;

  if not found then
    raise exception 'dispatch not found' using errcode = 'P0002';
  end if;

  perform app_private.assert_operational_active_branch(dispatch.branch_id);
  if not app_private.can_work_at_branch(dispatch.branch_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  if dispatch.stock_consumed is distinct from true
    or dispatch.posted_transaction_id is null
    or dispatch.dispatched_at is null
  then
    raise exception 'invoice notes can only be prepared after confirmed dispatch'
      using errcode = '23514';
  end if;

  if dispatch.status not in ('dispatched', 'in_transit', 'delivered', 'exception') then
    raise exception 'invoice notes can only be prepared after confirmed dispatch'
      using errcode = '23514';
  end if;

  select * into order_row
  from public.orders
  where orders.id = dispatch.order_id
  for update;

  perform 1
  from public.invoice_notes
  where invoice_notes.dispatch_id = dispatch.id
  for update;

  select * into existing
  from public.invoice_notes
  where invoice_notes.dispatch_id = dispatch.id
    and invoice_notes.status in ('draft', 'submitted', 'reviewed');

  if found then
    if existing.idempotency_key is distinct from cleaned_key then
      raise exception 'an open invoice note already exists for this dispatch'
        using errcode = '23505';
    end if;
    if existing.version is distinct from p_expected_version then
      raise exception 'invoice note was changed by someone else' using errcode = 'PT409';
    end if;
    return app_private.invoice_note_payload(existing.id);
  end if;

  if p_expected_version is distinct from 1 then
    raise exception 'invoice note was changed by someone else' using errcode = 'PT409';
  end if;

  perform app_private.assert_return_grains_match_ledger(dispatch);

  perform 1
  from public.products
  where products.id in (
    select src.product_id
    from app_private.dispatch_return_source_grains(dispatch) src
  )
  for update;

  perform 1
  from public.product_selling_prices
  where product_selling_prices.is_active
    and product_selling_prices.product_id in (
      select src.product_id
      from app_private.dispatch_return_source_grains(dispatch) src
    )
  for update;

  select
    md5(string_agg(
      src.order_line_id::text || '|' ||
      src.product_id::text || '|' ||
      src.lot_id::text || '|' ||
      src.source_crate_id::text || '|' ||
      src.dispatched_cases::text,
      ',' order by src.order_line_id, src.lot_id, src.source_crate_id
    ))
  into quantity_fp
  from app_private.dispatch_return_source_grains(dispatch) src;

  if quantity_fp is null then
    raise exception 'dispatch has no billable shipped cases' using errcode = '23514';
  end if;

  insert into public.invoice_notes (
    status,
    version,
    idempotency_key,
    dispatch_id,
    order_id,
    shop_id,
    branch_id,
    as_of_date,
    dispatch_confirmed_at,
    billed_cases,
    billed_quantity,
    subtotal_amount,
    tax_amount,
    grand_total,
    quantity_fingerprint,
    price_fingerprint,
    remarks,
    created_by
  )
  values (
    'draft',
    1,
    cleaned_key,
    dispatch.id,
    order_row.id,
    order_row.shop_id,
    dispatch.branch_id,
    (dispatch.dispatched_at at time zone 'utc')::date,
    dispatch.dispatched_at,
    1,
    1,
    0.01,
    0,
    0.01,
    quantity_fp,
    'pending',
    cleaned_remarks,
    auth.uid()
  )
  returning * into created;

  for grain_row in
    select *
    from app_private.dispatch_return_source_grains(dispatch)
    order by order_line_id, lot_id, source_crate_id
  loop
    select * into product_row from public.products where products.id = grain_row.product_id;
    if product_row.billing_unit is null or product_row.billed_units_per_case is null then
      raise exception 'billing conversion is missing for a dispatched product'
        using errcode = '23514';
    end if;

    select * into resolved
    from app_private.resolve_selling_price(
      grain_row.product_id,
      order_row.shop_id,
      (dispatch.dispatched_at at time zone 'utc')::date
    );

    billed_qty := grain_row.dispatched_cases * product_row.billed_units_per_case;
    line_amount := round(billed_qty * resolved.unit_amount, 2);
    line_no := line_no + 1;
    total_cases := total_cases + grain_row.dispatched_cases;
    total_qty := total_qty + billed_qty;
    total_amount := total_amount + line_amount;

    insert into public.invoice_note_lines (
      invoice_note_id,
      line_no,
      order_line_id,
      product_id,
      lot_id,
      crate_id,
      product_sku,
      product_name,
      shipped_cases,
      billing_unit,
      billed_units_per_case,
      billed_quantity,
      unit_amount,
      line_amount,
      price_id,
      price_scope,
      price_effective_from,
      price_effective_to
    )
    values (
      created.id,
      line_no,
      grain_row.order_line_id,
      grain_row.product_id,
      grain_row.lot_id,
      grain_row.source_crate_id,
      product_row.sku,
      product_row.name,
      grain_row.dispatched_cases,
      product_row.billing_unit,
      product_row.billed_units_per_case,
      billed_qty,
      resolved.unit_amount,
      line_amount,
      resolved.price_id,
      resolved.price_scope,
      resolved.effective_from,
      resolved.effective_to
    );
  end loop;

  if line_no < 1 or total_amount <= 0 then
    raise exception 'dispatch has no billable shipped cases' using errcode = '23514';
  end if;

  select
    md5(string_agg(
      invoice_note_lines.order_line_id::text || '|' ||
      invoice_note_lines.product_id::text || '|' ||
      invoice_note_lines.lot_id::text || '|' ||
      invoice_note_lines.crate_id::text || '|' ||
      invoice_note_lines.shipped_cases::text || '|' ||
      app_private.invoice_numeric_token(invoice_note_lines.billed_units_per_case) || '|' ||
      invoice_note_lines.price_id::text || '|' ||
      app_private.invoice_numeric_token(invoice_note_lines.unit_amount),
      ',' order by invoice_note_lines.order_line_id, invoice_note_lines.lot_id, invoice_note_lines.crate_id
    ))
  into price_fp
  from public.invoice_note_lines
  where invoice_note_lines.invoice_note_id = created.id;

  update public.invoice_notes
  set
    billed_cases = total_cases,
    billed_quantity = total_qty,
    subtotal_amount = total_amount,
    tax_amount = 0,
    grand_total = total_amount,
    price_fingerprint = price_fp
  where invoice_notes.id = created.id
  returning * into created;

  perform app_private.assert_invoice_fingerprints(
    dispatch,
    order_row.shop_id,
    created.as_of_date,
    created.quantity_fingerprint,
    created.price_fingerprint
  );

  perform app_private.append_invoice_note_event(
    created, 'prepared', null, 'draft',
    jsonb_build_object('dispatch_id', dispatch.id, 'billed_cases', total_cases)
  );

  perform app_private.write_audit(
    auth.uid(),
    'prepare_invoice_note',
    'invoice_notes',
    created.id,
    jsonb_build_object('dispatch_id', dispatch.id, 'note_number', created.note_number)
  );

  return app_private.invoice_note_payload(created.id);
exception
  when unique_violation then
    raise exception 'an open invoice note already exists for this dispatch'
      using errcode = '23505';
end;
$$;
