-- Accounts verification may run at any active godown.
-- Warehouse packing/dispatch still use assert_operational_active_branch
-- (assignment + is_active). Inactive godowns stay blocked.

create or replace function app_private.assert_active_branch(target_branch uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  locked public.branches%rowtype;
begin
  if target_branch is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into locked
  from public.branches
  where branches.id = target_branch
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if not locked.is_active then
    raise exception 'godown is inactive' using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.assert_active_branch(uuid)
  from public, anon, authenticated, service_role;

comment on function app_private.assert_active_branch(uuid) is
  'Lock the godown and require branches.is_active. Does not require a user_branch_assignment. Warehouse writers keep assert_operational_active_branch.';

create or replace function public.verify_order(
  target_order uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  selected public.orders%rowtype;
  existing_event public.order_events%rowtype;
  availability jsonb;
  shortages jsonb;
begin
  perform app_private.assert_permission('orders.verify');
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select *
  into selected
  from public.orders
  where orders.id = target_order
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into existing_event
  from public.order_events
  where order_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.order_id is distinct from selected.id
      or existing_event.event_type is distinct from 'verified'
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;
    return public.get_order(selected.id);
  end if;

  if selected.status is distinct from 'submitted' then
    raise exception 'order cannot change from % to verified', selected.status
      using errcode = '23514';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'order was changed by someone else' using errcode = 'PT409';
  end if;

  if not exists (
    select 1
    from public.shops
    where shops.id = selected.shop_id
      and shops.is_active
  ) then
    raise exception 'shop is not active' using errcode = '23514';
  end if;

  perform app_private.assert_existing_order_lines(selected.id);
  -- Active godown only. Accounts does not need a site assignment to verify.
  perform app_private.assert_active_branch(selected.branch_id);

  availability := app_private.order_line_availability(selected.id, selected.branch_id);

  select coalesce(
    (
      select pg_catalog.jsonb_agg(entry order by entry ->> 'product_id')
      from pg_catalog.jsonb_array_elements(availability -> 'lines') as entry
      where (entry ->> 'shortfall_cases')::integer > 0
        or coalesce(entry ->> 'eligible', 'false') is distinct from 'true'
    ),
    '[]'::jsonb
  )
  into shortages;

  if pg_catalog.jsonb_array_length(shortages) > 0 then
    raise exception 'insufficient stock'
      using errcode = 'P0001',
            detail = shortages::text;
  end if;

  update public.orders
  set
    status = 'verified',
    verified_at = pg_catalog.clock_timestamp(),
    verified_by = auth.uid(),
    version = selected.version + 1
  where orders.id = selected.id;

  insert into public.order_events (
    order_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    version,
    idempotency_key,
    line_snapshot,
    availability_snapshot
  )
  values (
    selected.id,
    'verified',
    'submitted',
    'verified',
    auth.uid(),
    selected.version + 1,
    cleaned_key,
    app_private.current_order_line_snapshot(selected.id),
    availability
  );

  return public.get_order(selected.id);
end;
$$;
