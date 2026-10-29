-- M7.5E.2 internal credit-adjustment review and quantity reconciliation.
-- Approval is Accounts-only internal reconciliation. It is not a GST credit note.

-- ---------------------------------------------------------------------------
-- Occupied returns keep a unique open candidate through internal approval.
-- Rejected rows free the slot so Accounts can prepare a replacement.
-- ---------------------------------------------------------------------------

create or replace function app_private.credit_adjustment_occupies_return(p_status text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_status in ('preview', 'blocked', 'approved');
$$;

revoke all on function app_private.credit_adjustment_occupies_return(text)
  from public, anon, authenticated, service_role;

alter table public.invoice_credit_adjustments
  drop constraint if exists invoice_credit_adjustments_status_check;

alter table public.invoice_credit_adjustments
  add constraint invoice_credit_adjustments_status_check check (
    status in ('preview', 'blocked', 'approved', 'rejected')
  );

alter table public.invoice_credit_adjustments
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references public.profiles (id) on delete restrict,
  add column if not exists review_reason text,
  add column if not exists approved_at timestamptz,
  add column if not exists approved_by uuid references public.profiles (id) on delete restrict;

alter table public.invoice_credit_adjustments
  drop constraint if exists invoice_credit_adjustments_review_shape;

alter table public.invoice_credit_adjustments
  add constraint invoice_credit_adjustments_review_shape check (
    (
      status in ('preview', 'blocked')
      and reviewed_at is null
      and reviewed_by is null
      and review_reason is null
      and approved_at is null
      and approved_by is null
    )
    or (
      status = 'approved'
      and reviewed_at is not null
      and reviewed_by is not null
      and char_length(btrim(coalesce(review_reason, ''))) between 1 and 500
      and approved_at is not null
      and approved_by is not null
    )
    or (
      status = 'rejected'
      and reviewed_at is not null
      and reviewed_by is not null
      and char_length(btrim(coalesce(review_reason, ''))) between 1 and 500
      and approved_at is null
      and approved_by is null
    )
  );

-- Future legal numbers stay unique even though the not-issued check keeps them null.
create unique index if not exists invoice_credit_adjustments_legal_cn_uidx
  on public.invoice_credit_adjustments (legal_credit_note_number)
  where legal_credit_note_number is not null;

drop index if exists public.invoice_credit_adjustments_open_return_uidx;
create unique index invoice_credit_adjustments_open_return_uidx
  on public.invoice_credit_adjustments (return_id)
  where status in ('preview', 'blocked', 'approved');

alter table public.invoice_credit_adjustment_events
  drop constraint if exists invoice_credit_adjustment_events_type_check;

alter table public.invoice_credit_adjustment_events
  add constraint invoice_credit_adjustment_events_type_check check (
    event_type in ('prepared', 'previewed', 'approved', 'rejected')
  );

-- Financial snapshots stay immutable. Review columns may change through the GUC-gated RPC.
create or replace function app_private.guard_credit_adjustment_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform app_private.assert_credit_adjustment_write();
  if tg_op = 'DELETE' then
    raise exception 'credit-adjustment history cannot be deleted' using errcode = '42501';
  end if;
  if tg_table_name = 'invoice_credit_adjustment_events' and tg_op <> 'INSERT' then
    raise exception 'credit-adjustment events cannot be changed' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and tg_table_name = 'invoice_credit_adjustment_lines' then
    raise exception 'credit-adjustment financial snapshots are immutable'
      using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and tg_table_name = 'invoice_credit_adjustments' then
    if new.id is distinct from old.id
      or new.adjustment_number is distinct from old.adjustment_number
      or new.idempotency_key is distinct from old.idempotency_key
      or new.return_id is distinct from old.return_id
      or new.dispatch_id is distinct from old.dispatch_id
      or new.invoice_note_id is distinct from old.invoice_note_id
      or new.invoice_note_version is distinct from old.invoice_note_version
      or new.shop_id is distinct from old.shop_id
      or new.branch_id is distinct from old.branch_id
      or new.tax_preview_id is distinct from old.tax_preview_id
      or new.tax_input_fingerprint is distinct from old.tax_input_fingerprint
      or new.tax_preview_state is distinct from old.tax_preview_state
      or new.watermark is distinct from old.watermark
      or new.credited_cases is distinct from old.credited_cases
      or new.credited_quantity is distinct from old.credited_quantity
      or new.subtotal_amount is distinct from old.subtotal_amount
      or new.cgst_amount is distinct from old.cgst_amount
      or new.sgst_amount is distinct from old.sgst_amount
      or new.igst_amount is distinct from old.igst_amount
      or new.tax_amount is distinct from old.tax_amount
      or new.adjustment_total is distinct from old.adjustment_total
      or new.quantity_fingerprint is distinct from old.quantity_fingerprint
      or new.price_fingerprint is distinct from old.price_fingerprint
      or new.blockers is distinct from old.blockers
      or new.legal_credit_note_number is distinct from old.legal_credit_note_number
      or new.issued_at is distinct from old.issued_at
      or new.statutory_credit_note_id is distinct from old.statutory_credit_note_id
      or new.created_at is distinct from old.created_at
      or new.created_by is distinct from old.created_by
    then
      raise exception 'credit-adjustment financial snapshots are immutable'
        using errcode = '42501';
    end if;
    if old.status in ('approved', 'rejected') and new.status is distinct from old.status then
      raise exception 'terminal credit-adjustment status cannot change'
        using errcode = '23514';
    end if;
    if old.status in ('preview', 'blocked')
      and new.status not in ('preview', 'blocked', 'approved', 'rejected')
    then
      raise exception 'credit-adjustment status is not valid' using errcode = '23514';
    end if;
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function app_private.guard_credit_adjustment_write()
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Read-only whole-case reconciliation. Live product prices are never used.
-- ---------------------------------------------------------------------------

create or replace function public.get_credit_adjustment_reconciliation(p_adjustment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  header public.invoice_credit_adjustments;
  note public.invoice_notes;
  ret public.stock_delivery_returns;
  lines jsonb := '[]'::jsonb;
  discrepancies jsonb := '[]'::jsonb;
  billed_cases integer := 0;
  dispatched_cases integer := 0;
  returned_cases integer := 0;
  prepared_cases integer := 0;
  approved_cases integer := 0;
  remaining_cases integer := 0;
begin
  if not app_private.can_manage_credit_adjustment() then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select * into header
  from public.invoice_credit_adjustments
  where invoice_credit_adjustments.id = p_adjustment_id;
  if not found then
    raise exception 'credit adjustment not found' using errcode = 'P0002';
  end if;
  if not app_private.can_work_at_branch(header.branch_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select * into note from public.invoice_notes where invoice_notes.id = header.invoice_note_id;
  select * into ret from public.stock_delivery_returns where stock_delivery_returns.id = header.return_id;

  select
    coalesce(jsonb_agg(line_payload order by (line_payload ->> 'line_no')::integer), '[]'::jsonb),
    coalesce(sum((line_payload ->> 'billed_cases')::integer), 0),
    coalesce(sum((line_payload ->> 'dispatched_cases')::integer), 0),
    coalesce(sum((line_payload ->> 'returned_cases')::integer), 0),
    coalesce(sum((line_payload ->> 'prepared_cases')::integer), 0),
    coalesce(sum((line_payload ->> 'approved_cases')::integer), 0),
    coalesce(sum((line_payload ->> 'remaining_eligible_cases')::integer), 0)
  into lines, billed_cases, dispatched_cases, returned_cases, prepared_cases, approved_cases, remaining_cases
  from (
    select jsonb_build_object(
      'invoice_note_line_id', note_line.id,
      'line_no', note_line.line_no,
      'product_id', note_line.product_id,
      'product_sku', note_line.product_sku,
      'product_name', note_line.product_name,
      'billing_unit', note_line.billing_unit,
      'billed_units_per_case', note_line.billed_units_per_case,
      'unit_amount', note_line.unit_amount,
      'billed_cases', note_line.shipped_cases,
      'dispatched_cases', coalesce(lot.dispatched_cases, 0),
      'returned_cases', coalesce(
        lot.saleable_cases + lot.damaged_cases + lot.uncertain_cases + lot.missing_cases,
        0
      ),
      'this_adjustment_cases', coalesce(this_line.credited_cases, 0),
      'prepared_cases', coalesce((
        select sum(invoice_credit_adjustment_lines.credited_cases)
        from public.invoice_credit_adjustment_lines
        join public.invoice_credit_adjustments
          on invoice_credit_adjustments.id = invoice_credit_adjustment_lines.adjustment_id
        where invoice_credit_adjustment_lines.invoice_note_line_id = note_line.id
          and invoice_credit_adjustments.status in ('preview', 'blocked')
      ), 0),
      'approved_cases', coalesce((
        select sum(invoice_credit_adjustment_lines.credited_cases)
        from public.invoice_credit_adjustment_lines
        join public.invoice_credit_adjustments
          on invoice_credit_adjustments.id = invoice_credit_adjustment_lines.adjustment_id
        where invoice_credit_adjustment_lines.invoice_note_line_id = note_line.id
          and invoice_credit_adjustments.status = 'approved'
      ), 0),
      'remaining_eligible_cases', greatest(
        0,
        least(
          note_line.shipped_cases,
          coalesce(
            lot.saleable_cases + lot.damaged_cases + lot.uncertain_cases + lot.missing_cases,
            0
          )
        ) - coalesce((
          select sum(invoice_credit_adjustment_lines.credited_cases)
          from public.invoice_credit_adjustment_lines
          join public.invoice_credit_adjustments
            on invoice_credit_adjustments.id = invoice_credit_adjustment_lines.adjustment_id
          where invoice_credit_adjustment_lines.invoice_note_line_id = note_line.id
            and app_private.credit_adjustment_occupies_return(invoice_credit_adjustments.status)
        ), 0)
      ),
      'price_from', 'reviewed_invoice_note_line',
      'missing_return_lot', lot.id is null
    ) as line_payload
    from public.invoice_note_lines note_line
    left join public.stock_delivery_return_lots lot
      on lot.return_id = header.return_id
     and lot.order_line_id = note_line.order_line_id
     and lot.lot_id = note_line.lot_id
     and lot.source_crate_id = note_line.crate_id
     and lot.product_id = note_line.product_id
    left join public.invoice_credit_adjustment_lines this_line
      on this_line.adjustment_id = header.id
     and this_line.invoice_note_line_id = note_line.id
    where note_line.invoice_note_id = header.invoice_note_id
  ) grains;

  if exists (
    select 1
    from jsonb_array_elements(lines) grain
    where (grain ->> 'returned_cases')::integer > (grain ->> 'billed_cases')::integer
  ) then
    discrepancies := discrepancies || jsonb_build_array(app_private.invoice_blocker(
      'returned_exceeds_billed',
      'Verified returned cases exceed the original billed carton quantity.'
    ));
  end if;
  if exists (
    select 1
    from jsonb_array_elements(lines) grain
    where (grain ->> 'dispatched_cases')::integer is distinct from (grain ->> 'billed_cases')::integer
  ) then
    discrepancies := discrepancies || jsonb_build_array(app_private.invoice_blocker(
      'dispatched_differs_from_billed',
      'Posted dispatch cases differ from the reviewed invoice-note billed cases.'
    ));
  end if;
  if exists (
    select 1
    from jsonb_array_elements(lines) grain
    where (grain ->> 'this_adjustment_cases')::integer > (grain ->> 'returned_cases')::integer
  ) then
    discrepancies := discrepancies || jsonb_build_array(app_private.invoice_blocker(
      'adjustment_exceeds_returned',
      'Prepared credit-adjustment cases exceed verified returned cases.'
    ));
  end if;
  if exists (
    select 1
    from jsonb_array_elements(lines) grain
    where (grain ->> 'missing_return_lot')::boolean
  ) then
    discrepancies := discrepancies || jsonb_build_array(app_private.invoice_blocker(
      'missing_return_lot_grain',
      'A billed invoice-note grain has no matching verified return-lot record.'
    ));
  end if;

  return jsonb_build_object(
    'adjustment_id', header.id,
    'return_id', header.return_id,
    'invoice_note_id', header.invoice_note_id,
    'return_status', ret.status,
    'invoice_note_status', note.status,
    'arithmetic', 'whole_case',
    'prices_from', 'reviewed_invoice_note_snapshot',
    'billed_cases', billed_cases,
    'dispatched_cases', dispatched_cases,
    'returned_cases', returned_cases,
    'prepared_cases', prepared_cases,
    'approved_cases', approved_cases,
    'remaining_eligible_cases', remaining_cases,
    'lines', lines,
    'discrepancies', discrepancies
  );
end;
$$;

revoke all on function public.get_credit_adjustment_reconciliation(uuid)
  from public, anon;
grant execute on function public.get_credit_adjustment_reconciliation(uuid)
  to authenticated;

comment on function public.get_credit_adjustment_reconciliation(uuid) is
  'Read-only whole-case reconciliation of billed, dispatched, returned, and internally adjusted cases. Does not post accounts or tax.';

-- ---------------------------------------------------------------------------
-- Accounts review. Approval never issues a credit note or writes stock.
-- ---------------------------------------------------------------------------

create or replace function public.review_credit_adjustment(
  p_adjustment_id uuid,
  p_decision text,
  p_reason text,
  p_expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid;
  header public.invoice_credit_adjustments;
  cleaned_reason text;
  next_status text;
  now_ts timestamptz;
begin
  actor := auth.uid();
  if actor is null or not app_private.can_manage_credit_adjustment() then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_decision not in ('approve', 'reject') then
    raise exception 'credit-adjustment decision is not valid' using errcode = '23514';
  end if;
  cleaned_reason := btrim(coalesce(p_reason, ''));
  if char_length(cleaned_reason) < 1 or char_length(cleaned_reason) > 500 then
    raise exception 'review reason is required' using errcode = '23514';
  end if;

  perform stock_dispatch_requests.id
  from public.stock_dispatch_requests
  join public.invoice_credit_adjustments
    on invoice_credit_adjustments.dispatch_id = stock_dispatch_requests.id
   and invoice_credit_adjustments.id = p_adjustment_id
  for update of stock_dispatch_requests;
  if not found then
    raise exception 'credit adjustment not found' using errcode = 'P0002';
  end if;

  perform stock_delivery_returns.id
  from public.stock_delivery_returns
  join public.invoice_credit_adjustments
    on invoice_credit_adjustments.return_id = stock_delivery_returns.id
   and invoice_credit_adjustments.id = p_adjustment_id
  for update of stock_delivery_returns;

  select * into header
  from public.invoice_credit_adjustments
  where invoice_credit_adjustments.id = p_adjustment_id
  for update;
  if not found then
    raise exception 'credit adjustment not found' using errcode = 'P0002';
  end if;
  if header.version is distinct from p_expected_version then
    raise exception 'credit adjustment was changed by someone else' using errcode = 'PT409';
  end if;
  if not app_private.can_work_at_branch(header.branch_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if header.status in ('approved', 'rejected') then
    raise exception 'credit adjustment is already reviewed' using errcode = '23514';
  end if;
  if p_decision = 'approve' and header.status is distinct from 'preview' then
    raise exception 'only a prepared preview can be approved for internal reconciliation'
      using errcode = '23514';
  end if;
  if p_decision = 'reject' and header.status not in ('preview', 'blocked') then
    raise exception 'only a prepared credit adjustment can be rejected'
      using errcode = '23514';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('credit-adj:' || header.invoice_note_id::text, 0)
  );

  next_status := case when p_decision = 'approve' then 'approved' else 'rejected' end;
  now_ts := pg_catalog.clock_timestamp();
  perform set_config('app.credit_adjustment_write', 'on', true);

  update public.invoice_credit_adjustments
  set
    status = next_status,
    version = header.version + 1,
    reviewed_at = now_ts,
    reviewed_by = actor,
    review_reason = cleaned_reason,
    approved_at = case when next_status = 'approved' then now_ts else null end,
    approved_by = case when next_status = 'approved' then actor else null end
  where invoice_credit_adjustments.id = header.id
  returning * into header;

  insert into public.invoice_credit_adjustment_events (
    adjustment_id, event_type, actor_id, payload
  )
  values (
    header.id,
    next_status,
    actor,
    jsonb_build_object(
      'decision', p_decision,
      'reason', cleaned_reason,
      'legal_issuance_blocked', true,
      'internal_reconciliation_only', true
    )
  );

  perform app_private.write_audit(
    actor,
    'credit_adjustment.' || next_status,
    'invoice_credit_adjustments',
    header.id,
    jsonb_build_object(
      'decision', p_decision,
      'reason', cleaned_reason,
      'legal_issuance_blocked', true
    )
  );

  return app_private.credit_adjustment_payload(header.id);
end;
$$;

revoke all on function public.review_credit_adjustment(uuid, text, text, integer)
  from public, anon;
grant execute on function public.review_credit_adjustment(uuid, text, text, integer)
  to authenticated;

comment on function public.review_credit_adjustment(uuid, text, text, integer) is
  'Accounts approve or reject an internal credit-adjustment preview. Never issues a GST credit note, allocates a legal number, or writes stock.';

-- Occupied-return lookups include approved so a second prepare cannot duplicate.
create or replace function public.prepare_credit_adjustment(
  p_return_id uuid,
  p_idempotency_key text,
  p_expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid;
  ret public.stock_delivery_returns;
  dispatch public.stock_dispatch_requests;
  note public.invoice_notes;
  preview public.invoice_tax_previews;
  existing public.invoice_credit_adjustments;
  lot public.stock_delivery_return_lots;
  note_line public.invoice_note_lines;
  tax_line public.invoice_tax_preview_lines;
  calc jsonb;
  adjustment_id uuid;
  credited integer;
  billed_qty numeric(14, 4);
  line_subtotal numeric(14, 2);
  line_no integer := 0;
  sum_cases integer := 0;
  sum_qty numeric(14, 4) := 0;
  sum_subtotal numeric(14, 2) := 0;
  sum_cgst numeric(14, 2) := 0;
  sum_sgst numeric(14, 2) := 0;
  sum_igst numeric(14, 2) := 0;
  sum_tax numeric(14, 2) := 0;
  sum_total numeric(14, 2) := 0;
  already integer;
  tax_state text := 'tax_unavailable';
  blockers jsonb := '[]'::jsonb;
  qty_fp text := '';
  price_fp text := '';
  cleaned_key text;
  line_payloads jsonb := '[]'::jsonb;
  elem jsonb;
  apply_tax boolean;
begin
  actor := auth.uid();
  if actor is null or not app_private.can_manage_credit_adjustment() then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  cleaned_key := btrim(coalesce(p_idempotency_key, ''));
  if char_length(cleaned_key) < 3 or char_length(cleaned_key) > 120 then
    raise exception 'idempotency key is not valid' using errcode = '23514';
  end if;

  select * into existing
  from public.invoice_credit_adjustments
  where invoice_credit_adjustments.idempotency_key = cleaned_key;
  if found then
    if not app_private.can_work_at_branch(existing.branch_id) then
      raise exception 'permission denied' using errcode = '42501';
    end if;
    return app_private.credit_adjustment_payload(existing.id);
  end if;

  perform stock_dispatch_requests.id
  from public.stock_dispatch_requests
  join public.stock_delivery_returns
    on stock_delivery_returns.dispatch_id = stock_dispatch_requests.id
   and stock_delivery_returns.id = p_return_id
  for update of stock_dispatch_requests;
  if not found then
    raise exception 'verified return not found' using errcode = 'P0002';
  end if;

  select * into ret
  from public.stock_delivery_returns
  where stock_delivery_returns.id = p_return_id
  for update;
  if not found then
    raise exception 'verified return not found' using errcode = 'P0002';
  end if;
  if ret.version is distinct from p_expected_version then
    raise exception 'return was changed by someone else' using errcode = 'PT409';
  end if;
  if not app_private.can_work_at_branch(ret.branch_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  select * into existing
  from public.invoice_credit_adjustments
  where invoice_credit_adjustments.return_id = ret.id
    and app_private.credit_adjustment_occupies_return(invoice_credit_adjustments.status);
  if found then
    return app_private.credit_adjustment_payload(existing.id);
  end if;

  if ret.status not in ('posted', 'closed_missing') then
    raise exception 'return is not a verified posted or closed-missing customer return'
      using errcode = '23514';
  end if;

  select * into dispatch
  from public.stock_dispatch_requests
  where stock_dispatch_requests.id = ret.dispatch_id;
  if dispatch.stock_consumed is distinct from true
    or dispatch.posted_transaction_id is null
  then
    raise exception 'source dispatch is not a posted consume' using errcode = '23514';
  end if;

  select * into note
  from public.invoice_notes
  where invoice_notes.dispatch_id = ret.dispatch_id
    and invoice_notes.status = 'reviewed'
  for update;
  if not found then
    raise exception 'reviewed invoice note is required for a credit adjustment preview'
      using errcode = '23514';
  end if;
  if not app_private.can_work_at_branch(note.branch_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if note.shop_id is distinct from (
    select orders.shop_id from public.orders where orders.id = note.order_id
  ) then
    raise exception 'return cannot credit a different shop invoice note'
      using errcode = '23514';
  end if;
  if note.branch_id is distinct from ret.branch_id then
    raise exception 'return cannot credit another godown invoice note'
      using errcode = '23514';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('credit-adj:' || note.id::text, 0)
  );

  select * into preview
  from public.invoice_tax_previews
  where invoice_tax_previews.invoice_note_id = note.id
    and invoice_tax_previews.is_current;

  if preview.id is null then
    tax_state := 'tax_unavailable';
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'tax_preview_missing',
      'No current tax-preview snapshot exists. Tax components are not invented.'
    ));
  elsif preview.invoice_note_version is distinct from note.version
    or preview.dispatch_id is distinct from note.dispatch_id
  then
    tax_state := 'tax_stale';
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'tax_preview_stale',
      'The tax-preview fingerprint does not match the reviewed invoice-note snapshot.'
    ));
  else
    tax_state := 'tax_preview';
  end if;

  blockers := blockers || jsonb_build_array(
    app_private.invoice_blocker(
      'gst_credit_note_disabled',
      'This preview is not a GST credit note and does not allocate a legal credit-note number.'
    )
  );

  perform set_config('app.credit_adjustment_write', 'on', true);

  for lot in
    select * from public.stock_delivery_return_lots
    where stock_delivery_return_lots.return_id = ret.id
    order by stock_delivery_return_lots.id
  loop
    credited := lot.saleable_cases + lot.damaged_cases + lot.uncertain_cases + lot.missing_cases;
    if credited <= 0 then
      continue;
    end if;

    select * into note_line
    from public.invoice_note_lines
    where invoice_note_lines.invoice_note_id = note.id
      and invoice_note_lines.order_line_id = lot.order_line_id
      and invoice_note_lines.lot_id = lot.lot_id
      and invoice_note_lines.crate_id = lot.source_crate_id
      and invoice_note_lines.product_id = lot.product_id;
    if not found then
      raise exception 'return grain does not match a reviewed invoice-note line'
        using errcode = '23514';
    end if;
    if credited > note_line.shipped_cases then
      raise exception 'credited cases exceed the original billed carton quantity'
        using errcode = '23514';
    end if;

    select coalesce(sum(invoice_credit_adjustment_lines.credited_cases), 0) into already
    from public.invoice_credit_adjustment_lines
    join public.invoice_credit_adjustments
      on invoice_credit_adjustments.id = invoice_credit_adjustment_lines.adjustment_id
    where invoice_credit_adjustment_lines.invoice_note_line_id = note_line.id
      and app_private.credit_adjustment_occupies_return(invoice_credit_adjustments.status);
    if already + credited > note_line.shipped_cases then
      raise exception 'cumulative credited cases exceed the original billed carton quantity'
        using errcode = '23514';
    end if;

    billed_qty := credited * note_line.billed_units_per_case;
    line_subtotal := round(billed_qty * note_line.unit_amount, 2);
    line_no := line_no + 1;
    calc := null;
    tax_line := null::public.invoice_tax_preview_lines;
    select * into tax_line
    from public.invoice_tax_preview_lines
    where preview.id is not null
      and invoice_tax_preview_lines.preview_id = preview.id
      and invoice_tax_preview_lines.invoice_note_line_id = note_line.id;

    if tax_state = 'tax_preview' and tax_line.id is null then
      tax_state := 'tax_incomplete';
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'tax_preview_incomplete',
        'A tax-preview line is missing for a credited invoice-note grain. Tax is not invented.'
      ));
    end if;

    if tax_state = 'tax_preview' and tax_line.id is not null then
      calc := app_private.gst_line_calc(
        line_subtotal,
        preview.pricing_treatment,
        preview.supply_kind,
        tax_line.cgst_rate,
        tax_line.sgst_rate,
        tax_line.igst_rate,
        preview.rounding_mode,
        preview.rounding_increment
      );
    end if;

    line_payloads := line_payloads || jsonb_build_array(jsonb_build_object(
      'return_lot_id', lot.id,
      'invoice_note_line_id', note_line.id,
      'line_no', line_no,
      'product_id', note_line.product_id,
      'product_sku', note_line.product_sku,
      'product_name', note_line.product_name,
      'original_shipped_cases', note_line.shipped_cases,
      'credited_cases', credited,
      'billing_unit', note_line.billing_unit,
      'billed_units_per_case', note_line.billed_units_per_case,
      'billed_quantity', billed_qty,
      'unit_amount', note_line.unit_amount,
      'line_subtotal', line_subtotal,
      'cgst_rate', tax_line.cgst_rate,
      'sgst_rate', tax_line.sgst_rate,
      'igst_rate', tax_line.igst_rate,
      'calc', calc
    ));

    sum_cases := sum_cases + credited;
    sum_qty := sum_qty + billed_qty;
    sum_subtotal := sum_subtotal + line_subtotal;
    qty_fp := qty_fp || note_line.id::text || ':' || credited::text || ';';
    price_fp := price_fp || note_line.id::text || ':' || note_line.unit_amount::text || ';';
  end loop;

  if line_no = 0 then
    raise exception 'verified return has no creditable carton cases'
      using errcode = '23514';
  end if;

  apply_tax := tax_state = 'tax_preview';
  if apply_tax then
    for elem in select jsonb_array_elements(line_payloads)
    loop
      sum_cgst := sum_cgst + coalesce((elem -> 'calc' ->> 'cgst_amount')::numeric, 0);
      sum_sgst := sum_sgst + coalesce((elem -> 'calc' ->> 'sgst_amount')::numeric, 0);
      sum_igst := sum_igst + coalesce((elem -> 'calc' ->> 'igst_amount')::numeric, 0);
      sum_tax := sum_tax + coalesce((elem -> 'calc' ->> 'tax_amount')::numeric, 0);
      sum_total := sum_total + coalesce(
        (elem -> 'calc' ->> 'line_total')::numeric,
        (elem ->> 'line_subtotal')::numeric
      );
    end loop;
  else
    sum_total := sum_subtotal;
  end if;

  insert into public.invoice_credit_adjustments (
    status, idempotency_key, return_id, dispatch_id, invoice_note_id, invoice_note_version,
    shop_id, branch_id, tax_preview_id, tax_input_fingerprint, tax_preview_state, watermark,
    credited_cases, credited_quantity, subtotal_amount, cgst_amount, sgst_amount, igst_amount,
    tax_amount, adjustment_total, quantity_fingerprint, price_fingerprint, blockers, created_by
  )
  values (
    'preview', cleaned_key, ret.id, ret.dispatch_id, note.id, note.version,
    note.shop_id, note.branch_id, preview.id, preview.input_fingerprint, tax_state,
    U&'CREDIT ADJUSTMENT PREVIEW \2014 NOT A GST CREDIT NOTE',
    sum_cases, sum_qty, sum_subtotal, sum_cgst, sum_sgst, sum_igst,
    sum_tax, sum_total, md5(qty_fp), md5(price_fp || note.price_fingerprint), blockers, actor
  )
  returning id into adjustment_id;

  for elem in select jsonb_array_elements(line_payloads)
  loop
    insert into public.invoice_credit_adjustment_lines (
      adjustment_id, return_lot_id, invoice_note_line_id, line_no, product_id,
      product_sku, product_name, original_shipped_cases, credited_cases, billing_unit,
      billed_units_per_case, billed_quantity, unit_amount, line_subtotal, taxable_value,
      cgst_rate, sgst_rate, igst_rate, cgst_amount, sgst_amount, igst_amount, tax_amount,
      line_total
    )
    values (
      adjustment_id,
      (elem ->> 'return_lot_id')::uuid,
      (elem ->> 'invoice_note_line_id')::uuid,
      (elem ->> 'line_no')::integer,
      (elem ->> 'product_id')::uuid,
      elem ->> 'product_sku',
      elem ->> 'product_name',
      (elem ->> 'original_shipped_cases')::integer,
      (elem ->> 'credited_cases')::integer,
      elem ->> 'billing_unit',
      (elem ->> 'billed_units_per_case')::numeric,
      (elem ->> 'billed_quantity')::numeric,
      (elem ->> 'unit_amount')::numeric,
      (elem ->> 'line_subtotal')::numeric,
      case when apply_tax then coalesce((elem -> 'calc' ->> 'taxable_value')::numeric, (elem ->> 'line_subtotal')::numeric)
           else (elem ->> 'line_subtotal')::numeric end,
      (elem ->> 'cgst_rate')::numeric,
      (elem ->> 'sgst_rate')::numeric,
      (elem ->> 'igst_rate')::numeric,
      case when apply_tax then coalesce((elem -> 'calc' ->> 'cgst_amount')::numeric, 0) else 0 end,
      case when apply_tax then coalesce((elem -> 'calc' ->> 'sgst_amount')::numeric, 0) else 0 end,
      case when apply_tax then coalesce((elem -> 'calc' ->> 'igst_amount')::numeric, 0) else 0 end,
      case when apply_tax then coalesce((elem -> 'calc' ->> 'tax_amount')::numeric, 0) else 0 end,
      case when apply_tax then coalesce((elem -> 'calc' ->> 'line_total')::numeric, (elem ->> 'line_subtotal')::numeric)
           else (elem ->> 'line_subtotal')::numeric end
    );
  end loop;

  insert into public.invoice_credit_adjustment_events (
    adjustment_id, event_type, actor_id, payload
  )
  values (
    adjustment_id,
    'prepared',
    actor,
    jsonb_build_object(
      'return_id', ret.id,
      'invoice_note_id', note.id,
      'invoice_note_version', note.version,
      'legal_issuance_blocked', true
    )
  );

  perform app_private.write_audit(
    actor,
    'credit_adjustment.prepared',
    'invoice_credit_adjustments',
    adjustment_id,
    jsonb_build_object(
      'return_id', ret.id,
      'invoice_note_id', note.id,
      'legal_issuance_blocked', true
    )
  );

  return app_private.credit_adjustment_payload(adjustment_id);
exception
  when unique_violation then
    select * into existing
    from public.invoice_credit_adjustments
    where invoice_credit_adjustments.return_id = p_return_id
      and app_private.credit_adjustment_occupies_return(invoice_credit_adjustments.status)
    limit 1;
    if existing.id is not null then
      return app_private.credit_adjustment_payload(existing.id);
    end if;
    raise;
end;
$$;

create or replace function app_private.credit_adjustment_payload(target uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  header public.invoice_credit_adjustments;
  note public.invoice_notes;
  ret public.stock_delivery_returns;
  dispatch public.stock_dispatch_requests;
  shop public.shops;
  reviewer public.profiles;
begin
  select * into header from public.invoice_credit_adjustments
  where invoice_credit_adjustments.id = target;
  if not found then
    raise exception 'credit adjustment not found' using errcode = 'P0002';
  end if;
  select * into note from public.invoice_notes where invoice_notes.id = header.invoice_note_id;
  select * into ret from public.stock_delivery_returns where stock_delivery_returns.id = header.return_id;
  select * into dispatch from public.stock_dispatch_requests where stock_dispatch_requests.id = header.dispatch_id;
  select * into shop from public.shops where shops.id = header.shop_id;
  select * into reviewer from public.profiles where profiles.id = header.reviewed_by;

  return jsonb_build_object(
    'id', header.id,
    'adjustment_number', header.adjustment_number,
    'status', header.status,
    'version', header.version,
    'watermark', header.watermark,
    'legal_credit_note_number', header.legal_credit_note_number,
    'legal_issuance_blocked', true,
    'internal_reconciliation_only', true,
    'tax_preview_state', header.tax_preview_state,
    'tax_preview_id', header.tax_preview_id,
    'tax_input_fingerprint', header.tax_input_fingerprint,
    'return_id', header.return_id,
    'return_number', ret.return_number,
    'return_status', ret.status,
    'dispatch_id', header.dispatch_id,
    'dispatch_number', dispatch.request_number,
    'invoice_note_id', header.invoice_note_id,
    'invoice_note_number', note.note_number,
    'invoice_note_version', header.invoice_note_version,
    'shop_id', header.shop_id,
    'shop_name', shop.name,
    'branch_id', header.branch_id,
    'credited_cases', header.credited_cases,
    'credited_quantity', header.credited_quantity,
    'subtotal_amount', header.subtotal_amount,
    'cgst_amount', header.cgst_amount,
    'sgst_amount', header.sgst_amount,
    'igst_amount', header.igst_amount,
    'tax_amount', header.tax_amount,
    'adjustment_total', header.adjustment_total,
    'blockers', header.blockers,
    'reviewed_at', header.reviewed_at,
    'reviewed_by', header.reviewed_by,
    'reviewer_name', reviewer.full_name,
    'review_reason', header.review_reason,
    'approved_at', header.approved_at,
    'approved_by', header.approved_by,
    'created_at', header.created_at,
    'generated_at', pg_catalog.clock_timestamp(),
    'reconciliation', public.get_credit_adjustment_reconciliation(header.id),
    'events', coalesce((
      select jsonb_agg(event_payload order by event_payload ->> 'created_at')
      from (
        select jsonb_build_object(
          'id', invoice_credit_adjustment_events.id,
          'event_type', invoice_credit_adjustment_events.event_type,
          'actor_id', invoice_credit_adjustment_events.actor_id,
          'payload', invoice_credit_adjustment_events.payload,
          'created_at', invoice_credit_adjustment_events.created_at
        ) as event_payload
        from public.invoice_credit_adjustment_events
        where invoice_credit_adjustment_events.adjustment_id = header.id
      ) events
    ), '[]'::jsonb),
    'lines', coalesce((
      select jsonb_agg(to_jsonb(invoice_credit_adjustment_lines) order by invoice_credit_adjustment_lines.line_no)
      from public.invoice_credit_adjustment_lines
      where invoice_credit_adjustment_lines.adjustment_id = header.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app_private.credit_adjustment_payload(uuid)
  from public, anon, authenticated, service_role;

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
  if p_status is not null
    and p_status not in ('preview', 'blocked', 'approved', 'rejected')
  then
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
        'reviewed_at', invoice_credit_adjustments.reviewed_at,
        'reviewed_by', invoice_credit_adjustments.reviewed_by,
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

revoke all on function public.prepare_credit_adjustment(uuid, text, integer)
  from public, anon;
revoke all on function public.list_credit_adjustments(text, uuid)
  from public, anon;
grant execute on function public.prepare_credit_adjustment(uuid, text, integer)
  to authenticated;
grant execute on function public.list_credit_adjustments(text, uuid)
  to authenticated;

notify pgrst, 'reload schema';

