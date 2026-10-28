-- M7.5C.1 statutory configuration foundation.
-- Local-only. Does not calculate GST, allocate statutory numbers, or finalize invoices.
-- Verifier permission is created but not granted to any existing user.

-- ---------------------------------------------------------------------------
-- Permissions and unassigned verifier role
-- ---------------------------------------------------------------------------

insert into public.roles (code, name, description)
values (
  'statutory_verifier',
  'Statutory verifier',
  'Accountant-authorized approver of statutory invoice configuration. Not assigned to existing users.'
)
on conflict (code) do nothing;

insert into public.permissions (code, description)
values
  (
    'statutory.config.prepare',
    'Prepare statutory invoice configuration drafts. Does not approve or issue tax invoices.'
  ),
  (
    'statutory.config.read',
    'Read statutory invoice configuration. Does not approve or issue tax invoices.'
  ),
  (
    'statutory.config.verify',
    'Verify statutory invoice configuration after accountant review. Does not issue tax invoices.'
  )
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code in (
  'statutory.config.prepare',
  'statutory.config.read'
)
where roles.code in ('admin', 'accounts')
on conflict do nothing;

-- Verifier permission is granted only to the unassigned statutory_verifier role.
insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code in (
  'statutory.config.read',
  'statutory.config.verify'
)
where roles.code = 'statutory_verifier'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Private signature/seal bucket (not public; bytes are not uploaded in this phase)
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'statutory-identity-assets',
  'statutory-identity-assets',
  false,
  1048576,
  array['image/png', 'image/jpeg', 'image/webp']::text[]
)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Shared writer GUC
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_statutory_write()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if current_setting('app.statutory_write', true) is distinct from 'on' then
    raise exception 'statutory configuration can only change through approved procedures'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function app_private.assert_statutory_write()
  from public, anon, authenticated, service_role;

create or replace function app_private.guard_statutory_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform app_private.assert_statutory_write();
  if tg_op = 'DELETE' then
    raise exception 'statutory configuration cannot be deleted' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function app_private.guard_statutory_write()
  from public, anon, authenticated, service_role;

create or replace function app_private.can_prepare_statutory_config()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app_private.has_permission('statutory.config.prepare');
$$;

create or replace function app_private.can_read_statutory_config()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    app_private.has_permission('statutory.config.read')
    or app_private.has_permission('statutory.config.prepare')
    or app_private.has_permission('statutory.config.verify');
$$;

create or replace function app_private.can_verify_statutory_config()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app_private.has_permission('statutory.config.verify');
$$;

revoke all on function app_private.can_prepare_statutory_config() from public, anon;
revoke all on function app_private.can_read_statutory_config() from public, anon;
revoke all on function app_private.can_verify_statutory_config() from public, anon;
grant execute on function app_private.can_prepare_statutory_config() to authenticated;
grant execute on function app_private.can_read_statutory_config() to authenticated;
grant execute on function app_private.can_verify_statutory_config() to authenticated;

create or replace function app_private.assert_valid_gstin(value text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if value is null then
    return;
  end if;
  if value !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$' then
    raise exception 'GSTIN format is not valid' using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.assert_valid_gstin(text)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Seller legal identity (versioned; not copied from the sample invoice)
-- ---------------------------------------------------------------------------

create table if not exists public.statutory_seller_identities (
  id uuid primary key default gen_random_uuid(),
  ownership_code text not null,
  version integer not null default 1,
  status text not null,
  legal_name text not null,
  registered_address text not null,
  state_name text,
  state_code text,
  gstin text,
  pan text,
  fssai_license text,
  msme_registration text,
  contact_phone text,
  contact_email text,
  bank_account_name text,
  bank_account_number text,
  bank_ifsc text,
  bank_name text,
  signature_caption text,
  seal_caption text,
  signature_storage_path text,
  seal_storage_path text,
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
  constraint statutory_seller_status_check check (
    status in ('draft', 'submitted', 'verified', 'superseded', 'cancelled')
  ),
  constraint statutory_seller_version_check check (version >= 1),
  constraint statutory_seller_window check (
    effective_to is null or effective_to >= effective_from
  ),
  constraint statutory_seller_ownership_shape check (
    char_length(btrim(ownership_code)) between 2 and 40
    and ownership_code = btrim(ownership_code)
  ),
  constraint statutory_seller_name_length check (
    char_length(btrim(legal_name)) between 1 and 200
  ),
  constraint statutory_seller_address_length check (
    char_length(btrim(registered_address)) between 1 and 500
  ),
  constraint statutory_seller_state_code_shape check (
    state_code is null or state_code ~ '^[0-9]{2}$'
  ),
  constraint statutory_seller_pan_shape check (
    pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'
  ),
  constraint statutory_seller_asset_path_shape check (
    (signature_storage_path is null or signature_storage_path ~ '^statutory-identity-assets/')
    and (seal_storage_path is null or seal_storage_path ~ '^statutory-identity-assets/')
  )
);

-- One open draft/submitted row per ownership. Multiple verified historical
-- windows are allowed only when they do not overlap.
create unique index if not exists statutory_seller_open_ownership_uidx
  on public.statutory_seller_identities (ownership_code)
  where status in ('draft', 'submitted');

-- ---------------------------------------------------------------------------
-- Customer / shop tax identity (does not overwrite shops)
-- ---------------------------------------------------------------------------

create table if not exists public.shop_tax_identities (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops (id) on delete restrict,
  version integer not null default 1,
  status text not null,
  billing_name text not null,
  billing_address text not null,
  shipping_address text,
  state_name text,
  state_code text,
  gstin text,
  registration_status text not null,
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
  constraint shop_tax_status_check check (
    status in ('draft', 'submitted', 'verified', 'superseded', 'cancelled')
  ),
  constraint shop_tax_version_check check (version >= 1),
  constraint shop_tax_window check (
    effective_to is null or effective_to >= effective_from
  ),
  constraint shop_tax_registration_check check (
    registration_status in ('unregistered', 'gst_registered', 'composition', 'unknown')
  ),
  constraint shop_tax_state_code_shape check (
    state_code is null or state_code ~ '^[0-9]{2}$'
  ),
  constraint shop_tax_gstin_required_when_registered check (
    registration_status <> 'gst_registered' or gstin is not null
  )
);

create unique index if not exists shop_tax_open_shop_uidx
  on public.shop_tax_identities (shop_id)
  where status in ('draft', 'submitted');

-- ---------------------------------------------------------------------------
-- Product HSN/SAC (no automatic classification, no tax rate)
-- ---------------------------------------------------------------------------

create table if not exists public.product_hsn_classifications (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete restrict,
  version integer not null default 1,
  status text not null,
  classification_kind text not null,
  hsn_sac_code text not null,
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
  constraint product_hsn_status_check check (
    status in ('draft', 'submitted', 'verified', 'superseded', 'cancelled')
  ),
  constraint product_hsn_kind_check check (classification_kind in ('hsn', 'sac')),
  constraint product_hsn_code_shape check (hsn_sac_code ~ '^[0-9]{4,8}$'),
  constraint product_hsn_window check (
    effective_to is null or effective_to >= effective_from
  )
);

create unique index if not exists product_hsn_open_product_uidx
  on public.product_hsn_classifications (product_id)
  where status in ('draft', 'submitted');

-- ---------------------------------------------------------------------------
-- Tax rate schedules (no default rate; CGST/SGST/IGST columns reserved)
-- ---------------------------------------------------------------------------

create table if not exists public.tax_rate_schedules (
  id uuid primary key default gen_random_uuid(),
  schedule_code text not null,
  version integer not null default 1,
  status text not null,
  hsn_sac_code text,
  cgst_rate numeric(5, 2),
  sgst_rate numeric(5, 2),
  igst_rate numeric(5, 2),
  treatment text not null,
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
  constraint tax_rate_status_check check (
    status in ('draft', 'submitted', 'verified', 'superseded', 'cancelled')
  ),
  constraint tax_rate_treatment_check check (
    treatment in ('unspecified', 'intra_state', 'inter_state')
  ),
  constraint tax_rate_window check (
    effective_to is null or effective_to >= effective_from
  ),
  constraint tax_rate_non_negative check (
    (cgst_rate is null or cgst_rate >= 0)
    and (sgst_rate is null or sgst_rate >= 0)
    and (igst_rate is null or igst_rate >= 0)
  ),
  constraint tax_rate_code_shape check (
    char_length(btrim(schedule_code)) between 2 and 40
    and schedule_code = btrim(schedule_code)
  )
);

create unique index if not exists tax_rate_open_code_uidx
  on public.tax_rate_schedules (schedule_code)
  where status in ('draft', 'submitted');

-- ---------------------------------------------------------------------------
-- Pending statutory policies (no permissive defaults)
-- ---------------------------------------------------------------------------

create table if not exists public.statutory_policies (
  id uuid primary key default gen_random_uuid(),
  policy_kind text not null,
  version integer not null default 1,
  status text not null,
  payload jsonb not null default '{}'::jsonb,
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
  constraint statutory_policy_kind_check check (
    policy_kind in (
      'invoice_date',
      'tax_inclusive_exclusive',
      'place_of_supply',
      'gst_component',
      'rounding',
      'credit_note_tax',
      'numbering'
    )
  ),
  constraint statutory_policy_status_check check (
    status in ('draft', 'submitted', 'verified', 'superseded', 'cancelled')
  ),
  constraint statutory_policy_window check (
    effective_to is null or effective_to >= effective_from
  )
);

create unique index if not exists statutory_policy_open_kind_uidx
  on public.statutory_policies (policy_kind)
  where status in ('draft', 'submitted');

create table if not exists public.statutory_config_events (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null,
  entity_id uuid not null,
  event_type text not null,
  from_status text,
  to_status text,
  payload jsonb not null default '{}'::jsonb,
  actor_id uuid not null references public.profiles (id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint statutory_config_events_type_check check (
    entity_type in (
      'seller_identity',
      'shop_tax_identity',
      'product_hsn',
      'tax_rate_schedule',
      'statutory_policy'
    )
  )
);

create index if not exists statutory_config_events_entity_idx
  on public.statutory_config_events (entity_type, entity_id, created_at);

comment on table public.statutory_seller_identities is
  'Versioned seller legal identity. Sample invoice values are not seeded. Signature/seal bytes stay out of public storage.';
comment on table public.shop_tax_identities is
  'Versioned shop tax identity. Does not overwrite shops.name/address. GSTIN is optional unless gst_registered.';
comment on table public.product_hsn_classifications is
  'Accountant-prepared HSN/SAC mapping. No automatic classification and no GST calculation.';
comment on table public.tax_rate_schedules is
  'Configurable CGST/SGST/IGST columns with no default rate. Calculation is not implemented in this phase.';
comment on table public.statutory_policies is
  'Pending invoice date, tax treatment, numbering, and related policies. Unapproved until statutory.config.verify.';
comment on table public.statutory_config_events is
  'Append-only statutory configuration history.';

-- ---------------------------------------------------------------------------
-- Overlap of verified windows (fail closed)
-- ---------------------------------------------------------------------------

create or replace function app_private.assert_statutory_seller_no_overlap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'verified'
    and exists (
      select 1
      from public.statutory_seller_identities other
      where other.ownership_code = new.ownership_code
        and other.status = 'verified'
        and other.id is distinct from new.id
        and app_private.selling_price_window(other.effective_from, other.effective_to)
          && app_private.selling_price_window(new.effective_from, new.effective_to)
    )
  then
    raise exception 'verified seller identity window overlaps another verified record'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function app_private.assert_shop_tax_no_overlap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'verified'
    and exists (
      select 1
      from public.shop_tax_identities other
      where other.shop_id = new.shop_id
        and other.status = 'verified'
        and other.id is distinct from new.id
        and app_private.selling_price_window(other.effective_from, other.effective_to)
          && app_private.selling_price_window(new.effective_from, new.effective_to)
    )
  then
    raise exception 'verified shop tax identity window overlaps another verified record'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function app_private.assert_product_hsn_no_overlap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'verified'
    and exists (
      select 1
      from public.product_hsn_classifications other
      where other.product_id = new.product_id
        and other.status = 'verified'
        and other.id is distinct from new.id
        and app_private.selling_price_window(other.effective_from, other.effective_to)
          && app_private.selling_price_window(new.effective_from, new.effective_to)
    )
  then
    raise exception 'verified HSN classification window overlaps another verified record'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function app_private.assert_tax_rate_no_overlap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'verified'
    and exists (
      select 1
      from public.tax_rate_schedules other
      where other.schedule_code = new.schedule_code
        and other.status = 'verified'
        and other.id is distinct from new.id
        and app_private.selling_price_window(other.effective_from, other.effective_to)
          && app_private.selling_price_window(new.effective_from, new.effective_to)
    )
  then
    raise exception 'verified tax schedule window overlaps another verified record'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function app_private.assert_statutory_policy_no_overlap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'verified'
    and exists (
      select 1
      from public.statutory_policies other
      where other.policy_kind = new.policy_kind
        and other.status = 'verified'
        and other.id is distinct from new.id
        and app_private.selling_price_window(other.effective_from, other.effective_to)
          && app_private.selling_price_window(new.effective_from, new.effective_to)
    )
  then
    raise exception 'verified statutory policy window overlaps another verified record'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function app_private.assert_statutory_seller_no_overlap()
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_shop_tax_no_overlap()
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_product_hsn_no_overlap()
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_tax_rate_no_overlap()
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_statutory_policy_no_overlap()
  from public, anon, authenticated, service_role;

create trigger statutory_seller_guard
  before insert or update or delete on public.statutory_seller_identities
  for each row execute function app_private.guard_statutory_write();
create trigger statutory_seller_overlap
  before insert or update on public.statutory_seller_identities
  for each row execute function app_private.assert_statutory_seller_no_overlap();
create trigger statutory_seller_updated
  before update on public.statutory_seller_identities
  for each row execute function app_private.set_updated_at();

create trigger shop_tax_guard
  before insert or update or delete on public.shop_tax_identities
  for each row execute function app_private.guard_statutory_write();
create trigger shop_tax_overlap
  before insert or update on public.shop_tax_identities
  for each row execute function app_private.assert_shop_tax_no_overlap();
create trigger shop_tax_updated
  before update on public.shop_tax_identities
  for each row execute function app_private.set_updated_at();

create trigger product_hsn_guard
  before insert or update or delete on public.product_hsn_classifications
  for each row execute function app_private.guard_statutory_write();
create trigger product_hsn_overlap
  before insert or update on public.product_hsn_classifications
  for each row execute function app_private.assert_product_hsn_no_overlap();
create trigger product_hsn_updated
  before update on public.product_hsn_classifications
  for each row execute function app_private.set_updated_at();

create trigger tax_rate_guard
  before insert or update or delete on public.tax_rate_schedules
  for each row execute function app_private.guard_statutory_write();
create trigger tax_rate_overlap
  before insert or update on public.tax_rate_schedules
  for each row execute function app_private.assert_tax_rate_no_overlap();
create trigger tax_rate_updated
  before update on public.tax_rate_schedules
  for each row execute function app_private.set_updated_at();

create trigger statutory_policy_guard
  before insert or update or delete on public.statutory_policies
  for each row execute function app_private.guard_statutory_write();
create trigger statutory_policy_overlap
  before insert or update on public.statutory_policies
  for each row execute function app_private.assert_statutory_policy_no_overlap();
create trigger statutory_policy_updated
  before update on public.statutory_policies
  for each row execute function app_private.set_updated_at();

create trigger statutory_config_events_guard
  before insert or update or delete on public.statutory_config_events
  for each row execute function app_private.guard_statutory_write();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.statutory_seller_identities enable row level security;
alter table public.statutory_seller_identities force row level security;
alter table public.shop_tax_identities enable row level security;
alter table public.shop_tax_identities force row level security;
alter table public.product_hsn_classifications enable row level security;
alter table public.product_hsn_classifications force row level security;
alter table public.tax_rate_schedules enable row level security;
alter table public.tax_rate_schedules force row level security;
alter table public.statutory_policies enable row level security;
alter table public.statutory_policies force row level security;
alter table public.statutory_config_events enable row level security;
alter table public.statutory_config_events force row level security;

create policy statutory_seller_select
  on public.statutory_seller_identities for select to authenticated
  using ((select app_private.can_read_statutory_config()));
create policy shop_tax_select
  on public.shop_tax_identities for select to authenticated
  using ((select app_private.can_read_statutory_config()));
create policy product_hsn_select
  on public.product_hsn_classifications for select to authenticated
  using ((select app_private.can_read_statutory_config()));
create policy tax_rate_select
  on public.tax_rate_schedules for select to authenticated
  using ((select app_private.can_read_statutory_config()));
create policy statutory_policy_select
  on public.statutory_policies for select to authenticated
  using ((select app_private.can_read_statutory_config()));
create policy statutory_events_select
  on public.statutory_config_events for select to authenticated
  using ((select app_private.can_read_statutory_config()));

revoke all on table public.statutory_seller_identities
  from public, anon, authenticated, service_role;
revoke all on table public.shop_tax_identities
  from public, anon, authenticated, service_role;
revoke all on table public.product_hsn_classifications
  from public, anon, authenticated, service_role;
revoke all on table public.tax_rate_schedules
  from public, anon, authenticated, service_role;
revoke all on table public.statutory_policies
  from public, anon, authenticated, service_role;
revoke all on table public.statutory_config_events
  from public, anon, authenticated, service_role;

grant select on table public.statutory_seller_identities to authenticated;
grant select on table public.shop_tax_identities to authenticated;
grant select on table public.product_hsn_classifications to authenticated;
grant select on table public.tax_rate_schedules to authenticated;
grant select on table public.statutory_policies to authenticated;
grant select on table public.statutory_config_events to authenticated;
