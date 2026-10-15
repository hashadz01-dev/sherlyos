-- Phase 2C.2 approved master-data grants and shop scope.
-- Does not add stock tables or change stock.opening.post.
-- Shop creation and salesperson assignment stay with shops.assign (Admin only).
-- A Salesperson may read and edit a shop only through an active assignment.
-- A revoked assignment does not reveal the shop. Administrators keep the history.
-- Godown Manager receives suppliers.read so a product form can list suppliers.
-- That role does not receive suppliers.manage.
-- Zone and crate parent changes stay unavailable: update functions do not accept a new parent.

update public.permissions
set description = 'View shops the caller is allowed to open, and the assignments visible to that caller.'
where code = 'shops.read';

update public.permissions
set description = 'Create, update, and deactivate shops the caller is authorized to manage. Assignment uses shops.assign.'
where code = 'shops.manage';

insert into public.permissions (code, description)
values (
  'shops.assign',
  'Assign or revoke a salesperson on a shop. Provisional Admin-only grant. Delegated assignment by a Salesperson is not approved.'
);

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from (
  values
    ('admin', 'products.read'),
    ('admin', 'products.manage'),
    ('admin', 'suppliers.read'),
    ('admin', 'suppliers.manage'),
    ('admin', 'shops.read'),
    ('admin', 'shops.manage'),
    ('admin', 'shops.assign'),
    ('admin', 'locations.read'),
    ('admin', 'locations.manage'),
    ('godown_manager', 'products.read'),
    ('godown_manager', 'products.manage'),
    ('godown_manager', 'suppliers.read'),
    ('godown_manager', 'locations.read'),
    ('godown_manager', 'locations.manage'),
    ('accounts', 'suppliers.read'),
    ('accounts', 'suppliers.manage'),
    ('salesperson', 'shops.read'),
    ('salesperson', 'shops.manage')
) as grants (role_code, permission_code)
join public.roles on roles.code = grants.role_code
join public.permissions on permissions.code = grants.permission_code;

create or replace function app_private.shop_assignment_is_active(
  target_shop uuid,
  target_salesperson uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.shop_salesperson_assignments
    where shop_salesperson_assignments.shop_id = target_shop
      and shop_salesperson_assignments.salesperson_id = target_salesperson
      and shop_salesperson_assignments.is_active
  );
$$;

revoke all on function app_private.shop_assignment_is_active(uuid, uuid) from public, anon, authenticated, service_role;

create or replace function public.create_shop(
  shop_name text,
  shop_phone text,
  shop_address text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
begin
  -- New shops have no owner yet. Salesperson creation stays blocked.
  perform app_private.assert_permission('shops.assign');

  insert into public.shops (name, phone, address)
  values (
    app_private.clean_required_name(shop_name),
    app_private.clean_optional_phone(shop_phone),
    app_private.clean_optional_text(shop_address, 400)
  )
  returning id into created_id;

  perform app_private.write_audit(
    auth.uid(),
    'create_shop',
    'shops',
    created_id,
    pg_catalog.jsonb_build_object('name', app_private.clean_required_name(shop_name))
  );

  return created_id;
end;
$$;

create or replace function public.update_shop(
  target_shop uuid,
  shop_name text,
  shop_phone text,
  shop_address text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('shops.manage');

  if not app_private.has_permission('shops.assign')
    and not app_private.shop_assignment_is_active(target_shop, auth.uid())
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  update public.shops
  set
    name = app_private.clean_required_name(shop_name),
    phone = app_private.clean_optional_phone(shop_phone),
    address = app_private.clean_optional_text(shop_address, 400)
  where shops.id = target_shop;

  if not found then
    raise exception 'shop not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'update_shop',
    'shops',
    target_shop,
    pg_catalog.jsonb_build_object('name', app_private.clean_required_name(shop_name))
  );
end;
$$;

create or replace function public.set_shop_active(target_shop uuid, active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('shops.manage');

  if not app_private.has_permission('shops.assign')
    and not app_private.shop_assignment_is_active(target_shop, auth.uid())
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  update public.shops
  set is_active = active
  where shops.id = target_shop;

  if not found then
    raise exception 'shop not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'set_shop_active',
    'shops',
    target_shop,
    pg_catalog.jsonb_build_object('is_active', active)
  );
end;
$$;

create or replace function public.assign_shop_salesperson(
  target_shop uuid,
  target_salesperson uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
begin
  -- shops.assign is Admin only. A Salesperson cannot grant shop access.
  -- Cross-godown eligibility is not checked: shops have no godown.
  perform app_private.assert_permission('shops.assign');

  if not exists (
    select 1
    from public.shops
    where shops.id = target_shop
      and shops.is_active
  ) then
    raise exception 'shop not found or inactive' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.profiles
    join public.user_roles on user_roles.user_id = profiles.id
    join public.roles on roles.id = user_roles.role_id
    where profiles.id = target_salesperson
      and profiles.is_active
      and roles.code = 'salesperson'
  ) then
    raise exception 'an active salesperson is required' using errcode = '42501';
  end if;

  insert into public.shop_salesperson_assignments (shop_id, salesperson_id, assigned_by)
  values (target_shop, target_salesperson, auth.uid())
  returning id into created_id;

  perform app_private.write_audit(
    auth.uid(),
    'assign_shop_salesperson',
    'shop_salesperson_assignments',
    created_id,
    pg_catalog.jsonb_build_object(
      'shop_id', target_shop,
      'salesperson_id', target_salesperson
    )
  );

  return created_id;
exception
  when unique_violation then
    raise exception 'salesperson is already assigned to this shop' using errcode = '23505';
end;
$$;

create or replace function public.revoke_shop_salesperson(
  target_shop uuid,
  target_salesperson uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  assignment_id uuid;
begin
  perform app_private.assert_permission('shops.assign');

  update public.shop_salesperson_assignments
  set
    is_active = false,
    revoked_at = pg_catalog.now(),
    revoked_by = auth.uid()
  where shop_salesperson_assignments.shop_id = target_shop
    and shop_salesperson_assignments.salesperson_id = target_salesperson
    and shop_salesperson_assignments.is_active
  returning id into assignment_id;

  if assignment_id is null then
    raise exception 'assignment not found' using errcode = '42501';
  end if;

  perform app_private.write_audit(
    auth.uid(),
    'revoke_shop_salesperson',
    'shop_salesperson_assignments',
    assignment_id,
    pg_catalog.jsonb_build_object(
      'shop_id', target_shop,
      'salesperson_id', target_salesperson,
      'reason', 'revoked'
    )
  );
end;
$$;

drop policy if exists shops_select_readers on public.shops;
drop policy if exists shop_salesperson_assignments_select_readers on public.shop_salesperson_assignments;

create policy shops_select_authorized
  on public.shops
  for select
  to authenticated
  using (
    (select app_private.has_permission('shops.read'))
    and (
      (select app_private.has_permission('shops.assign'))
      or exists (
        select 1
        from public.shop_salesperson_assignments
        where shop_salesperson_assignments.shop_id = shops.id
          and shop_salesperson_assignments.salesperson_id = (select auth.uid())
          and shop_salesperson_assignments.is_active
      )
    )
  );

create policy shop_salesperson_assignments_select_authorized
  on public.shop_salesperson_assignments
  for select
  to authenticated
  using (
    (select app_private.has_permission('shops.assign'))
    or (
      (select app_private.has_permission('shops.read'))
      and salesperson_id = (select auth.uid())
      and is_active
    )
  );

comment on function public.create_shop(text, text, text) is
  'Requires shops.assign. Salesperson creation is blocked until shop ownership is approved.';

comment on function public.assign_shop_salesperson(uuid, uuid) is
  'Requires shops.assign, granted to Admin only. Does not check a godown.';

comment on function public.update_zone(uuid, text, text, text) is
  'Updates code, name, and description. Cannot move a zone to another godown.';

comment on function public.update_crate(uuid, text, text, text) is
  'Updates code, name, and description. Cannot move a crate to another zone.';
