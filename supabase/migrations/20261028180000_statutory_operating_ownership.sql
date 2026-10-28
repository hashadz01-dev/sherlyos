-- M7.5C.2 single-company operating ownership.
-- Clients cannot invent a seller ownership_code; it must match this singleton.
-- Not a multi-tenant split. Existing C.1 rows are not rewritten.

create table if not exists public.statutory_operating_ownership (
  id uuid primary key default gen_random_uuid(),
  ownership_code text not null,
  version integer not null default 1,
  status text not null,
  effective_from date not null,
  effective_to date,
  fingerprint text not null,
  submitted_at timestamptz,
  submitted_by uuid references public.profiles (id) on delete restrict,
  verified_at timestamptz,
  verified_by uuid references public.profiles (id) on delete restrict,
  superseded_at timestamptz,
  superseded_by uuid references public.profiles (id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  created_by uuid not null references public.profiles (id) on delete restrict,
  updated_at timestamptz not null default pg_catalog.now(),
  constraint statutory_operating_status_check check (
    status in ('draft', 'submitted', 'verified', 'superseded', 'cancelled')
  ),
  constraint statutory_operating_code_shape check (
    char_length(btrim(ownership_code)) between 2 and 40
    and ownership_code = btrim(ownership_code)
  )
);

-- One open operating-ownership row for the whole application.
create unique index if not exists statutory_operating_open_uidx
  on public.statutory_operating_ownership ((true))
  where status in ('draft', 'submitted', 'verified');

alter table public.shop_tax_identities
  add column if not exists ownership_code text;
alter table public.product_hsn_classifications
  add column if not exists ownership_code text;
alter table public.tax_rate_schedules
  add column if not exists ownership_code text;
alter table public.statutory_policies
  add column if not exists ownership_code text;

create or replace function app_private.registered_operating_ownership_code()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select statutory_operating_ownership.ownership_code
  from public.statutory_operating_ownership
  where statutory_operating_ownership.status in ('draft', 'submitted', 'verified')
  order by case statutory_operating_ownership.status
    when 'verified' then 0
    when 'submitted' then 1
    else 2
  end
  limit 1;
$$;

revoke all on function app_private.registered_operating_ownership_code()
  from public, anon, authenticated, service_role;

create or replace function app_private.require_operating_ownership(p_code text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  registered text;
  cleaned text;
begin
  cleaned := btrim(coalesce(p_code, ''));
  registered := app_private.registered_operating_ownership_code();
  if registered is null then
    raise exception 'operating ownership must be registered before statutory configuration'
      using errcode = '23514';
  end if;
  if cleaned = '' then
    return registered;
  end if;
  if cleaned is distinct from registered then
    raise exception 'ownership_code does not match the registered operating ownership'
      using errcode = '42501';
  end if;
  return registered;
end;
$$;

revoke all on function app_private.require_operating_ownership(text)
  from public, anon, authenticated, service_role;

create or replace function app_private.stamp_statutory_ownership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  registered text;
begin
  registered := app_private.require_operating_ownership(coalesce(new.ownership_code, ''));
  new.ownership_code := registered;
  return new;
end;
$$;

revoke all on function app_private.stamp_statutory_ownership()
  from public, anon, authenticated, service_role;

drop trigger if exists statutory_seller_ownership_stamp on public.statutory_seller_identities;
create trigger statutory_seller_ownership_stamp
  before insert or update on public.statutory_seller_identities
  for each row execute function app_private.stamp_statutory_ownership();

drop trigger if exists shop_tax_ownership_stamp on public.shop_tax_identities;
create trigger shop_tax_ownership_stamp
  before insert or update on public.shop_tax_identities
  for each row execute function app_private.stamp_statutory_ownership();

drop trigger if exists product_hsn_ownership_stamp on public.product_hsn_classifications;
create trigger product_hsn_ownership_stamp
  before insert or update on public.product_hsn_classifications
  for each row execute function app_private.stamp_statutory_ownership();

drop trigger if exists tax_rate_ownership_stamp on public.tax_rate_schedules;
create trigger tax_rate_ownership_stamp
  before insert or update on public.tax_rate_schedules
  for each row execute function app_private.stamp_statutory_ownership();

drop trigger if exists statutory_policy_ownership_stamp on public.statutory_policies;
create trigger statutory_policy_ownership_stamp
  before insert or update on public.statutory_policies
  for each row execute function app_private.stamp_statutory_ownership();

create trigger statutory_operating_guard
  before insert or update or delete on public.statutory_operating_ownership
  for each row execute function app_private.guard_statutory_write();
create trigger statutory_operating_updated
  before update on public.statutory_operating_ownership
  for each row execute function app_private.set_updated_at();

alter table public.statutory_operating_ownership enable row level security;
alter table public.statutory_operating_ownership force row level security;

create policy statutory_operating_select
  on public.statutory_operating_ownership for select to authenticated
  using ((select app_private.can_read_statutory_config()));

revoke all on table public.statutory_operating_ownership
  from public, anon, authenticated, service_role;
grant select on table public.statutory_operating_ownership to authenticated;

create or replace function public.upsert_statutory_operating_ownership(
  p_ownership_code text,
  p_effective_from date,
  p_expected_version integer,
  p_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned text;
  current_row public.statutory_operating_ownership;
  result_row public.statutory_operating_ownership;
  fp text;
begin
  if not app_private.can_prepare_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  cleaned := btrim(coalesce(p_ownership_code, ''));
  if cleaned = '' or p_effective_from is null then
    raise exception 'operating ownership code and effective from are required'
      using errcode = '23514';
  end if;
  fp := md5(cleaned || '|' || p_effective_from::text);

  if p_id is not null then
    select * into current_row from public.statutory_operating_ownership
    where statutory_operating_ownership.id = p_id for update;
    if not found then
      raise exception 'operating ownership not found' using errcode = 'P0002';
    end if;
    if current_row.version is distinct from p_expected_version then
      raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
    end if;
    if current_row.status = 'verified' then
      update public.statutory_operating_ownership
      set status = 'superseded', version = current_row.version + 1,
          superseded_at = clock_timestamp(), superseded_by = auth.uid()
      where statutory_operating_ownership.id = current_row.id;
      insert into public.statutory_operating_ownership (
        ownership_code, version, status, effective_from, fingerprint, created_by
      )
      values (cleaned, 1, 'draft', p_effective_from, fp, auth.uid())
      returning * into result_row;
    else
      update public.statutory_operating_ownership
      set ownership_code = cleaned,
          effective_from = p_effective_from,
          fingerprint = fp,
          status = 'draft',
          version = current_row.version + 1,
          submitted_at = null, submitted_by = null,
          verified_at = null, verified_by = null
      where statutory_operating_ownership.id = current_row.id
      returning * into result_row;
    end if;
  else
    if p_expected_version is distinct from 1 then
      raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
    end if;
    insert into public.statutory_operating_ownership (
      ownership_code, version, status, effective_from, fingerprint, created_by
    )
    values (cleaned, 1, 'draft', p_effective_from, fp, auth.uid())
    returning * into result_row;
  end if;
  return to_jsonb(result_row);
end;
$$;

create or replace function public.submit_statutory_operating_ownership(
  p_id uuid,
  p_expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.statutory_operating_ownership;
begin
  if not app_private.can_prepare_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  select * into header from public.statutory_operating_ownership
  where statutory_operating_ownership.id = p_id for update;
  if not found then
    raise exception 'operating ownership not found' using errcode = 'P0002';
  end if;
  if header.version is distinct from p_expected_version then
    raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
  end if;
  if header.status is distinct from 'draft' then
    raise exception 'only draft operating ownership can be submitted' using errcode = '23514';
  end if;
  update public.statutory_operating_ownership
  set status = 'submitted', version = header.version + 1,
      submitted_at = clock_timestamp(), submitted_by = auth.uid()
  where statutory_operating_ownership.id = header.id
  returning * into header;
  return to_jsonb(header);
end;
$$;

create or replace function public.verify_statutory_operating_ownership(
  p_id uuid,
  p_expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.statutory_operating_ownership;
begin
  if not app_private.can_verify_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform set_config('app.statutory_write', 'on', true);
  select * into header from public.statutory_operating_ownership
  where statutory_operating_ownership.id = p_id for update;
  if not found then
    raise exception 'operating ownership not found' using errcode = 'P0002';
  end if;
  if header.version is distinct from p_expected_version then
    raise exception 'statutory configuration was changed by someone else' using errcode = 'PT409';
  end if;
  if header.status is distinct from 'submitted' then
    raise exception 'only submitted operating ownership can be verified' using errcode = '23514';
  end if;
  update public.statutory_operating_ownership
  set status = 'verified', version = header.version + 1,
      verified_at = clock_timestamp(), verified_by = auth.uid()
  where statutory_operating_ownership.id = header.id
  returning * into header;
  return to_jsonb(header);
end;
$$;

create or replace function public.registered_operating_ownership_code()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app_private.can_read_statutory_config() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  return app_private.registered_operating_ownership_code();
end;
$$;

create or replace function public.list_statutory_operating_ownership()
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
      select * from public.statutory_operating_ownership
      order by created_at desc
      limit 20
    ) row
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.upsert_statutory_operating_ownership(text, date, integer, uuid)
  from public, anon;
revoke all on function public.submit_statutory_operating_ownership(uuid, integer) from public, anon;
revoke all on function public.verify_statutory_operating_ownership(uuid, integer) from public, anon;
revoke all on function public.list_statutory_operating_ownership() from public, anon;
revoke all on function public.registered_operating_ownership_code() from public, anon;
grant execute on function public.upsert_statutory_operating_ownership(text, date, integer, uuid)
  to authenticated;
grant execute on function public.submit_statutory_operating_ownership(uuid, integer) to authenticated;
grant execute on function public.verify_statutory_operating_ownership(uuid, integer) to authenticated;
grant execute on function public.list_statutory_operating_ownership() to authenticated;
grant execute on function public.registered_operating_ownership_code() to authenticated;

notify pgrst, 'reload schema';
