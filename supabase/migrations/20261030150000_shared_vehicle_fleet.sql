-- M7.8. Vehicles are a shared delivery fleet, not a per-godown master.
-- Godown is chosen when a delivery run is assigned, not when the vehicle is created.
-- Does not write stock. Does not flip operational flags.

alter table public.vehicles
  alter column branch_id drop not null;

comment on table public.vehicles is
  'Shared delivery fleet. branch_id is optional home site only. Assignment happens on the dispatch. Inactive rows stay for history. Hard delete is refused.';

drop policy if exists vehicles_select_readers on public.vehicles;

create policy vehicles_select_readers
  on public.vehicles
  for select
  to authenticated
  using ((select app_private.has_permission('vehicles.view')));

create or replace function app_private.assert_vehicle_manager(target_branch uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('vehicles.manage');
  -- Fleet rows have no home godown. A supplied godown still requires access.
  if target_branch is not null and not app_private.can_work_at_branch(target_branch) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.create_vehicle(
  target_branch uuid,
  registration_number text,
  vehicle_type text,
  display_name text,
  capacity_cases integer,
  operational_notes text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_id uuid;
  cleaned_registration text := btrim(coalesce(registration_number, ''));
  normalized text;
begin
  perform app_private.assert_vehicle_manager(target_branch);
  if target_branch is not null and not exists (
    select 1 from public.branches
    where branches.id = target_branch and branches.is_active
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  normalized := app_private.normalize_vehicle_registration(cleaned_registration);

  insert into public.vehicles (
    branch_id, registration_number, registration_normalized, vehicle_type,
    display_name, capacity_cases, notes, created_by, updated_by
  )
  values (
    target_branch,
    cleaned_registration,
    normalized,
    app_private.clean_vehicle_type(vehicle_type),
    app_private.clean_required_name(display_name),
    capacity_cases,
    app_private.clean_optional_text(operational_notes, 500),
    auth.uid(),
    auth.uid()
  )
  returning id into created_id;

  perform app_private.write_audit(
    auth.uid(), 'create_vehicle', 'vehicles', created_id,
    pg_catalog.jsonb_build_object(
      'branch_id', target_branch,
      'registration_normalized', normalized
    )
  );

  return created_id;
exception
  when unique_violation then
    raise exception 'an active vehicle with this registration already exists'
      using errcode = '23505';
end;
$$;

create or replace function app_private.lock_vehicle_for_dispatch(
  target_vehicle uuid,
  target_dispatch uuid,
  target_branch uuid
)
returns public.vehicles
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.vehicles%rowtype;
begin
  if target_vehicle is null then
    raise exception 'an active vehicle is required' using errcode = '23514';
  end if;

  select * into selected
  from public.vehicles
  where vehicles.id = target_vehicle
  for update;

  if not found then
    raise exception 'vehicle not found' using errcode = '23514';
  end if;

  if selected.is_active is distinct from true then
    raise exception 'inactive vehicles cannot be assigned' using errcode = '23514';
  end if;

  -- Fleet vehicles can serve any godown. target_branch is the dispatch site.
  if target_branch is null then
    raise exception 'dispatch godown is required' using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.stock_dispatch_requests
    where stock_dispatch_requests.vehicle_id = selected.id
      and stock_dispatch_requests.id is distinct from target_dispatch
      and stock_dispatch_requests.status in ('dispatched', 'in_transit')
  ) then
    raise exception 'vehicle is already assigned to an active delivery'
      using errcode = '23514';
  end if;

  return selected;
end;
$$;

create or replace function public.list_assignable_vehicles(target_branch uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_dispatch_assigner(target_branch);

  return coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', vehicles.id,
      'display_name', vehicles.display_name,
      'registration_number', vehicles.registration_number,
      'vehicle_type', vehicles.vehicle_type,
      'in_use', exists (
        select 1
        from public.stock_dispatch_requests
        where stock_dispatch_requests.vehicle_id = vehicles.id
          and stock_dispatch_requests.status in ('dispatched', 'in_transit')
      )
    ) order by vehicles.display_name, vehicles.registration_number, vehicles.id)
    from public.vehicles
    where vehicles.is_active
  ), '[]'::jsonb);
end;
$$;

comment on function public.create_vehicle(uuid, text, text, text, integer, text) is
  'Shared fleet create. target_branch is optional. Unique active registration. Does not assign a delivery.';
comment on function public.list_assignable_vehicles(uuid) is
  'Active fleet vehicles for delivery assignment. in_use is global. Caller must be able to assign at the dispatch godown.';

notify pgrst, 'reload schema';
