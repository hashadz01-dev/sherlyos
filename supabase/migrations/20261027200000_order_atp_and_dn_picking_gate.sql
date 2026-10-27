-- M7.2. Picking-eligible ATP for order verify. Acknowledged DN before allocate.
-- Reuses picking_line_plan / picking_cutover_blockers. No stock writer.
-- Does not flip damage.stock_hold_ready or lot cutover flags.
-- verify_stock_receipt and confirm_dispatch are unchanged.

-- ---------------------------------------------------------------------------
-- Open DN lookup (read). Status acknowledged is the D1 picking gate.
-- ---------------------------------------------------------------------------
create or replace function app_private.open_delivery_note_for_order(target_order uuid)
returns public.delivery_notes
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected public.delivery_notes%rowtype;
begin
  select *
  into selected
  from public.delivery_notes
  where delivery_notes.order_id = target_order
    and delivery_notes.status is distinct from 'voided'
  order by delivery_notes.created_at desc, delivery_notes.id desc
  limit 1;

  return selected;
end;
$$;

revoke all on function app_private.open_delivery_note_for_order(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.order_has_acknowledged_delivery_note(target_order uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.delivery_notes
    where delivery_notes.order_id = target_order
      and delivery_notes.status = 'acknowledged'
  );
$$;

revoke all on function app_private.order_has_acknowledged_delivery_note(uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Gross on-hand excluding quarantine crates. Informational only — not ATP.
-- ---------------------------------------------------------------------------
create or replace function app_private.order_line_on_hand_cases(
  target_product uuid,
  target_branch uuid
)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(stock_balances.quantity), 0)::integer
  from public.stock_balances
  join public.crates on crates.id = stock_balances.crate_id
  join public.zones on zones.id = crates.zone_id
  where stock_balances.product_id = target_product
    and zones.branch_id = target_branch
    and crates.location_role is distinct from 'quarantine'
    and zones.location_role is distinct from 'quarantine'
    and not app_private.crate_is_quarantine(crates.id);
$$;

revoke all on function app_private.order_line_on_hand_cases(uuid, uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Authoritative ATP: same engine as picking. Cutover blockers fail closed.
-- Does not reserve. Allocation remains the TOCTOU authority.
-- ---------------------------------------------------------------------------
create or replace function app_private.order_line_availability(
  target_order uuid,
  target_branch uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cutover text[];
  operational boolean;
  lines jsonb := '[]'::jsonb;
  line public.order_lines%rowtype;
  plan jsonb;
  on_hand integer;
  eligible_cases integer;
  shortfall integer;
  blockers jsonb;
  eligible boolean;
begin
  cutover := app_private.picking_cutover_blockers();
  operational := coalesce(pg_catalog.array_length(cutover, 1), 0) = 0;

  for line in
    select *
    from public.order_lines
    where order_lines.order_id = target_order
    order by order_lines.created_at, order_lines.id
  loop
    on_hand := app_private.order_line_on_hand_cases(line.product_id, target_branch);

    if not operational then
      -- Pre-cutover: do not treat aggregate stock as pickable FEFO/FIFO.
      eligible_cases := 0;
      shortfall := line.requested_cases;
      eligible := false;
      blockers := to_jsonb(cutover);
    else
      plan := app_private.picking_line_plan(
        line.product_id, target_branch, line.requested_cases
      );
      eligible_cases := coalesce((plan ->> 'allocated_cases')::integer, 0);
      shortfall := coalesce((plan ->> 'shortfall_cases')::integer, line.requested_cases);
      eligible := coalesce(plan ->> 'eligible', 'false') is not distinct from 'true';
      blockers := coalesce(plan -> 'blockers', '[]'::jsonb);
    end if;

    lines := lines || jsonb_build_array(pg_catalog.jsonb_build_object(
      'product_id', line.product_id,
      'requested_cases', line.requested_cases,
      'on_hand_cases', on_hand,
      'eligible_cases', eligible_cases,
      'shortfall_cases', shortfall,
      'eligible', eligible,
      'blockers', blockers
    ));
  end loop;

  return pg_catalog.jsonb_build_object(
    'reserves_stock', false,
    'picking_operational', operational,
    'cutover_blockers', to_jsonb(cutover),
    'lines', lines
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Availability RPC returns the snapshot object, not a bare line array.
-- ---------------------------------------------------------------------------
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

  if selected.id is null
    or not app_private.can_work_at_branch(selected.branch_id)
  then
    raise exception 'godown is not authorized' using errcode = '42501';
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

comment on function public.check_order_availability(uuid) is
  'M7.2 picking-eligible ATP. Read-only. Does not reserve. Pre-cutover fail-closed.';

-- Rule A still rejects any shortfall. Snapshot now includes eligible_cases.
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

  if not found
    or not app_private.can_work_at_branch(selected.branch_id)
  then
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

comment on function public.verify_order(uuid, integer, text) is
  'Accounts verify. Picking-eligible ATP. Does not reserve. Allocation is the later authority.';

-- Open DN summary for authorized order viewers (picking gate UI).
create or replace function public.get_order(target_order uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  note public.delivery_notes%rowtype;
begin
  if target_order is null or not app_private.can_view_order(target_order) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  note := app_private.open_delivery_note_for_order(target_order);

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
    end
  );
end;
$$;

-- Inactive godown cannot accept a new operational acknowledgement.
create or replace function app_private.assert_delivery_note_acknowledger(target_branch uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('delivery_notes.acknowledge');

  if target_branch is null
    or not app_private.can_work_at_branch(target_branch)
  then
    raise exception 'godown is not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_operational_active_branch(target_branch);
end;
$$;

-- Replay of a completed ack must not bypass current assignment/permission.
create or replace function public.acknowledge_delivery_note(
  target_note uuid,
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
  selected_order public.orders%rowtype;
  selected public.delivery_notes%rowtype;
  existing_event public.delivery_note_events%rowtype;
  snapshot jsonb;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select *
  into existing_event
  from public.delivery_note_events
  where delivery_note_events.idempotency_key = cleaned_key;

  if found then
    if existing_event.delivery_note_id is distinct from target_note
      or existing_event.event_type is distinct from 'acknowledged'
      or existing_event.version is distinct from expected_version + 1
    then
      raise exception 'idempotency key does not match the original request'
        using errcode = '23514';
    end if;

    if not app_private.has_permission('delivery_notes.acknowledge')
      or not app_private.can_view_delivery_note(existing_event.delivery_note_id)
    then
      raise exception 'not authorized' using errcode = '42501';
    end if;

    return public.get_delivery_note(existing_event.delivery_note_id);
  end if;

  select delivery_notes.*
  into selected
  from public.delivery_notes
  where delivery_notes.id = target_note;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  -- Order first, then DN. Matches cancel_order and picking reserve.
  select *
  into selected_order
  from public.orders
  where orders.id = selected.order_id
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select *
  into selected
  from public.delivery_notes
  where delivery_notes.id = target_note
  for update;

  perform app_private.assert_delivery_note_acknowledger(selected.branch_id);

  if selected.version is distinct from expected_version then
    raise exception 'delivery note was changed by someone else' using errcode = 'PT409';
  end if;

  if selected.status is distinct from 'sent' then
    raise exception 'delivery note cannot change from % to acknowledged', selected.status
      using errcode = '23514';
  end if;

  if selected_order.status is distinct from 'verified' then
    raise exception 'delivery note requires a verified order' using errcode = '23514';
  end if;

  snapshot := app_private.current_delivery_note_line_snapshot(selected.id);

  update public.delivery_notes
  set
    status = 'acknowledged',
    acknowledged_at = pg_catalog.clock_timestamp(),
    acknowledged_by = auth.uid(),
    version = selected.version + 1
  where delivery_notes.id = selected.id;

  insert into public.delivery_note_events (
    delivery_note_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    version,
    idempotency_key,
    line_snapshot
  )
  values (
    selected.id,
    'acknowledged',
    selected.status,
    'acknowledged',
    auth.uid(),
    selected.version + 1,
    cleaned_key,
    snapshot
  );

  return public.get_delivery_note(selected.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Picking preview/reserve/list: D1 acknowledged DN required.
-- ---------------------------------------------------------------------------
create or replace function public.preview_order_allocation(target_order uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  selected public.orders%rowtype;
  cutover text[];
  line public.order_lines%rowtype;
  plans jsonb := '[]'::jsonb;
  plan jsonb;
  blockers text[] := '{}';
  eligible boolean := true;
  note public.delivery_notes%rowtype;
begin
  select * into selected from public.orders where orders.id = target_order;
  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_picking_allocator(selected.branch_id);

  cutover := app_private.picking_cutover_blockers();
  blockers := blockers || cutover;

  if selected.status is distinct from 'verified' then
    blockers := array_append(blockers, 'Picking can start only from a verified order.');
  end if;

  note := app_private.open_delivery_note_for_order(selected.id);
  if note.id is null or note.status is distinct from 'acknowledged' then
    blockers := array_append(
      blockers,
      'Godown Manager must acknowledge the delivery note before picking.'
    );
  end if;

  if exists (
    select 1 from public.stock_picking_requests
    where stock_picking_requests.order_id = selected.id
      and stock_picking_requests.status is distinct from 'cancelled'
  ) then
    blockers := array_append(blockers, 'This order already has an active picking request.');
  end if;

  for line in
    select * from public.order_lines
    where order_lines.order_id = selected.id
    order by order_lines.created_at, order_lines.id
  loop
    plan := app_private.picking_line_plan(
      line.product_id, selected.branch_id, line.requested_cases
    );
    plan := plan || pg_catalog.jsonb_build_object(
      'order_line_id', line.id,
      'sku', (select products.sku from public.products where products.id = line.product_id),
      'product_name', (select products.name from public.products where products.id = line.product_id)
    );
    plans := plans || jsonb_build_array(plan);
    if coalesce(plan ->> 'eligible', 'false') is distinct from 'true' then
      eligible := false;
      blockers := blockers || coalesce(
        array(select jsonb_array_elements_text(plan -> 'blockers')),
        '{}'
      );
    end if;
  end loop;

  if coalesce(jsonb_array_length(plans), 0) < 1 then
    eligible := false;
    blockers := array_append(blockers, 'The order has no lines to allocate.');
  end if;

  if coalesce(pg_catalog.array_length(cutover, 1), 0) > 0 then
    eligible := false;
  end if;

  if selected.status is distinct from 'verified' then
    eligible := false;
  end if;

  if note.id is null or note.status is distinct from 'acknowledged' then
    eligible := false;
  end if;

  return pg_catalog.jsonb_build_object(
    'order_id', selected.id,
    'order_number', selected.order_number,
    'order_status', selected.status,
    'order_version', selected.version,
    'branch_id', selected.branch_id,
    'shop_id', selected.shop_id,
    'delivery_note_id', note.id,
    'delivery_note_status', note.status,
    'eligible', eligible and coalesce(pg_catalog.array_length(blockers, 1), 0) = 0,
    'blockers', to_jsonb(blockers),
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
    'lines', plans
  );
end;
$$;

create or replace function public.reserve_order_allocation(
  target_order uuid,
  expected_order_version integer,
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
  existing public.stock_picking_requests%rowtype;
  created uuid;
  request_number text;
  preview jsonb;
  line jsonb;
  slice jsonb;
  blockers text[];
  first_blocker text;
  note public.delivery_notes%rowtype;
begin
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  select *
  into existing
  from public.stock_picking_requests
  where stock_picking_requests.idempotency_key = cleaned_key;
  if found then
    if existing.created_by is distinct from auth.uid()
      or not app_private.has_permission('picking.allocate')
      or not app_private.can_work_at_branch(existing.branch_id)
    then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    return app_private.picking_payload(existing.id);
  end if;

  perform app_private.acquire_stock_cutover_shared_lock();
  perform set_config('app.picking_write', 'on', true);

  select * into selected
  from public.orders
  where orders.id = target_order
  for update;

  if not found then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.assert_picking_allocator(selected.branch_id);

  if selected.version is distinct from expected_order_version then
    raise exception 'order was changed by someone else' using errcode = 'PT409';
  end if;

  -- Order already locked. DN next. Then location grains in preview/recompute.
  note := app_private.lock_open_delivery_note_for_order(selected.id);
  if note.id is null or note.status is distinct from 'acknowledged' then
    raise exception 'Godown Manager must acknowledge the delivery note before picking.'
      using errcode = '23514';
  end if;

  preview := public.preview_order_allocation(selected.id);
  if coalesce(preview ->> 'eligible', 'false') is distinct from 'true' then
    blockers := coalesce(
      array(select jsonb_array_elements_text(preview -> 'blockers')),
      '{}'
    );
    first_blocker := blockers[1];
    raise exception '%', coalesce(first_blocker, 'Allocation is not eligible.')
      using errcode = '23514';
  end if;

  perform stock_lot_balances.lot_id
  from public.stock_lot_balances
  join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
  join public.order_lines on order_lines.product_id = stock_lots.product_id
  where order_lines.order_id = selected.id
    and stock_lots.branch_id = selected.branch_id
  order by stock_lot_balances.crate_id, stock_lot_balances.lot_id
  for update of stock_lot_balances;

  preview := public.preview_order_allocation(selected.id);
  if coalesce(preview ->> 'eligible', 'false') is distinct from 'true' then
    raise exception 'insufficient eligible stock'
      using errcode = '23514';
  end if;

  request_number := 'PK-'
    || to_char(pg_catalog.clock_timestamp() at time zone 'UTC', 'YYYYMMDD')
    || '-'
    || pg_catalog.lpad(
      pg_catalog.nextval('public.stock_picking_request_seq')::text, 6, '0'
    );

  insert into public.stock_picking_requests (
    request_number, order_id, branch_id, status, created_by, idempotency_key
  )
  values (
    request_number, selected.id, selected.branch_id, 'allocated', auth.uid(), cleaned_key
  )
  returning id into created;

  for line in select value from jsonb_array_elements(preview -> 'lines')
  loop
    for slice in select value from jsonb_array_elements(line -> 'slices')
    loop
      if app_private.picking_available_cases(
        (slice ->> 'lot_id')::uuid,
        (slice ->> 'crate_id')::uuid
      ) < (slice ->> 'reserved_cases')::integer then
        raise exception 'insufficient eligible stock' using errcode = '23514';
      end if;

      insert into public.stock_reservations (
        picking_request_id,
        order_id,
        order_line_id,
        product_id,
        crate_id,
        lot_id,
        branch_id,
        reserved_cases,
        picked_cases,
        status,
        created_by
      )
      values (
        created,
        selected.id,
        (line ->> 'order_line_id')::uuid,
        (line ->> 'product_id')::uuid,
        (slice ->> 'crate_id')::uuid,
        (slice ->> 'lot_id')::uuid,
        selected.branch_id,
        (slice ->> 'reserved_cases')::integer,
        0,
        'active',
        auth.uid()
      );
    end loop;
  end loop;

  perform app_private.picking_event(
    created, 'allocated', null, 'allocated', 1, preview, cleaned_key
  );
  perform app_private.write_audit(
    auth.uid(),
    'reserve_order_allocation',
    'stock_picking_requests',
    created,
    pg_catalog.jsonb_build_object('order_id', selected.id, 'request_number', request_number)
  );

  return app_private.picking_payload(created);
end;
$$;

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
        'delivery_note_status', 'acknowledged'
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
      'updated_at', header.updated_at
    ) order by header.created_at desc)
    from public.stock_picking_requests header
    join public.orders on orders.id = header.order_id
    where (cleaned is null or header.status = cleaned)
      and app_private.picking_can_view(header)
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.check_order_availability(uuid)
  from public, anon, service_role;
grant execute on function public.check_order_availability(uuid) to authenticated;

revoke all on function public.verify_order(uuid, integer, text)
  from public, anon, service_role;
grant execute on function public.verify_order(uuid, integer, text) to authenticated;

revoke all on function public.get_order(uuid)
  from public, anon, service_role;
grant execute on function public.get_order(uuid) to authenticated;

revoke all on function public.acknowledge_delivery_note(uuid, integer, text)
  from public, anon, service_role;
grant execute on function public.acknowledge_delivery_note(uuid, integer, text)
  to authenticated;

revoke all on function public.preview_order_allocation(uuid)
  from public, anon, service_role;
grant execute on function public.preview_order_allocation(uuid) to authenticated;

revoke all on function public.reserve_order_allocation(uuid, integer, text)
  from public, anon, service_role;
grant execute on function public.reserve_order_allocation(uuid, integer, text)
  to authenticated;

revoke all on function public.list_picking_requests(text)
  from public, anon, service_role;
grant execute on function public.list_picking_requests(text) to authenticated;

notify pgrst, 'reload schema';
