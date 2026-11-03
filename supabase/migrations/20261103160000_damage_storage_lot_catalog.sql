-- DMG-03D: Storage damage catalogs expose eligible lot grains, and draft
-- replace validates lot↔product↔crate when dual-write is on. Isolation still
-- re-checks availability under locks; this closes the UI/RPC lot gap only.

create or replace function app_private.build_damage_storage_catalogs(
  p_godown uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
begin
  return pg_catalog.jsonb_build_object(
    'dual_write_enabled', dual_write,
    'crates', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', crates.id,
        'code', crates.code,
        'name', crates.name,
        'zone_code', zones.code
      ) order by crates.code)
      from public.crates
      join public.zones on zones.id = crates.zone_id
      where zones.branch_id = p_godown
        and crates.is_active
        and crates.location_role is distinct from 'quarantine'
    ), '[]'::jsonb),
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
            and zones.branch_id = p_godown
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
      where zones.branch_id = p_godown
        and stock_balances.quantity > 0
    ), '[]'::jsonb),
    -- Lot grains use the same availability engine as picking (on_hand − reserved − holds).
    'lots', case
      when not dual_write then '[]'::jsonb
      else coalesce((
        select pg_catalog.jsonb_agg(grain.payload order by grain.sort_sku, grain.sort_crate, grain.sort_expiry nulls last, grain.sort_code, grain.sort_lot)
        from (
          select
            pg_catalog.jsonb_build_object(
              'lot_id', stock_lots.id,
              'product_id', stock_lots.product_id,
              'crate_id', stock_lot_balances.crate_id,
              'manufacturer_lot_code', stock_lots.manufacturer_lot_code,
              'expiry_date', stock_lots.expiry_date,
              'on_hand_cases', stock_lot_balances.quantity,
              'reserved_cases', app_private.active_reserved_lot_cases(
                stock_lots.id, stock_lot_balances.crate_id
              ),
              'held_cases', app_private.active_damage_hold_lot_cases(
                stock_lots.id, stock_lot_balances.crate_id
              ),
              'available_cases', app_private.picking_available_cases(
                stock_lots.id, stock_lot_balances.crate_id
              )
            ) as payload,
            products.sku as sort_sku,
            crates.code as sort_crate,
            stock_lots.expiry_date as sort_expiry,
            stock_lots.manufacturer_lot_code as sort_code,
            stock_lots.id as sort_lot
          from public.stock_lot_balances
          join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
          join public.products on products.id = stock_lots.product_id
          join public.crates on crates.id = stock_lot_balances.crate_id
          join public.zones on zones.id = crates.zone_id
          where zones.branch_id = p_godown
            and stock_lots.branch_id = p_godown
            and stock_lot_balances.quantity > 0
            and crates.is_active
            and crates.location_role is distinct from 'quarantine'
        ) grain
      ), '[]'::jsonb)
    end
  );
end;
$$;

revoke all on function app_private.build_damage_storage_catalogs(uuid)
  from public, anon, authenticated, service_role;

-- Storage dual-write: require lot and prove the grain exists at crate/product.
create or replace function app_private.replace_damage_lines(
  target_report uuid,
  scenario text,
  target_godown uuid,
  source_receipt uuid,
  source_picking uuid,
  source_dispatch uuid,
  report_lines jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
  line_product uuid;
  line_crate uuid;
  line_lot uuid;
  line_receipt uuid;
  line_qty integer;
  line_reason text;
  line_notes text;
  sort_no integer := 0;
  picking uuid;
  reserved_qty integer;
  reported_qty integer;
  damaged_qty integer;
  already_qty integer;
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
begin
  if report_lines is null or pg_catalog.jsonb_typeof(report_lines) is distinct from 'array'
    or pg_catalog.jsonb_array_length(report_lines) < 1
  then
    raise exception 'a damage report needs at least one line' using errcode = '23514';
  end if;

  delete from public.damage_report_lines
  where damage_report_lines.damage_report_id = target_report;

  if scenario = 'loading' then
    select coalesce(source_picking, stock_dispatch_requests.picking_request_id)
    into picking
    from public.stock_dispatch_requests
    where stock_dispatch_requests.id = source_dispatch;

    picking := coalesce(source_picking, picking);
  elsif scenario = 'transit' then
    select stock_dispatch_requests.picking_request_id
    into picking
    from public.stock_dispatch_requests
    where stock_dispatch_requests.id = source_dispatch;
  end if;

  for item in
    select value from jsonb_array_elements(report_lines)
  loop
    sort_no := sort_no + 1;
    begin
      line_product := (item ->> 'product_id')::uuid;
    exception
      when others then
        raise exception 'product is required' using errcode = '23514';
    end;

    if line_product is null or not exists (
      select 1 from public.products where products.id = line_product
    ) then
      raise exception 'product is inactive or missing' using errcode = '23514';
    end if;

    begin
      line_crate := nullif(item ->> 'crate_id', '')::uuid;
    exception
      when others then
        raise exception 'crate is invalid' using errcode = '23514';
    end;

    begin
      line_lot := nullif(item ->> 'lot_id', '')::uuid;
    exception
      when others then
        raise exception 'stock lot is invalid' using errcode = '23514';
    end;

    begin
      line_receipt := nullif(item ->> 'receipt_line_id', '')::uuid;
    exception
      when others then
        raise exception 'receipt line is invalid' using errcode = '23514';
    end;

    line_qty := app_private.receipt_case_count(item -> 'quantity_cases');
    if line_qty < 1 then
      raise exception 'quantity must be a whole number of carton cases'
        using errcode = '23514';
    end if;

    line_reason := pg_catalog.btrim(coalesce(item ->> 'damage_reason', ''));
    if pg_catalog.char_length(line_reason) < 1
      or pg_catalog.char_length(line_reason) > 80
    then
      raise exception 'damage reason is required' using errcode = '23514';
    end if;

    line_notes := app_private.clean_verification_text(item ->> 'notes', false);
    perform app_private.assert_optional_damage_lot(line_lot, line_product, target_godown);

    if scenario in ('refill_supply', 'unloading') then
      if line_receipt is null then
        raise exception 'inbound damage requires a receipt line' using errcode = '23514';
      end if;

      select stock_receipt_lines.damaged_cases, stock_receipt_lines.destination_crate_id
      into damaged_qty, line_crate
      from public.stock_receipt_lines
      join public.stock_receipts
        on stock_receipts.id = stock_receipt_lines.receipt_id
      where stock_receipt_lines.id = line_receipt
        and stock_receipt_lines.receipt_id = source_receipt
        and stock_receipt_lines.product_id = line_product
        and stock_receipts.godown_id = target_godown
      for update of stock_receipt_lines;

      if not found then
        raise exception 'receipt line does not match this damage report'
          using errcode = '23514';
      end if;

      already_qty := app_private.damage_open_receipt_qty(line_receipt, target_report);
      if already_qty + line_qty > damaged_qty then
        raise exception 'damaged quantity exceeds the receipt line'
          using errcode = '23514';
      end if;
    elsif scenario in ('storage', 'loading') then
      perform app_private.assert_crate_in_godown(line_crate, target_godown);

      -- Dual-write storage drafts must name the damaged lot at draft time so
      -- submit isolation never depends on a SQL workaround or browser guess.
      if scenario = 'storage' and dual_write then
        if line_lot is null then
          raise exception 'storage damage requires a lot when lot-aware dual-write is enabled'
            using errcode = '23514';
        end if;

        if not exists (
          select 1
          from public.stock_lot_balances
          join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
          where stock_lot_balances.lot_id = line_lot
            and stock_lot_balances.crate_id = line_crate
            and stock_lots.product_id = line_product
            and stock_lots.branch_id = target_godown
        ) then
          raise exception 'stock lot is not available at the selected crate'
            using errcode = '23514';
        end if;

        -- Early reject against the same available floor submit uses; submit
        -- still re-checks under grain locks for concurrency.
        if line_qty > app_private.picking_available_cases(line_lot, line_crate) then
          raise exception 'insufficient unreserved stock' using errcode = '23514';
        end if;
      end if;
    elsif scenario = 'shop_return' then
      if line_crate is not null then
        perform app_private.assert_crate_in_godown(line_crate, target_godown);
      end if;
    elsif scenario = 'transit' then
      if line_crate is not null then
        perform app_private.assert_crate_in_godown(line_crate, target_godown);
      end if;
    end if;

    if scenario in ('loading', 'transit') then
      if picking is null then
        raise exception 'loading damage requires a reserved grain' using errcode = '23514';
      end if;

      select coalesce(sum(stock_reservations.reserved_cases), 0)
      into reserved_qty
      from public.stock_reservations
      where stock_reservations.picking_request_id = picking
        and stock_reservations.product_id = line_product
        and (
          line_crate is null
          or stock_reservations.crate_id = line_crate
        );

      if reserved_qty < 1 then
        raise exception 'loading damage requires a reserved grain' using errcode = '23514';
      end if;
    end if;

    insert into public.damage_report_lines (
      damage_report_id, product_id, crate_id, lot_id, receipt_line_id,
      quantity_cases, damage_reason, notes, sort_order
    )
    values (
      target_report, line_product, line_crate, line_lot, line_receipt,
      line_qty, line_reason, line_notes, sort_no
    );
  end loop;

  if scenario in ('loading', 'transit') then
    for line_product in
      select distinct damage_report_lines.product_id
      from public.damage_report_lines
      where damage_report_lines.damage_report_id = target_report
    loop
      select coalesce(sum(damage_report_lines.quantity_cases), 0)
      into reported_qty
      from public.damage_report_lines
      where damage_report_lines.damage_report_id = target_report
        and damage_report_lines.product_id = line_product;

      select coalesce(sum(stock_reservations.reserved_cases), 0)
      into reserved_qty
      from public.stock_reservations
      where stock_reservations.picking_request_id = picking
        and stock_reservations.product_id = line_product;

      if reported_qty > reserved_qty then
        raise exception 'damaged quantity exceeds the source document'
          using errcode = '23514';
      end if;
    end loop;
  end if;
end;
$$;

revoke all on function app_private.replace_damage_lines(
  uuid, text, uuid, uuid, uuid, uuid, jsonb
) from public, anon, authenticated, service_role;

comment on function app_private.replace_damage_lines(uuid, text, uuid, uuid, uuid, uuid, jsonb) is
  'Replaces damage lines. Storage dual-write requires a lot grain at the crate; inbound claims lock the receipt line.';

-- Wire storage catalogs through the lot-aware builder (crates/products/balances/lots).
CREATE OR REPLACE FUNCTION public.list_damage_report_sources(scenario text, target_godown uuid, search_text text DEFAULT NULL::text, page integer DEFAULT 1, page_size integer DEFAULT 50, catalog_search text DEFAULT NULL::text, catalog_page integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  cleaned_scenario text := pg_catalog.lower(pg_catalog.btrim(coalesce(scenario, '')));
  cleaned_search text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(search_text, ''))), '');
  cleaned_catalog text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(catalog_search, ''))), '');
  safe_page integer := greatest(coalesce(page, 1), 1);
  safe_size integer := least(greatest(coalesce(page_size, 50), 1), 50);
  safe_catalog_page integer := greatest(coalesce(catalog_page, 1), 1);
  total_count integer := 0;
  product_total integer := 0;
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
  if cleaned_catalog is not null then
    cleaned_catalog := replace(replace(replace(cleaned_catalog, '\', '\\'), '%', '\%'), '_', '\_');
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
    catalogs := app_private.build_damage_storage_catalogs(target_godown);
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

    select count(*)::integer into product_total
    from public.products
    where products.is_active
      and (
        cleaned_catalog is null
        or pg_catalog.lower(products.sku) like '%' || cleaned_catalog || '%' escape '\'
        or pg_catalog.lower(products.name) like '%' || cleaned_catalog || '%' escape '\'
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
            and (
              cleaned_catalog is null
              or pg_catalog.lower(products.sku) like '%' || cleaned_catalog || '%' escape '\'
              or pg_catalog.lower(products.name) like '%' || cleaned_catalog || '%' escape '\'
            )
          order by products.sku, products.id
          offset (safe_catalog_page - 1) * safe_size
          limit safe_size
        ) listed
      ), '[]'::jsonb),
      'products_total', product_total,
      'products_page', safe_catalog_page
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
$function$;

grant execute on function public.list_damage_report_sources(
  text, uuid, text, integer, integer, text, integer
) to authenticated;

revoke all on function public.list_damage_report_sources(
  text, uuid, text, integer, integer, text, integer
) from public, anon, service_role;

-- Isolation: reject mismatched lot grains before availability math.
create or replace function app_private.isolate_storage_damage(header public.damage_reports)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  line public.damage_report_lines;
  on_hand integer;
  reserved integer;
  held integer;
  crate_ids uuid[];
  product_ids uuid[];
  lot_ids uuid[];
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
begin
  select array_agg(distinct crate_id), array_agg(distinct product_id),
         array_remove(array_agg(distinct lot_id), null)
  into crate_ids, product_ids, lot_ids
  from public.damage_report_lines
  where damage_report_id = header.id;

  if crate_ids is null or exists (
    select 1 from public.damage_report_lines
    where damage_report_id = header.id and crate_id is null
  ) then
    raise exception 'storage damage requires a crate' using errcode = '23514';
  end if;

  if dual_write and exists (
    select 1 from public.damage_report_lines
    where damage_report_id = header.id and lot_id is null
  ) then
    raise exception 'storage damage requires a lot when lot-aware dual-write is enabled'
      using errcode = '23514';
  end if;

  perform app_private.lock_damage_stock_grains(header.godown_id, crate_ids, product_ids, lot_ids);

  perform stock_lot_balances.lot_id
  from public.stock_lot_balances
  where stock_lot_balances.crate_id = any (crate_ids)
    and (lot_ids is null or stock_lot_balances.lot_id = any (lot_ids))
  order by stock_lot_balances.crate_id, stock_lot_balances.lot_id
  for update of stock_lot_balances;

  perform stock_balances.crate_id
  from public.stock_balances
  where stock_balances.crate_id = any (crate_ids)
    and stock_balances.product_id = any (product_ids)
  order by stock_balances.crate_id, stock_balances.product_id
  for update of stock_balances;

  for line in
    select * from public.damage_report_lines
    where damage_report_id = header.id
    order by crate_id, product_id, lot_id
  loop
    if app_private.crate_is_quarantine(line.crate_id) then
      raise exception 'quarantine locations cannot be used for ordinary stock posting'
        using errcode = '23514';
    end if;

    if line.lot_id is not null then
      -- Trusted grain check: lot must belong to product/godown and sit at crate.
      if not exists (
        select 1
        from public.stock_lots
        join public.stock_lot_balances
          on stock_lot_balances.lot_id = stock_lots.id
        where stock_lots.id = line.lot_id
          and stock_lots.product_id = line.product_id
          and stock_lots.branch_id = header.godown_id
          and stock_lot_balances.crate_id = line.crate_id
      ) then
        raise exception 'stock lot is not available at the selected crate'
          using errcode = '23514';
      end if;

      select coalesce(quantity, 0) into on_hand
      from public.stock_lot_balances
      where lot_id = line.lot_id and crate_id = line.crate_id;
      reserved := app_private.active_reserved_lot_cases(line.lot_id, line.crate_id);
      held := app_private.active_damage_hold_lot_cases(line.lot_id, line.crate_id);
    else
      select coalesce(sum(quantity), 0) into on_hand
      from public.stock_balances
      where crate_id = line.crate_id and product_id = line.product_id;

      reserved := app_private.active_reserved_grain_cases(line.crate_id, line.product_id);
      held := app_private.active_damage_hold_grain_cases(line.crate_id, line.product_id);
    end if;

    if line.quantity_cases > on_hand - reserved - held then
      raise exception 'insufficient unreserved stock' using errcode = '23514';
    end if;

    insert into public.damage_stock_holds (
      damage_report_id, damage_report_line_id, product_id, crate_id, lot_id,
      quantity_cases, hold_kind, status
    )
    values (
      header.id, line.id, line.product_id, line.crate_id, line.lot_id,
      line.quantity_cases, 'on_hand_deduction', 'active'
    );
  end loop;
end;
$$;

revoke all on function app_private.isolate_storage_damage(public.damage_reports)
  from public, anon, authenticated, service_role;
