-- M7.5C.1 statutory configuration RPCs and extended readiness gate.
-- Does not calculate GST, consume statutory numbers, or finalize invoices.

create or replace function app_private.append_statutory_event(
  entity_type text,
  entity_id uuid,
  event_type text,
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
  insert into public.statutory_config_events (
    entity_type, entity_id, event_type, from_status, to_status, payload, actor_id
  )
  values (
    entity_type,
    entity_id,
    event_type,
    from_status,
    to_status,
    coalesce(extra, '{}'::jsonb),
    auth.uid()
  );
end;
$$;

revoke all on function app_private.append_statutory_event(text, uuid, text, text, text, jsonb)
  from public, anon, authenticated, service_role;

create or replace function app_private.seller_fingerprint(
  p_legal_name text,
  p_registered_address text,
  p_state_code text,
  p_gstin text,
  p_pan text,
  p_effective_from date,
  p_effective_to date
)
returns text
language sql
immutable
set search_path = ''
as $$
  select md5(
    coalesce(p_legal_name, '') || '|' ||
    coalesce(p_registered_address, '') || '|' ||
    coalesce(p_state_code, '') || '|' ||
    coalesce(p_gstin, '') || '|' ||
    coalesce(p_pan, '') || '|' ||
    coalesce(p_effective_from::text, '') || '|' ||
    coalesce(p_effective_to::text, '')
  );
$$;

revoke all on function app_private.seller_fingerprint(text, text, text, text, text, date, date)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Seller identity
-- ---------------------------------------------------------------------------

create or replace function public.upsert_statutory_seller_identity(
  p_ownership_code text,
  p_legal_name text,
  p_registered_address text,
  p_effective_from date,
  p_expected_version integer,
  p_state_name text default null,
  p_state_code text default null,
  p_gstin text default null,
  p_pan text default null,
  p_fssai_license text default null,
  p_msme_registration text default null,
  p_contact_phone text default null,
  p_contact_email text default null,
  p_bank_account_name text default null,
  p_bank_account_number text default null,
  p_bank_ifsc text default null,
  p_bank_name text default null,
  p_signature_caption text default null,
  p_seal_caption text default null,
  p_effective_to date default null,
  p_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_code text;
  cleaned_name text;
  cleaned_address text;
  current_row public.statutory_seller_identities;
  result_row public.statutory_seller_identities;
  fp text;
begin
  if not app_private.can_prepare_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);

  cleaned_code := btrim(coalesce(p_ownership_code, ''));
  cleaned_name := btrim(coalesce(p_legal_name, ''));
  cleaned_address := btrim(coalesce(p_registered_address, ''));
  if cleaned_code = '' or cleaned_name = '' or cleaned_address = '' or p_effective_from is null then
    raise exception 'seller legal name, address, ownership code, and effective from are required'
      using errcode = '23514';
  end if;
  perform app_private.assert_valid_gstin(nullif(btrim(coalesce(p_gstin, '')), ''));
  fp := app_private.seller_fingerprint(
    cleaned_name, cleaned_address, p_state_code,
    nullif(btrim(coalesce(p_gstin, '')), ''),
    nullif(btrim(coalesce(p_pan, '')), ''),
    p_effective_from, p_effective_to
  );

  if p_id is not null then
    select * into current_row
    from public.statutory_seller_identities
    where statutory_seller_identities.id = p_id
    for update;
    if not found then
      raise exception 'seller identity not found' using errcode = 'P0002';
    end if;
    if current_row.version is distinct from p_expected_version then
      raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
    end if;
    if current_row.status in ('superseded', 'cancelled') then
      raise exception 'seller identity is not editable' using errcode = '23514';
    end if;

    if current_row.status = 'verified' then
      update public.statutory_seller_identities
      set
        status = 'superseded',
        version = current_row.version + 1,
        superseded_at = clock_timestamp(),
        superseded_by = auth.uid()
      where statutory_seller_identities.id = current_row.id;
      perform app_private.append_statutory_event(
        'seller_identity', current_row.id, 'superseded', 'verified', 'superseded',
        jsonb_build_object('reason', 'material_edit')
      );
      insert into public.statutory_seller_identities (
        ownership_code, version, status, legal_name, registered_address, state_name, state_code,
        gstin, pan, fssai_license, msme_registration, contact_phone, contact_email,
        bank_account_name, bank_account_number, bank_ifsc, bank_name,
        signature_caption, seal_caption, effective_from, effective_to, fingerprint, created_by
      )
      values (
        cleaned_code, 1, 'draft', cleaned_name, cleaned_address,
        nullif(btrim(coalesce(p_state_name, '')), ''),
        nullif(btrim(coalesce(p_state_code, '')), ''),
        nullif(btrim(coalesce(p_gstin, '')), ''),
        nullif(btrim(coalesce(p_pan, '')), ''),
        nullif(btrim(coalesce(p_fssai_license, '')), ''),
        nullif(btrim(coalesce(p_msme_registration, '')), ''),
        nullif(btrim(coalesce(p_contact_phone, '')), ''),
        nullif(btrim(coalesce(p_contact_email, '')), ''),
        nullif(btrim(coalesce(p_bank_account_name, '')), ''),
        nullif(btrim(coalesce(p_bank_account_number, '')), ''),
        nullif(btrim(coalesce(p_bank_ifsc, '')), ''),
        nullif(btrim(coalesce(p_bank_name, '')), ''),
        nullif(btrim(coalesce(p_signature_caption, '')), ''),
        nullif(btrim(coalesce(p_seal_caption, '')), ''),
        p_effective_from, p_effective_to, fp, auth.uid()
      )
      returning * into result_row;
      perform app_private.append_statutory_event(
        'seller_identity', result_row.id, 'prepared', null, 'draft',
        jsonb_build_object('supersedes', current_row.id)
      );
    else
      update public.statutory_seller_identities
      set
        ownership_code = cleaned_code,
        legal_name = cleaned_name,
        registered_address = cleaned_address,
        state_name = nullif(btrim(coalesce(p_state_name, '')), ''),
        state_code = nullif(btrim(coalesce(p_state_code, '')), ''),
        gstin = nullif(btrim(coalesce(p_gstin, '')), ''),
        pan = nullif(btrim(coalesce(p_pan, '')), ''),
        fssai_license = nullif(btrim(coalesce(p_fssai_license, '')), ''),
        msme_registration = nullif(btrim(coalesce(p_msme_registration, '')), ''),
        contact_phone = nullif(btrim(coalesce(p_contact_phone, '')), ''),
        contact_email = nullif(btrim(coalesce(p_contact_email, '')), ''),
        bank_account_name = nullif(btrim(coalesce(p_bank_account_name, '')), ''),
        bank_account_number = nullif(btrim(coalesce(p_bank_account_number, '')), ''),
        bank_ifsc = nullif(btrim(coalesce(p_bank_ifsc, '')), ''),
        bank_name = nullif(btrim(coalesce(p_bank_name, '')), ''),
        signature_caption = nullif(btrim(coalesce(p_signature_caption, '')), ''),
        seal_caption = nullif(btrim(coalesce(p_seal_caption, '')), ''),
        effective_from = p_effective_from,
        effective_to = p_effective_to,
        fingerprint = fp,
        status = 'draft',
        version = current_row.version + 1,
        submitted_at = null,
        submitted_by = null,
        verified_at = null,
        verified_by = null
      where statutory_seller_identities.id = current_row.id
      returning * into result_row;
      perform app_private.append_statutory_event(
        'seller_identity', result_row.id, 'edited', current_row.status, 'draft',
        jsonb_build_object('invalidated_approval', current_row.status = 'submitted')
      );
    end if;
  else
    if p_expected_version is distinct from 1 then
      raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
    end if;
    insert into public.statutory_seller_identities (
      ownership_code, version, status, legal_name, registered_address, state_name, state_code,
      gstin, pan, fssai_license, msme_registration, contact_phone, contact_email,
      bank_account_name, bank_account_number, bank_ifsc, bank_name,
      signature_caption, seal_caption, effective_from, effective_to, fingerprint, created_by
    )
    values (
      cleaned_code, 1, 'draft', cleaned_name, cleaned_address,
      nullif(btrim(coalesce(p_state_name, '')), ''),
      nullif(btrim(coalesce(p_state_code, '')), ''),
      nullif(btrim(coalesce(p_gstin, '')), ''),
      nullif(btrim(coalesce(p_pan, '')), ''),
      nullif(btrim(coalesce(p_fssai_license, '')), ''),
      nullif(btrim(coalesce(p_msme_registration, '')), ''),
      nullif(btrim(coalesce(p_contact_phone, '')), ''),
      nullif(btrim(coalesce(p_contact_email, '')), ''),
      nullif(btrim(coalesce(p_bank_account_name, '')), ''),
      nullif(btrim(coalesce(p_bank_account_number, '')), ''),
      nullif(btrim(coalesce(p_bank_ifsc, '')), ''),
      nullif(btrim(coalesce(p_bank_name, '')), ''),
      nullif(btrim(coalesce(p_signature_caption, '')), ''),
      nullif(btrim(coalesce(p_seal_caption, '')), ''),
      p_effective_from, p_effective_to, fp, auth.uid()
    )
    returning * into result_row;
    perform app_private.append_statutory_event(
      'seller_identity', result_row.id, 'prepared', null, 'draft', '{}'::jsonb
    );
  end if;

  perform app_private.write_audit(
    auth.uid(), 'upsert_statutory_seller_identity', 'statutory_seller_identities',
    result_row.id, jsonb_build_object('ownership_code', result_row.ownership_code)
  );
  return to_jsonb(result_row);
end;
$$;

create or replace function public.submit_statutory_seller_identity(
  p_id uuid,
  p_expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.statutory_seller_identities;
begin
  if not app_private.can_prepare_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);

  select * into header from public.statutory_seller_identities
  where statutory_seller_identities.id = p_id for update;
  if not found then
    raise exception 'seller identity not found' using errcode = 'P0002';
  end if;
  if header.version is distinct from p_expected_version then
    raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
  end if;
  if header.status is distinct from 'draft' then
    raise exception 'only draft seller identities can be submitted' using errcode = '23514';
  end if;
  if header.gstin is null then
    raise exception 'seller GSTIN is required before submission' using errcode = '23514';
  end if;

  update public.statutory_seller_identities
  set status = 'submitted', version = header.version + 1,
      submitted_at = clock_timestamp(), submitted_by = auth.uid()
  where statutory_seller_identities.id = header.id
  returning * into header;

  perform app_private.append_statutory_event(
    'seller_identity', header.id, 'submitted', 'draft', 'submitted', '{}'::jsonb
  );
  return to_jsonb(header);
end;
$$;

create or replace function public.verify_statutory_seller_identity(
  p_id uuid,
  p_expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.statutory_seller_identities;
begin
  if not app_private.can_verify_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);

  select * into header from public.statutory_seller_identities
  where statutory_seller_identities.id = p_id for update;
  if not found then
    raise exception 'seller identity not found' using errcode = 'P0002';
  end if;
  if header.version is distinct from p_expected_version then
    raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
  end if;
  if header.status is distinct from 'submitted' then
    raise exception 'only submitted seller identities can be verified' using errcode = '23514';
  end if;

  update public.statutory_seller_identities
  set status = 'verified', version = header.version + 1,
      verified_at = clock_timestamp(), verified_by = auth.uid()
  where statutory_seller_identities.id = header.id
  returning * into header;

  perform app_private.append_statutory_event(
    'seller_identity', header.id, 'verified', 'submitted', 'verified', '{}'::jsonb
  );
  return to_jsonb(header);
end;
$$;

create or replace function public.list_statutory_seller_identities()
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
      select * from public.statutory_seller_identities
      order by created_at desc
      limit 100
    ) row
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- Shop tax identity
-- ---------------------------------------------------------------------------

create or replace function public.upsert_shop_tax_identity(
  p_shop_id uuid,
  p_billing_name text,
  p_billing_address text,
  p_registration_status text,
  p_effective_from date,
  p_expected_version integer,
  p_shipping_address text default null,
  p_state_name text default null,
  p_state_code text default null,
  p_gstin text default null,
  p_effective_to date default null,
  p_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_row public.shop_tax_identities;
  result_row public.shop_tax_identities;
  cleaned_gstin text;
  fp text;
begin
  if not app_private.can_prepare_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  if p_registration_status not in ('unregistered', 'gst_registered', 'composition', 'unknown') then
    raise exception 'shop registration status is not valid' using errcode = '23514';
  end if;
  if btrim(coalesce(p_billing_name, '')) = '' or btrim(coalesce(p_billing_address, '')) = '' then
    raise exception 'billing name and address are required' using errcode = '23514';
  end if;
  cleaned_gstin := nullif(btrim(coalesce(p_gstin, '')), '');
  perform app_private.assert_valid_gstin(cleaned_gstin);
  if p_registration_status = 'gst_registered' and cleaned_gstin is null then
    raise exception 'GSTIN is required for a GST-registered shop' using errcode = '23514';
  end if;
  if not exists (select 1 from public.shops where shops.id = p_shop_id) then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;

  fp := md5(
    p_shop_id::text || '|' || btrim(p_billing_name) || '|' || btrim(p_billing_address) || '|' ||
    p_registration_status || '|' || coalesce(cleaned_gstin, '') || '|' ||
    coalesce(p_effective_from::text, '')
  );

  if p_id is not null then
    select * into current_row from public.shop_tax_identities
    where shop_tax_identities.id = p_id for update;
    if not found then
      raise exception 'shop tax identity not found' using errcode = 'P0002';
    end if;
    if current_row.version is distinct from p_expected_version then
      raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
    end if;
    if current_row.status = 'verified' then
      update public.shop_tax_identities
      set status = 'superseded', version = current_row.version + 1,
          superseded_at = clock_timestamp(), superseded_by = auth.uid()
      where shop_tax_identities.id = current_row.id;
      insert into public.shop_tax_identities (
        shop_id, version, status, billing_name, billing_address, shipping_address,
        state_name, state_code, gstin, registration_status, effective_from, effective_to,
        fingerprint, created_by
      )
      values (
        p_shop_id, 1, 'draft', btrim(p_billing_name), btrim(p_billing_address),
        nullif(btrim(coalesce(p_shipping_address, '')), ''),
        nullif(btrim(coalesce(p_state_name, '')), ''),
        nullif(btrim(coalesce(p_state_code, '')), ''),
        cleaned_gstin, p_registration_status, p_effective_from, p_effective_to, fp, auth.uid()
      )
      returning * into result_row;
      perform app_private.append_statutory_event(
        'shop_tax_identity', result_row.id, 'prepared', null, 'draft',
        jsonb_build_object('supersedes', current_row.id)
      );
    else
      update public.shop_tax_identities
      set shop_id = p_shop_id,
          billing_name = btrim(p_billing_name),
          billing_address = btrim(p_billing_address),
          shipping_address = nullif(btrim(coalesce(p_shipping_address, '')), ''),
          state_name = nullif(btrim(coalesce(p_state_name, '')), ''),
          state_code = nullif(btrim(coalesce(p_state_code, '')), ''),
          gstin = cleaned_gstin,
          registration_status = p_registration_status,
          effective_from = p_effective_from,
          effective_to = p_effective_to,
          fingerprint = fp,
          status = 'draft',
          version = current_row.version + 1,
          submitted_at = null, submitted_by = null,
          verified_at = null, verified_by = null
      where shop_tax_identities.id = current_row.id
      returning * into result_row;
      perform app_private.append_statutory_event(
        'shop_tax_identity', result_row.id, 'edited', current_row.status, 'draft', '{}'::jsonb
      );
    end if;
  else
    if p_expected_version is distinct from 1 then
      raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
    end if;
    insert into public.shop_tax_identities (
      shop_id, version, status, billing_name, billing_address, shipping_address,
      state_name, state_code, gstin, registration_status, effective_from, effective_to,
      fingerprint, created_by
    )
    values (
      p_shop_id, 1, 'draft', btrim(p_billing_name), btrim(p_billing_address),
      nullif(btrim(coalesce(p_shipping_address, '')), ''),
      nullif(btrim(coalesce(p_state_name, '')), ''),
      nullif(btrim(coalesce(p_state_code, '')), ''),
      cleaned_gstin, p_registration_status, p_effective_from, p_effective_to, fp, auth.uid()
    )
    returning * into result_row;
    perform app_private.append_statutory_event(
      'shop_tax_identity', result_row.id, 'prepared', null, 'draft', '{}'::jsonb
    );
  end if;
  return to_jsonb(result_row);
end;
$$;

create or replace function public.submit_shop_tax_identity(p_id uuid, p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.shop_tax_identities;
begin
  if not app_private.can_prepare_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  select * into header from public.shop_tax_identities where shop_tax_identities.id = p_id for update;
  if not found then
    raise exception 'shop tax identity not found' using errcode = 'P0002';
  end if;
  if header.version is distinct from p_expected_version then
    raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
  end if;
  if header.status is distinct from 'draft' then
    raise exception 'only draft shop tax identities can be submitted' using errcode = '23514';
  end if;
  update public.shop_tax_identities
  set status = 'submitted', version = header.version + 1,
      submitted_at = clock_timestamp(), submitted_by = auth.uid()
  where shop_tax_identities.id = header.id
  returning * into header;
  perform app_private.append_statutory_event(
    'shop_tax_identity', header.id, 'submitted', 'draft', 'submitted', '{}'::jsonb
  );
  return to_jsonb(header);
end;
$$;

create or replace function public.verify_shop_tax_identity(p_id uuid, p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.shop_tax_identities;
begin
  if not app_private.can_verify_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  select * into header from public.shop_tax_identities where shop_tax_identities.id = p_id for update;
  if not found then
    raise exception 'shop tax identity not found' using errcode = 'P0002';
  end if;
  if header.version is distinct from p_expected_version then
    raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
  end if;
  if header.status is distinct from 'submitted' then
    raise exception 'only submitted shop tax identities can be verified' using errcode = '23514';
  end if;
  update public.shop_tax_identities
  set status = 'verified', version = header.version + 1,
      verified_at = clock_timestamp(), verified_by = auth.uid()
  where shop_tax_identities.id = header.id
  returning * into header;
  perform app_private.append_statutory_event(
    'shop_tax_identity', header.id, 'verified', 'submitted', 'verified', '{}'::jsonb
  );
  return to_jsonb(header);
end;
$$;

create or replace function public.list_shop_tax_identities(p_shop_id uuid default null)
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
      select shop_tax_identities.*, shops.name as shop_name
      from public.shop_tax_identities
      join public.shops on shops.id = shop_tax_identities.shop_id
      where p_shop_id is null or shop_tax_identities.shop_id = p_shop_id
      order by shop_tax_identities.created_at desc
      limit 100
    ) row
  ), '[]'::jsonb);
end;
$$;
