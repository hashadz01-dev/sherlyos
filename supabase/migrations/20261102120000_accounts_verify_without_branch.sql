-- Accounts verification is a company-wide Accounts action.
-- Godown assignment stays required for warehouse stock, packing, and dispatch.
-- Salesperson capture still requires shop assignment / created_by.

create or replace function app_private.can_view_order(target_order uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.orders
    where orders.id = target_order
      and (
        (select app_private.has_permission('operations.monitor'))
        or (select app_private.has_permission('orders.verify'))
        or (
          (select app_private.has_permission('orders.capture'))
          and orders.created_by = (select auth.uid())
        )
      )
  );
$$;

create or replace function public.check_order_availability(target_order uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected public.orders%rowtype;
begin
  perform app_private.assert_permission('orders.verify');

  select *
  into selected
  from public.orders
  where orders.id = target_order;

  if selected.id is null then
    raise exception 'not authorized' using errcode = '42501';
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

  return app_private.order_line_availability(selected.id, selected.branch_id);
end;
$$;

create or replace function public.hold_order(
  target_order uuid,
  expected_version integer,
  hold_note text,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  cleaned_note text;
  selected public.orders%rowtype;
  existing_event public.order_events%rowtype;
begin
  perform app_private.assert_permission('orders.verify');
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_note := app_private.clean_required_order_text(hold_note, 500);

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
      or existing_event.event_type is distinct from 'held'
      or existing_event.note is distinct from cleaned_note
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;
    return public.get_order(selected.id);
  end if;

  if selected.status is distinct from 'submitted' then
    raise exception 'order cannot change from % to held', selected.status
      using errcode = '23514';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'order was changed by someone else' using errcode = 'PT409';
  end if;

  update public.orders
  set
    status = 'held',
    held_at = pg_catalog.clock_timestamp(),
    held_by = (select auth.uid()),
    version = selected.version + 1
  where orders.id = selected.id;

  insert into public.order_events (
    order_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    note,
    version,
    idempotency_key,
    line_snapshot
  )
  values (
    selected.id,
    'held',
    'submitted',
    'held',
    (select auth.uid()),
    cleaned_note,
    selected.version + 1,
    cleaned_key,
    app_private.current_order_line_snapshot(selected.id)
  );

  return public.get_order(selected.id);
end;
$$;

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
  perform app_private.assert_operational_active_branch(selected.branch_id);

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

create or replace function public.cancel_order(
  target_order uuid,
  expected_version integer,
  cancellation_reason text,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  cleaned_reason text;
  selected public.orders%rowtype;
  existing_event public.order_events%rowtype;
  open_note public.delivery_notes%rowtype;
  picking public.stock_picking_requests%rowtype;
  dispatch public.stock_dispatch_requests%rowtype;
  is_creator boolean;
  is_accounts boolean;
begin
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
  into picking
  from public.stock_picking_requests
  where stock_picking_requests.order_id = selected.id
    and stock_picking_requests.status is distinct from 'cancelled'
  for update;

  if found then
    if picking.status in ('picking', 'picked', 'ready_for_dispatch') then
      raise exception 'cancel picking or finish dispatch before cancelling this order'
        using errcode = '23514';
    end if;
  end if;

  select *
  into dispatch
  from public.stock_dispatch_requests
  where stock_dispatch_requests.order_id = selected.id
    and stock_dispatch_requests.status is distinct from 'cancelled'
  for update;

  if found then
    if dispatch.stock_consumed then
      raise exception 'dispatched stock cannot be reversed by order cancellation'
        using errcode = '23514';
    end if;
    raise exception 'cancel the preparing dispatch before cancelling this order'
      using errcode = '23514';
  end if;

  open_note := app_private.lock_open_delivery_note_for_order(selected.id);
  if open_note.id is not null then
    if open_note.status = 'acknowledged' then
      raise exception 'order cannot be cancelled while an acknowledged delivery note exists'
        using errcode = '23514';
    end if;

    raise exception
      'void the active delivery note before cancelling this order'
      using errcode = '23514';
  end if;

  is_creator := selected.created_by = (select auth.uid())
    and (select app_private.has_permission('orders.capture'));
  is_accounts := (select app_private.has_permission('orders.verify'));

  select *
  into existing_event
  from public.order_events
  where order_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.order_id is distinct from selected.id
      or existing_event.event_type is distinct from 'cancelled'
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;
    return public.get_order(selected.id);
  end if;

  if selected.status = 'cancelled' then
    raise exception 'order cannot change from cancelled to cancelled'
      using errcode = '23514';
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'order was changed by someone else' using errcode = 'PT409';
  end if;

  if selected.status in ('draft', 'held') then
    if not is_creator then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    cleaned_reason := app_private.clean_optional_order_text(cancellation_reason, 500);
  elsif selected.status in ('submitted', 'verified') then
    if not is_accounts then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    cleaned_reason := app_private.clean_required_order_text(cancellation_reason, 500);
  else
    raise exception 'order cannot change from % to cancelled', selected.status
      using errcode = '23514';
  end if;

  if picking.id is not null and picking.status = 'allocated' then
    perform set_config('app.picking_write', 'on', true);
    update public.stock_reservations
    set status = 'released'
    where picking_request_id = picking.id
      and status = 'active';
    update public.stock_picking_requests
    set
      status = 'cancelled',
      cancelled_by = auth.uid(),
      cancelled_at = pg_catalog.clock_timestamp(),
      cancellation_reason = cleaned_reason,
      version = picking.version + 1
    where id = picking.id;
    perform app_private.picking_event(
      picking.id, 'cancelled', 'allocated', 'cancelled', picking.version + 1,
      pg_catalog.jsonb_build_object('reason', 'order cancelled'),
      null
    );
  end if;

  update public.orders
  set
    status = 'cancelled',
    cancelled_at = pg_catalog.clock_timestamp(),
    cancelled_by = (select auth.uid()),
    cancellation_reason = cleaned_reason,
    version = selected.version + 1
  where orders.id = selected.id;

  insert into public.order_events (
    order_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    note,
    version,
    idempotency_key,
    line_snapshot
  )
  values (
    selected.id,
    'cancelled',
    selected.status,
    'cancelled',
    (select auth.uid()),
    cleaned_reason,
    selected.version + 1,
    cleaned_key,
    app_private.current_order_line_snapshot(selected.id)
  );

  return public.get_order(selected.id);
end;
$$;

comment on function app_private.can_view_order(uuid) is
  'Accounts with orders.verify can read all orders. Warehouse site grants are unchanged.';
