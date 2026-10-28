-- M7.5C.1 HSN, tax schedules, policies, readiness gate, and grants.

create or replace function public.upsert_product_hsn_classification(
  p_product_id uuid,
  p_classification_kind text,
  p_hsn_sac_code text,
  p_effective_from date,
  p_expected_version integer,
  p_effective_to date default null,
  p_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_row public.product_hsn_classifications;
  result_row public.product_hsn_classifications;
  cleaned_code text;
  fp text;
begin
  if not app_private.can_prepare_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  if p_classification_kind not in ('hsn', 'sac') then
    raise exception 'classification kind must be hsn or sac' using errcode = '23514';
  end if;
  cleaned_code := btrim(coalesce(p_hsn_sac_code, ''));
  if cleaned_code !~ '^[0-9]{4,8}$' then
    raise exception 'HSN/SAC code must be 4 to 8 digits' using errcode = '23514';
  end if;
  if not exists (select 1 from public.products where products.id = p_product_id) then
    raise exception 'product not found' using errcode = 'P0002';
  end if;
  fp := md5(p_product_id::text || '|' || p_classification_kind || '|' || cleaned_code || '|' || coalesce(p_effective_from::text, ''));

  if p_id is not null then
    select * into current_row from public.product_hsn_classifications
    where product_hsn_classifications.id = p_id for update;
    if not found then
      raise exception 'HSN classification not found' using errcode = 'P0002';
    end if;
    if current_row.version is distinct from p_expected_version then
      raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
    end if;
    if current_row.status = 'verified' then
      update public.product_hsn_classifications
      set status = 'superseded', version = current_row.version + 1,
          superseded_at = clock_timestamp(), superseded_by = auth.uid()
      where product_hsn_classifications.id = current_row.id;
      insert into public.product_hsn_classifications (
        product_id, version, status, classification_kind, hsn_sac_code,
        effective_from, effective_to, fingerprint, created_by
      )
      values (
        p_product_id, 1, 'draft', p_classification_kind, cleaned_code,
        p_effective_from, p_effective_to, fp, auth.uid()
      )
      returning * into result_row;
    else
      update public.product_hsn_classifications
      set product_id = p_product_id,
          classification_kind = p_classification_kind,
          hsn_sac_code = cleaned_code,
          effective_from = p_effective_from,
          effective_to = p_effective_to,
          fingerprint = fp,
          status = 'draft',
          version = current_row.version + 1,
          submitted_at = null, submitted_by = null,
          verified_at = null, verified_by = null
      where product_hsn_classifications.id = current_row.id
      returning * into result_row;
    end if;
    perform app_private.append_statutory_event(
      'product_hsn', result_row.id, 'edited', current_row.status, 'draft', '{}'::jsonb
    );
  else
    if p_expected_version is distinct from 1 then
      raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
    end if;
    insert into public.product_hsn_classifications (
      product_id, version, status, classification_kind, hsn_sac_code,
      effective_from, effective_to, fingerprint, created_by
    )
    values (
      p_product_id, 1, 'draft', p_classification_kind, cleaned_code,
      p_effective_from, p_effective_to, fp, auth.uid()
    )
    returning * into result_row;
    perform app_private.append_statutory_event(
      'product_hsn', result_row.id, 'prepared', null, 'draft', '{}'::jsonb
    );
  end if;
  return to_jsonb(result_row);
end;
$$;

create or replace function public.submit_product_hsn_classification(p_id uuid, p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.product_hsn_classifications;
begin
  if not app_private.can_prepare_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  select * into header from public.product_hsn_classifications
  where product_hsn_classifications.id = p_id for update;
  if not found then
    raise exception 'HSN classification not found' using errcode = 'P0002';
  end if;
  if header.version is distinct from p_expected_version then
    raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
  end if;
  if header.status is distinct from 'draft' then
    raise exception 'only draft HSN classifications can be submitted' using errcode = '23514';
  end if;
  update public.product_hsn_classifications
  set status = 'submitted', version = header.version + 1,
      submitted_at = clock_timestamp(), submitted_by = auth.uid()
  where product_hsn_classifications.id = header.id
  returning * into header;
  perform app_private.append_statutory_event(
    'product_hsn', header.id, 'submitted', 'draft', 'submitted', '{}'::jsonb
  );
  return to_jsonb(header);
end;
$$;

create or replace function public.verify_product_hsn_classification(p_id uuid, p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.product_hsn_classifications;
begin
  if not app_private.can_verify_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  select * into header from public.product_hsn_classifications
  where product_hsn_classifications.id = p_id for update;
  if not found then
    raise exception 'HSN classification not found' using errcode = 'P0002';
  end if;
  if header.version is distinct from p_expected_version then
    raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
  end if;
  if header.status is distinct from 'submitted' then
    raise exception 'only submitted HSN classifications can be verified' using errcode = '23514';
  end if;
  update public.product_hsn_classifications
  set status = 'verified', version = header.version + 1,
      verified_at = clock_timestamp(), verified_by = auth.uid()
  where product_hsn_classifications.id = header.id
  returning * into header;
  perform app_private.append_statutory_event(
    'product_hsn', header.id, 'verified', 'submitted', 'verified', '{}'::jsonb
  );
  return to_jsonb(header);
end;
$$;

create or replace function public.list_product_hsn_classifications(p_product_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app_private.can_read_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(row) order by row.created_at desc)
    from (
      select product_hsn_classifications.*, products.sku, products.name as product_name
      from public.product_hsn_classifications
      join public.products on products.id = product_hsn_classifications.product_id
      where p_product_id is null or product_hsn_classifications.product_id = p_product_id
      order by product_hsn_classifications.created_at desc
      limit 100
    ) row
  ), '[]'::jsonb);
end;
$$;

create or replace function public.upsert_tax_rate_schedule(
  p_schedule_code text,
  p_treatment text,
  p_effective_from date,
  p_expected_version integer,
  p_hsn_sac_code text default null,
  p_cgst_rate numeric default null,
  p_sgst_rate numeric default null,
  p_igst_rate numeric default null,
  p_effective_to date default null,
  p_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_row public.tax_rate_schedules;
  result_row public.tax_rate_schedules;
  cleaned_code text;
  fp text;
begin
  if not app_private.can_prepare_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  cleaned_code := btrim(coalesce(p_schedule_code, ''));
  if cleaned_code = '' then
    raise exception 'tax schedule code is required' using errcode = '23514';
  end if;
  if p_treatment not in ('unspecified', 'intra_state', 'inter_state') then
    raise exception 'tax treatment is not valid' using errcode = '23514';
  end if;
  fp := md5(
    cleaned_code || '|' || p_treatment || '|' || coalesce(p_hsn_sac_code, '') || '|' ||
    coalesce(p_cgst_rate::text, '') || '|' || coalesce(p_sgst_rate::text, '') || '|' ||
    coalesce(p_igst_rate::text, '') || '|' || coalesce(p_effective_from::text, '')
  );

  if p_id is not null then
    select * into current_row from public.tax_rate_schedules
    where tax_rate_schedules.id = p_id for update;
    if not found then
      raise exception 'tax schedule not found' using errcode = 'P0002';
    end if;
    if current_row.version is distinct from p_expected_version then
      raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
    end if;
    if current_row.status = 'verified' then
      update public.tax_rate_schedules
      set status = 'superseded', version = current_row.version + 1,
          superseded_at = clock_timestamp(), superseded_by = auth.uid()
      where tax_rate_schedules.id = current_row.id;
      insert into public.tax_rate_schedules (
        schedule_code, version, status, hsn_sac_code, cgst_rate, sgst_rate, igst_rate,
        treatment, effective_from, effective_to, fingerprint, created_by
      )
      values (
        cleaned_code, 1, 'draft', nullif(btrim(coalesce(p_hsn_sac_code, '')), ''),
        p_cgst_rate, p_sgst_rate, p_igst_rate, p_treatment, p_effective_from, p_effective_to, fp, auth.uid()
      )
      returning * into result_row;
    else
      update public.tax_rate_schedules
      set schedule_code = cleaned_code,
          hsn_sac_code = nullif(btrim(coalesce(p_hsn_sac_code, '')), ''),
          cgst_rate = p_cgst_rate,
          sgst_rate = p_sgst_rate,
          igst_rate = p_igst_rate,
          treatment = p_treatment,
          effective_from = p_effective_from,
          effective_to = p_effective_to,
          fingerprint = fp,
          status = 'draft',
          version = current_row.version + 1,
          submitted_at = null, submitted_by = null,
          verified_at = null, verified_by = null
      where tax_rate_schedules.id = current_row.id
      returning * into result_row;
    end if;
    perform app_private.append_statutory_event(
      'tax_rate_schedule', result_row.id, 'edited', current_row.status, 'draft', '{}'::jsonb
    );
  else
    if p_expected_version is distinct from 1 then
      raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
    end if;
    insert into public.tax_rate_schedules (
      schedule_code, version, status, hsn_sac_code, cgst_rate, sgst_rate, igst_rate,
      treatment, effective_from, effective_to, fingerprint, created_by
    )
    values (
      cleaned_code, 1, 'draft', nullif(btrim(coalesce(p_hsn_sac_code, '')), ''),
      p_cgst_rate, p_sgst_rate, p_igst_rate, p_treatment, p_effective_from, p_effective_to, fp, auth.uid()
    )
    returning * into result_row;
    perform app_private.append_statutory_event(
      'tax_rate_schedule', result_row.id, 'prepared', null, 'draft', '{}'::jsonb
    );
  end if;
  return to_jsonb(result_row);
end;
$$;

create or replace function public.submit_tax_rate_schedule(p_id uuid, p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.tax_rate_schedules;
begin
  if not app_private.can_prepare_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  select * into header from public.tax_rate_schedules where tax_rate_schedules.id = p_id for update;
  if not found then
    raise exception 'tax schedule not found' using errcode = 'P0002';
  end if;
  if header.version is distinct from p_expected_version then
    raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
  end if;
  if header.status is distinct from 'draft' then
    raise exception 'only draft tax schedules can be submitted' using errcode = '23514';
  end if;
  update public.tax_rate_schedules
  set status = 'submitted', version = header.version + 1,
      submitted_at = clock_timestamp(), submitted_by = auth.uid()
  where tax_rate_schedules.id = header.id
  returning * into header;
  perform app_private.append_statutory_event(
    'tax_rate_schedule', header.id, 'submitted', 'draft', 'submitted', '{}'::jsonb
  );
  return to_jsonb(header);
end;
$$;

create or replace function public.verify_tax_rate_schedule(p_id uuid, p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.tax_rate_schedules;
begin
  if not app_private.can_verify_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  select * into header from public.tax_rate_schedules where tax_rate_schedules.id = p_id for update;
  if not found then
    raise exception 'tax schedule not found' using errcode = 'P0002';
  end if;
  if header.version is distinct from p_expected_version then
    raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
  end if;
  if header.status is distinct from 'submitted' then
    raise exception 'only submitted tax schedules can be verified' using errcode = '23514';
  end if;
  -- Explicit rates are required to verify. Zero is allowed only as an explicit value.
  if header.treatment = 'unspecified'
    or (header.cgst_rate is null and header.sgst_rate is null and header.igst_rate is null)
  then
    raise exception 'tax rates and treatment must be explicitly recorded before verification'
      using errcode = '23514';
  end if;
  update public.tax_rate_schedules
  set status = 'verified', version = header.version + 1,
      verified_at = clock_timestamp(), verified_by = auth.uid()
  where tax_rate_schedules.id = header.id
  returning * into header;
  perform app_private.append_statutory_event(
    'tax_rate_schedule', header.id, 'verified', 'submitted', 'verified', '{}'::jsonb
  );
  return to_jsonb(header);
end;
$$;

create or replace function public.list_tax_rate_schedules()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app_private.can_read_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(row) order by row.created_at desc)
    from (
      select * from public.tax_rate_schedules
      order by created_at desc
      limit 100
    ) row
  ), '[]'::jsonb);
end;
$$;

create or replace function public.upsert_statutory_policy(
  p_policy_kind text,
  p_payload jsonb,
  p_effective_from date,
  p_expected_version integer,
  p_effective_to date default null,
  p_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_row public.statutory_policies;
  result_row public.statutory_policies;
  fp text;
begin
  if not app_private.can_prepare_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  if p_policy_kind not in (
    'invoice_date', 'tax_inclusive_exclusive', 'place_of_supply',
    'gst_component', 'rounding', 'credit_note_tax', 'numbering'
  ) then
    raise exception 'statutory policy kind is not valid' using errcode = '23514';
  end if;
  fp := md5(p_policy_kind || '|' || coalesce(p_payload::text, '{}') || '|' || coalesce(p_effective_from::text, ''));

  if p_id is not null then
    select * into current_row from public.statutory_policies
    where statutory_policies.id = p_id for update;
    if not found then
      raise exception 'statutory policy not found' using errcode = 'P0002';
    end if;
    if current_row.version is distinct from p_expected_version then
      raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
    end if;
    if current_row.status = 'verified' then
      update public.statutory_policies
      set status = 'superseded', version = current_row.version + 1,
          superseded_at = clock_timestamp(), superseded_by = auth.uid()
      where statutory_policies.id = current_row.id;
      insert into public.statutory_policies (
        policy_kind, version, status, payload, effective_from, effective_to, fingerprint, created_by
      )
      values (
        p_policy_kind, 1, 'draft', coalesce(p_payload, '{}'::jsonb),
        p_effective_from, p_effective_to, fp, auth.uid()
      )
      returning * into result_row;
    else
      update public.statutory_policies
      set payload = coalesce(p_payload, '{}'::jsonb),
          effective_from = p_effective_from,
          effective_to = p_effective_to,
          fingerprint = fp,
          status = 'draft',
          version = current_row.version + 1,
          submitted_at = null, submitted_by = null,
          verified_at = null, verified_by = null
      where statutory_policies.id = current_row.id
      returning * into result_row;
    end if;
    perform app_private.append_statutory_event(
      'statutory_policy', result_row.id, 'edited', current_row.status, 'draft', '{}'::jsonb
    );
  else
    if p_expected_version is distinct from 1 then
      raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
    end if;
    insert into public.statutory_policies (
      policy_kind, version, status, payload, effective_from, effective_to, fingerprint, created_by
    )
    values (
      p_policy_kind, 1, 'draft', coalesce(p_payload, '{}'::jsonb),
      p_effective_from, p_effective_to, fp, auth.uid()
    )
    returning * into result_row;
    perform app_private.append_statutory_event(
      'statutory_policy', result_row.id, 'prepared', null, 'draft', '{}'::jsonb
    );
  end if;
  return to_jsonb(result_row);
end;
$$;

create or replace function public.submit_statutory_policy(p_id uuid, p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.statutory_policies;
begin
  if not app_private.can_prepare_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  select * into header from public.statutory_policies where statutory_policies.id = p_id for update;
  if not found then
    raise exception 'statutory policy not found' using errcode = 'P0002';
  end if;
  if header.version is distinct from p_expected_version then
    raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
  end if;
  if header.status is distinct from 'draft' then
    raise exception 'only draft statutory policies can be submitted' using errcode = '23514';
  end if;
  update public.statutory_policies
  set status = 'submitted', version = header.version + 1,
      submitted_at = clock_timestamp(), submitted_by = auth.uid()
  where statutory_policies.id = header.id
  returning * into header;
  perform app_private.append_statutory_event(
    'statutory_policy', header.id, 'submitted', 'draft', 'submitted', '{}'::jsonb
  );
  return to_jsonb(header);
end;
$$;

create or replace function public.verify_statutory_policy(p_id uuid, p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.statutory_policies;
begin
  if not app_private.can_verify_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  select * into header from public.statutory_policies where statutory_policies.id = p_id for update;
  if not found then
    raise exception 'statutory policy not found' using errcode = 'P0002';
  end if;
  if header.version is distinct from p_expected_version then
    raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
  end if;
  if header.status is distinct from 'submitted' then
    raise exception 'only submitted statutory policies can be verified' using errcode = '23514';
  end if;
  update public.statutory_policies
  set status = 'verified', version = header.version + 1,
      verified_at = clock_timestamp(), verified_by = auth.uid()
  where statutory_policies.id = header.id
  returning * into header;
  perform app_private.append_statutory_event(
    'statutory_policy', header.id, 'verified', 'submitted', 'verified', '{}'::jsonb
  );
  return to_jsonb(header);
end;
$$;

create or replace function public.list_statutory_policies()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app_private.can_read_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(row) order by row.policy_kind, row.created_at desc)
    from (
      select * from public.statutory_policies
      order by policy_kind, created_at desc
      limit 100
    ) row
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- Readiness gate: diagnostics plus a hard C.2 block. ready is always false.
-- ---------------------------------------------------------------------------

drop function if exists public.assess_invoice_finalization_readiness();

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
      'message', 'No accountant-verified tax rate schedule exists. GST is not calculated.'
    ));
  end if;

  if not exists (
    select 1 from public.statutory_policies
    where statutory_policies.policy_kind = 'tax_inclusive_exclusive'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'tax_treatment_unapproved',
      'message', 'Tax-inclusive versus exclusive treatment is unapproved (I3).'
    ));
  end if;

  if not exists (
    select 1 from public.statutory_policies
    where statutory_policies.policy_kind = 'numbering'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'numbering_policy_unapproved',
      'message', 'Financial-year invoice numbering is unapproved (I7). No statutory number is allocated.'
    ));
  end if;

  if not exists (
    select 1 from public.statutory_policies
    where statutory_policies.policy_kind = 'invoice_date'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'invoice_date_policy_unapproved',
      'message', 'Invoice date versus dispatch date rule is unapproved (I10).'
    ));
  end if;

  if not exists (
    select 1 from public.statutory_policies
    where statutory_policies.policy_kind = 'place_of_supply'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'place_of_supply_unapproved',
      'message', 'Place-of-supply determination is unapproved.'
    ));
  end if;

  if not exists (
    select 1 from public.statutory_policies
    where statutory_policies.policy_kind = 'gst_component'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'gst_component_unapproved',
      'message', 'CGST/SGST/IGST selection rule is unapproved. GST is not calculated.'
    ));
  end if;

  if not exists (
    select 1 from public.statutory_policies
    where statutory_policies.policy_kind = 'rounding'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'rounding_unapproved',
      'message', 'Invoice rounding policy is unapproved.'
    ));
  end if;

  if not exists (
    select 1 from public.statutory_policies
    where statutory_policies.policy_kind = 'credit_note_tax'
      and statutory_policies.status = 'verified'
  ) then
    blockers := blockers || jsonb_build_array(jsonb_build_object(
      'code', 'credit_note_tax_unapproved',
      'message', 'Credit-note tax treatment is unapproved. Credit notes are not issued.'
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

  -- Hard block for M7.5C.2. Configuration completeness cannot set ready true.
  blockers := blockers || jsonb_build_array(
    jsonb_build_object(
      'code', 'tax_calculation_unimplemented',
      'message', 'Validated GST calculation is not implemented. M7.5C.2 is required.'
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
      'M7.5C.2 validated tax calculation and statutory finalization are not implemented.',
    'blockers', blockers
  );
end;
$$;

-- Invoice-note payload should pass the note id into the extended gate.
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

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

revoke all on function public.upsert_statutory_seller_identity(
  text, text, text, date, integer, text, text, text, text, text, text, text, text, text, text, text, text, text, text, date, uuid
) from public, anon;
revoke all on function public.submit_statutory_seller_identity(uuid, integer) from public, anon;
revoke all on function public.verify_statutory_seller_identity(uuid, integer) from public, anon;
revoke all on function public.list_statutory_seller_identities() from public, anon;
revoke all on function public.upsert_shop_tax_identity(
  uuid, text, text, text, date, integer, text, text, text, text, date, uuid
) from public, anon;
revoke all on function public.submit_shop_tax_identity(uuid, integer) from public, anon;
revoke all on function public.verify_shop_tax_identity(uuid, integer) from public, anon;
revoke all on function public.list_shop_tax_identities(uuid) from public, anon;
revoke all on function public.upsert_product_hsn_classification(uuid, text, text, date, integer, date, uuid) from public, anon;
revoke all on function public.submit_product_hsn_classification(uuid, integer) from public, anon;
revoke all on function public.verify_product_hsn_classification(uuid, integer) from public, anon;
revoke all on function public.list_product_hsn_classifications(uuid) from public, anon;
revoke all on function public.upsert_tax_rate_schedule(text, text, date, integer, text, numeric, numeric, numeric, date, uuid) from public, anon;
revoke all on function public.submit_tax_rate_schedule(uuid, integer) from public, anon;
revoke all on function public.verify_tax_rate_schedule(uuid, integer) from public, anon;
revoke all on function public.list_tax_rate_schedules() from public, anon;
revoke all on function public.upsert_statutory_policy(text, jsonb, date, integer, date, uuid) from public, anon;
revoke all on function public.submit_statutory_policy(uuid, integer) from public, anon;
revoke all on function public.verify_statutory_policy(uuid, integer) from public, anon;
revoke all on function public.list_statutory_policies() from public, anon;
revoke all on function public.assess_invoice_finalization_readiness(uuid) from public, anon;

grant execute on function public.upsert_statutory_seller_identity(
  text, text, text, date, integer, text, text, text, text, text, text, text, text, text, text, text, text, text, text, date, uuid
) to authenticated;
grant execute on function public.submit_statutory_seller_identity(uuid, integer) to authenticated;
grant execute on function public.verify_statutory_seller_identity(uuid, integer) to authenticated;
grant execute on function public.list_statutory_seller_identities() to authenticated;
grant execute on function public.upsert_shop_tax_identity(
  uuid, text, text, text, date, integer, text, text, text, text, date, uuid
) to authenticated;
grant execute on function public.submit_shop_tax_identity(uuid, integer) to authenticated;
grant execute on function public.verify_shop_tax_identity(uuid, integer) to authenticated;
grant execute on function public.list_shop_tax_identities(uuid) to authenticated;
grant execute on function public.upsert_product_hsn_classification(uuid, text, text, date, integer, date, uuid) to authenticated;
grant execute on function public.submit_product_hsn_classification(uuid, integer) to authenticated;
grant execute on function public.verify_product_hsn_classification(uuid, integer) to authenticated;
grant execute on function public.list_product_hsn_classifications(uuid) to authenticated;
grant execute on function public.upsert_tax_rate_schedule(text, text, date, integer, text, numeric, numeric, numeric, date, uuid) to authenticated;
grant execute on function public.submit_tax_rate_schedule(uuid, integer) to authenticated;
grant execute on function public.verify_tax_rate_schedule(uuid, integer) to authenticated;
grant execute on function public.list_tax_rate_schedules() to authenticated;
grant execute on function public.upsert_statutory_policy(text, jsonb, date, integer, date, uuid) to authenticated;
grant execute on function public.submit_statutory_policy(uuid, integer) to authenticated;
grant execute on function public.verify_statutory_policy(uuid, integer) to authenticated;
grant execute on function public.list_statutory_policies() to authenticated;
grant execute on function public.assess_invoice_finalization_readiness(uuid) to authenticated;

comment on function public.assess_invoice_finalization_readiness(uuid) is
  'Structured statutory diagnostics. ready is always false until M7.5C.2. Configuration cannot bypass the block.';
comment on function public.verify_statutory_seller_identity(uuid, integer) is
  'Accountant verifier only. Existing Accounts/Admin roles are not granted this permission.';

notify pgrst, 'reload schema';
