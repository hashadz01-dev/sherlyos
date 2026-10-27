-- M7.3. Order-to-picking integration and fail-closed short-pick handoff.
-- Reuses M2 picking, M3 dispatch, M7.2 DN acknowledgement. No stock writer.
-- confirm_dispatch posting and verify_stock_receipt are unchanged.
-- Controlled short-shipment is not operational: shortage may be recorded,
-- but GM handoff refuses so dispatch is not reached with a reduced fill.

-- ---------------------------------------------------------------------------
-- Read-only fulfilment snapshot for queue, order, and picking payloads.
-- Released reservations are excluded from allocated_cases.
-- ---------------------------------------------------------------------------
create or replace function app_private.picking_fulfilment_snapshot(target_request uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  ordered integer := 0;
  allocated integer := 0;
  picked integer := 0;
  shortage integer := 0;
  has_shortage boolean := false;
begin
  select coalesce(sum(order_lines.requested_cases), 0)
    into ordered
  from public.order_lines
  join public.stock_picking_requests
    on stock_picking_requests.order_id = order_lines.order_id
  where stock_picking_requests.id = target_request;

  select coalesce(sum(stock_reservations.reserved_cases), 0)
    into allocated
  from public.stock_reservations
  where stock_reservations.picking_request_id = target_request
    and stock_reservations.status is distinct from 'released';

  select coalesce(sum(stock_reservations.picked_cases), 0)
    into picked
  from public.stock_reservations
  where stock_reservations.picking_request_id = target_request;

  select coalesce(sum(stock_picking_exceptions.quantity), 0)
    into shortage
  from public.stock_picking_exceptions
  where stock_picking_exceptions.picking_request_id = target_request
    and stock_picking_exceptions.exception_type = 'shortage';

  -- Shortage exceptions are the warehouse record that fill dropped.
  -- Dispatch still requires reserved == ordered; this snapshot is display.
  has_shortage := exists (
    select 1
    from public.stock_picking_exceptions
    where stock_picking_exceptions.picking_request_id = target_request
      and stock_picking_exceptions.exception_type = 'shortage'
  );

  return pg_catalog.jsonb_build_object(
    'ordered_cases', ordered,
    'allocated_cases', allocated,
    'picked_cases', picked,
    'remaining_cases', greatest(allocated - picked, 0),
    'shortfall_cases', greatest(ordered - allocated, 0),
    'shortage_cases', coalesce(shortage, 0),
    'has_shortage', has_shortage,
    'short_shipment_operational', false
  );
end;
$$;

revoke all on function app_private.picking_fulfilment_snapshot(uuid)
  from public, anon, authenticated, service_role;

-- Refuse GM handoff when a shortage was recorded. Does not change
-- confirm_dispatch, reservation release, or original order/DN quantities.
create or replace function app_private.assert_picking_no_short_shipment(target_request uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.stock_picking_exceptions
    where stock_picking_exceptions.picking_request_id = target_request
      and stock_picking_exceptions.exception_type = 'shortage'
  ) then
    raise exception
      'Short picks cannot be handed to dispatch. Cancel this picking request and reallocate the full order, or pick every reserved carton. Controlled short-shipment is not operational.'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.assert_picking_no_short_shipment(uuid)
  from public, anon, authenticated, service_role;

-- Open picking row for order viewers (cancelled requests are history only).
create or replace function app_private.open_picking_request_for_order(target_order uuid)
returns public.stock_picking_requests
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected public.stock_picking_requests%rowtype;
begin
  select *
    into selected
  from public.stock_picking_requests
  where stock_picking_requests.order_id = target_order
    and stock_picking_requests.status is distinct from 'cancelled'
  order by stock_picking_requests.created_at desc, stock_picking_requests.id desc
  limit 1;

  return selected;
end;
$$;

revoke all on function app_private.open_picking_request_for_order(uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- get_order: DN + open picking + cutover. Verify still does not reserve.
-- ---------------------------------------------------------------------------
create or replace function public.get_order(target_order uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  note public.delivery_notes%rowtype;
  picking public.stock_picking_requests%rowtype;
  cutover text[];
begin
  if target_order is null or not app_private.can_view_order(target_order) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  note := app_private.open_delivery_note_for_order(target_order);
  picking := app_private.open_picking_request_for_order(target_order);
  cutover := app_private.picking_cutover_blockers();

  return pg_catalog.jsonb_build_object(
    'order',
    (select to_jsonb(orders) from public.orders where orders.id = target_order),
    'lines',
    coalesce(
      (
        select pg_catalog.jsonb_agg(to_jsonb(order_lines) order by order_lines.created_at)
        from public.order_lines
        where order_lines.order_id = target_order
      ),
      '[]'::jsonb
    ),
    'events',
    coalesce(
      (
        select pg_catalog.jsonb_agg(to_jsonb(order_events) order by order_events.created_at)
        from public.order_events
        where order_events.order_id = target_order
      ),
      '[]'::jsonb
    ),
    'open_delivery_note',
    case
      when note.id is null then null
      else pg_catalog.jsonb_build_object(
        'id', note.id,
        'delivery_note_number', note.delivery_note_number,
        'status', note.status,
        'version', note.version,
        'acknowledged_at', note.acknowledged_at,
        'acknowledged_by', note.acknowledged_by
      )
    end,
    'open_picking_request',
    case
      when picking.id is null then null
      else pg_catalog.jsonb_build_object(
        'id', picking.id,
        'request_number', picking.request_number,
        'status', picking.status,
        'version', picking.version,
        'fulfilment', app_private.picking_fulfilment_snapshot(picking.id)
      )
    end,
    'picking_cutover',
    pg_catalog.jsonb_build_object(
      'dual_write_enabled', exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.dual_write_enabled' and value = 'true'::jsonb
      ),
      'aggregate_only_blocked', exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.aggregate_only_blocked' and value = 'true'::jsonb
      ),
      'blockers', to_jsonb(coalesce(cutover, '{}'::text[]))
    )
  );
end;
$$;

revoke all on function public.get_order(uuid)
  from public, anon, service_role;
grant execute on function public.get_order(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- picking_payload: same reservations/events, plus fulfilment and DN status.
-- ---------------------------------------------------------------------------
create or replace function app_private.picking_payload(target_request uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  header public.stock_picking_requests;
  selected_order public.orders%rowtype;
  note public.delivery_notes%rowtype;
begin
  select *
    into header
  from public.stock_picking_requests
  where id = target_request;

  if not found or not app_private.picking_can_view(header) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select * into selected_order from public.orders where id = header.order_id;
  note := app_private.open_delivery_note_for_order(header.order_id);

  return pg_catalog.jsonb_build_object(
    'id', header.id,
    'request_number', header.request_number,
    'order_id', header.order_id,
    'order_number', selected_order.order_number,
    'order_status', selected_order.status,
    'order_version', selected_order.version,
    'shop_id', selected_order.shop_id,
    'branch_id', header.branch_id,
    'status', header.status,
    'version', header.version,
    'assigned_to', header.assigned_to,
    'created_by', header.created_by,
    'started_at', header.started_at,
    'completed_at', header.completed_at,
    'handed_off_at', header.handed_off_at,
    'cancelled_at', header.cancelled_at,
    'cancellation_reason', header.cancellation_reason,
    'blocked_reason', header.blocked_reason,
    'created_at', header.created_at,
    'updated_at', header.updated_at,
    'delivery_note_status', note.status,
    'fulfilment', app_private.picking_fulfilment_snapshot(header.id),
    'cutover', pg_catalog.jsonb_build_object(
      'dual_write_enabled', exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.dual_write_enabled' and value = 'true'::jsonb
      ),
      'aggregate_only_blocked', exists (
        select 1 from public.app_configuration
        where key = 'stock.lots.aggregate_only_blocked' and value = 'true'::jsonb
      )
    ),
    'reservations', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_reservations.id,
        'order_line_id', stock_reservations.order_line_id,
        'product_id', stock_reservations.product_id,
        'sku', products.sku,
        'product_name', products.name,
        'crate_id', stock_reservations.crate_id,
        'crate_code', crates.code,
        'zone_code', zones.code,
        'lot_id', stock_reservations.lot_id,
        'manufacturer_lot_code', stock_lots.manufacturer_lot_code,
        'expiry_date', stock_lots.expiry_date,
        'received_on', stock_lots.received_on,
        'lot_status', stock_lots.status,
        'reserved_cases', stock_reservations.reserved_cases,
        'picked_cases', stock_reservations.picked_cases,
        'remaining_cases', stock_reservations.reserved_cases - stock_reservations.picked_cases,
        'status', stock_reservations.status
      ) order by products.sku, crates.code, stock_lots.id)
      from public.stock_reservations
      join public.products on products.id = stock_reservations.product_id
      join public.crates on crates.id = stock_reservations.crate_id
      join public.zones on zones.id = crates.zone_id
      join public.stock_lots on stock_lots.id = stock_reservations.lot_id
      where stock_reservations.picking_request_id = header.id
    ), '[]'::jsonb),
    'exceptions', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_picking_exceptions.id,
        'reservation_id', stock_picking_exceptions.reservation_id,
        'exception_type', stock_picking_exceptions.exception_type,
        'message', stock_picking_exceptions.message,
        'quantity', stock_picking_exceptions.quantity,
        'created_at', stock_picking_exceptions.created_at
      ) order by stock_picking_exceptions.created_at, stock_picking_exceptions.id)
      from public.stock_picking_exceptions
      where stock_picking_exceptions.picking_request_id = header.id
    ), '[]'::jsonb),
    'events', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_picking_events.id,
        'event_type', stock_picking_events.event_type,
        'actor_id', stock_picking_events.actor_id,
        'from_status', stock_picking_events.from_status,
        'to_status', stock_picking_events.to_status,
        'request_version', stock_picking_events.request_version,
        'payload', stock_picking_events.payload,
        'created_at', stock_picking_events.created_at
      ) order by stock_picking_events.created_at, stock_picking_events.id)
      from public.stock_picking_events
      where stock_picking_events.picking_request_id = header.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app_private.picking_payload(uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Queue: pending still requires acknowledged DN. Request rows show fill.
-- ---------------------------------------------------------------------------
create or replace function public.list_picking_requests(status_filter text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cleaned text := nullif(pg_catalog.btrim(coalesce(status_filter, '')), '');
begin
  if cleaned is not null and cleaned is distinct from 'pending_allocation'
    and cleaned not in (
      'allocated', 'picking', 'picked', 'ready_for_dispatch', 'cancelled', 'blocked'
    )
  then
    raise exception 'picking status is invalid' using errcode = '23514';
  end if;

  if cleaned is not distinct from 'pending_allocation' then
    if not (
      app_private.has_permission('picking.allocate')
      or app_private.has_permission('picking.manage')
      or app_private.has_permission('operations.monitor')
    ) then
      return '[]'::jsonb;
    end if;

    return coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'kind', 'pending_order',
        'order_id', orders.id,
        'order_number', orders.order_number,
        'order_status', orders.status,
        'order_version', orders.version,
        'branch_id', orders.branch_id,
        'shop_id', orders.shop_id,
        'created_at', orders.verified_at,
        'status', 'pending_allocation',
        'delivery_note_status', 'acknowledged',
        'ordered_cases', (
          select coalesce(sum(order_lines.requested_cases), 0)
          from public.order_lines
          where order_lines.order_id = orders.id
        ),
        'allocated_cases', 0,
        'picked_cases', 0,
        'shortfall_cases', (
          select coalesce(sum(order_lines.requested_cases), 0)
          from public.order_lines
          where order_lines.order_id = orders.id
        ),
        'has_shortage', false
      ) order by orders.verified_at, orders.order_number)
      from public.orders
      where orders.status = 'verified'
        and app_private.can_work_at_branch(orders.branch_id)
        and app_private.order_has_acknowledged_delivery_note(orders.id)
        and not exists (
          select 1 from public.stock_picking_requests
          where stock_picking_requests.order_id = orders.id
            and stock_picking_requests.status is distinct from 'cancelled'
        )
    ), '[]'::jsonb);
  end if;

  return coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'kind', 'picking_request',
      'id', header.id,
      'request_number', header.request_number,
      'order_id', header.order_id,
      'order_number', orders.order_number,
      'branch_id', header.branch_id,
      'status', header.status,
      'version', header.version,
      'assigned_to', header.assigned_to,
      'created_at', header.created_at,
      'updated_at', header.updated_at,
      'delivery_note_status', (
        app_private.open_delivery_note_for_order(header.order_id)
      ).status,
      'ordered_cases', coalesce((snap.fill ->> 'ordered_cases')::integer, 0),
      'allocated_cases', coalesce((snap.fill ->> 'allocated_cases')::integer, 0),
      'picked_cases', coalesce((snap.fill ->> 'picked_cases')::integer, 0),
      'shortfall_cases', coalesce((snap.fill ->> 'shortfall_cases')::integer, 0),
      'has_shortage', coalesce((snap.fill ->> 'has_shortage')::boolean, false)
    ) order by header.created_at desc)
    from public.stock_picking_requests header
    join public.orders on orders.id = header.order_id
    cross join lateral (
      select app_private.picking_fulfilment_snapshot(header.id) as fill
    ) snap
    where (cleaned is null or header.status = cleaned)
      and app_private.picking_can_view(header)
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.list_picking_requests(text)
  from public, anon, service_role;
grant execute on function public.list_picking_requests(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Handoff: M4.1 inactive-godown manager gate plus short-pick refusal.
-- Lock order is unchanged (cutover share, then picking row). No ledger write.
-- ---------------------------------------------------------------------------
create or replace function public.confirm_picking_handoff(
  target_request uuid,
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
  header public.stock_picking_requests;
  replay uuid;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  replay := app_private.replay_picking_event(cleaned_key, 'handed_off', target_request);
  if replay is not null then
    return app_private.picking_payload(replay);
  end if;

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.picking_write', 'on', true);
  header := app_private.lock_picking_request(target_request, expected_version);
  perform app_private.assert_picking_manager(header.branch_id);
  perform app_private.assert_operational_active_branch(header.branch_id);

  if header.status is distinct from 'picked' then
    raise exception 'handoff requires completed picking' using errcode = '23514';
  end if;

  -- Fail here rather than at confirm_dispatch quantity mismatch.
  perform app_private.assert_picking_no_short_shipment(header.id);

  update public.stock_picking_requests
  set
    status = 'ready_for_dispatch',
    handed_off_by = auth.uid(),
    handed_off_at = pg_catalog.clock_timestamp(),
    version = header.version + 1
  where id = header.id;

  perform app_private.picking_event(
    header.id, 'handed_off', 'picked', 'ready_for_dispatch', header.version + 1,
    '{}'::jsonb, cleaned_key
  );
  perform app_private.write_audit(
    auth.uid(),
    'confirm_picking_handoff',
    'stock_picking_requests',
    header.id,
    pg_catalog.jsonb_build_object('status', 'ready_for_dispatch')
  );

  return app_private.picking_payload(header.id);
end;
$$;

revoke all on function public.confirm_picking_handoff(uuid, integer, text)
  from public, anon, service_role;
grant execute on function public.confirm_picking_handoff(uuid, integer, text)
  to authenticated;

notify pgrst, 'reload schema';
