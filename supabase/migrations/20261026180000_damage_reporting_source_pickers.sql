-- M5.4B read-only source pickers and draft evidence metadata.
-- Local-first. Does not flip damage.stock_hold_ready or lot cutover flags.
-- Does not add write pathways. Create/update/submit/photo RPCs stay M5.2.

-- Draft editors need unfinalized evidence metadata (never storage_path).
-- Preview and get_damage_photo_url still require verified_at.
create or replace function app_private.damage_report_payload(target_report uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  header public.damage_reports;
begin
  select * into header from public.damage_reports where damage_reports.id = target_report;

  if not found
    or not app_private.can_view_damage_report(
      header.godown_id, header.scenario, header.reporter_user_id, header.dispatch_id
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'id', header.id,
    'report_number', header.report_number,
    'scenario', header.scenario,
    'godown_id', header.godown_id,
    'godown_name', (select branches.name from public.branches where branches.id = header.godown_id),
    'status', header.status,
    'version', header.version,
    'receipt_id', header.receipt_id,
    'picking_request_id', header.picking_request_id,
    'dispatch_id', header.dispatch_id,
    'order_id', header.order_id,
    'shop_id', header.shop_id,
    'notes', header.notes,
    'reporter_user_id', header.reporter_user_id,
    'physical_custody_confirmed', header.physical_custody_confirmed_at is not null,
    'reporter_name', (
      select profiles.full_name from public.profiles where profiles.id = header.reporter_user_id
    ),
    'created_at', header.created_at,
    'updated_at', header.updated_at,
    'lines', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', damage_report_lines.id,
        'product_id', damage_report_lines.product_id,
        'product_sku', products.sku,
        'product_name', products.name,
        'crate_id', damage_report_lines.crate_id,
        'crate_code', crates.code,
        'lot_id', damage_report_lines.lot_id,
        'quantity_cases', damage_report_lines.quantity_cases,
        'damage_reason', damage_report_lines.damage_reason,
        'notes', damage_report_lines.notes,
        'receipt_line_id', damage_report_lines.receipt_line_id
      ) order by damage_report_lines.sort_order, damage_report_lines.id)
      from public.damage_report_lines
      join public.products on products.id = damage_report_lines.product_id
      left join public.crates on crates.id = damage_report_lines.crate_id
      where damage_report_lines.damage_report_id = header.id
    ), '[]'::jsonb),
    'holds', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', damage_stock_holds.id,
        'line_id', damage_stock_holds.damage_report_line_id,
        'product_id', damage_stock_holds.product_id,
        'crate_id', damage_stock_holds.crate_id,
        'crate_code', crates.code,
        'location_role', crates.location_role,
        'lot_id', damage_stock_holds.lot_id,
        'quantity_cases', damage_stock_holds.quantity_cases,
        'hold_kind', damage_stock_holds.hold_kind,
        'status', damage_stock_holds.status,
        'posted_transaction_id', damage_stock_holds.posted_transaction_id
      ) order by damage_stock_holds.created_at, damage_stock_holds.id)
      from public.damage_stock_holds
      left join public.crates on crates.id = damage_stock_holds.crate_id
      where damage_stock_holds.damage_report_id = header.id
    ), '[]'::jsonb),
    'exceptional_requests', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', damage_exceptional_requests.id,
        'kind', damage_exceptional_requests.disposition_kind,
        'status', damage_exceptional_requests.status,
        'version', damage_exceptional_requests.version,
        'request_reason', damage_exceptional_requests.request_reason,
        'requested_at', damage_exceptional_requests.requested_at
      ) order by damage_exceptional_requests.created_at)
      from public.damage_exceptional_requests
      where damage_exceptional_requests.damage_report_id = header.id
    ), '[]'::jsonb),
    'events', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'action', damage_report_events.action,
        'actor_name', profiles.full_name,
        'previous_status', damage_report_events.previous_status,
        'next_status', damage_report_events.next_status,
        'created_at', damage_report_events.created_at,
        'metadata', damage_report_events.metadata
      ) order by damage_report_events.created_at, damage_report_events.id)
      from public.damage_report_events
      join public.profiles on profiles.id = damage_report_events.actor_id
      where damage_report_events.damage_report_id = header.id
    ), '[]'::jsonb),
    'evidence', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', damage_evidence.id,
        'finalized', damage_evidence.verified_at is not null,
        'mime_type', damage_evidence.mime_type,
        'uploaded_at', damage_evidence.uploaded_at,
        'note', damage_evidence.note
      ) order by damage_evidence.uploaded_at, damage_evidence.id)
      from public.damage_evidence
      where damage_evidence.damage_report_id = header.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app_private.damage_report_payload(uuid)
  from public, anon, authenticated, service_role;

-- Not STABLE: create-auth helpers may lock configuration. PostgREST must
-- not classify this as a read-only GET.
create or replace function public.list_damage_report_sources(
  scenario text,
  target_godown uuid,
  search_text text default null,
  page integer default 1,
  page_size integer default 50
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_scenario text := pg_catalog.lower(pg_catalog.btrim(coalesce(scenario, '')));
  cleaned_search text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(search_text, ''))), '');
  safe_page integer := greatest(coalesce(page, 1), 1);
  safe_size integer := least(greatest(coalesce(page_size, 50), 1), 50);
  total_count integer := 0;
  items jsonb := '[]'::jsonb;
  catalogs jsonb := '{}'::jsonb;
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if target_godown is null then
    raise exception 'godown is required' using errcode = '23514';
  end if;

  if cleaned_scenario not in (
    'refill_supply', 'unloading', 'storage', 'loading', 'transit', 'shop_return'
  ) then
    raise exception 'damage scenario is invalid' using errcode = '23514';
  end if;

  -- Same create-auth gates as write RPCs, without requiring a specific document yet.
  if cleaned_scenario = 'transit' then
    if not (
      app_private.has_permission('damage.record')
      or app_private.has_permission('deliveries.execute')
    ) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    if not app_private.can_complete_consumed_delivery_at_branch(target_godown) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
  else
    perform app_private.assert_damage_create_auth(cleaned_scenario, target_godown, null);
  end if;

  if cleaned_search is not null then
    cleaned_search := replace(replace(replace(cleaned_search, '\', '\\'), '%', '\%'), '_', '\_');
  end if;

  if cleaned_scenario in ('refill_supply', 'unloading') then
    select count(*) into total_count
    from public.stock_receipts
    where stock_receipts.godown_id = target_godown
      and stock_receipts.status = 'posted'
      and exists (
        select 1 from public.stock_receipt_lines
        where stock_receipt_lines.receipt_id = stock_receipts.id
          and stock_receipt_lines.damaged_cases > 0
      )
      and (
        cleaned_search is null
        or pg_catalog.lower(stock_receipts.receipt_number) like '%' || cleaned_search || '%' escape '\'
      );

    select coalesce(pg_catalog.jsonb_agg(item), '[]'::jsonb)
    into items
    from (
      select pg_catalog.jsonb_build_object(
        'id', stock_receipts.id,
        'kind', 'receipt',
        'label', stock_receipts.receipt_number,
        'godown_id', stock_receipts.godown_id,
        'receipt_id', stock_receipts.id,
        'received_date', stock_receipts.received_date,
        'supplier_name', suppliers.name,
        'lines', coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'receipt_line_id', stock_receipt_lines.id,
            'product_id', stock_receipt_lines.product_id,
            'product_sku', products.sku,
            'product_name', products.name,
            'crate_id', stock_receipt_lines.destination_crate_id,
            'crate_code', crates.code,
            'damaged_cases', stock_receipt_lines.damaged_cases,
            'already_reported', app_private.damage_open_receipt_qty(stock_receipt_lines.id, null),
            'remaining_cases', greatest(
              stock_receipt_lines.damaged_cases
              - app_private.damage_open_receipt_qty(stock_receipt_lines.id, null),
              0
            )
          ) order by stock_receipt_lines.id)
          from public.stock_receipt_lines
          join public.products on products.id = stock_receipt_lines.product_id
          left join public.crates on crates.id = stock_receipt_lines.destination_crate_id
          where stock_receipt_lines.receipt_id = stock_receipts.id
            and stock_receipt_lines.damaged_cases > 0
        ), '[]'::jsonb)
      ) as item
      from public.stock_receipts
      join public.suppliers on suppliers.id = stock_receipts.supplier_id
      where stock_receipts.godown_id = target_godown
        and stock_receipts.status = 'posted'
        and exists (
          select 1 from public.stock_receipt_lines
          where stock_receipt_lines.receipt_id = stock_receipts.id
            and stock_receipt_lines.damaged_cases > 0
        )
        and (
          cleaned_search is null
          or pg_catalog.lower(stock_receipts.receipt_number) like '%' || cleaned_search || '%' escape '\'
        )
      order by stock_receipts.received_date desc, stock_receipts.id desc
      offset (safe_page - 1) * safe_size
      limit safe_size
    ) listed;
  elsif cleaned_scenario = 'storage' then
    total_count := 1;
    items := pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', target_godown,
        'kind', 'godown',
        'label', (select branches.name from public.branches where branches.id = target_godown),
        'godown_id', target_godown
      )
    );
    catalogs := pg_catalog.jsonb_build_object(
      'crates', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', crates.id,
          'code', crates.code,
          'name', crates.name,
          'zone_code', zones.code
        ) order by crates.code)
        from public.crates
        join public.zones on zones.id = crates.zone_id
        where zones.branch_id = target_godown
          and crates.is_active
          and crates.location_role is distinct from 'quarantine'
      ), '[]'::jsonb),
      -- Only products with on-hand at this godown. Avoids unbounded product dumps.
      'products', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', products.id,
          'sku', products.sku,
          'name', products.name
        ) order by products.sku)
        from public.products
        where products.is_active
          and exists (
            select 1
            from public.stock_balances
            join public.crates on crates.id = stock_balances.crate_id
            join public.zones on zones.id = crates.zone_id
            where stock_balances.product_id = products.id
              and zones.branch_id = target_godown
              and stock_balances.quantity > 0
          )
      ), '[]'::jsonb),
      'balances', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'crate_id', stock_balances.crate_id,
          'product_id', stock_balances.product_id,
          'on_hand_cases', stock_balances.quantity
        ))
        from public.stock_balances
        join public.crates on crates.id = stock_balances.crate_id
        join public.zones on zones.id = crates.zone_id
        where zones.branch_id = target_godown
          and stock_balances.quantity > 0
      ), '[]'::jsonb)
    );
  elsif cleaned_scenario = 'loading' then
    select count(*) into total_count
    from public.stock_picking_requests
    where stock_picking_requests.branch_id = target_godown
      and stock_picking_requests.status in ('allocated', 'picking', 'picked', 'ready_for_dispatch')
      and (
        cleaned_search is null
        or pg_catalog.lower(stock_picking_requests.request_number) like '%' || cleaned_search || '%' escape '\'
      );

    select coalesce(pg_catalog.jsonb_agg(item), '[]'::jsonb)
    into items
    from (
      select pg_catalog.jsonb_build_object(
        'id', stock_picking_requests.id,
        'kind', 'picking',
        'label', stock_picking_requests.request_number,
        'godown_id', stock_picking_requests.branch_id,
        'picking_request_id', stock_picking_requests.id,
        'dispatch_id', preparing.id,
        'order_id', stock_picking_requests.order_id,
        'status', stock_picking_requests.status,
        'lines', coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'product_id', grain.product_id,
            'product_sku', products.sku,
            'product_name', products.name,
            'crate_id', grain.crate_id,
            'crate_code', crates.code,
            'lot_id', grain.lot_id,
            'reserved_cases', grain.reserved_cases
          ) order by products.sku)
          from (
            select
              stock_reservations.product_id,
              stock_reservations.crate_id,
              stock_reservations.lot_id,
              sum(stock_reservations.reserved_cases)::integer as reserved_cases
            from public.stock_reservations
            where stock_reservations.picking_request_id = stock_picking_requests.id
              and stock_reservations.status = 'active'
            group by stock_reservations.product_id, stock_reservations.crate_id, stock_reservations.lot_id
          ) grain
          join public.products on products.id = grain.product_id
          join public.crates on crates.id = grain.crate_id
        ), '[]'::jsonb)
      ) as item
      from public.stock_picking_requests
      left join public.stock_dispatch_requests preparing
        on preparing.picking_request_id = stock_picking_requests.id
        and preparing.status = 'preparing'
        and preparing.stock_consumed = false
      where stock_picking_requests.branch_id = target_godown
        and stock_picking_requests.status in ('allocated', 'picking', 'picked', 'ready_for_dispatch')
        and (
          cleaned_search is null
          or pg_catalog.lower(stock_picking_requests.request_number) like '%' || cleaned_search || '%' escape '\'
        )
      order by stock_picking_requests.created_at desc, stock_picking_requests.id desc
      offset (safe_page - 1) * safe_size
      limit safe_size
    ) listed;
  elsif cleaned_scenario = 'transit' then
    select count(*) into total_count
    from public.stock_dispatch_requests
    where stock_dispatch_requests.branch_id = target_godown
      and stock_dispatch_requests.stock_consumed
      and stock_dispatch_requests.status in ('dispatched', 'in_transit', 'delivered', 'exception')
      and (
        app_private.has_permission('damage.record')
        or stock_dispatch_requests.assigned_to = auth.uid()
      )
      and (
        cleaned_search is null
        or pg_catalog.lower(stock_dispatch_requests.request_number) like '%' || cleaned_search || '%' escape '\'
      );

    select coalesce(pg_catalog.jsonb_agg(item), '[]'::jsonb)
    into items
    from (
      select pg_catalog.jsonb_build_object(
        'id', stock_dispatch_requests.id,
        'kind', 'dispatch_consumed',
        'label', stock_dispatch_requests.request_number,
        'godown_id', stock_dispatch_requests.branch_id,
        'dispatch_id', stock_dispatch_requests.id,
        'picking_request_id', stock_dispatch_requests.picking_request_id,
        'order_id', stock_dispatch_requests.order_id,
        'status', stock_dispatch_requests.status,
        'assigned_to', stock_dispatch_requests.assigned_to,
        'lines', coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'product_id', grain.product_id,
            'product_sku', products.sku,
            'product_name', products.name,
            'crate_id', grain.crate_id,
            'crate_code', crates.code,
            'lot_id', grain.lot_id,
            'reserved_cases', grain.reserved_cases
          ) order by products.sku)
          from (
            select
              stock_reservations.product_id,
              stock_reservations.crate_id,
              stock_reservations.lot_id,
              sum(stock_reservations.reserved_cases)::integer as reserved_cases
            from public.stock_reservations
            where stock_reservations.picking_request_id = stock_dispatch_requests.picking_request_id
              and stock_reservations.status in ('active', 'consumed')
            group by stock_reservations.product_id, stock_reservations.crate_id, stock_reservations.lot_id
          ) grain
          join public.products on products.id = grain.product_id
          join public.crates on crates.id = grain.crate_id
        ), '[]'::jsonb)
      ) as item
      from public.stock_dispatch_requests
      where stock_dispatch_requests.branch_id = target_godown
        and stock_dispatch_requests.stock_consumed
        and stock_dispatch_requests.status in ('dispatched', 'in_transit', 'delivered', 'exception')
        and (
          app_private.has_permission('damage.record')
          or stock_dispatch_requests.assigned_to = auth.uid()
        )
        and (
          cleaned_search is null
          or pg_catalog.lower(stock_dispatch_requests.request_number) like '%' || cleaned_search || '%' escape '\'
        )
      order by stock_dispatch_requests.created_at desc, stock_dispatch_requests.id desc
      offset (safe_page - 1) * safe_size
      limit safe_size
    ) listed;
  elsif cleaned_scenario = 'shop_return' then
    select count(*) into total_count
    from public.shops
    where shops.is_active
      and (
        cleaned_search is null
        or pg_catalog.lower(shops.name) like '%' || cleaned_search || '%' escape '\'
      );

    select coalesce(pg_catalog.jsonb_agg(item), '[]'::jsonb)
    into items
    from (
      select pg_catalog.jsonb_build_object(
        'id', shops.id,
        'kind', 'shop',
        'label', shops.name,
        'godown_id', target_godown,
        'shop_id', shops.id
      ) as item
      from public.shops
      where shops.is_active
        and (
          cleaned_search is null
          or pg_catalog.lower(shops.name) like '%' || cleaned_search || '%' escape '\'
        )
      order by shops.name, shops.id
      offset (safe_page - 1) * safe_size
      limit safe_size
    ) listed;

    catalogs := pg_catalog.jsonb_build_object(
      'crates', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', crates.id,
          'code', crates.code,
          'name', crates.name,
          'zone_code', zones.code
        ) order by crates.code)
        from public.crates
        join public.zones on zones.id = crates.zone_id
        where zones.branch_id = target_godown
          and crates.is_active
          and crates.location_role is distinct from 'quarantine'
      ), '[]'::jsonb),
      -- Shop-return lines are not on-hand bound. Cap the catalog to keep the
      -- picker from downloading the full product master.
      'products', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', listed.id,
          'sku', listed.sku,
          'name', listed.name
        ))
        from (
          select products.id, products.sku, products.name
          from public.products
          where products.is_active
          order by products.sku
          limit 200
        ) listed
      ), '[]'::jsonb)
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'total', total_count,
    'page', safe_page,
    'page_size', safe_size,
    'items', coalesce(items, '[]'::jsonb),
    'catalogs', catalogs
  );
end;
$$;

revoke all on function public.list_damage_report_sources(text, uuid, text, integer, integer)
  from public, anon, service_role;
grant execute on function public.list_damage_report_sources(text, uuid, text, integer, integer)
  to authenticated;
