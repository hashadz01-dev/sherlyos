-- M7.5B stages B2/B3: priced invoice-note drafts from posted DISPATCH.
-- Local-only. Does not finalize, issue GST, consume statutory numbers, or
-- post credit notes. Tax amount is forced to 0 until accountant rules exist.

-- ---------------------------------------------------------------------------
-- Permissions (review is separate from unused invoices.issue)
-- ---------------------------------------------------------------------------

insert into public.permissions (code, description)
values
  (
    'invoices.review',
    'Accounts review of a priced invoice-note draft. Does not issue a tax invoice.'
  )
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'invoices.review'
where roles.code in ('admin', 'accounts')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Draft numbering (explicitly not a tax invoice number)
-- ---------------------------------------------------------------------------

create sequence if not exists public.invoice_note_seq as bigint;

revoke all on sequence public.invoice_note_seq
  from public, anon, authenticated, service_role;

comment on sequence public.invoice_note_seq is
  'Internal invoice-note draft numbers only (IN-YYYYMMDD-######). Not a statutory tax invoice series.';

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table if not exists public.invoice_notes (
  id uuid primary key default gen_random_uuid(),
  note_number text not null,
  status text not null,
  version integer not null default 1,
  idempotency_key text not null,
  dispatch_id uuid not null references public.stock_dispatch_requests (id) on delete restrict,
  order_id uuid not null references public.orders (id) on delete restrict,
  shop_id uuid not null references public.shops (id) on delete restrict,
  branch_id uuid not null references public.branches (id) on delete restrict,
  as_of_date date not null,
  dispatch_confirmed_at timestamptz not null,
  currency_code text not null default 'INR',
  billed_cases integer not null,
  billed_quantity numeric(14, 4) not null,
  subtotal_amount numeric(14, 2) not null,
  tax_amount numeric(14, 2) not null default 0,
  grand_total numeric(14, 2) not null,
  quantity_fingerprint text not null,
  price_fingerprint text not null,
  remarks text,
  submitted_at timestamptz,
  submitted_by uuid references public.profiles (id) on delete restrict,
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles (id) on delete restrict,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  created_by uuid not null references public.profiles (id) on delete restrict,
  updated_at timestamptz not null default pg_catalog.now(),
  constraint invoice_notes_number_key unique (note_number),
  constraint invoice_notes_status_check check (
    status in ('draft', 'submitted', 'reviewed', 'cancelled')
  ),
  constraint invoice_notes_version_check check (version >= 1),
  constraint invoice_notes_currency_inr check (currency_code = 'INR'),
  constraint invoice_notes_qty_check check (
    billed_cases > 0 and billed_quantity > 0
  ),
  constraint invoice_notes_amount_check check (
    subtotal_amount > 0
    and tax_amount = 0
    and grand_total = subtotal_amount
  ),
  constraint invoice_notes_remarks_length check (
    remarks is null
    or (
      char_length(btrim(remarks)) between 1 and 500
      and remarks = btrim(remarks)
    )
  )
);

create unique index if not exists invoice_notes_open_dispatch_uidx
  on public.invoice_notes (dispatch_id)
  where status in ('draft', 'submitted', 'reviewed');

create unique index if not exists invoice_notes_open_idempotency_uidx
  on public.invoice_notes (idempotency_key)
  where status <> 'cancelled';

create index if not exists invoice_notes_branch_status_idx
  on public.invoice_notes (branch_id, status, created_at desc);

create table if not exists public.invoice_note_lines (
  id uuid primary key default gen_random_uuid(),
  invoice_note_id uuid not null
    references public.invoice_notes (id) on delete restrict,
  line_no integer not null,
  order_line_id uuid not null references public.order_lines (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  lot_id uuid not null references public.stock_lots (id) on delete restrict,
  crate_id uuid not null references public.crates (id) on delete restrict,
  product_sku text not null,
  product_name text not null,
  shipped_cases integer not null,
  billing_unit text not null,
  billed_units_per_case numeric(12, 4) not null,
  billed_quantity numeric(14, 4) not null,
  unit_amount numeric(14, 4) not null,
  line_amount numeric(14, 2) not null,
  price_id uuid not null references public.product_selling_prices (id) on delete restrict,
  price_scope text not null,
  price_effective_from date not null,
  price_effective_to date,
  constraint invoice_note_lines_line_key unique (invoice_note_id, line_no),
  constraint invoice_note_lines_grain_key unique (
    invoice_note_id, order_line_id, lot_id, crate_id
  ),
  constraint invoice_note_lines_qty_check check (
    line_no >= 1
    and shipped_cases > 0
    and billed_units_per_case > 0
    and billed_quantity > 0
    and unit_amount > 0
    and line_amount > 0
  ),
  constraint invoice_note_lines_scope_check check (
    price_scope in ('shop', 'default')
  )
);

create table if not exists public.invoice_note_events (
  id uuid primary key default gen_random_uuid(),
  invoice_note_id uuid not null
    references public.invoice_notes (id) on delete restrict,
  event_type text not null,
  actor_id uuid not null references public.profiles (id) on delete restrict,
  from_status text,
  to_status text not null,
  note_version integer not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint invoice_note_events_type_check check (
    event_type in ('prepared', 'submitted', 'reviewed', 'cancelled')
  )
);

create index if not exists invoice_note_lines_note_idx
  on public.invoice_note_lines (invoice_note_id, line_no);

create index if not exists invoice_note_events_note_idx
  on public.invoice_note_events (invoice_note_id, created_at);

create trigger invoice_notes_set_updated_at
  before update on public.invoice_notes
  for each row execute function app_private.set_updated_at();

comment on table public.invoice_notes is
  'Priced invoice-note drafts. Not tax invoices. Unique open note per posted dispatch. GST is blocked.';
comment on table public.invoice_note_lines is
  'Frozen billed quantity and INR unit price snapshots from DISPATCH consume grains.';
comment on table public.invoice_note_events is
  'Append-only invoice-note history. Client writes are rejected.';

-- ---------------------------------------------------------------------------
-- Writer GUC + immutability
-- ---------------------------------------------------------------------------

create or replace function app_private.guard_invoice_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform app_private.assert_invoice_write();
  if tg_table_name = 'invoice_note_events' and tg_op <> 'INSERT' then
    raise exception 'invoice-note events cannot be changed' using errcode = '42501';
  end if;
  if tg_table_name = 'invoice_note_lines' and tg_op = 'DELETE' then
    raise exception 'invoice-note lines cannot be deleted' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function app_private.guard_invoice_write()
  from public, anon, authenticated, service_role;

drop trigger if exists invoice_notes_guard_write on public.invoice_notes;
create trigger invoice_notes_guard_write
  before insert or update or delete on public.invoice_notes
  for each row execute function app_private.guard_invoice_write();

drop trigger if exists invoice_note_lines_guard_write on public.invoice_note_lines;
create trigger invoice_note_lines_guard_write
  before insert or update or delete on public.invoice_note_lines
  for each row execute function app_private.guard_invoice_write();

drop trigger if exists invoice_note_events_guard_write on public.invoice_note_events;
create trigger invoice_note_events_guard_write
  before insert or update or delete on public.invoice_note_events
  for each row execute function app_private.guard_invoice_write();

create or replace function app_private.assign_invoice_note_number()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' and new.note_number is null then
    new.note_number := 'IN-'
      || to_char(pg_catalog.clock_timestamp() at time zone 'utc', 'YYYYMMDD')
      || '-'
      || pg_catalog.lpad(pg_catalog.nextval('public.invoice_note_seq')::text, 6, '0');
  end if;
  if tg_op = 'UPDATE' and new.note_number is distinct from old.note_number then
    raise exception 'invoice-note number is immutable' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and new.dispatch_id is distinct from old.dispatch_id then
    raise exception 'invoice-note dispatch is immutable' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and new.idempotency_key is distinct from old.idempotency_key then
    raise exception 'idempotency key is immutable' using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function app_private.assign_invoice_note_number()
  from public, anon, authenticated, service_role;

drop trigger if exists invoice_notes_assign_number on public.invoice_notes;
create trigger invoice_notes_assign_number
  before insert or update on public.invoice_notes
  for each row execute function app_private.assign_invoice_note_number();

-- ---------------------------------------------------------------------------
-- Access + statutory gate
-- ---------------------------------------------------------------------------

create or replace function app_private.can_view_invoice_note()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    app_private.has_permission('invoice_notes.prepare')
    or app_private.has_permission('invoices.review')
    or app_private.has_permission('operations.monitor');
$$;

revoke all on function app_private.can_view_invoice_note()
  from public, anon;
grant execute on function app_private.can_view_invoice_note() to authenticated;

create or replace function public.assess_invoice_finalization_readiness()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  identity jsonb;
  blockers jsonb := '[]'::jsonb;
begin
  if not app_private.can_view_invoice_note() then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  identity := app_private.read_company_print_identity();

  -- Identity is necessary later but never sufficient. Accountant tax rules
  -- are still missing, so ready stays false even when legal_name is set.
  if coalesce(identity ->> 'ready', 'false') is distinct from 'true' then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'company_identity_unverified',
      'message', 'Verified statutory company identity is not configured.'
    ));
  else
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'company_identity_unverified_for_gst',
      'message', 'Print identity exists but GST issuance identity is not accountant-verified.'
    ));
  end if;

  blockers := blockers || jsonb_build_array(
    jsonb_build_object(
      'code', 'tax_inclusive_exclusive_unapproved',
      'message', 'Tax-inclusive versus exclusive treatment is pending accountant approval (I3).'
    ),
    jsonb_build_object(
      'code', 'gst_rate_hsn_unapproved',
      'message', 'GST rates and HSN treatment are pending accountant approval (I11).'
    ),
    jsonb_build_object(
      'code', 'fy_numbering_unapproved',
      'message', 'Financial-year invoice numbering is pending accountant approval (I7).'
    ),
    jsonb_build_object(
      'code', 'invoice_date_rule_unapproved',
      'message', 'Invoice date versus dispatch date rule is pending accountant approval (I10).'
    ),
    jsonb_build_object(
      'code', 'finalize_rpc_disabled',
      'message', 'No invoice finalization or statutory number consume RPC exists in this phase.'
    )
  );

  return jsonb_build_object(
    'ready', false,
    'legal_issuance_blocked', true,
    'currency_code', 'INR',
    'blockers', blockers
  );
end;
$$;

create or replace function app_private.amount_in_words_inr(amount numeric)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  rupees bigint;
  paise integer;
  words text;
begin
  if amount is null or amount < 0 then
    raise exception 'amount in words requires a non-negative INR amount'
      using errcode = '23514';
  end if;

  rupees := trunc(amount);
  paise := round((amount - rupees) * 100);

  words := 'RUPEES ' || rupees::text;
  if paise > 0 then
    words := words || ' AND ' || paise::text || ' PAISE';
  end if;
  return words || ' ONLY';
end;
$$;

revoke all on function app_private.amount_in_words_inr(numeric)
  from public, anon, authenticated, service_role;

create or replace function app_private.invoice_numeric_token(value numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  -- Stable token so 12 and 12.0000 cannot split a review fingerprint.
  select to_char(value, 'FM999999999990.0000');
$$;

revoke all on function app_private.invoice_numeric_token(numeric)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_invoice_fingerprints(
  header public.stock_dispatch_requests,
  shop uuid,
  as_of date,
  expected_quantity text,
  expected_price text
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  live_quantity text;
  live_price text;
begin
  select
    md5(string_agg(
      grain.order_line_id::text || '|' ||
      grain.product_id::text || '|' ||
      grain.lot_id::text || '|' ||
      grain.source_crate_id::text || '|' ||
      grain.dispatched_cases::text,
      ',' order by grain.order_line_id, grain.lot_id, grain.source_crate_id
    ))
  into live_quantity
  from app_private.dispatch_return_source_grains(header) grain;

  select
    md5(string_agg(
      grain.order_line_id::text || '|' ||
      grain.product_id::text || '|' ||
      grain.lot_id::text || '|' ||
      grain.source_crate_id::text || '|' ||
      grain.dispatched_cases::text || '|' ||
      app_private.invoice_numeric_token(products.billed_units_per_case) || '|' ||
      resolved.price_id::text || '|' ||
      app_private.invoice_numeric_token(resolved.unit_amount),
      ',' order by grain.order_line_id, grain.lot_id, grain.source_crate_id
    ))
  into live_price
  from app_private.dispatch_return_source_grains(header) grain
  join public.products on products.id = grain.product_id
  join lateral app_private.resolve_selling_price(
    grain.product_id,
    shop,
    as_of
  ) resolved on true;

  if live_quantity is distinct from expected_quantity
    or live_price is distinct from expected_price
  then
    raise exception 'invoice-note prices or billed quantities no longer match the dispatch'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.assert_invoice_fingerprints(
  public.stock_dispatch_requests, uuid, date, text, text
) from public, anon, authenticated, service_role;

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

revoke all on function app_private.invoice_note_payload(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.lock_invoice_note_for_update(
  target uuid,
  expected_version integer
)
returns public.invoice_notes
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.invoice_notes;
begin
  select * into header
  from public.invoice_notes
  where invoice_notes.id = target
  for update;

  if not found then
    raise exception 'invoice note not found' using errcode = 'P0002';
  end if;
  if header.version is distinct from expected_version then
    raise exception 'invoice note was changed by someone else' using errcode = 'PT409';
  end if;
  if not app_private.can_work_at_branch(header.branch_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  perform app_private.assert_operational_active_branch(header.branch_id);
  return header;
end;
$$;

revoke all on function app_private.lock_invoice_note_for_update(uuid, integer)
  from public, anon, authenticated, service_role;

create or replace function app_private.append_invoice_note_event(
  header public.invoice_notes,
  event_name text,
  from_status text,
  to_status text,
  extra jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.invoice_note_events (
    invoice_note_id,
    event_type,
    actor_id,
    from_status,
    to_status,
    note_version,
    payload
  )
  values (
    header.id,
    event_name,
    auth.uid(),
    from_status,
    to_status,
    header.version,
    coalesce(extra, '{}'::jsonb)
  );
end;
$$;

revoke all on function app_private.append_invoice_note_event(
  public.invoice_notes, text, text, text, jsonb
) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Prepare from posted DISPATCH consume quantity
-- ---------------------------------------------------------------------------

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

  -- Lock order: dispatch → order → existing notes → products/prices.
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

create or replace function public.submit_invoice_note(
  p_invoice_note_id uuid,
  p_expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.invoice_notes;
begin
  perform app_private.assert_permission('invoice_notes.prepare');
  perform set_config('app.invoice_write', 'on', true);

  header := app_private.lock_invoice_note_for_update(p_invoice_note_id, p_expected_version);
  if header.status is distinct from 'draft' then
    raise exception 'only draft invoice notes can be submitted' using errcode = '23514';
  end if;

  update public.invoice_notes
  set
    status = 'submitted',
    version = header.version + 1,
    submitted_at = clock_timestamp(),
    submitted_by = auth.uid()
  where invoice_notes.id = header.id
  returning * into header;

  perform app_private.append_invoice_note_event(
    header, 'submitted', 'draft', 'submitted', '{}'::jsonb
  );
  perform app_private.write_audit(
    auth.uid(), 'submit_invoice_note', 'invoice_notes', header.id,
    jsonb_build_object('note_number', header.note_number)
  );

  return app_private.invoice_note_payload(header.id);
end;
$$;

create or replace function public.review_invoice_note(
  p_invoice_note_id uuid,
  p_expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.invoice_notes;
  dispatch public.stock_dispatch_requests;
begin
  perform app_private.assert_permission('invoices.review');
  perform set_config('app.invoice_write', 'on', true);

  header := app_private.lock_invoice_note_for_update(p_invoice_note_id, p_expected_version);
  if header.status is distinct from 'submitted' then
    raise exception 'only submitted invoice notes can be reviewed' using errcode = '23514';
  end if;

  select * into dispatch
  from public.stock_dispatch_requests
  where stock_dispatch_requests.id = header.dispatch_id
  for update;

  perform app_private.assert_return_grains_match_ledger(dispatch);
  perform app_private.assert_invoice_fingerprints(
    dispatch,
    header.shop_id,
    header.as_of_date,
    header.quantity_fingerprint,
    header.price_fingerprint
  );

  update public.invoice_notes
  set
    status = 'reviewed',
    version = header.version + 1,
    reviewed_at = clock_timestamp(),
    reviewed_by = auth.uid()
  where invoice_notes.id = header.id
  returning * into header;

  perform app_private.append_invoice_note_event(
    header, 'reviewed', 'submitted', 'reviewed', '{}'::jsonb
  );
  perform app_private.write_audit(
    auth.uid(), 'review_invoice_note', 'invoice_notes', header.id,
    jsonb_build_object('note_number', header.note_number)
  );

  return app_private.invoice_note_payload(header.id);
end;
$$;

create or replace function public.cancel_invoice_note(
  p_invoice_note_id uuid,
  p_expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.invoice_notes;
  previous_status text;
  actor_can_prepare boolean;
  actor_can_review boolean;
begin
  actor_can_prepare := app_private.has_permission('invoice_notes.prepare');
  actor_can_review := app_private.has_permission('invoices.review');
  if not (actor_can_prepare or actor_can_review) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  perform set_config('app.invoice_write', 'on', true);

  header := app_private.lock_invoice_note_for_update(p_invoice_note_id, p_expected_version);
  previous_status := header.status;

  if previous_status = 'cancelled' then
    raise exception 'invoice note is already cancelled' using errcode = '23514';
  end if;
  if previous_status = 'draft' and not actor_can_prepare then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if previous_status = 'reviewed' and not actor_can_review then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  update public.invoice_notes
  set
    status = 'cancelled',
    version = header.version + 1,
    cancelled_at = clock_timestamp(),
    cancelled_by = auth.uid()
  where invoice_notes.id = header.id
  returning * into header;

  perform app_private.append_invoice_note_event(
    header, 'cancelled', previous_status, 'cancelled', '{}'::jsonb
  );
  perform app_private.write_audit(
    auth.uid(), 'cancel_invoice_note', 'invoice_notes', header.id,
    jsonb_build_object('note_number', header.note_number)
  );

  return app_private.invoice_note_payload(header.id);
end;
$$;

create or replace function public.get_invoice_note(p_invoice_note_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  header public.invoice_notes;
begin
  if not app_private.can_view_invoice_note() then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  select * into header from public.invoice_notes where invoice_notes.id = p_invoice_note_id;
  if not found then
    raise exception 'invoice note not found' using errcode = 'P0002';
  end if;
  if not app_private.can_work_at_branch(header.branch_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  return app_private.invoice_note_payload(header.id);
end;
$$;

create or replace function public.list_invoice_notes(
  p_status text default null,
  p_branch_id uuid default null,
  p_shop_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app_private.can_view_invoice_note() then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_status is not null
    and p_status not in ('draft', 'submitted', 'reviewed', 'cancelled')
  then
    raise exception 'invoice-note status is not valid' using errcode = '23514';
  end if;

  return coalesce(
    (
      select jsonb_agg(item order by item ->> 'created_at' desc)
      from (
        select jsonb_build_object(
          'id', invoice_notes.id,
          'note_number', invoice_notes.note_number,
          'status', invoice_notes.status,
          'version', invoice_notes.version,
          'dispatch_id', invoice_notes.dispatch_id,
          'order_id', invoice_notes.order_id,
          'shop_id', invoice_notes.shop_id,
          'shop_name', shops.name,
          'branch_id', invoice_notes.branch_id,
          'billed_cases', invoice_notes.billed_cases,
          'grand_total', invoice_notes.grand_total,
          'currency_code', invoice_notes.currency_code,
          'watermark', 'DRAFT INVOICE NOTE — NOT A TAX INVOICE',
          'legal_issuance_blocked', true,
          'created_at', invoice_notes.created_at
        ) as item
        from public.invoice_notes
        join public.shops on shops.id = invoice_notes.shop_id
        where app_private.can_work_at_branch(invoice_notes.branch_id)
          and (p_status is null or invoice_notes.status = p_status)
          and (p_branch_id is null or invoice_notes.branch_id = p_branch_id)
          and (p_shop_id is null or invoice_notes.shop_id = p_shop_id)
        order by invoice_notes.created_at desc
        limit 100
      ) listed
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.get_invoice_note_preview(
  p_invoice_note_id uuid,
  p_copy text default 'accounts'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  copy_label text;
  payload jsonb;
begin
  if p_copy not in ('recipient', 'transporter', 'accounts') then
    raise exception 'invoice copy must be recipient, transporter, or accounts'
      using errcode = '23514';
  end if;

  payload := public.get_invoice_note(p_invoice_note_id);
  copy_label := case p_copy
    when 'recipient' then 'RECIPIENT COPY'
    when 'transporter' then 'TRANSPORTER / DRIVER COPY'
    else 'ACCOUNTS COPY'
  end;

  return payload || jsonb_build_object(
    'copy', p_copy,
    'copy_label', copy_label,
    'watermark', 'DRAFT INVOICE NOTE — NOT A TAX INVOICE',
    'legal_seal_caption', 'NO LEGAL SEAL — DRAFT ONLY',
    'signature_block', jsonb_build_object(
      'shown', false,
      'reason', 'Signature and seal appear only on a finalized tax invoice (I9).'
    )
  );
end;
$$;

create or replace function public.list_invoice_eligible_dispatches()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('invoice_notes.prepare');

  return coalesce(
    (
      select jsonb_agg(item order by item ->> 'dispatched_at' desc)
      from (
        select jsonb_build_object(
          'dispatch_id', stock_dispatch_requests.id,
          'dispatch_number', stock_dispatch_requests.request_number,
          'order_id', stock_dispatch_requests.order_id,
          'order_number', orders.order_number,
          'shop_id', orders.shop_id,
          'shop_name', shops.name,
          'branch_id', stock_dispatch_requests.branch_id,
          'status', stock_dispatch_requests.status,
          'dispatched_at', stock_dispatch_requests.dispatched_at
        ) as item
        from public.stock_dispatch_requests
        join public.orders on orders.id = stock_dispatch_requests.order_id
        join public.shops on shops.id = orders.shop_id
        where stock_dispatch_requests.stock_consumed
          and stock_dispatch_requests.posted_transaction_id is not null
          and stock_dispatch_requests.status in (
            'dispatched', 'in_transit', 'delivered', 'exception'
          )
          and app_private.can_work_at_branch(stock_dispatch_requests.branch_id)
          and not exists (
            select 1
            from public.invoice_notes
            where invoice_notes.dispatch_id = stock_dispatch_requests.id
              and invoice_notes.status in ('draft', 'submitted', 'reviewed')
          )
        order by stock_dispatch_requests.dispatched_at desc
        limit 100
      ) listed
    ),
    '[]'::jsonb
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- RLS + grants
-- ---------------------------------------------------------------------------

alter table public.invoice_notes enable row level security;
alter table public.invoice_notes force row level security;
alter table public.invoice_note_lines enable row level security;
alter table public.invoice_note_lines force row level security;
alter table public.invoice_note_events enable row level security;
alter table public.invoice_note_events force row level security;

create policy invoice_notes_select_authorized
  on public.invoice_notes
  for select
  to authenticated
  using (
    (select app_private.can_view_invoice_note())
    and (select app_private.can_work_at_branch(invoice_notes.branch_id))
  );

create policy invoice_note_lines_select_authorized
  on public.invoice_note_lines
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.invoice_notes header
      where header.id = invoice_note_lines.invoice_note_id
    )
  );

create policy invoice_note_events_select_authorized
  on public.invoice_note_events
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.invoice_notes header
      where header.id = invoice_note_events.invoice_note_id
    )
  );

revoke all on table public.invoice_notes
  from public, anon, authenticated, service_role;
revoke all on table public.invoice_note_lines
  from public, anon, authenticated, service_role;
revoke all on table public.invoice_note_events
  from public, anon, authenticated, service_role;

grant select on table public.invoice_notes to authenticated;
grant select on table public.invoice_note_lines to authenticated;
grant select on table public.invoice_note_events to authenticated;

revoke all on function public.assess_invoice_finalization_readiness()
  from public, anon;
revoke all on function public.prepare_invoice_note(uuid, text, integer, text)
  from public, anon;
revoke all on function public.submit_invoice_note(uuid, integer)
  from public, anon;
revoke all on function public.review_invoice_note(uuid, integer)
  from public, anon;
revoke all on function public.cancel_invoice_note(uuid, integer)
  from public, anon;
revoke all on function public.get_invoice_note(uuid)
  from public, anon;
revoke all on function public.list_invoice_notes(text, uuid, uuid)
  from public, anon;
revoke all on function public.get_invoice_note_preview(uuid, text)
  from public, anon;
revoke all on function public.list_invoice_eligible_dispatches()
  from public, anon;

grant execute on function public.assess_invoice_finalization_readiness() to authenticated;
grant execute on function public.prepare_invoice_note(uuid, text, integer, text) to authenticated;
grant execute on function public.submit_invoice_note(uuid, integer) to authenticated;
grant execute on function public.review_invoice_note(uuid, integer) to authenticated;
grant execute on function public.cancel_invoice_note(uuid, integer) to authenticated;
grant execute on function public.get_invoice_note(uuid) to authenticated;
grant execute on function public.list_invoice_notes(text, uuid, uuid) to authenticated;
grant execute on function public.get_invoice_note_preview(uuid, text) to authenticated;
grant execute on function public.list_invoice_eligible_dispatches() to authenticated;

comment on function public.assess_invoice_finalization_readiness() is
  'Always reports not-ready. Accountant GST, numbering, and date rules are still pending.';
comment on function public.prepare_invoice_note(uuid, text, integer, text) is
  'Create a priced invoice-note draft from posted DISPATCH consume quantity. Not a tax invoice.';
comment on function public.submit_invoice_note(uuid, integer) is
  'GM submits a draft for Accounts review. Does not issue GST.';
comment on function public.review_invoice_note(uuid, integer) is
  'Accounts review. Re-resolves prices as-of dispatch and fails closed on fingerprint mismatch.';
comment on function public.cancel_invoice_note(uuid, integer) is
  'Cancel a draft so a replacement can be prepared. Does not post a credit note.';
comment on function public.get_invoice_note_preview(uuid, text) is
  'Draft print preview with DRAFT watermark and no legal seal. Two-copy labels only.';
