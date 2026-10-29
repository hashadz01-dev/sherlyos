-- M7.5E.1 internal credit-adjustment preview.
-- Links posted/closed-missing delivery returns to reviewed invoice-note snapshots.
-- Does not issue GST credit notes, allocate legal numbers, post ledgers, or write stock.

create sequence if not exists public.invoice_credit_adjustment_seq as bigint;

revoke all on sequence public.invoice_credit_adjustment_seq
  from public, anon, authenticated, service_role;

comment on sequence public.invoice_credit_adjustment_seq is
  'Internal credit-adjustment preview numbers (CA-YYYYMMDD-######). Not a GST credit-note series.';

create or replace function app_private.assert_credit_adjustment_write()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if current_setting('app.credit_adjustment_write', true) is distinct from 'on' then
    raise exception 'credit adjustments can only change through approved procedures'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_credit_adjustment_write()
  from public, anon, authenticated, service_role;

create or replace function app_private.can_manage_credit_adjustment()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app_private.has_permission('invoices.review');
$$;

revoke all on function app_private.can_manage_credit_adjustment() from public, anon;
grant execute on function app_private.can_manage_credit_adjustment() to authenticated;

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
  if tg_op = 'UPDATE' and tg_table_name in (
    'invoice_credit_adjustments',
    'invoice_credit_adjustment_lines'
  ) then
    raise exception 'credit-adjustment financial snapshots are immutable'
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function app_private.guard_credit_adjustment_write()
  from public, anon, authenticated, service_role;

create table if not exists public.invoice_credit_adjustments (
  id uuid primary key default gen_random_uuid(),
  adjustment_number text not null,
  status text not null,
  version integer not null default 1,
  idempotency_key text not null,
  return_id uuid not null
    references public.stock_delivery_returns (id) on delete restrict,
  dispatch_id uuid not null
    references public.stock_dispatch_requests (id) on delete restrict,
  invoice_note_id uuid not null
    references public.invoice_notes (id) on delete restrict,
  invoice_note_version integer not null,
  shop_id uuid not null references public.shops (id) on delete restrict,
  branch_id uuid not null references public.branches (id) on delete restrict,
  tax_preview_id uuid references public.invoice_tax_previews (id) on delete restrict,
  tax_input_fingerprint text,
  tax_preview_state text not null,
  watermark text not null,
  credited_cases integer not null,
  credited_quantity numeric(14, 4) not null,
  subtotal_amount numeric(14, 2) not null,
  cgst_amount numeric(14, 2) not null default 0,
  sgst_amount numeric(14, 2) not null default 0,
  igst_amount numeric(14, 2) not null default 0,
  tax_amount numeric(14, 2) not null default 0,
  adjustment_total numeric(14, 2) not null,
  quantity_fingerprint text not null,
  price_fingerprint text not null,
  blockers jsonb not null default '[]'::jsonb,
  legal_credit_note_number text,
  issued_at timestamptz,
  statutory_credit_note_id uuid,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  created_by uuid not null references public.profiles (id) on delete restrict,
  updated_at timestamptz not null default pg_catalog.now(),
  constraint invoice_credit_adjustments_number_key unique (adjustment_number),
  constraint invoice_credit_adjustments_idempotency_key unique (idempotency_key),
  constraint invoice_credit_adjustments_status_check check (
    status in ('preview', 'blocked')
  ),
  constraint invoice_credit_adjustments_tax_state_check check (
    tax_preview_state in ('tax_preview', 'tax_unavailable', 'tax_stale', 'tax_incomplete')
  ),
  constraint invoice_credit_adjustments_watermark_check check (
    watermark = U&'CREDIT ADJUSTMENT PREVIEW \2014 NOT A GST CREDIT NOTE'
  ),
  constraint invoice_credit_adjustments_not_issued check (
    legal_credit_note_number is null
    and issued_at is null
    and statutory_credit_note_id is null
  ),
  constraint invoice_credit_adjustments_qty_check check (
    credited_cases > 0
    and credited_quantity > 0
    and subtotal_amount > 0
    and adjustment_total > 0
    and cgst_amount >= 0
    and sgst_amount >= 0
    and igst_amount >= 0
    and tax_amount >= 0
  )
);

create unique index if not exists invoice_credit_adjustments_open_return_uidx
  on public.invoice_credit_adjustments (return_id)
  where status in ('preview', 'blocked');

create index if not exists invoice_credit_adjustments_note_idx
  on public.invoice_credit_adjustments (invoice_note_id, created_at desc);

create table if not exists public.invoice_credit_adjustment_lines (
  id uuid primary key default gen_random_uuid(),
  adjustment_id uuid not null
    references public.invoice_credit_adjustments (id) on delete restrict,
  return_lot_id uuid not null
    references public.stock_delivery_return_lots (id) on delete restrict,
  invoice_note_line_id uuid not null
    references public.invoice_note_lines (id) on delete restrict,
  line_no integer not null,
  product_id uuid not null,
  product_sku text not null,
  product_name text not null,
  original_shipped_cases integer not null,
  credited_cases integer not null,
  billing_unit text not null,
  billed_units_per_case numeric(12, 4) not null,
  billed_quantity numeric(14, 4) not null,
  unit_amount numeric(14, 4) not null,
  line_subtotal numeric(14, 2) not null,
  taxable_value numeric(14, 2) not null default 0,
  cgst_rate numeric(5, 2),
  sgst_rate numeric(5, 2),
  igst_rate numeric(5, 2),
  cgst_amount numeric(14, 2) not null default 0,
  sgst_amount numeric(14, 2) not null default 0,
  igst_amount numeric(14, 2) not null default 0,
  tax_amount numeric(14, 2) not null default 0,
  line_total numeric(14, 2) not null,
  constraint invoice_credit_adjustment_lines_key unique (adjustment_id, line_no),
  constraint invoice_credit_adjustment_lines_grain_key unique (
    adjustment_id, invoice_note_line_id
  ),
  constraint invoice_credit_adjustment_lines_qty_check check (
    line_no >= 1
    and original_shipped_cases > 0
    and credited_cases > 0
    and credited_cases <= original_shipped_cases
    and billed_units_per_case > 0
    and billed_quantity > 0
    and unit_amount > 0
    and line_subtotal > 0
  )
);

create table if not exists public.invoice_credit_adjustment_events (
  id uuid primary key default gen_random_uuid(),
  adjustment_id uuid not null
    references public.invoice_credit_adjustments (id) on delete restrict,
  event_type text not null,
  actor_id uuid not null references public.profiles (id) on delete restrict,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint invoice_credit_adjustment_events_type_check check (
    event_type in ('prepared', 'previewed')
  )
);

create index if not exists invoice_credit_adjustment_lines_header_idx
  on public.invoice_credit_adjustment_lines (adjustment_id, line_no);
create index if not exists invoice_credit_adjustment_events_header_idx
  on public.invoice_credit_adjustment_events (adjustment_id, created_at);
create index if not exists invoice_credit_adjustment_lines_note_line_idx
  on public.invoice_credit_adjustment_lines (invoice_note_line_id);

comment on table public.invoice_credit_adjustments is
  'Internal financial-adjustment preview from a verified delivery return. Not a GST credit note.';
comment on table public.invoice_credit_adjustment_lines is
  'Immutable billed quantities and INR prices copied from the reviewed invoice-note line. Live prices are not used.';
comment on table public.invoice_credit_adjustment_events is
  'Append-only credit-adjustment history.';

create or replace function app_private.assign_credit_adjustment_number()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' and new.adjustment_number is null then
    new.adjustment_number := 'CA-'
      || to_char(pg_catalog.clock_timestamp() at time zone 'utc', 'YYYYMMDD')
      || '-'
      || pg_catalog.lpad(
        pg_catalog.nextval('public.invoice_credit_adjustment_seq')::text,
        6,
        '0'
      );
  end if;
  if tg_op = 'UPDATE' and new.adjustment_number is distinct from old.adjustment_number then
    raise exception 'credit-adjustment number is immutable' using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function app_private.assign_credit_adjustment_number()
  from public, anon, authenticated, service_role;

create trigger invoice_credit_adjustments_assign_number
  before insert or update on public.invoice_credit_adjustments
  for each row execute function app_private.assign_credit_adjustment_number();

create trigger invoice_credit_adjustments_set_updated_at
  before update on public.invoice_credit_adjustments
  for each row execute function app_private.set_updated_at();

create trigger invoice_credit_adjustments_guard
  before insert or update or delete on public.invoice_credit_adjustments
  for each row execute function app_private.guard_credit_adjustment_write();
create trigger invoice_credit_adjustment_lines_guard
  before insert or update or delete on public.invoice_credit_adjustment_lines
  for each row execute function app_private.guard_credit_adjustment_write();
create trigger invoice_credit_adjustment_events_guard
  before insert or update or delete on public.invoice_credit_adjustment_events
  for each row execute function app_private.guard_credit_adjustment_write();

alter table public.invoice_credit_adjustments enable row level security;
alter table public.invoice_credit_adjustments force row level security;
alter table public.invoice_credit_adjustment_lines enable row level security;
alter table public.invoice_credit_adjustment_lines force row level security;
alter table public.invoice_credit_adjustment_events enable row level security;
alter table public.invoice_credit_adjustment_events force row level security;

create policy invoice_credit_adjustments_select
  on public.invoice_credit_adjustments for select to authenticated
  using (
    (select app_private.can_manage_credit_adjustment())
    and app_private.can_work_at_branch(invoice_credit_adjustments.branch_id)
  );
create policy invoice_credit_adjustment_lines_select
  on public.invoice_credit_adjustment_lines for select to authenticated
  using (
    exists (
      select 1 from public.invoice_credit_adjustments
      where invoice_credit_adjustments.id = invoice_credit_adjustment_lines.adjustment_id
        and app_private.can_manage_credit_adjustment()
        and app_private.can_work_at_branch(invoice_credit_adjustments.branch_id)
    )
  );
create policy invoice_credit_adjustment_events_select
  on public.invoice_credit_adjustment_events for select to authenticated
  using (
    exists (
      select 1 from public.invoice_credit_adjustments
      where invoice_credit_adjustments.id = invoice_credit_adjustment_events.adjustment_id
        and app_private.can_manage_credit_adjustment()
        and app_private.can_work_at_branch(invoice_credit_adjustments.branch_id)
    )
  );

revoke all on table public.invoice_credit_adjustments
  from public, anon, authenticated, service_role;
revoke all on table public.invoice_credit_adjustment_lines
  from public, anon, authenticated, service_role;
revoke all on table public.invoice_credit_adjustment_events
  from public, anon, authenticated, service_role;
grant select on table public.invoice_credit_adjustments to authenticated;
grant select on table public.invoice_credit_adjustment_lines to authenticated;
grant select on table public.invoice_credit_adjustment_events to authenticated;

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

  return jsonb_build_object(
    'id', header.id,
    'adjustment_number', header.adjustment_number,
    'status', header.status,
    'version', header.version,
    'watermark', header.watermark,
    'legal_credit_note_number', header.legal_credit_note_number,
    'legal_issuance_blocked', true,
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
    'created_at', header.created_at,
    'generated_at', pg_catalog.clock_timestamp(),
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

  -- Lock dispatch first, then the return, matching M7.4B lock order.
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
    and invoice_credit_adjustments.status in ('preview', 'blocked');
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
      and invoice_credit_adjustments.status in ('preview', 'blocked');
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
      and invoice_credit_adjustments.status in ('preview', 'blocked')
    limit 1;
    if existing.id is not null then
      return app_private.credit_adjustment_payload(existing.id);
    end if;
    raise;
end;
$$;

create or replace function public.get_credit_adjustment(p_adjustment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  header public.invoice_credit_adjustments;
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
  return app_private.credit_adjustment_payload(header.id);
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
        'invoice_note_id', invoice_credit_adjustments.invoice_note_id,
        'shop_id', invoice_credit_adjustments.shop_id,
        'branch_id', invoice_credit_adjustments.branch_id,
        'credited_cases', invoice_credit_adjustments.credited_cases,
        'adjustment_total', invoice_credit_adjustments.adjustment_total,
        'tax_preview_state', invoice_credit_adjustments.tax_preview_state,
        'legal_issuance_blocked', true,
        'created_at', invoice_credit_adjustments.created_at
      ) as item
      from public.invoice_credit_adjustments
      where app_private.can_work_at_branch(invoice_credit_adjustments.branch_id)
        and (p_status is null or invoice_credit_adjustments.status = p_status)
        and (p_branch_id is null or invoice_credit_adjustments.branch_id = p_branch_id)
    ) listed
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.prepare_credit_adjustment(uuid, text, integer)
  from public, anon;
revoke all on function public.get_credit_adjustment(uuid)
  from public, anon;
revoke all on function public.list_credit_adjustments(text, uuid)
  from public, anon;
grant execute on function public.prepare_credit_adjustment(uuid, text, integer)
  to authenticated;
grant execute on function public.get_credit_adjustment(uuid)
  to authenticated;
grant execute on function public.list_credit_adjustments(text, uuid)
  to authenticated;

comment on function public.prepare_credit_adjustment(uuid, text, integer) is
  'Accounts preview of an internal credit adjustment from a verified delivery return. Never issues a GST credit note or writes stock.';
comment on function public.get_credit_adjustment(uuid) is
  'Read-only credit-adjustment preview. Accounts/admin with invoices.review only.';

notify pgrst, 'reload schema';
