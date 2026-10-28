-- M7.5C.2 GST calculation preview.
-- NUMERIC arithmetic only. No statutory numbering, finalization, stock, or credit notes.
-- Invoice-note tax_amount stays 0 (reviewed price snapshots are not rewritten).

create or replace function app_private.assert_tax_preview_write()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if current_setting('app.tax_preview_write', true) is distinct from 'on' then
    raise exception 'tax previews can only change through approved procedures'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_tax_preview_write()
  from public, anon, authenticated, service_role;

create table if not exists public.invoice_tax_previews (
  id uuid primary key default gen_random_uuid(),
  invoice_note_id uuid not null references public.invoice_notes (id) on delete restrict,
  invoice_note_version integer not null,
  dispatch_id uuid not null,
  ownership_code text not null,
  is_current boolean not null default true,
  watermark text not null,
  pricing_treatment text not null,
  place_of_supply_basis text not null,
  supply_kind text not null,
  seller_state_code text not null,
  customer_state_code text not null,
  rounding_mode text not null,
  rounding_increment numeric(12, 4) not null,
  seller_identity_id uuid not null,
  seller_identity_version integer not null,
  shop_tax_id uuid not null,
  shop_tax_version integer not null,
  treatment_policy_id uuid not null,
  treatment_policy_version integer not null,
  place_policy_id uuid not null,
  place_policy_version integer not null,
  rounding_policy_id uuid not null,
  rounding_policy_version integer not null,
  component_policy_id uuid not null,
  component_policy_version integer not null,
  taxable_value numeric(14, 2) not null,
  cgst_amount numeric(14, 2) not null,
  sgst_amount numeric(14, 2) not null,
  igst_amount numeric(14, 2) not null,
  tax_amount numeric(14, 2) not null,
  invoice_total numeric(14, 2) not null,
  input_fingerprint text not null,
  calculated_at timestamptz not null default pg_catalog.clock_timestamp(),
  created_by uuid not null references public.profiles (id) on delete restrict,
  constraint invoice_tax_previews_watermark_check check (
    watermark = 'TAX CALCULATION PREVIEW — NOT A TAX INVOICE'
  ),
  constraint invoice_tax_previews_treatment_check check (
    pricing_treatment in ('inclusive', 'exclusive')
  ),
  constraint invoice_tax_previews_supply_check check (
    supply_kind in ('intra_state', 'inter_state')
  )
);

create unique index if not exists invoice_tax_previews_current_uidx
  on public.invoice_tax_previews (invoice_note_id)
  where is_current;

create table if not exists public.invoice_tax_preview_lines (
  id uuid primary key default gen_random_uuid(),
  preview_id uuid not null references public.invoice_tax_previews (id) on delete restrict,
  invoice_note_line_id uuid not null references public.invoice_note_lines (id) on delete restrict,
  product_id uuid not null,
  hsn_id uuid not null,
  hsn_version integer not null,
  hsn_sac_code text not null,
  schedule_id uuid not null,
  schedule_version integer not null,
  price_id uuid not null,
  price_unit_amount numeric(14, 4) not null,
  billed_quantity numeric(14, 4) not null,
  line_amount numeric(14, 2) not null,
  cgst_rate numeric(5, 2) not null,
  sgst_rate numeric(5, 2) not null,
  igst_rate numeric(5, 2) not null,
  taxable_value numeric(14, 2) not null,
  cgst_amount numeric(14, 2) not null,
  sgst_amount numeric(14, 2) not null,
  igst_amount numeric(14, 2) not null,
  tax_amount numeric(14, 2) not null,
  line_total numeric(14, 2) not null
);

create index if not exists invoice_tax_preview_lines_preview_idx
  on public.invoice_tax_preview_lines (preview_id);

create or replace function app_private.guard_tax_preview_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform app_private.assert_tax_preview_write();
  if tg_op = 'DELETE' then
    raise exception 'tax previews cannot be deleted' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function app_private.guard_tax_preview_write()
  from public, anon, authenticated, service_role;

create trigger invoice_tax_previews_guard
  before insert or update or delete on public.invoice_tax_previews
  for each row execute function app_private.guard_tax_preview_write();
create trigger invoice_tax_preview_lines_guard
  before insert or update or delete on public.invoice_tax_preview_lines
  for each row execute function app_private.guard_tax_preview_write();

alter table public.invoice_tax_previews enable row level security;
alter table public.invoice_tax_previews force row level security;
alter table public.invoice_tax_preview_lines enable row level security;
alter table public.invoice_tax_preview_lines force row level security;

create policy invoice_tax_previews_select
  on public.invoice_tax_previews for select to authenticated
  using ((select app_private.can_view_invoice_note()));
create policy invoice_tax_preview_lines_select
  on public.invoice_tax_preview_lines for select to authenticated
  using ((select app_private.can_view_invoice_note()));

revoke all on table public.invoice_tax_previews from public, anon, authenticated, service_role;
revoke all on table public.invoice_tax_preview_lines from public, anon, authenticated, service_role;
grant select on table public.invoice_tax_previews to authenticated;
grant select on table public.invoice_tax_preview_lines to authenticated;

-- Serialize GST preview against tax-config verification for one ownership.
create or replace function app_private.lock_tax_config_scope(p_ownership text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('tax-config:' || coalesce(p_ownership, ''), 0)
  );
end;
$$;

revoke all on function app_private.lock_tax_config_scope(text)
  from public, anon, authenticated, service_role;

-- PostgreSQL numeric round() is half away from zero. No JS floats.
create or replace function app_private.gst_round(
  p_amount numeric,
  p_increment numeric,
  p_mode text
)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_mode is distinct from 'nearest_half_up' then
    raise exception 'rounding mode is not an approved explicit value' using errcode = '23514';
  end if;
  if p_increment is distinct from 0.01 then
    raise exception 'rounding increment is not an approved explicit value' using errcode = '23514';
  end if;
  return round(p_amount, 2);
end;
$$;

revoke all on function app_private.gst_round(numeric, numeric, text)
  from public, anon, authenticated, service_role;

create or replace function app_private.verified_policy(
  p_kind text,
  p_ownership text,
  p_as_of date
)
returns public.statutory_policies
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  hit_count integer;
  header public.statutory_policies;
begin
  select count(*) into hit_count
  from public.statutory_policies
  where statutory_policies.policy_kind = p_kind
    and statutory_policies.status = 'verified'
    and statutory_policies.ownership_code = p_ownership
    and statutory_policies.effective_from <= p_as_of
    and (
      statutory_policies.effective_to is null
      or statutory_policies.effective_to >= p_as_of
    );
  if hit_count <> 1 then
    raise exception 'statutory policy % is missing, unapproved, or ambiguous', p_kind
      using errcode = 'P0002';
  end if;
  select * into header
  from public.statutory_policies
  where statutory_policies.policy_kind = p_kind
    and statutory_policies.status = 'verified'
    and statutory_policies.ownership_code = p_ownership
    and statutory_policies.effective_from <= p_as_of
    and (
      statutory_policies.effective_to is null
      or statutory_policies.effective_to >= p_as_of
    );
  return header;
end;
$$;

revoke all on function app_private.verified_policy(text, text, date)
  from public, anon, authenticated, service_role;

create or replace function app_private.gst_line_calc(
  p_line_amount numeric,
  p_treatment text,
  p_supply_kind text,
  p_cgst numeric,
  p_sgst numeric,
  p_igst numeric,
  p_round_mode text,
  p_round_increment numeric
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  rate numeric;
  taxable numeric;
  tax numeric;
  cgst_amt numeric := 0;
  sgst_amt numeric := 0;
  igst_amt numeric := 0;
begin
  if p_treatment = 'exclusive' then
    taxable := app_private.gst_round(p_line_amount, p_round_increment, p_round_mode);
    if p_supply_kind = 'intra_state' then
      cgst_amt := app_private.gst_round(taxable * coalesce(p_cgst, 0) / 100, p_round_increment, p_round_mode);
      sgst_amt := app_private.gst_round(taxable * coalesce(p_sgst, 0) / 100, p_round_increment, p_round_mode);
    else
      igst_amt := app_private.gst_round(taxable * coalesce(p_igst, 0) / 100, p_round_increment, p_round_mode);
    end if;
    tax := cgst_amt + sgst_amt + igst_amt;
    return jsonb_build_object(
      'taxable_value', taxable,
      'cgst_amount', cgst_amt,
      'sgst_amount', sgst_amt,
      'igst_amount', igst_amt,
      'tax_amount', tax,
      'line_total', taxable + tax
    );
  end if;

  if p_supply_kind = 'intra_state' then
    rate := coalesce(p_cgst, 0) + coalesce(p_sgst, 0);
  else
    rate := coalesce(p_igst, 0);
  end if;

  if rate = 0 then
    taxable := app_private.gst_round(p_line_amount, p_round_increment, p_round_mode);
    tax := 0;
  else
    taxable := app_private.gst_round(
      p_line_amount * 100 / (100 + rate),
      p_round_increment,
      p_round_mode
    );
    tax := app_private.gst_round(p_line_amount, p_round_increment, p_round_mode) - taxable;
  end if;

  if p_supply_kind = 'intra_state' then
    if rate = 0 then
      cgst_amt := 0;
      sgst_amt := 0;
    else
      cgst_amt := app_private.gst_round(tax * coalesce(p_cgst, 0) / rate, p_round_increment, p_round_mode);
      sgst_amt := tax - cgst_amt;
    end if;
  else
    igst_amt := tax;
  end if;

  return jsonb_build_object(
    'taxable_value', taxable,
    'cgst_amount', cgst_amt,
    'sgst_amount', sgst_amt,
    'igst_amount', igst_amt,
    'tax_amount', tax,
    'line_total', taxable + tax
  );
end;
$$;

revoke all on function app_private.gst_line_calc(numeric, text, text, numeric, numeric, numeric, text, numeric)
  from public, anon, authenticated, service_role;

create or replace function public.preview_invoice_tax(
  p_invoice_note_id uuid,
  p_expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  note public.invoice_notes;
  ownership text;
  seller public.statutory_seller_identities;
  shop_tax public.shop_tax_identities;
  treatment_policy public.statutory_policies;
  place_policy public.statutory_policies;
  rounding_policy public.statutory_policies;
  component_policy public.statutory_policies;
  pricing text;
  pos_basis text;
  round_mode text;
  round_increment numeric;
  seller_state text;
  customer_state text;
  supply_kind text;
  line_row public.invoice_note_lines;
  hsn_row public.product_hsn_classifications;
  schedule_row public.tax_rate_schedules;
  hsn_hits integer;
  schedule_hits integer;
  calc jsonb;
  blockers jsonb := '[]'::jsonb;
  line_payloads jsonb := '[]'::jsonb;
  fp_parts text := '';
  fingerprint text;
  existing public.invoice_tax_previews;
  preview_row public.invoice_tax_previews;
  sum_taxable numeric := 0;
  sum_cgst numeric := 0;
  sum_sgst numeric := 0;
  sum_igst numeric := 0;
  sum_tax numeric := 0;
  sum_total numeric := 0;
  return_count integer := 0;
begin
  if not (
    app_private.has_permission('invoice_notes.prepare')
    or app_private.has_permission('invoices.review')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select * into note
  from public.invoice_notes
  where invoice_notes.id = p_invoice_note_id
  for update;
  if not found then
    raise exception 'invoice note not found' using errcode = 'P0002';
  end if;
  if not app_private.can_work_at_branch(note.branch_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  if note.version is distinct from p_expected_version then
    raise exception 'invoice note was changed by someone else' using errcode = 'PT409';
  end if;
  if note.status is distinct from 'reviewed' then
    raise exception 'tax calculation preview is limited to reviewed invoice notes'
      using errcode = '23514';
  end if;

  ownership := app_private.registered_operating_ownership_code();
  if ownership is null then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'operating_ownership_unregistered',
      'message', 'Operating ownership is not registered.'
    ));
  else
    -- Serialize preview against policy/schedule verification for this ownership.
    perform app_private.lock_tax_config_scope(ownership);
  end if;

  select * into seller
  from public.statutory_seller_identities
  where statutory_seller_identities.status = 'verified'
    and statutory_seller_identities.ownership_code = ownership
    and statutory_seller_identities.effective_from <= note.as_of_date
    and (
      statutory_seller_identities.effective_to is null
      or statutory_seller_identities.effective_to >= note.as_of_date
    )
  order by verified_at desc
  limit 1;

  select * into shop_tax
  from public.shop_tax_identities
  where shop_tax_identities.shop_id = note.shop_id
    and shop_tax_identities.status = 'verified'
    and shop_tax_identities.ownership_code = ownership
    and shop_tax_identities.effective_from <= note.as_of_date
    and (
      shop_tax_identities.effective_to is null
      or shop_tax_identities.effective_to >= note.as_of_date
    )
  order by verified_at desc
  limit 1;

  if seller.id is null or seller.gstin is null or seller.state_code is null then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'seller_identity_unverified',
      'message', 'Verified seller GSTIN and state code are required.'
    ));
  end if;
  if shop_tax.id is null then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'customer_identity_incomplete',
      'message', 'Verified customer tax identity is required.'
    ));
  elsif shop_tax.registration_status = 'gst_registered' and shop_tax.gstin is null then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'customer_gstin_missing',
      'message', 'GSTIN is required for a GST-registered customer.'
    ));
  elsif shop_tax.state_code is null then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'customer_state_missing',
      'message', 'Customer state code is required for place of supply.'
    ));
  end if;

  begin
    treatment_policy := app_private.verified_policy('tax_inclusive_exclusive', ownership, note.as_of_date);
    pricing := treatment_policy.payload ->> 'pricing';
    if pricing not in ('inclusive', 'exclusive') then
      blockers := blockers || jsonb_build_array(jsonb_build_object(
        'code', 'tax_treatment_unapproved',
        'message', 'Tax-inclusive versus exclusive pricing is not an explicit approved value.'
      ));
    end if;
  exception
    when others then
      blockers := blockers || jsonb_build_array(jsonb_build_object(
        'code', 'tax_treatment_unapproved',
        'message', 'Tax-inclusive versus exclusive policy is missing or unapproved.'
      ));
  end;

  begin
    place_policy := app_private.verified_policy('place_of_supply', ownership, note.as_of_date);
    pos_basis := place_policy.payload ->> 'basis';
    if pos_basis not in ('billing_state', 'shipping_state') then
      blockers := blockers || jsonb_build_array(jsonb_build_object(
        'code', 'place_of_supply_unapproved',
        'message', 'Place-of-supply basis is not an explicit approved value.'
      ));
    end if;
  exception
    when others then
      blockers := blockers || jsonb_build_array(jsonb_build_object(
        'code', 'place_of_supply_unapproved',
        'message', 'Place-of-supply policy is missing or unapproved.'
      ));
  end;

  begin
    rounding_policy := app_private.verified_policy('rounding', ownership, note.as_of_date);
    round_mode := rounding_policy.payload ->> 'mode';
    round_increment := (rounding_policy.payload ->> 'increment')::numeric;
    if round_mode is distinct from 'nearest_half_up' or round_increment is distinct from 0.01 then
      blockers := blockers || jsonb_build_array(jsonb_build_object(
        'code', 'rounding_unapproved',
        'message', 'Rounding policy must explicitly record nearest_half_up at 0.01.'
      ));
    end if;
  exception
    when others then
      blockers := blockers || jsonb_build_array(jsonb_build_object(
        'code', 'rounding_unapproved',
        'message', 'Rounding policy is missing or unapproved.'
      ));
  end;

  begin
    component_policy := app_private.verified_policy('gst_component', ownership, note.as_of_date);
    if component_policy.payload ->> 'intra_state' is distinct from 'cgst_sgst'
      or component_policy.payload ->> 'inter_state' is distinct from 'igst'
    then
      blockers := blockers || jsonb_build_array(jsonb_build_object(
        'code', 'gst_component_unapproved',
        'message', 'CGST/SGST versus IGST selection is not an explicit approved value.'
      ));
    end if;
  exception
    when others then
      blockers := blockers || jsonb_build_array(jsonb_build_object(
        'code', 'gst_component_unapproved',
        'message', 'GST component policy is missing or unapproved.'
      ));
  end;

  seller_state := seller.state_code;
  if pos_basis = 'shipping_state' then
    -- shop_tax_identities stores one state_code (billing). Shipping state is not a
    -- recorded field, so shipping_state basis cannot be inferred from billing.
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'place_of_supply_shipping_state_unavailable',
      'message', 'Shipping state is not a recorded tax field. Place of supply cannot be inferred from billing state.'
    ));
    customer_state := null;
  else
    customer_state := shop_tax.state_code;
  end if;

  if seller_state is null or customer_state is null then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'place_of_supply_incomplete',
      'message', 'Seller and customer state codes are required to resolve place of supply.'
    ));
  elsif seller_state = customer_state then
    supply_kind := 'intra_state';
  else
    supply_kind := 'inter_state';
  end if;

  for line_row in
    select * from public.invoice_note_lines
    where invoice_note_lines.invoice_note_id = note.id
    order by line_no
  loop
    select count(*) into hsn_hits
    from public.product_hsn_classifications
    where product_hsn_classifications.product_id = line_row.product_id
      and product_hsn_classifications.status = 'verified'
      and product_hsn_classifications.ownership_code = ownership
      and product_hsn_classifications.effective_from <= note.as_of_date
      and (
        product_hsn_classifications.effective_to is null
        or product_hsn_classifications.effective_to >= note.as_of_date
      );
    if hsn_hits <> 1 then
      blockers := blockers || jsonb_build_array(jsonb_build_object(
        'code', 'product_hsn_missing',
        'message', format('Verified HSN is missing or ambiguous for product %s.', line_row.product_sku)
      ));
      continue;
    end if;
    select * into hsn_row
    from public.product_hsn_classifications
    where product_hsn_classifications.product_id = line_row.product_id
      and product_hsn_classifications.status = 'verified'
      and product_hsn_classifications.ownership_code = ownership
      and product_hsn_classifications.effective_from <= note.as_of_date
      and (
        product_hsn_classifications.effective_to is null
        or product_hsn_classifications.effective_to >= note.as_of_date
      );

    select count(*) into schedule_hits
    from public.tax_rate_schedules
    where tax_rate_schedules.status = 'verified'
      and tax_rate_schedules.ownership_code = ownership
      and tax_rate_schedules.hsn_sac_code = hsn_row.hsn_sac_code
      and tax_rate_schedules.treatment = supply_kind
      and tax_rate_schedules.effective_from <= note.as_of_date
      and (
        tax_rate_schedules.effective_to is null
        or tax_rate_schedules.effective_to >= note.as_of_date
      );
    if schedule_hits <> 1 then
      blockers := blockers || jsonb_build_array(jsonb_build_object(
        'code', 'tax_classification_unapproved',
        'message', format('Verified tax schedule is missing or overlapping for HSN %s.', hsn_row.hsn_sac_code)
      ));
      continue;
    end if;
    select * into schedule_row
    from public.tax_rate_schedules
    where tax_rate_schedules.status = 'verified'
      and tax_rate_schedules.ownership_code = ownership
      and tax_rate_schedules.hsn_sac_code = hsn_row.hsn_sac_code
      and tax_rate_schedules.treatment = supply_kind
      and tax_rate_schedules.effective_from <= note.as_of_date
      and (
        tax_rate_schedules.effective_to is null
        or tax_rate_schedules.effective_to >= note.as_of_date
      );

    if supply_kind = 'intra_state'
      and (schedule_row.cgst_rate is null or schedule_row.sgst_rate is null)
    then
      blockers := blockers || jsonb_build_array(jsonb_build_object(
        'code', 'tax_rate_incomplete',
        'message', 'Intra-state schedule must record explicit CGST and SGST rates.'
      ));
      continue;
    end if;
    if supply_kind = 'inter_state' and schedule_row.igst_rate is null then
      blockers := blockers || jsonb_build_array(jsonb_build_object(
        'code', 'tax_rate_incomplete',
        'message', 'Inter-state schedule must record an explicit IGST rate.'
      ));
      continue;
    end if;

    if jsonb_array_length(blockers) = 0 then
      calc := app_private.gst_line_calc(
        line_row.line_amount,
        pricing,
        supply_kind,
        coalesce(schedule_row.cgst_rate, 0),
        coalesce(schedule_row.sgst_rate, 0),
        coalesce(schedule_row.igst_rate, 0),
        round_mode,
        round_increment
      );
      sum_taxable := sum_taxable + (calc ->> 'taxable_value')::numeric;
      sum_cgst := sum_cgst + (calc ->> 'cgst_amount')::numeric;
      sum_sgst := sum_sgst + (calc ->> 'sgst_amount')::numeric;
      sum_igst := sum_igst + (calc ->> 'igst_amount')::numeric;
      sum_tax := sum_tax + (calc ->> 'tax_amount')::numeric;
      sum_total := sum_total + (calc ->> 'line_total')::numeric;
      line_payloads := line_payloads || jsonb_build_array(jsonb_build_object(
        'invoice_note_line_id', line_row.id,
        'product_id', line_row.product_id,
        'hsn_id', hsn_row.id,
        'hsn_version', hsn_row.version,
        'hsn_sac_code', hsn_row.hsn_sac_code,
        'schedule_id', schedule_row.id,
        'schedule_version', schedule_row.version,
        'price_id', line_row.price_id,
        'price_unit_amount', line_row.unit_amount,
        'billed_quantity', line_row.billed_quantity,
        'line_amount', line_row.line_amount
      ) || calc);
      fp_parts := fp_parts || line_row.id::text || '|' || hsn_row.version::text || '|' ||
        schedule_row.version::text || '|' || line_row.line_amount::text || ';';
    end if;
  end loop;

  select count(*) into return_count
  from public.stock_delivery_returns
  where stock_delivery_returns.dispatch_id = note.dispatch_id;

  if jsonb_array_length(blockers) > 0 then
    return jsonb_build_object(
      'watermark', 'TAX CALCULATION PREVIEW — NOT A TAX INVOICE',
      'legal_issuance_blocked', true,
      'ready', false,
      'calculated', false,
      'blockers', blockers,
      'invoice_note_id', note.id,
      'invoice_note_version', note.version
    );
  end if;

  fingerprint := md5(
    note.id::text || '|' || note.version::text || '|' || note.dispatch_id::text || '|' ||
    coalesce(pricing, '') || '|' || coalesce(pos_basis, '') || '|' || coalesce(supply_kind, '') || '|' ||
    seller.id::text || '|' || seller.version::text || '|' ||
    shop_tax.id::text || '|' || shop_tax.version::text || '|' ||
    treatment_policy.id::text || '|' || treatment_policy.version::text || '|' ||
    place_policy.id::text || '|' || place_policy.version::text || '|' ||
    rounding_policy.id::text || '|' || rounding_policy.version::text || '|' ||
    component_policy.id::text || '|' || component_policy.version::text || '|' ||
    fp_parts
  );

  perform set_config('app.tax_preview_write', 'on', true);

  select * into existing
  from public.invoice_tax_previews
  where invoice_tax_previews.invoice_note_id = note.id
    and invoice_tax_previews.is_current
  for update;

  if existing.id is not null and existing.input_fingerprint = fingerprint then
    return public.get_invoice_tax_preview(note.id);
  end if;

  if existing.id is not null then
    update public.invoice_tax_previews
    set is_current = false
    where invoice_tax_previews.id = existing.id;
  end if;

  insert into public.invoice_tax_previews (
    invoice_note_id, invoice_note_version, dispatch_id, ownership_code, is_current,
    watermark, pricing_treatment, place_of_supply_basis, supply_kind,
    seller_state_code, customer_state_code, rounding_mode, rounding_increment,
    seller_identity_id, seller_identity_version, shop_tax_id, shop_tax_version,
    treatment_policy_id, treatment_policy_version, place_policy_id, place_policy_version,
    rounding_policy_id, rounding_policy_version, component_policy_id, component_policy_version,
    taxable_value, cgst_amount, sgst_amount, igst_amount, tax_amount, invoice_total,
    input_fingerprint, created_by
  )
  values (
    note.id, note.version, note.dispatch_id, ownership, true,
    'TAX CALCULATION PREVIEW — NOT A TAX INVOICE', pricing, pos_basis, supply_kind,
    seller_state, customer_state, round_mode, round_increment,
    seller.id, seller.version, shop_tax.id, shop_tax.version,
    treatment_policy.id, treatment_policy.version, place_policy.id, place_policy.version,
    rounding_policy.id, rounding_policy.version, component_policy.id, component_policy.version,
    sum_taxable, sum_cgst, sum_sgst, sum_igst, sum_tax, sum_total,
    fingerprint, auth.uid()
  )
  returning * into preview_row;

  insert into public.invoice_tax_preview_lines (
    preview_id, invoice_note_line_id, product_id, hsn_id, hsn_version, hsn_sac_code,
    schedule_id, schedule_version, price_id, price_unit_amount, billed_quantity, line_amount,
    cgst_rate, sgst_rate, igst_rate, taxable_value, cgst_amount, sgst_amount, igst_amount,
    tax_amount, line_total
  )
  select
    preview_row.id,
    (payload ->> 'invoice_note_line_id')::uuid,
    (payload ->> 'product_id')::uuid,
    (payload ->> 'hsn_id')::uuid,
    (payload ->> 'hsn_version')::integer,
    payload ->> 'hsn_sac_code',
    (payload ->> 'schedule_id')::uuid,
    (payload ->> 'schedule_version')::integer,
    (payload ->> 'price_id')::uuid,
    (payload ->> 'price_unit_amount')::numeric,
    (payload ->> 'billed_quantity')::numeric,
    (payload ->> 'line_amount')::numeric,
    coalesce((
      select tax_rate_schedules.cgst_rate from public.tax_rate_schedules
      where tax_rate_schedules.id = (payload ->> 'schedule_id')::uuid
    ), 0),
    coalesce((
      select tax_rate_schedules.sgst_rate from public.tax_rate_schedules
      where tax_rate_schedules.id = (payload ->> 'schedule_id')::uuid
    ), 0),
    coalesce((
      select tax_rate_schedules.igst_rate from public.tax_rate_schedules
      where tax_rate_schedules.id = (payload ->> 'schedule_id')::uuid
    ), 0),
    (payload ->> 'taxable_value')::numeric,
    (payload ->> 'cgst_amount')::numeric,
    (payload ->> 'sgst_amount')::numeric,
    (payload ->> 'igst_amount')::numeric,
    (payload ->> 'tax_amount')::numeric,
    (payload ->> 'line_total')::numeric
  from jsonb_array_elements(line_payloads) as payload;

  perform app_private.write_audit(
    auth.uid(), 'preview_invoice_tax', 'invoice_tax_previews', preview_row.id,
    jsonb_build_object('invoice_note_id', note.id, 'fingerprint', fingerprint)
  );

  return public.get_invoice_tax_preview(note.id) || jsonb_build_object(
    'returns_not_netted', return_count > 0,
    'return_count', return_count
  );
end;
$$;

create or replace function public.get_invoice_tax_preview(p_invoice_note_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  note public.invoice_notes;
  header public.invoice_tax_previews;
  stale boolean := false;
begin
  if not (
    app_private.has_permission('invoice_notes.prepare')
    or app_private.has_permission('invoices.review')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  select * into note from public.invoice_notes where invoice_notes.id = p_invoice_note_id;
  if not found then
    raise exception 'invoice note not found' using errcode = 'P0002';
  end if;
  if not app_private.can_work_at_branch(note.branch_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  select * into header
  from public.invoice_tax_previews
  where invoice_tax_previews.invoice_note_id = p_invoice_note_id
    and invoice_tax_previews.is_current;
  if not found then
    return jsonb_build_object(
      'watermark', 'TAX CALCULATION PREVIEW — NOT A TAX INVOICE',
      'calculated', false,
      'legal_issuance_blocked', true,
      'ready', false
    );
  end if;
  -- Stale when the reviewed note moved, or when a snapshotted config row is no
  -- longer the live verified version. Regeneration is a new preview_invoice_tax.
  stale := header.invoice_note_version is distinct from note.version
    or not exists (
      select 1 from public.statutory_seller_identities seller
      where seller.id = header.seller_identity_id
        and seller.version = header.seller_identity_version
        and seller.status = 'verified'
    )
    or not exists (
      select 1 from public.shop_tax_identities shop_tax
      where shop_tax.id = header.shop_tax_id
        and shop_tax.version = header.shop_tax_version
        and shop_tax.status = 'verified'
    )
    or not exists (
      select 1 from public.statutory_policies policy
      where policy.id = header.treatment_policy_id
        and policy.version = header.treatment_policy_version
        and policy.status = 'verified'
    )
    or not exists (
      select 1 from public.statutory_policies policy
      where policy.id = header.place_policy_id
        and policy.version = header.place_policy_version
        and policy.status = 'verified'
    )
    or not exists (
      select 1 from public.statutory_policies policy
      where policy.id = header.rounding_policy_id
        and policy.version = header.rounding_policy_version
        and policy.status = 'verified'
    )
    or not exists (
      select 1 from public.statutory_policies policy
      where policy.id = header.component_policy_id
        and policy.version = header.component_policy_version
        and policy.status = 'verified'
    )
    or exists (
      select 1
      from public.invoice_tax_preview_lines line
      where line.preview_id = header.id
        and (
          not exists (
            select 1 from public.product_hsn_classifications hsn
            where hsn.id = line.hsn_id
              and hsn.version = line.hsn_version
              and hsn.status = 'verified'
          )
          or not exists (
            select 1 from public.tax_rate_schedules schedule
            where schedule.id = line.schedule_id
              and schedule.version = line.schedule_version
              and schedule.status = 'verified'
          )
        )
    );

  return jsonb_build_object(
    'id', header.id,
    'watermark', header.watermark,
    'calculated', true,
    'stale', stale,
    'legal_issuance_blocked', true,
    'ready', false,
    'invoice_note_id', header.invoice_note_id,
    'invoice_note_version', header.invoice_note_version,
    'dispatch_id', header.dispatch_id,
    'pricing_treatment', header.pricing_treatment,
    'place_of_supply_basis', header.place_of_supply_basis,
    'supply_kind', header.supply_kind,
    'seller_state_code', header.seller_state_code,
    'customer_state_code', header.customer_state_code,
    'taxable_value', header.taxable_value,
    'cgst_amount', header.cgst_amount,
    'sgst_amount', header.sgst_amount,
    'igst_amount', header.igst_amount,
    'tax_amount', header.tax_amount,
    'invoice_total', header.invoice_total,
    'input_fingerprint', header.input_fingerprint,
    'calculated_at', header.calculated_at,
    'lines', coalesce((
      select jsonb_agg(to_jsonb(invoice_tax_preview_lines) order by invoice_tax_preview_lines.line_total)
      from public.invoice_tax_preview_lines
      where invoice_tax_preview_lines.preview_id = header.id
    ), '[]'::jsonb)
  );
end;
$$;

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
  seller public.statutory_seller_identities;
  shop_tax public.shop_tax_identities;
  missing_hsn integer := 0;
  missing_conversion integer := 0;
begin
  if not (
    app_private.can_view_invoice_note()
    or app_private.can_read_statutory_config()
  ) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  select * into seller
  from public.statutory_seller_identities
  where statutory_seller_identities.status = 'verified'
  order by verified_at desc
  limit 1;

  if seller.id is null then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'seller_identity_unverified',
      'message', 'Seller legal identity is not accountant-verified.'
    ));
  elsif seller.signature_caption is null and seller.seal_caption is null then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'signature_seal_unapproved',
      'message', 'Authorized signature and seal metadata are not recorded on the verified seller identity.'
    ));
  end if;

  if not exists (
    select 1 from public.tax_rate_schedules where tax_rate_schedules.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'tax_classification_unapproved',
      'message', 'No accountant-verified tax rate schedule exists. GST is not calculated for issuance.'
    ));
  end if;

  if p_invoice_note_id is not null then
    select * into note from public.invoice_notes where invoice_notes.id = p_invoice_note_id;
    if found then
      select * into shop_tax
      from public.shop_tax_identities
      where shop_tax_identities.shop_id = note.shop_id
        and shop_tax_identities.status = 'verified'
      order by verified_at desc
      limit 1;
      if shop_tax.id is null then
        blockers := blockers || jsonb_build_array(jsonb_build_object(
          'code', 'customer_identity_incomplete',
          'message', 'Customer tax identity is missing or not accountant-verified for this shop.'
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
        blockers := blockers || jsonb_build_array(jsonb_build_object(
          'code', 'product_hsn_missing',
          'message', 'One or more billed products have no verified HSN/SAC classification.'
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
        blockers := blockers || jsonb_build_array(jsonb_build_object(
          'code', 'pricing_billing_conversion_invalid',
          'message', 'Billing conversion is missing or invalid on one or more invoice-note lines.'
        ));
      end if;
    end if;
  end if;

  blockers := blockers || jsonb_build_array(
    jsonb_build_object(
      'code', 'tax_preview_is_not_a_tax_invoice',
      'message', 'GST calculation preview is not a tax invoice.'
    ),
    jsonb_build_object(
      'code', 'finalize_rpc_disabled',
      'message', 'No invoice finalization or statutory number consume RPC exists.'
    )
  );

  return jsonb_build_object(
    'ready', false,
    'legal_issuance_blocked', true,
    'currency_code', 'INR',
    'issuance_blocked_reason',
      'Tax calculation preview cannot finalize or number a statutory invoice.',
    'blockers', blockers
  );
end;
$$;

revoke all on function public.preview_invoice_tax(uuid, integer) from public, anon;
revoke all on function public.get_invoice_tax_preview(uuid) from public, anon;
grant execute on function public.preview_invoice_tax(uuid, integer) to authenticated;
grant execute on function public.get_invoice_tax_preview(uuid) to authenticated;

comment on function public.preview_invoice_tax(uuid, integer) is
  'Reviewed-note GST preview. Never allocates statutory numbers, never writes stock, never posts credit notes.';
comment on function public.assess_invoice_finalization_readiness(uuid) is
  'ready remains false. Preview is not issuance.';

notify pgrst, 'reload schema';
