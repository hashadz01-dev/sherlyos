-- M7.5D.2 statutory invoice finalization foundation.
-- Schema and read-only eligibility only. Legal issuance stays disabled.
-- Does not allocate production invoice numbers, issue tax invoices, or write stock.

create extension if not exists btree_gist with schema extensions;

-- ---------------------------------------------------------------------------
-- Writer GUCs. Application roles never receive these.
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_statutory_invoice_write()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if current_setting('app.statutory_invoice_write', true) is distinct from 'on' then
    raise exception 'statutory invoice foundation can only change through approved procedures'
      using errcode = '42501';
  end if;
end;
$$;

create or replace function app_private.assert_invoice_numbering_write()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if current_setting('app.invoice_numbering_write', true) is distinct from 'on' then
    raise exception 'invoice numbering configuration can only change through approved procedures'
      using errcode = '42501';
  end if;
end;
$$;

create or replace function app_private.assert_invoice_number_proof()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if current_setting('app.invoice_number_proof', true) is distinct from 'on' then
    raise exception 'synthetic invoice-number proof is not enabled'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_statutory_invoice_write()
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_invoice_numbering_write()
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_invoice_number_proof()
  from public, anon, authenticated, service_role;

create or replace function app_private.guard_statutory_invoice_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform app_private.assert_statutory_invoice_write();
  if tg_op = 'DELETE' then
    raise exception 'statutory invoice history cannot be deleted' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' then
    if tg_table_name = 'statutory_invoice_events' then
      raise exception 'statutory invoice events cannot be changed' using errcode = '42501';
    end if;
    if tg_table_name in (
      'statutory_invoices',
      'statutory_invoice_lines',
      'statutory_invoice_tax_components'
    ) then
      raise exception 'statutory invoice financial snapshots are immutable'
        using errcode = '42501';
    end if;
  end if;
  return coalesce(new, old);
end;
$$;

create or replace function app_private.guard_invoice_numbering_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_name = 'invoice_number_allocations' then
    if current_setting('app.invoice_number_proof', true) is distinct from 'on'
      and current_setting('app.invoice_numbering_write', true) is distinct from 'on'
    then
      raise exception 'invoice number allocations are not writable'
        using errcode = '42501';
    end if;
  elsif tg_table_name = 'invoice_number_series'
    and tg_op = 'UPDATE'
    and current_setting('app.invoice_number_proof', true) = 'on'
  then
    -- Proof allocator may only advance the synthetic counter inside the same txn.
    if new.prefix is distinct from old.prefix
      or new.is_synthetic is distinct from old.is_synthetic
      or new.legal_allocation_enabled is distinct from old.legal_allocation_enabled
      or new.financial_year_id is distinct from old.financial_year_id
    then
      raise exception 'synthetic proof cannot rewrite series identity'
        using errcode = '42501';
    end if;
  else
    perform app_private.assert_invoice_numbering_write();
  end if;
  if tg_op = 'DELETE' and tg_table_name <> 'invoice_number_allocations' then
    raise exception 'invoice numbering configuration cannot be deleted'
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function app_private.guard_statutory_invoice_write()
  from public, anon, authenticated, service_role;
revoke all on function app_private.guard_invoice_numbering_write()
  from public, anon, authenticated, service_role;

create or replace function app_private.invoice_blocker(p_code text, p_message text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('code', p_code, 'message', p_message);
$$;

revoke all on function app_private.invoice_blocker(text, text)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Financial-year numbering configuration. Legal allocation is hard-false.
-- ---------------------------------------------------------------------------

create table if not exists public.invoice_financial_years (
  id uuid primary key default gen_random_uuid(),
  ownership_code text not null,
  code text not null,
  label text not null,
  starts_on date not null,
  ends_on date not null,
  status text not null,
  legal_allocation_enabled boolean not null default false,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  created_by uuid not null references public.profiles (id) on delete restrict,
  updated_at timestamptz not null default pg_catalog.now(),
  constraint invoice_financial_years_code_key unique (ownership_code, code),
  constraint invoice_financial_years_status_check check (
    status in ('draft', 'verified', 'superseded', 'cancelled')
  ),
  constraint invoice_financial_years_window check (ends_on >= starts_on),
  constraint invoice_financial_years_legal_off check (
    legal_allocation_enabled = false
  ),
  constraint invoice_financial_years_code_shape check (
    char_length(btrim(code)) between 2 and 20
    and code = btrim(code)
  )
);

alter table public.invoice_financial_years
  add constraint invoice_financial_years_verified_window_excl
  exclude using gist (
    ownership_code with =,
    app_private.selling_price_window(starts_on, ends_on) with &&
  )
  where (status = 'verified');

create table if not exists public.invoice_number_series (
  id uuid primary key default gen_random_uuid(),
  financial_year_id uuid not null
    references public.invoice_financial_years (id) on delete restrict,
  series_code text not null,
  prefix text not null,
  pad_width integer not null default 5,
  next_number bigint not null default 1,
  last_allocated_number bigint,
  uniqueness_scope text not null default 'ownership_year_series',
  is_synthetic boolean not null default false,
  legal_allocation_enabled boolean not null default false,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  created_by uuid not null references public.profiles (id) on delete restrict,
  updated_at timestamptz not null default pg_catalog.now(),
  constraint invoice_number_series_key unique (financial_year_id, series_code),
  constraint invoice_number_series_scope_check check (
    uniqueness_scope = 'ownership_year_series'
  ),
  constraint invoice_number_series_pad_check check (pad_width between 1 and 10),
  constraint invoice_number_series_next_check check (next_number >= 1),
  constraint invoice_number_series_legal_off check (
    legal_allocation_enabled = false
  ),
  constraint invoice_number_series_synthetic_prefix check (
    is_synthetic = false
    or prefix like 'PROOF-%'
  )
);

create table if not exists public.invoice_number_allocations (
  id uuid primary key default gen_random_uuid(),
  series_id uuid not null
    references public.invoice_number_series (id) on delete restrict,
  allocated_number bigint not null,
  formatted_number text not null,
  is_legal boolean not null default false,
  is_consumed boolean not null default false,
  proof_only boolean not null default true,
  allocated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint invoice_number_allocations_series_number_key
    unique (series_id, allocated_number),
  constraint invoice_number_allocations_formatted_key unique (formatted_number),
  constraint invoice_number_allocations_legal_off check (is_legal = false),
  constraint invoice_number_allocations_proof_only check (proof_only = true),
  constraint invoice_number_allocations_not_consumed check (is_consumed = false),
  constraint invoice_number_allocations_proof_shape check (
    formatted_number like 'PROOF-%'
  )
);

create index if not exists invoice_number_allocations_series_idx
  on public.invoice_number_allocations (series_id, allocated_number);

-- ---------------------------------------------------------------------------
-- Future statutory invoice record. Status cannot become issued in this phase.
-- ---------------------------------------------------------------------------

create table if not exists public.statutory_invoices (
  id uuid primary key default gen_random_uuid(),
  invoice_note_id uuid not null
    references public.invoice_notes (id) on delete restrict,
  tax_preview_id uuid not null
    references public.invoice_tax_previews (id) on delete restrict,
  invoice_note_version integer not null,
  dispatch_id uuid not null,
  quantity_fingerprint text not null,
  price_fingerprint text not null,
  tax_input_fingerprint text not null,
  seller_identity_id uuid,
  seller_snapshot jsonb not null default '{}'::jsonb,
  customer_identity_id uuid,
  customer_snapshot jsonb not null default '{}'::jsonb,
  financial_year_id uuid
    references public.invoice_financial_years (id) on delete restrict,
  number_allocation_id uuid
    references public.invoice_number_allocations (id) on delete restrict,
  formatted_number text,
  status text not null,
  issued_at timestamptz,
  legal_invoice_number text,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  created_by uuid not null references public.profiles (id) on delete restrict,
  constraint statutory_invoices_note_key unique (invoice_note_id),
  constraint statutory_invoices_status_check check (
    status in ('foundation_reserved', 'blocked')
  ),
  constraint statutory_invoices_not_issued check (
    issued_at is null
    and legal_invoice_number is null
    and (
      formatted_number is null
      or formatted_number like 'PROOF-%'
    )
  ),
  constraint statutory_invoices_version_check check (invoice_note_version >= 1)
);

create table if not exists public.statutory_invoice_lines (
  id uuid primary key default gen_random_uuid(),
  statutory_invoice_id uuid not null
    references public.statutory_invoices (id) on delete restrict,
  invoice_note_line_id uuid not null
    references public.invoice_note_lines (id) on delete restrict,
  line_no integer not null,
  product_id uuid not null,
  product_sku text not null,
  product_name text not null,
  shipped_cases integer not null,
  billed_quantity numeric(14, 4) not null,
  billing_unit text not null,
  unit_amount numeric(14, 4) not null,
  line_amount numeric(14, 2) not null,
  hsn_sac_code text,
  taxable_value numeric(14, 2) not null default 0,
  tax_amount numeric(14, 2) not null default 0,
  line_total numeric(14, 2) not null,
  constraint statutory_invoice_lines_key unique (statutory_invoice_id, line_no),
  constraint statutory_invoice_lines_qty_check check (
    line_no >= 1
    and shipped_cases > 0
    and billed_quantity > 0
    and unit_amount > 0
    and line_amount > 0
  )
);

create table if not exists public.statutory_invoice_tax_components (
  id uuid primary key default gen_random_uuid(),
  statutory_invoice_id uuid not null
    references public.statutory_invoices (id) on delete restrict,
  statutory_invoice_line_id uuid not null
    references public.statutory_invoice_lines (id) on delete restrict,
  component_code text not null,
  rate numeric(5, 2) not null,
  amount numeric(14, 2) not null,
  constraint statutory_invoice_tax_components_key unique (
    statutory_invoice_line_id, component_code
  ),
  constraint statutory_invoice_tax_components_code_check check (
    component_code in ('cgst', 'sgst', 'igst')
  )
);

create table if not exists public.statutory_invoice_events (
  id uuid primary key default gen_random_uuid(),
  statutory_invoice_id uuid not null
    references public.statutory_invoices (id) on delete restrict,
  event_type text not null,
  actor_id uuid not null references public.profiles (id) on delete restrict,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint statutory_invoice_events_type_check check (
    event_type in (
      'foundation_reserved',
      'eligibility_assessed',
      'issuance_blocked',
      'cancellation_blocked'
    )
  )
);

create table if not exists public.statutory_invoice_cancellations (
  id uuid primary key default gen_random_uuid(),
  statutory_invoice_id uuid not null
    references public.statutory_invoices (id) on delete restrict,
  reason text not null,
  status text not null,
  credit_note_id uuid,
  actor_id uuid not null references public.profiles (id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint statutory_invoice_cancellations_status_check check (
    status = 'blocked_intent'
  ),
  constraint statutory_invoice_cancellations_no_credit check (
    credit_note_id is null
  ),
  constraint statutory_invoice_cancellations_reason_length check (
    char_length(btrim(reason)) between 1 and 500
    and reason = btrim(reason)
  )
);

create index if not exists statutory_invoice_lines_header_idx
  on public.statutory_invoice_lines (statutory_invoice_id, line_no);
create index if not exists statutory_invoice_events_header_idx
  on public.statutory_invoice_events (statutory_invoice_id, created_at);

comment on table public.invoice_financial_years is
  'Configurable financial-year windows. legal_allocation_enabled is hard-false until a later owner-approved issuance phase.';
comment on table public.invoice_number_series is
  'Invoice series configuration. Production consume is disabled. Synthetic PROOF- series exist only for concurrency proofs.';
comment on table public.invoice_number_allocations is
  'Synthetic proof allocations only. is_legal and is_consumed stay false. Formatted values must start with PROOF-.';
comment on table public.statutory_invoices is
  'Future statutory invoice header. Cannot be issued, numbered legally, or used as a tax invoice in this phase.';
comment on table public.statutory_invoice_cancellations is
  'Cancellation intent foundation. Completed cancellation and credit-note posting are blocked.';

create trigger invoice_financial_years_set_updated_at
  before update on public.invoice_financial_years
  for each row execute function app_private.set_updated_at();
create trigger invoice_number_series_set_updated_at
  before update on public.invoice_number_series
  for each row execute function app_private.set_updated_at();

create trigger invoice_financial_years_guard
  before insert or update or delete on public.invoice_financial_years
  for each row execute function app_private.guard_invoice_numbering_write();
create trigger invoice_number_series_guard
  before insert or update or delete on public.invoice_number_series
  for each row execute function app_private.guard_invoice_numbering_write();
create trigger invoice_number_allocations_guard
  before insert or update or delete on public.invoice_number_allocations
  for each row execute function app_private.guard_invoice_numbering_write();

create trigger statutory_invoices_guard
  before insert or update or delete on public.statutory_invoices
  for each row execute function app_private.guard_statutory_invoice_write();
create trigger statutory_invoice_lines_guard
  before insert or update or delete on public.statutory_invoice_lines
  for each row execute function app_private.guard_statutory_invoice_write();
create trigger statutory_invoice_tax_components_guard
  before insert or update or delete on public.statutory_invoice_tax_components
  for each row execute function app_private.guard_statutory_invoice_write();
create trigger statutory_invoice_events_guard
  before insert or update or delete on public.statutory_invoice_events
  for each row execute function app_private.guard_statutory_invoice_write();
create trigger statutory_invoice_cancellations_guard
  before insert or update or delete on public.statutory_invoice_cancellations
  for each row execute function app_private.guard_statutory_invoice_write();

-- ---------------------------------------------------------------------------
-- FORCE RLS. Clients may SELECT diagnostic rows; all writes stay GUC-gated.
-- ---------------------------------------------------------------------------

alter table public.invoice_financial_years enable row level security;
alter table public.invoice_financial_years force row level security;
alter table public.invoice_number_series enable row level security;
alter table public.invoice_number_series force row level security;
alter table public.invoice_number_allocations enable row level security;
alter table public.invoice_number_allocations force row level security;
alter table public.statutory_invoices enable row level security;
alter table public.statutory_invoices force row level security;
alter table public.statutory_invoice_lines enable row level security;
alter table public.statutory_invoice_lines force row level security;
alter table public.statutory_invoice_tax_components enable row level security;
alter table public.statutory_invoice_tax_components force row level security;
alter table public.statutory_invoice_events enable row level security;
alter table public.statutory_invoice_events force row level security;
alter table public.statutory_invoice_cancellations enable row level security;
alter table public.statutory_invoice_cancellations force row level security;

create policy invoice_financial_years_select
  on public.invoice_financial_years for select to authenticated
  using (
    (select app_private.can_read_statutory_config())
    or (select app_private.can_view_invoice_note())
  );
create policy invoice_number_series_select
  on public.invoice_number_series for select to authenticated
  using (
    (select app_private.can_read_statutory_config())
    or (select app_private.can_view_invoice_note())
  );
create policy invoice_number_allocations_select
  on public.invoice_number_allocations for select to authenticated
  using (
    (select app_private.can_read_statutory_config())
    and invoice_number_allocations.proof_only
  );
create policy statutory_invoices_select
  on public.statutory_invoices for select to authenticated
  using (
    (select app_private.can_view_invoice_note())
    and exists (
      select 1
      from public.invoice_notes
      where invoice_notes.id = statutory_invoices.invoice_note_id
        and app_private.can_work_at_branch(invoice_notes.branch_id)
    )
  );
create policy statutory_invoice_lines_select
  on public.statutory_invoice_lines for select to authenticated
  using (
    exists (
      select 1
      from public.statutory_invoices
      join public.invoice_notes
        on invoice_notes.id = statutory_invoices.invoice_note_id
      where statutory_invoices.id = statutory_invoice_lines.statutory_invoice_id
        and app_private.can_view_invoice_note()
        and app_private.can_work_at_branch(invoice_notes.branch_id)
    )
  );
create policy statutory_invoice_tax_components_select
  on public.statutory_invoice_tax_components for select to authenticated
  using (
    exists (
      select 1
      from public.statutory_invoices
      join public.invoice_notes
        on invoice_notes.id = statutory_invoices.invoice_note_id
      where statutory_invoices.id = statutory_invoice_tax_components.statutory_invoice_id
        and app_private.can_view_invoice_note()
        and app_private.can_work_at_branch(invoice_notes.branch_id)
    )
  );
create policy statutory_invoice_events_select
  on public.statutory_invoice_events for select to authenticated
  using (
    exists (
      select 1
      from public.statutory_invoices
      join public.invoice_notes
        on invoice_notes.id = statutory_invoices.invoice_note_id
      where statutory_invoices.id = statutory_invoice_events.statutory_invoice_id
        and app_private.can_view_invoice_note()
        and app_private.can_work_at_branch(invoice_notes.branch_id)
    )
  );
create policy statutory_invoice_cancellations_select
  on public.statutory_invoice_cancellations for select to authenticated
  using (
    exists (
      select 1
      from public.statutory_invoices
      join public.invoice_notes
        on invoice_notes.id = statutory_invoices.invoice_note_id
      where statutory_invoices.id = statutory_invoice_cancellations.statutory_invoice_id
        and app_private.can_view_invoice_note()
        and app_private.can_work_at_branch(invoice_notes.branch_id)
    )
  );

revoke all on table public.invoice_financial_years
  from public, anon, authenticated, service_role;
revoke all on table public.invoice_number_series
  from public, anon, authenticated, service_role;
revoke all on table public.invoice_number_allocations
  from public, anon, authenticated, service_role;
revoke all on table public.statutory_invoices
  from public, anon, authenticated, service_role;
revoke all on table public.statutory_invoice_lines
  from public, anon, authenticated, service_role;
revoke all on table public.statutory_invoice_tax_components
  from public, anon, authenticated, service_role;
revoke all on table public.statutory_invoice_events
  from public, anon, authenticated, service_role;
revoke all on table public.statutory_invoice_cancellations
  from public, anon, authenticated, service_role;

grant select on table public.invoice_financial_years to authenticated;
grant select on table public.invoice_number_series to authenticated;
grant select on table public.invoice_number_allocations to authenticated;
grant select on table public.statutory_invoices to authenticated;
grant select on table public.statutory_invoice_lines to authenticated;
grant select on table public.statutory_invoice_tax_components to authenticated;
grant select on table public.statutory_invoice_events to authenticated;
grant select on table public.statutory_invoice_cancellations to authenticated;

-- ---------------------------------------------------------------------------
-- Synthetic numbering (private). Never legal, never client-callable.
-- ---------------------------------------------------------------------------

create or replace function app_private.allocate_synthetic_invoice_number(
  p_series_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  series public.invoice_number_series;
  year_row public.invoice_financial_years;
  allocated bigint;
  formatted text;
  allocation_id uuid;
begin
  perform app_private.assert_invoice_number_proof();

  select * into series
  from public.invoice_number_series
  where invoice_number_series.id = p_series_id
  for update;
  if not found then
    raise exception 'invoice number series not found' using errcode = 'P0002';
  end if;
  if series.is_synthetic is distinct from true
    or series.legal_allocation_enabled
    or series.prefix not like 'PROOF-%'
  then
    raise exception 'only synthetic proof series can allocate in this phase'
      using errcode = '42501';
  end if;

  select * into year_row
  from public.invoice_financial_years
  where invoice_financial_years.id = series.financial_year_id;
  if year_row.legal_allocation_enabled then
    raise exception 'legal allocation cannot be enabled' using errcode = '42501';
  end if;

  allocated := series.next_number;
  formatted := series.prefix || '/' || year_row.code || '/' ||
    lpad(allocated::text, series.pad_width, '0');

  insert into public.invoice_number_allocations (
    series_id, allocated_number, formatted_number, is_legal, is_consumed, proof_only
  )
  values (series.id, allocated, formatted, false, false, true)
  returning id into allocation_id;

  update public.invoice_number_series
  set
    next_number = allocated + 1,
    last_allocated_number = allocated
  where invoice_number_series.id = series.id;

  return jsonb_build_object(
    'id', allocation_id,
    'series_id', series.id,
    'allocated_number', allocated,
    'formatted_number', formatted,
    'is_legal', false,
    'proof_only', true
  );
end;
$$;

revoke all on function app_private.allocate_synthetic_invoice_number(uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Immutable foundation snapshot. Private. Cannot mark issued.
-- ---------------------------------------------------------------------------

create or replace function app_private.reserve_statutory_invoice_foundation(
  p_invoice_note_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  note public.invoice_notes;
  preview public.invoice_tax_previews;
  invoice_id uuid;
  actor uuid;
  line_row record;
  preview_line public.invoice_tax_preview_lines;
  new_line_id uuid;
begin
  perform app_private.assert_statutory_invoice_write();
  actor := nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
  if actor is null then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  select * into note from public.invoice_notes where invoice_notes.id = p_invoice_note_id;
  if not found then
    raise exception 'invoice note not found' using errcode = 'P0002';
  end if;
  if note.status is distinct from 'reviewed' then
    raise exception 'statutory foundation requires a reviewed invoice note'
      using errcode = '23514';
  end if;

  select * into preview
  from public.invoice_tax_previews
  where invoice_tax_previews.invoice_note_id = note.id
    and invoice_tax_previews.is_current;
  if not found then
    raise exception 'current tax preview is required for foundation reservation'
      using errcode = '23514';
  end if;
  if preview.invoice_note_version is distinct from note.version then
    raise exception 'tax preview is stale relative to the reviewed note'
      using errcode = '23514';
  end if;

  insert into public.statutory_invoices (
    invoice_note_id, tax_preview_id, invoice_note_version, dispatch_id,
    quantity_fingerprint, price_fingerprint, tax_input_fingerprint,
    seller_identity_id, seller_snapshot, customer_identity_id, customer_snapshot,
    status, created_by
  )
  values (
    note.id,
    preview.id,
    note.version,
    note.dispatch_id,
    note.quantity_fingerprint,
    note.price_fingerprint,
    preview.input_fingerprint,
    preview.seller_identity_id,
    jsonb_build_object(
      'seller_identity_id', preview.seller_identity_id,
      'seller_identity_version', preview.seller_identity_version,
      'seller_state_code', preview.seller_state_code
    ),
    preview.shop_tax_id,
    jsonb_build_object(
      'shop_tax_id', preview.shop_tax_id,
      'shop_tax_version', preview.shop_tax_version,
      'customer_state_code', preview.customer_state_code
    ),
    'foundation_reserved',
    actor
  )
  returning id into invoice_id;

  for line_row in
    select * from public.invoice_note_lines
    where invoice_note_lines.invoice_note_id = note.id
    order by invoice_note_lines.line_no
  loop
    select * into preview_line
    from public.invoice_tax_preview_lines
    where invoice_tax_preview_lines.preview_id = preview.id
      and invoice_tax_preview_lines.invoice_note_line_id = line_row.id;

    insert into public.statutory_invoice_lines (
      statutory_invoice_id, invoice_note_line_id, line_no, product_id,
      product_sku, product_name, shipped_cases, billed_quantity, billing_unit,
      unit_amount, line_amount, hsn_sac_code, taxable_value, tax_amount, line_total
    )
    values (
      invoice_id,
      line_row.id,
      line_row.line_no,
      line_row.product_id,
      line_row.product_sku,
      line_row.product_name,
      line_row.shipped_cases,
      line_row.billed_quantity,
      line_row.billing_unit,
      line_row.unit_amount,
      line_row.line_amount,
      preview_line.hsn_sac_code,
      coalesce(preview_line.taxable_value, line_row.line_amount),
      coalesce(preview_line.tax_amount, 0),
      coalesce(preview_line.line_total, line_row.line_amount)
    )
    returning id into new_line_id;

    if preview_line.id is not null then
      insert into public.statutory_invoice_tax_components (
        statutory_invoice_id, statutory_invoice_line_id, component_code, rate, amount
      )
      values
        (invoice_id, new_line_id, 'cgst', preview_line.cgst_rate, preview_line.cgst_amount),
        (invoice_id, new_line_id, 'sgst', preview_line.sgst_rate, preview_line.sgst_amount),
        (invoice_id, new_line_id, 'igst', preview_line.igst_rate, preview_line.igst_amount);
    end if;
  end loop;

  insert into public.statutory_invoice_events (
    statutory_invoice_id, event_type, actor_id, payload
  )
  values (
    invoice_id,
    'foundation_reserved',
    actor,
    jsonb_build_object(
      'invoice_note_id', note.id,
      'invoice_note_version', note.version,
      'tax_preview_id', preview.id,
      'legal_issuance_blocked', true
    )
  );

  perform app_private.write_audit(
    actor,
    'statutory_invoice.foundation_reserved',
    'statutory_invoices',
    invoice_id,
    jsonb_build_object(
      'invoice_note_id', note.id,
      'legal_issuance_blocked', true
    )
  );

  return invoice_id;
end;
$$;

revoke all on function app_private.reserve_statutory_invoice_foundation(uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Read-only eligibility. Completeness cannot set ready true.
-- ---------------------------------------------------------------------------

create or replace function public.assess_invoice_finalization_readiness(
  p_invoice_note_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  blockers jsonb := '[]'::jsonb;
  note public.invoice_notes;
  dispatch public.stock_dispatch_requests;
  seller public.statutory_seller_identities;
  shop_tax public.shop_tax_identities;
  preview public.invoice_tax_previews;
  fy_count integer := 0;
  series_count integer := 0;
  verifier_count integer := 0;
  missing_hsn integer := 0;
  missing_conversion integer := 0;
  issued_count integer := 0;
  as_of date := CURRENT_DATE;
begin
  if p_invoice_note_id is null then
    if not (
      app_private.can_view_invoice_note()
      or app_private.can_read_statutory_config()
    ) then
      raise exception 'permission denied' using errcode = '42501';
    end if;
  else
    if not app_private.can_view_invoice_note() then
      raise exception 'permission denied' using errcode = '42501';
    end if;
    select * into note from public.invoice_notes where invoice_notes.id = p_invoice_note_id;
    if not found then
      raise exception 'invoice note not found' using errcode = 'P0002';
    end if;
    if not app_private.can_work_at_branch(note.branch_id) then
      raise exception 'permission denied' using errcode = '42501';
    end if;
    as_of := note.as_of_date;
  end if;

  select * into seller
  from public.statutory_seller_identities
  where statutory_seller_identities.status = 'verified'
    and statutory_seller_identities.effective_from <= as_of
    and (
      statutory_seller_identities.effective_to is null
      or statutory_seller_identities.effective_to >= as_of
    )
  order by verified_at desc
  limit 1;

  if seller.id is null then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'seller_identity_unverified',
      'Seller legal identity is not accountant-verified for the invoice date.'
    ));
  elsif seller.signature_caption is null and seller.seal_caption is null then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'signature_seal_unapproved',
      'Authorized signature and seal metadata are not recorded on the verified seller identity.'
    ));
  end if;

  if not exists (
    select 1 from public.tax_rate_schedules where tax_rate_schedules.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'tax_classification_unapproved',
      'No accountant-verified tax rate schedule exists.'
    ));
  end if;

  if not exists (
    select 1 from public.statutory_policies
    where statutory_policies.policy_kind = 'tax_inclusive_exclusive'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'tax_treatment_unapproved',
      'Tax-inclusive versus exclusive treatment is unapproved (I3).'
    ));
  end if;

  if not exists (
    select 1 from public.statutory_policies
    where statutory_policies.policy_kind = 'numbering'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'numbering_policy_unapproved',
      'Financial-year invoice numbering is unapproved (I7). No statutory number is allocated.'
    ));
  end if;

  if not exists (
    select 1 from public.statutory_policies
    where statutory_policies.policy_kind = 'invoice_date'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'invoice_date_policy_unapproved',
      'Invoice date versus dispatch date rule is unapproved (I10).'
    ));
  end if;

  if not exists (
    select 1 from public.statutory_policies
    where statutory_policies.policy_kind = 'place_of_supply'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'place_of_supply_unapproved',
      'Place-of-supply determination is unapproved.'
    ));
  end if;

  if not exists (
    select 1 from public.statutory_policies
    where statutory_policies.policy_kind = 'gst_component'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'gst_component_unapproved',
      'CGST/SGST/IGST selection rule is unapproved.'
    ));
  end if;

  if not exists (
    select 1 from public.statutory_policies
    where statutory_policies.policy_kind = 'rounding'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'rounding_unapproved',
      'Invoice rounding policy is unapproved.'
    ));
  end if;

  if not exists (
    select 1 from public.statutory_policies
    where statutory_policies.policy_kind = 'credit_note_tax'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'credit_note_tax_unapproved',
      'Credit-note tax treatment is unapproved. Credit notes are not issued.'
    ));
  end if;

  select count(*) into fy_count
  from public.invoice_financial_years
  where invoice_financial_years.status = 'verified'
    and invoice_financial_years.starts_on <= as_of
    and invoice_financial_years.ends_on >= as_of;
  if fy_count = 0 then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'financial_year_unconfigured',
      'No verified financial-year numbering window covers this invoice date.'
    ));
  end if;

  select count(*) into series_count
  from public.invoice_number_series
  join public.invoice_financial_years
    on invoice_financial_years.id = invoice_number_series.financial_year_id
  where invoice_financial_years.status = 'verified'
    and invoice_number_series.is_synthetic = false
    and invoice_financial_years.starts_on <= as_of
    and invoice_financial_years.ends_on >= as_of;
  if series_count = 0 then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'invoice_series_unconfigured',
      'No non-synthetic invoice series is configured for the covering financial year.'
    ));
  end if;

  select count(*) into verifier_count
  from public.user_roles
  join public.roles on roles.id = user_roles.role_id
  join public.profiles on profiles.id = user_roles.user_id
  where roles.code = 'statutory_verifier'
    and profiles.is_active;
  if verifier_count = 0 then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'statutory_verifier_unassigned',
      'No active user is assigned the statutory_verifier role.'
    ));
  end if;
  blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
    'statutory_verifier_issuance_not_authorized',
    'Owner has not authorized a named accountant to verify statutory issuance.'
  ));

  if note.id is not null then
    if note.status is distinct from 'reviewed' then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'invoice_note_not_reviewed',
        'Only a reviewed invoice-note snapshot can be considered for future finalization.'
      ));
    end if;

    select * into dispatch
    from public.stock_dispatch_requests
    where stock_dispatch_requests.id = note.dispatch_id;
    if dispatch.id is null
      or dispatch.stock_consumed is distinct from true
      or dispatch.posted_transaction_id is null
      or dispatch.status not in ('dispatched', 'in_transit', 'delivered', 'exception')
    then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'dispatch_not_valid',
        'Source dispatch is missing, unposted, or not in an eligible operational status.'
      ));
    end if;

    select * into shop_tax
    from public.shop_tax_identities
    where shop_tax_identities.shop_id = note.shop_id
      and shop_tax_identities.status = 'verified'
      and shop_tax_identities.effective_from <= note.as_of_date
      and (
        shop_tax_identities.effective_to is null
        or shop_tax_identities.effective_to >= note.as_of_date
      )
    order by verified_at desc
    limit 1;
    if shop_tax.id is null then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'customer_identity_incomplete',
        'Customer tax identity is missing or not accountant-verified for this shop.'
      ));
    elsif shop_tax.registration_status = 'gst_registered'
      and shop_tax.gstin is null
    then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'customer_gstin_required',
        'GST-registered customer identity is missing a GSTIN.'
      ));
    end if;

    select count(*) into missing_hsn
    from public.invoice_note_lines
    where invoice_note_lines.invoice_note_id = note.id
      and not exists (
        select 1 from public.product_hsn_classifications
        where product_hsn_classifications.product_id = invoice_note_lines.product_id
          and product_hsn_classifications.status = 'verified'
      );
    if missing_hsn > 0 then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'product_hsn_missing',
        'One or more billed products have no verified HSN/SAC classification.'
      ));
    end if;

    select count(*) into missing_conversion
    from public.invoice_note_lines
    where invoice_note_lines.invoice_note_id = note.id
      and (
        invoice_note_lines.billing_unit is null
        or invoice_note_lines.billed_units_per_case is null
        or invoice_note_lines.billed_units_per_case <= 0
      );
    if missing_conversion > 0 then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'pricing_billing_conversion_invalid',
        'Billing conversion is missing or invalid on one or more invoice-note lines.'
      ));
    end if;

    select * into preview
    from public.invoice_tax_previews
    where invoice_tax_previews.invoice_note_id = note.id
      and invoice_tax_previews.is_current;
    if preview.id is null then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'tax_preview_missing',
        'No current tax-preview snapshot exists for this reviewed note.'
      ));
    elsif preview.invoice_note_version is distinct from note.version
      or preview.dispatch_id is distinct from note.dispatch_id
    then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'tax_preview_stale',
        'The current tax-preview fingerprint does not match the reviewed invoice-note snapshot.'
      ));
    end if;

    if exists (
      select 1 from public.statutory_invoices
      where statutory_invoices.invoice_note_id = note.id
    ) then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'conflicting_finalization',
        'A statutory invoice foundation record already exists for this note.'
      ));
    end if;
  end if;

  select count(*) into issued_count
  from public.statutory_invoices
  where statutory_invoices.legal_invoice_number is not null
     or statutory_invoices.issued_at is not null;
  if issued_count > 0 then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'unexpected_issued_invoice',
      'An issued statutory invoice row exists while issuance is disabled.'
    ));
  end if;

  blockers := blockers || jsonb_build_array(
    app_private.invoice_blocker(
      'tax_preview_is_not_a_tax_invoice',
      'GST calculation preview is not a tax invoice.'
    ),
    app_private.invoice_blocker(
      'finalize_rpc_disabled',
      'No invoice finalization or statutory number consume RPC exists.'
    ),
    app_private.invoice_blocker(
      'statutory_issuance_disabled',
      'Statutory GST invoice issuance is disabled until owner approval.'
    ),
    app_private.invoice_blocker(
      'legal_numbering_allocation_disabled',
      'Legal financial-year invoice numbering allocation is disabled.'
    )
  );

  return jsonb_build_object(
    'ready', false,
    'legal_issuance_blocked', true,
    'currency_code', 'INR',
    'issuance_blocked_reason',
      'Statutory invoice finalization foundation cannot issue or number a tax invoice.',
    'numbering_allocation_enabled', false,
    'cancellation_blocked', true,
    'issued_invoice_count', issued_count,
    'blockers', blockers
  );
end;
$$;

create or replace function public.assess_statutory_cancellation_readiness(
  p_statutory_invoice_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  blockers jsonb := '[]'::jsonb;
  header public.statutory_invoices;
  note public.invoice_notes;
begin
  if not app_private.can_view_invoice_note() then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  if p_statutory_invoice_id is not null then
    select * into header
    from public.statutory_invoices
    where statutory_invoices.id = p_statutory_invoice_id;
    if not found then
      raise exception 'statutory invoice not found' using errcode = 'P0002';
    end if;
    select * into note
    from public.invoice_notes
    where invoice_notes.id = header.invoice_note_id;
    if not app_private.can_work_at_branch(note.branch_id) then
      raise exception 'permission denied' using errcode = '42501';
    end if;
  end if;

  blockers := blockers || jsonb_build_array(
    app_private.invoice_blocker(
      'statutory_invoice_never_issued',
      'No legally issued tax invoice exists to cancel.'
    ),
    app_private.invoice_blocker(
      'credit_note_unapproved',
      'Credit-note tax treatment is unapproved. Cancellation cannot post a financial adjustment.'
    ),
    app_private.invoice_blocker(
      'statutory_cancellation_disabled',
      'Controlled statutory cancellation is disabled until owner approval.'
    )
  );

  return jsonb_build_object(
    'ready', false,
    'legal_cancellation_blocked', true,
    'rewrites_financial_values', false,
    'deletes_history', false,
    'blockers', blockers
  );
end;
$$;

revoke all on function public.assess_invoice_finalization_readiness(uuid)
  from public, anon;
revoke all on function public.assess_statutory_cancellation_readiness(uuid)
  from public, anon;
grant execute on function public.assess_invoice_finalization_readiness(uuid)
  to authenticated;
grant execute on function public.assess_statutory_cancellation_readiness(uuid)
  to authenticated;

comment on function public.assess_invoice_finalization_readiness(uuid) is
  'Read-only eligibility. ready remains false. Completeness cannot issue a tax invoice.';
comment on function public.assess_statutory_cancellation_readiness(uuid) is
  'Read-only cancellation foundation. Never deletes issued history or posts credit notes.';
comment on function app_private.allocate_synthetic_invoice_number(uuid) is
  'Private synthetic PROOF- allocator. Revoked from application roles. Not a legal invoice number.';
comment on function app_private.reserve_statutory_invoice_foundation(uuid) is
  'Private immutable snapshot reservation. Cannot set issued status or legal_invoice_number.';

notify pgrst, 'reload schema';
