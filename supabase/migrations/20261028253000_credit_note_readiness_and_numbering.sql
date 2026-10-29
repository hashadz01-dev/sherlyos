-- M7.5E.2 read-only GST credit-note readiness and synthetic numbering foundation.
-- Legal allocation stays false. No public issue or allocate RPC.

create or replace function app_private.assert_credit_note_numbering_write()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if current_setting('app.credit_note_numbering_write', true) is distinct from 'on' then
    raise exception 'credit-note numbering configuration can only change through approved procedures'
      using errcode = '42501';
  end if;
end;
$$;

create or replace function app_private.assert_credit_note_number_proof()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if current_setting('app.credit_note_number_proof', true) is distinct from 'on' then
    raise exception 'synthetic credit-note-number proof is not enabled'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_credit_note_numbering_write()
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_credit_note_number_proof()
  from public, anon, authenticated, service_role;

create or replace function app_private.guard_credit_note_numbering_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_name = 'invoice_credit_note_number_allocations' then
    if current_setting('app.credit_note_number_proof', true) is distinct from 'on'
      and current_setting('app.credit_note_numbering_write', true) is distinct from 'on'
    then
      raise exception 'credit-note number allocations are not writable'
        using errcode = '42501';
    end if;
  elsif tg_table_name = 'invoice_credit_note_number_series'
    and tg_op = 'UPDATE'
    and current_setting('app.credit_note_number_proof', true) = 'on'
  then
    if new.prefix is distinct from old.prefix
      or new.is_synthetic is distinct from old.is_synthetic
      or new.legal_allocation_enabled is distinct from old.legal_allocation_enabled
      or new.financial_year_id is distinct from old.financial_year_id
    then
      raise exception 'synthetic credit-note proof cannot rewrite series identity'
        using errcode = '42501';
    end if;
  else
    perform app_private.assert_credit_note_numbering_write();
  end if;
  if tg_op = 'DELETE' and tg_table_name <> 'invoice_credit_note_number_allocations' then
    raise exception 'credit-note numbering configuration cannot be deleted'
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function app_private.guard_credit_note_numbering_write()
  from public, anon, authenticated, service_role;

create table if not exists public.invoice_credit_note_number_series (
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
  constraint invoice_credit_note_number_series_key unique (financial_year_id, series_code),
  constraint invoice_credit_note_number_series_scope_check check (
    uniqueness_scope = 'ownership_year_series'
  ),
  constraint invoice_credit_note_number_series_pad_check check (pad_width between 1 and 10),
  constraint invoice_credit_note_number_series_next_check check (next_number >= 1),
  constraint invoice_credit_note_number_series_legal_off check (
    legal_allocation_enabled = false
  ),
  constraint invoice_credit_note_number_series_synthetic_prefix check (
    is_synthetic = false
    or prefix like 'PROOF-CN-%'
  )
);

create table if not exists public.invoice_credit_note_number_allocations (
  id uuid primary key default gen_random_uuid(),
  series_id uuid not null
    references public.invoice_credit_note_number_series (id) on delete restrict,
  allocated_number bigint not null,
  formatted_number text not null,
  is_legal boolean not null default false,
  is_consumed boolean not null default false,
  proof_only boolean not null default true,
  allocated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint invoice_credit_note_number_allocations_series_number_key
    unique (series_id, allocated_number),
  constraint invoice_credit_note_number_allocations_formatted_key unique (formatted_number),
  constraint invoice_credit_note_number_allocations_legal_off check (is_legal = false),
  constraint invoice_credit_note_number_allocations_proof_only check (proof_only = true),
  constraint invoice_credit_note_number_allocations_not_consumed check (is_consumed = false),
  constraint invoice_credit_note_number_allocations_proof_shape check (
    formatted_number like 'PROOF-CN-%'
  )
);

drop trigger if exists invoice_credit_note_number_series_updated_at
  on public.invoice_credit_note_number_series;
drop trigger if exists invoice_credit_note_number_series_guard
  on public.invoice_credit_note_number_series;
drop trigger if exists invoice_credit_note_number_allocations_guard
  on public.invoice_credit_note_number_allocations;

create trigger invoice_credit_note_number_series_updated_at
  before update on public.invoice_credit_note_number_series
  for each row execute function app_private.set_updated_at();
create trigger invoice_credit_note_number_series_guard
  before insert or update or delete on public.invoice_credit_note_number_series
  for each row execute function app_private.guard_credit_note_numbering_write();
create trigger invoice_credit_note_number_allocations_guard
  before insert or update or delete on public.invoice_credit_note_number_allocations
  for each row execute function app_private.guard_credit_note_numbering_write();

alter table public.invoice_credit_note_number_series enable row level security;
alter table public.invoice_credit_note_number_series force row level security;
alter table public.invoice_credit_note_number_allocations enable row level security;
alter table public.invoice_credit_note_number_allocations force row level security;

drop policy if exists invoice_credit_note_number_series_select
  on public.invoice_credit_note_number_series;
drop policy if exists invoice_credit_note_number_allocations_select
  on public.invoice_credit_note_number_allocations;

create policy invoice_credit_note_number_series_select
  on public.invoice_credit_note_number_series for select to authenticated
  using (
    (select app_private.can_read_statutory_config())
    or (select app_private.can_manage_credit_adjustment())
  );
create policy invoice_credit_note_number_allocations_select
  on public.invoice_credit_note_number_allocations for select to authenticated
  using (
    (select app_private.can_read_statutory_config())
    and invoice_credit_note_number_allocations.proof_only
  );

revoke all on table public.invoice_credit_note_number_series
  from public, anon, authenticated, service_role;
revoke all on table public.invoice_credit_note_number_allocations
  from public, anon, authenticated, service_role;
grant select on table public.invoice_credit_note_number_series to authenticated;
grant select on table public.invoice_credit_note_number_allocations to authenticated;

create or replace function app_private.allocate_synthetic_credit_note_number(
  p_series_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  series public.invoice_credit_note_number_series;
  year_row public.invoice_financial_years;
  allocated bigint;
  formatted text;
  allocation_id uuid;
begin
  perform app_private.assert_credit_note_number_proof();

  select * into series
  from public.invoice_credit_note_number_series
  where invoice_credit_note_number_series.id = p_series_id
  for update;
  if not found then
    raise exception 'credit-note number series not found' using errcode = 'P0002';
  end if;
  if series.is_synthetic is distinct from true
    or series.legal_allocation_enabled
    or series.prefix not like 'PROOF-CN-%'
  then
    raise exception 'only synthetic credit-note proof series can allocate in this phase'
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

  insert into public.invoice_credit_note_number_allocations (
    series_id, allocated_number, formatted_number, is_legal, is_consumed, proof_only
  )
  values (series.id, allocated, formatted, false, false, true)
  returning id into allocation_id;

  update public.invoice_credit_note_number_series
  set
    next_number = allocated + 1,
    last_allocated_number = allocated
  where invoice_credit_note_number_series.id = series.id;

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

revoke all on function app_private.allocate_synthetic_credit_note_number(uuid)
  from public, anon, authenticated, service_role;

comment on function app_private.allocate_synthetic_credit_note_number(uuid) is
  'Isolated PROOF-CN- allocator. Never legal, never public, never attached to a credit adjustment.';

-- Readiness is always false. Completeness of configuration cannot authorize issuance.
create or replace function public.assess_credit_note_issuance_readiness(
  p_adjustment_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  blockers jsonb := '[]'::jsonb;
  header public.invoice_credit_adjustments;
  note public.invoice_notes;
  ret public.stock_delivery_returns;
  preview public.invoice_tax_previews;
  fy_count integer := 0;
  series_count integer := 0;
  verifier_count integer := 0;
  as_of date := CURRENT_DATE;
begin
  if p_adjustment_id is null then
    if not (
      app_private.can_manage_credit_adjustment()
      or app_private.can_read_statutory_config()
    ) then
      raise exception 'permission denied' using errcode = '42501';
    end if;
  else
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
    as_of := note.as_of_date;
  end if;

  -- Hard gates. These stay even if accountant policies are later verified.
  blockers := blockers || jsonb_build_array(
    app_private.invoice_blocker(
      'credit_note_issue_rpc_disabled',
      'No public GST credit-note issuance RPC exists.'
    ),
    app_private.invoice_blocker(
      'statutory_credit_note_issuance_disabled',
      'Statutory credit-note issuance is disabled for this phase.'
    ),
    app_private.invoice_blocker(
      'legal_credit_note_numbering_disabled',
      'Legal credit-note number allocation is disabled.'
    )
  );

  if header.id is not null then
    if not exists (
      select 1
      from public.statutory_invoices
      where statutory_invoices.invoice_note_id = header.invoice_note_id
        and statutory_invoices.issued_at is not null
        and statutory_invoices.legal_invoice_number is not null
    ) then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'original_legal_invoice_missing',
        'No legally issued tax invoice exists for this invoice note. Credit notes cannot be issued.'
      ));
    elsif exists (
      select 1
      from public.statutory_invoice_cancellations
      join public.statutory_invoices
        on statutory_invoices.id = statutory_invoice_cancellations.statutory_invoice_id
      where statutory_invoices.invoice_note_id = header.invoice_note_id
    ) then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'original_legal_invoice_invalidated',
        'The original statutory invoice has a cancellation record.'
      ));
    end if;

    if ret.id is null or ret.status not in ('posted', 'closed_missing') then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'verified_return_missing',
        'A posted or closed-missing customer return is required.'
      ));
    end if;

    if header.credited_cases <= 0 then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'creditable_quantity_missing',
        'No remaining creditable carton cases exist on this adjustment.'
      ));
    end if;

    select * into preview
    from public.invoice_tax_previews
    where invoice_tax_previews.id = header.tax_preview_id;
    if preview.id is null
      or header.tax_preview_state is distinct from 'tax_preview'
      or preview.input_fingerprint is distinct from header.tax_input_fingerprint
    then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'original_tax_basis_unavailable',
        'The original tax-preview basis is missing, stale, or incomplete. Tax is not invented.'
      ));
    end if;

    if header.legal_credit_note_number is not null
      or header.statutory_credit_note_id is not null
      or exists (
        select 1
        from public.invoice_credit_adjustments other
        where other.invoice_note_id = header.invoice_note_id
          and other.id <> header.id
          and other.legal_credit_note_number is not null
      )
    then
      blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
        'duplicate_legal_credit_note',
        'A legal credit-note number already exists for this invoice note.'
      ));
    end if;
  else
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'original_legal_invoice_missing',
      'No legally issued tax invoice exists. Credit notes cannot be issued.'
    ));
  end if;

  if not exists (
    select 1
    from public.statutory_policies
    where statutory_policies.policy_kind = 'credit_note_tax'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'credit_note_tax_unapproved',
      'GST credit-note tax treatment is not accountant-approved. No policy is invented.'
    ));
  end if;

  if not exists (
    select 1
    from public.statutory_policies
    where statutory_policies.policy_kind = 'numbering'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'numbering_policy_unapproved',
      'Financial-year numbering policy is not accountant-approved.'
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
      'No verified financial-year window covers this document date.'
    ));
  end if;

  select count(*) into series_count
  from public.invoice_credit_note_number_series
  join public.invoice_financial_years
    on invoice_financial_years.id = invoice_credit_note_number_series.financial_year_id
  where invoice_financial_years.status = 'verified'
    and invoice_credit_note_number_series.is_synthetic = false
    and invoice_financial_years.starts_on <= as_of
    and invoice_financial_years.ends_on >= as_of;
  if series_count = 0 then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'credit_note_series_unconfigured',
      'No non-synthetic credit-note series is configured for the covering financial year.'
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

  if not exists (
    select 1
    from public.statutory_seller_identities
    where statutory_seller_identities.status = 'verified'
      and statutory_seller_identities.effective_from <= as_of
      and (
        statutory_seller_identities.effective_to is null
        or statutory_seller_identities.effective_to >= as_of
      )
      and (
        statutory_seller_identities.signature_caption is not null
        or statutory_seller_identities.seal_caption is not null
      )
  ) then
    blockers := blockers || jsonb_build_array(app_private.invoice_blocker(
      'signature_seal_unapproved',
      'Authorized signature and seal metadata are not accountant-approved.'
    ));
  end if;

  return jsonb_build_object(
    'ready', false,
    'legal_issuance_blocked', true,
    'numbering_allocation_enabled', false,
    'issuance_blocked_reason', 'GST credit notes are not issued in this phase.',
    'blockers', blockers
  );
end;
$$;

revoke all on function public.assess_credit_note_issuance_readiness(uuid)
  from public, anon;
grant execute on function public.assess_credit_note_issuance_readiness(uuid)
  to authenticated;

comment on function public.assess_credit_note_issuance_readiness(uuid) is
  'Read-only GST credit-note readiness. Always ready=false. Does not invent accountant policy or allocate numbers.';

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
    'tax_readiness', public.assess_credit_note_issuance_readiness(header.id),
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

-- Existing-adjustment lookup must hide rejected rows and keep approved ones occupied.
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
              and app_private.credit_adjustment_occupies_return(invoice_credit_adjustments.status)
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

notify pgrst, 'reload schema';
