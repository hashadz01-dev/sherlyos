-- M7.5C.2 tax-config serialization and preview integrity.
-- Locks GST preview against HSN/schedule/policy verification for one ownership.
-- Preview/get bodies in 190000 already include this lock and fail-closed shipping POS.
-- This migration upgrades verify RPCs on databases that already applied 190000.

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
  perform app_private.lock_tax_config_scope(app_private.registered_operating_ownership_code());
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
  perform app_private.lock_tax_config_scope(app_private.registered_operating_ownership_code());
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
  perform app_private.lock_tax_config_scope(app_private.registered_operating_ownership_code());
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

notify pgrst, 'reload schema';
