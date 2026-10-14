-- SherlysOS access-control foundation.
-- Drafted for review. Do not apply this file to the remote project until it is accepted.
-- It does not create orders, stock, deliveries, receiving, damage, verification, or refill tables.

create schema if not exists app_private;

revoke all on schema app_private from public;
revoke all on schema app_private from anon;
grant usage on schema app_private to authenticated;

create or replace function app_private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = pg_catalog.now();
  return new;
end;
$$;

revoke all on function app_private.set_updated_at() from public;
revoke all on function app_private.set_updated_at() from anon, authenticated;

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null default '',
  employee_code text,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint profiles_full_name_length check (char_length(full_name) <= 160),
  constraint profiles_employee_code_shape check (
    employee_code is null
    or (
      char_length(btrim(employee_code)) between 1 and 40
      and employee_code = btrim(employee_code)
    )
  )
);

create unique index profiles_employee_code_key
  on public.profiles (lower(employee_code))
  where employee_code is not null;

create index profiles_is_active_idx on public.profiles (is_active);

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function app_private.set_updated_at();

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name text not null,
  description text not null,
  created_at timestamptz not null default pg_catalog.now(),
  constraint roles_code_key unique (code),
  constraint roles_name_key unique (name),
  constraint roles_code_shape check (code ~ '^[a-z0-9_]+$')
);

create table public.permissions (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  description text not null,
  created_at timestamptz not null default pg_catalog.now(),
  constraint permissions_code_key unique (code),
  constraint permissions_code_shape check (code ~ '^[a-z0-9_.]+$')
);

create table public.role_permissions (
  role_id uuid not null references public.roles (id) on delete restrict,
  permission_id uuid not null references public.permissions (id) on delete restrict,
  created_at timestamptz not null default pg_catalog.now(),
  primary key (role_id, permission_id)
);

create index role_permissions_permission_id_idx
  on public.role_permissions (permission_id);

create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  role_id uuid not null references public.roles (id) on delete restrict,
  assigned_by uuid,
  created_at timestamptz not null default pg_catalog.now(),
  constraint user_roles_user_role_key unique (user_id, role_id)
);

create index user_roles_role_id_idx on public.user_roles (role_id);

create table public.branches (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint branches_code_key unique (code),
  constraint branches_code_shape check (code ~ '^[a-z0-9_]+$'),
  constraint branches_name_length check (char_length(btrim(name)) between 1 and 160)
);

create index branches_is_active_idx on public.branches (is_active);

create trigger branches_set_updated_at
  before update on public.branches
  for each row execute function app_private.set_updated_at();

create table public.user_branch_assignments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  branch_id uuid not null references public.branches (id) on delete restrict,
  assigned_by uuid,
  created_at timestamptz not null default pg_catalog.now(),
  constraint user_branch_assignments_user_branch_key unique (user_id, branch_id)
);

create index user_branch_assignments_branch_id_idx
  on public.user_branch_assignments (branch_id);

create table public.app_configuration (
  key text primary key,
  value jsonb not null,
  description text not null,
  updated_at timestamptz not null default pg_catalog.now(),
  constraint app_configuration_key_shape check (key ~ '^[a-z0-9_.]+$')
);

create trigger app_configuration_set_updated_at
  before update on public.app_configuration
  for each row execute function app_private.set_updated_at();

comment on table public.app_configuration is
  'Configurable business-rule thresholds. Values are proposals until formally approved. Not an inventory ledger.';

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  occurred_at timestamptz not null default pg_catalog.now(),
  actor_id uuid,
  action text not null,
  entity_table text not null,
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  constraint audit_logs_action_length check (char_length(btrim(action)) between 1 and 80),
  constraint audit_logs_entity_table_length check (char_length(btrim(entity_table)) between 1 and 80)
);

create index audit_logs_occurred_at_idx on public.audit_logs (occurred_at desc);
create index audit_logs_entity_idx on public.audit_logs (entity_table, entity_id);
create index audit_logs_actor_id_idx on public.audit_logs (actor_id);

comment on table public.profiles is
  'Employee profile for one Supabase Auth user. A new profile receives no role.';

comment on column public.profiles.is_active is
  'Privileged employment status. A person cannot change this on their own row.';

comment on table public.roles is
  'The six Sherlys job roles. Labels live here. What a role may do lives in permissions.';

comment on table public.branches is
  'Operating sites, such as a godown location. BPM Branch 01 through Branch 05 are workflows and must not be inserted here.';

comment on table public.user_roles is
  'Organization-wide role membership. Branch scope is user_branch_assignments, not a column on this table.';

comment on table public.audit_logs is
  'Append-only security history. actor_id is a copied user id with no foreign key, so deleting a profile cannot rewrite the log.';

insert into public.roles (code, name, description)
values
  (
    'admin',
    'Admin',
    'Monitors all modules and activities and approves stock refill requests.'
  ),
  (
    'accounts',
    'Accounts',
    'Verifies shop orders, prepares billing documentation and stock refill requests.'
  ),
  (
    'godown_manager',
    'Godown Manager',
    'Owns daily stock verification, godown picking, receiving verification, delivery assignment, and authorized stock adjustments.'
  ),
  (
    'salesperson',
    'Salesperson',
    'Sells products to shops, develops new shops and expands the distribution network.'
  ),
  (
    'delivery_person',
    'Delivery Person',
    'Delivers requested products correctly to shops with the relevant invoice and documentation.'
  ),
  (
    'store_keeper',
    'Store Keeper',
    'Handles stock receiving, physical counts, allocations, damage separation and loading support.'
  );

insert into public.permissions (code, description)
values
  ('employees.read', 'View employee profiles, role membership, and branch assignments.'),
  ('employees.manage', 'Maintain another employee profile and active status.'),
  ('roles.assign', 'Grant or revoke another person''s role.'),
  ('branches.manage', 'Create an operating site and change its active status.'),
  ('branches.access_all', 'Work across every operating site without a personal assignment.'),
  ('assignments.manage', 'Assign another person to an operating site or remove that assignment.'),
  ('audit.read', 'Read the security audit log.'),
  ('operations.monitor', 'View operational activity across modules once those modules exist.'),
  ('orders.capture', 'Record a shop order request.'),
  ('orders.verify', 'Verify a shop order and hold an invalid request.'),
  ('delivery_notes.issue', 'Generate a delivery note for an approved order.'),
  ('invoices.issue', 'Create, sign, and hand over the final invoice.'),
  ('invoice_notes.prepare', 'Prepare the invoice note from goods actually loaded.'),
  ('picking.execute', 'Pick goods using expiry and receipt order.'),
  ('deliveries.assign', 'Assign a vehicle and delivery person.'),
  ('deliveries.execute', 'Deliver requested products to a shop and record the outcome.'),
  ('receiving.execute', 'Count supplier goods, separate damage, and allocate accepted cases.'),
  ('receiving.verify', 'Verify a receipt and its godown, zone, and crate allocation.'),
  ('damage.record', 'Record damaged goods and keep them unavailable until disposition.'),
  ('loading.assist', 'Support loading and separate goods damaged while loading.'),
  (
    'stock.verify',
    'Own the daily stock verification workflow: scope, physical count, mismatch review, snapshot, and initiating adjustment.'
  ),
  (
    'stock.count_assist',
    'Assist with physical counting during verification or receiving when assigned to the site. Does not own verification.'
  ),
  (
    'stock.discrepancy.report',
    'Report a counted mismatch and supporting evidence without posting a balance change.'
  ),
  (
    'stock.adjustment.request',
    'Create a stock adjustment request with reason and reference to verification or investigation.'
  ),
  (
    'stock.adjustment.post',
    'Post a routine authorized adjustment through the controlled database workflow. Never updates balances directly.'
  ),
  (
    'stock.adjustment.approve_exceptional',
    'Approve an adjustment that exceeds configured exceptional thresholds before it may be posted.'
  ),
  ('refill.request', 'Prepare and submit a brand-specific refill request.'),
  ('refill.approve', 'Approve, hold, or reject a refill request.'),
  ('shops.develop', 'Develop shop relationships and the distribution network.');

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from (
  values
    ('admin', 'employees.read'),
    ('admin', 'employees.manage'),
    ('admin', 'roles.assign'),
    ('admin', 'branches.manage'),
    ('admin', 'branches.access_all'),
    ('admin', 'assignments.manage'),
    ('admin', 'audit.read'),
    ('admin', 'operations.monitor'),
    ('admin', 'refill.approve'),
    ('accounts', 'orders.capture'),
    ('accounts', 'orders.verify'),
    ('accounts', 'delivery_notes.issue'),
    ('accounts', 'invoices.issue'),
    ('accounts', 'refill.request'),
    ('godown_manager', 'picking.execute'),
    ('godown_manager', 'deliveries.assign'),
    ('godown_manager', 'invoice_notes.prepare'),
    ('godown_manager', 'receiving.verify'),
    ('godown_manager', 'stock.verify'),
    ('godown_manager', 'stock.discrepancy.report'),
    ('godown_manager', 'stock.adjustment.request'),
    ('godown_manager', 'stock.adjustment.post'),
    ('godown_manager', 'damage.record'),
    ('admin', 'stock.adjustment.approve_exceptional'),
    ('salesperson', 'orders.capture'),
    ('salesperson', 'shops.develop'),
    ('delivery_person', 'deliveries.execute'),
    ('store_keeper', 'receiving.execute'),
    ('store_keeper', 'damage.record'),
    ('store_keeper', 'stock.count_assist'),
    ('store_keeper', 'loading.assist')
) as grants (role_code, permission_code)
join public.roles on roles.code = grants.role_code
join public.permissions on permissions.code = grants.permission_code;

insert into public.app_configuration (key, value, description)
values
  (
    'stock.adjustment.exceptional_absolute_units',
    '50'::jsonb,
    'Provisional placeholder only — not an approved business rule. Replace after formal sign-off.'
  ),
  (
    'stock.adjustment.exceptional_requires_admin',
    'true'::jsonb,
    'When true, exceptional adjustments require stock.adjustment.approve_exceptional before a Godown Manager may post.'
  );

create or replace function app_private.has_permission(requested_code text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_roles
    join public.role_permissions
      on role_permissions.role_id = user_roles.role_id
    join public.permissions
      on permissions.id = role_permissions.permission_id
    join public.profiles
      on profiles.id = user_roles.user_id
    where user_roles.user_id = auth.uid()
      and permissions.code = requested_code
      and profiles.is_active
  );
$$;

create or replace function app_private.can_work_at_branch(target_branch uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    app_private.has_permission('branches.access_all')
    or exists (
      select 1
      from public.user_branch_assignments
      join public.branches on branches.id = user_branch_assignments.branch_id
      where user_branch_assignments.user_id = auth.uid()
        and user_branch_assignments.branch_id = target_branch
        and branches.is_active
    );
$$;

revoke all on function app_private.can_work_at_branch(uuid) from public;
revoke all on function app_private.can_work_at_branch(uuid) from anon;
grant execute on function app_private.can_work_at_branch(uuid) to authenticated;

create or replace function app_private.write_audit(
  actor uuid,
  action_name text,
  target_table text,
  target_id uuid,
  details jsonb
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_logs (actor_id, action, entity_table, entity_id, metadata)
  values (actor, action_name, target_table, target_id, coalesce(details, '{}'::jsonb));
$$;

create or replace function app_private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

create or replace function app_private.bootstrap_initial_admin(
  target_user uuid,
  confirmation text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin_role uuid;
begin
  if confirmation is distinct from 'create-initial-administrator' then
    raise exception 'initial administrator bootstrap was not confirmed'
      using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.user_roles
    join public.roles on roles.id = user_roles.role_id
    where roles.code = 'admin'
  ) then
    raise exception 'initial administrator already exists'
      using errcode = '42501';
  end if;

  if not exists (select 1 from public.profiles where profiles.id = target_user) then
    raise exception 'employee profile not found'
      using errcode = '42501';
  end if;

  select roles.id
  into admin_role
  from public.roles
  where roles.code = 'admin';

  insert into public.user_roles (user_id, role_id, assigned_by)
  values (target_user, admin_role, null);

  perform app_private.write_audit(
    null,
    'bootstrap_initial_admin',
    'user_roles',
    target_user,
    jsonb_build_object('role', 'admin')
  );
end;
$$;

revoke all on function app_private.has_permission(text) from public;
revoke all on function app_private.has_permission(text) from anon;
grant execute on function app_private.has_permission(text) to authenticated;

revoke all on function app_private.write_audit(uuid, text, text, uuid, jsonb) from public;
revoke all on function app_private.write_audit(uuid, text, text, uuid, jsonb) from anon, authenticated, service_role;

revoke all on function app_private.handle_new_user() from public;
revoke all on function app_private.handle_new_user() from anon, authenticated, service_role;

revoke all on function app_private.bootstrap_initial_admin(uuid, text) from public;
revoke all on function app_private.bootstrap_initial_admin(uuid, text) from anon, authenticated;
grant execute on function app_private.bootstrap_initial_admin(uuid, text) to service_role;

create or replace function public.assign_user_role(target_user uuid, role_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_role uuid;
begin
  if auth.uid() is null or not app_private.has_permission('roles.assign') then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if target_user = auth.uid() then
    raise exception 'you cannot change your own roles' using errcode = '42501';
  end if;

  if not exists (select 1 from public.profiles where profiles.id = target_user) then
    raise exception 'employee profile not found' using errcode = '42501';
  end if;

  select roles.id
  into selected_role
  from public.roles
  where roles.code = role_code;

  if selected_role is null then
    raise exception 'unknown role' using errcode = '42501';
  end if;

  insert into public.user_roles (user_id, role_id, assigned_by)
  values (target_user, selected_role, auth.uid())
  on conflict (user_id, role_id) do nothing;

  perform app_private.write_audit(
    auth.uid(),
    'assign_user_role',
    'user_roles',
    target_user,
    jsonb_build_object('role', role_code)
  );
end;
$$;

create or replace function public.revoke_user_role(target_user uuid, role_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_role uuid;
begin
  if auth.uid() is null or not app_private.has_permission('roles.assign') then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if target_user = auth.uid() then
    raise exception 'you cannot change your own roles' using errcode = '42501';
  end if;

  select roles.id
  into selected_role
  from public.roles
  where roles.code = role_code;

  if selected_role is null then
    raise exception 'unknown role' using errcode = '42501';
  end if;

  delete from public.user_roles
  where user_roles.user_id = target_user
    and user_roles.role_id = selected_role;

  perform app_private.write_audit(
    auth.uid(),
    'revoke_user_role',
    'user_roles',
    target_user,
    jsonb_build_object('role', role_code)
  );
end;
$$;

create or replace function public.set_employee_active(target_user uuid, active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not app_private.has_permission('employees.manage') then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if target_user = auth.uid() then
    raise exception 'you cannot change your own active status' using errcode = '42501';
  end if;

  update public.profiles
  set is_active = active
  where profiles.id = target_user;

  if not found then
    raise exception 'employee profile not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'set_employee_active',
    'profiles',
    target_user,
    jsonb_build_object('is_active', active)
  );
end;
$$;

create or replace function public.update_employee_profile(
  target_user uuid,
  next_full_name text,
  next_employee_code text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not app_private.has_permission('employees.manage') then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if target_user = auth.uid() then
    raise exception 'you cannot administer your own profile' using errcode = '42501';
  end if;

  update public.profiles
  set
    full_name = coalesce(next_full_name, ''),
    employee_code = nullif(btrim(next_employee_code), '')
  where profiles.id = target_user;

  if not found then
    raise exception 'employee profile not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'update_employee_profile',
    'profiles',
    target_user,
    jsonb_build_object('employee_code', nullif(btrim(next_employee_code), ''))
  );
end;
$$;

create or replace function public.update_own_profile(next_full_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  update public.profiles
  set full_name = coalesce(next_full_name, '')
  where profiles.id = auth.uid()
    and profiles.is_active;

  if not found then
    raise exception 'employee profile not found' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.create_branch(branch_code text, branch_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
  cleaned_code text := lower(btrim(branch_code));
begin
  if auth.uid() is null or not app_private.has_permission('branches.manage') then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  insert into public.branches (code, name)
  values (cleaned_code, btrim(branch_name))
  returning id into created_id;

  perform app_private.write_audit(
    auth.uid(),
    'create_branch',
    'branches',
    created_id,
    jsonb_build_object('code', cleaned_code)
  );

  return created_id;
end;
$$;

create or replace function public.set_branch_active(target_branch uuid, active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not app_private.has_permission('branches.manage') then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  update public.branches
  set is_active = active
  where branches.id = target_branch;

  if not found then
    raise exception 'branch not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'set_branch_active',
    'branches',
    target_branch,
    jsonb_build_object('is_active', active)
  );
end;
$$;

create or replace function public.assign_user_branch(target_user uuid, target_branch uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not app_private.has_permission('assignments.manage') then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if target_user = auth.uid() then
    raise exception 'you cannot change your own branch assignments' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.branches
    where branches.id = target_branch
      and branches.is_active
  ) then
    raise exception 'branch not found or inactive' using errcode = '42501';
  end if;

  insert into public.user_branch_assignments (user_id, branch_id, assigned_by)
  values (target_user, target_branch, auth.uid())
  on conflict (user_id, branch_id) do nothing;

  perform app_private.write_audit(
    auth.uid(),
    'assign_user_branch',
    'user_branch_assignments',
    target_user,
    jsonb_build_object('branch_id', target_branch)
  );
end;
$$;

create or replace function public.revoke_user_branch(target_user uuid, target_branch uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not app_private.has_permission('assignments.manage') then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if target_user = auth.uid() then
    raise exception 'you cannot change your own branch assignments' using errcode = '42501';
  end if;

  delete from public.user_branch_assignments
  where user_branch_assignments.user_id = target_user
    and user_branch_assignments.branch_id = target_branch;

  perform app_private.write_audit(
    auth.uid(),
    'revoke_user_branch',
    'user_branch_assignments',
    target_user,
    jsonb_build_object('branch_id', target_branch)
  );
end;
$$;

revoke all on function public.assign_user_role(uuid, text) from public, anon;
revoke all on function public.revoke_user_role(uuid, text) from public, anon;
revoke all on function public.set_employee_active(uuid, boolean) from public, anon;
revoke all on function public.update_employee_profile(uuid, text, text) from public, anon;
revoke all on function public.update_own_profile(text) from public, anon;
revoke all on function public.create_branch(text, text) from public, anon;
revoke all on function public.set_branch_active(uuid, boolean) from public, anon;
revoke all on function public.assign_user_branch(uuid, uuid) from public, anon;
revoke all on function public.revoke_user_branch(uuid, uuid) from public, anon;

grant execute on function public.assign_user_role(uuid, text) to authenticated;
grant execute on function public.revoke_user_role(uuid, text) to authenticated;
grant execute on function public.set_employee_active(uuid, boolean) to authenticated;
grant execute on function public.update_employee_profile(uuid, text, text) to authenticated;
grant execute on function public.update_own_profile(text) to authenticated;
grant execute on function public.create_branch(text, text) to authenticated;
grant execute on function public.set_branch_active(uuid, boolean) to authenticated;
grant execute on function public.assign_user_branch(uuid, uuid) to authenticated;
grant execute on function public.revoke_user_branch(uuid, uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.roles enable row level security;
alter table public.permissions enable row level security;
alter table public.role_permissions enable row level security;
alter table public.user_roles enable row level security;
alter table public.branches enable row level security;
alter table public.user_branch_assignments enable row level security;
alter table public.app_configuration enable row level security;
alter table public.audit_logs enable row level security;

alter table public.profiles force row level security;
alter table public.roles force row level security;
alter table public.permissions force row level security;
alter table public.role_permissions force row level security;
alter table public.user_roles force row level security;
alter table public.branches force row level security;
alter table public.user_branch_assignments force row level security;
alter table public.app_configuration force row level security;
alter table public.audit_logs force row level security;

create policy profiles_select_own_or_staff
  on public.profiles
  for select
  to authenticated
  using (
    id = (select auth.uid())
    or (select app_private.has_permission('employees.read'))
  );

create policy roles_select_catalog
  on public.roles
  for select
  to authenticated
  using (true);

create policy permissions_select_catalog
  on public.permissions
  for select
  to authenticated
  using (true);

create policy role_permissions_select_own_role_or_staff
  on public.role_permissions
  for select
  to authenticated
  using (
    (select app_private.has_permission('employees.read'))
    or exists (
      select 1
      from public.user_roles
      where user_roles.user_id = (select auth.uid())
        and user_roles.role_id = role_permissions.role_id
    )
  );

create policy user_roles_select_own_or_staff
  on public.user_roles
  for select
  to authenticated
  using (
    user_id = (select auth.uid())
    or (select app_private.has_permission('employees.read'))
  );

create policy branches_select_assigned_or_all
  on public.branches
  for select
  to authenticated
  using (
    (select app_private.has_permission('branches.access_all'))
    or (select app_private.has_permission('employees.read'))
    or exists (
      select 1
      from public.user_branch_assignments
      where user_branch_assignments.user_id = (select auth.uid())
        and user_branch_assignments.branch_id = branches.id
    )
  );

create policy user_branch_assignments_select_own_or_staff
  on public.user_branch_assignments
  for select
  to authenticated
  using (
    user_id = (select auth.uid())
    or (select app_private.has_permission('employees.read'))
    or (select app_private.has_permission('branches.access_all'))
  );

create policy audit_logs_select_auditors
  on public.audit_logs
  for select
  to authenticated
  using ((select app_private.has_permission('audit.read')));

create policy app_configuration_select_adjustment_roles
  on public.app_configuration
  for select
  to authenticated
  using (
    (select app_private.has_permission('stock.adjustment.post'))
    or (select app_private.has_permission('stock.adjustment.approve_exceptional'))
    or (select app_private.has_permission('operations.monitor'))
  );

revoke all on table public.profiles from public, anon, authenticated;
revoke all on table public.roles from public, anon, authenticated;
revoke all on table public.permissions from public, anon, authenticated;
revoke all on table public.role_permissions from public, anon, authenticated;
revoke all on table public.user_roles from public, anon, authenticated;
revoke all on table public.branches from public, anon, authenticated;
revoke all on table public.user_branch_assignments from public, anon, authenticated;
revoke all on table public.app_configuration from public, anon, authenticated;
revoke all on table public.audit_logs from public, anon, authenticated, service_role;

revoke insert, update, delete, truncate on table public.profiles from service_role;
revoke insert, update, delete, truncate on table public.roles from service_role;
revoke insert, update, delete, truncate on table public.permissions from service_role;
revoke insert, update, delete, truncate on table public.role_permissions from service_role;
revoke insert, update, delete, truncate on table public.user_roles from service_role;
revoke insert, update, delete, truncate on table public.branches from service_role;
revoke insert, update, delete, truncate on table public.user_branch_assignments from service_role;
revoke insert, update, delete, truncate on table public.app_configuration from service_role;

grant select on table public.profiles to authenticated;
grant select on table public.roles to authenticated;
grant select on table public.permissions to authenticated;
grant select on table public.role_permissions to authenticated;
grant select on table public.user_roles to authenticated;
grant select on table public.branches to authenticated;
grant select on table public.user_branch_assignments to authenticated;
grant select on table public.app_configuration to authenticated;
grant select on table public.audit_logs to authenticated;

comment on function app_private.can_work_at_branch(uuid) is
  'Future stock and verification functions must call this before acting on a branch_id.';

comment on schema public is
  'SherlysOS. Phase 2A adds identity and access control only. Future stock posting must use a SECURITY DEFINER function that checks stock.adjustment.post, app_private.can_work_at_branch, reads app_configuration thresholds, runs in one transaction with row locking, writes append-only ledger rows, rejects direct balance updates, and records audit_logs.';

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app_private.handle_new_user();
