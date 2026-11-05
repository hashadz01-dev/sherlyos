-- DMG-06 salesperson shop-return workflow (local-first).
-- Salesperson may create/submit shop_return only for assigned shops.
-- Submit does not post inventory. GM confirms custody on submitted reports.
-- Independent verify posts quarantine intake exactly once.
-- Does not flip operational flags. Does not alter historical stock postings.

-- ---------------------------------------------------------------------------
-- 1. Permission: shop-return create without warehouse damage.record
-- ---------------------------------------------------------------------------

insert into public.permissions (code, description)
values (
  'damage.shop_return.record',
  'Create, edit own drafts, submit, and view authorized shop-return (DMG-06) damage reports. Does not grant warehouse scenarios, custody confirmation, verification, or disposition.'
)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id)
select roles.id, permissions.id
from public.roles
join public.permissions on permissions.code = 'damage.shop_return.record'
where roles.code = 'salesperson'
on conflict do nothing;

-- Intentionally no damage.read for salesperson: visibility is own shop_return
-- reports via can_view_damage_report + damage.shop_return.record only.

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------

create or replace function app_private.salesperson_assigned_to_shop(target_shop uuid)
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
      and shop_salesperson_assignments.salesperson_id = auth.uid()
      and shop_salesperson_assignments.is_active
  );
$$;

revoke all on function app_private.salesperson_assigned_to_shop(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_shop_return_receive_godown(target_godown uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if target_godown is null
    or not exists (
      select 1
      from public.branches
      where branches.id = target_godown
        and branches.is_active
    )
  then
    raise exception 'godown is inactive or missing' using errcode = '23514';
  end if;
end;
$$;

revoke all on function app_private.assert_shop_return_receive_godown(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_damage_create_auth(
  scenario text,
  target_godown uuid,
  target_dispatch uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  header public.stock_dispatch_requests;
  gm_transit boolean;
  driver_transit boolean;
  godown_active boolean;
  shop_return_salesperson boolean;
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if scenario = 'transit' then
    select *
    into header
    from public.stock_dispatch_requests
    where stock_dispatch_requests.id = target_dispatch;

    if not found or header.branch_id is distinct from target_godown then
      raise exception 'not authorized' using errcode = '42501';
    end if;

    if not header.stock_consumed then
      raise exception 'transit damage requires a consumed dispatch'
        using errcode = '23514';
    end if;

    if header.status not in ('dispatched', 'in_transit', 'delivered', 'exception') then
      raise exception 'dispatch is not eligible for transit damage'
        using errcode = '23514';
    end if;

    if not app_private.can_complete_consumed_delivery_at_branch(target_godown) then
      raise exception 'not authorized' using errcode = '42501';
    end if;

    gm_transit := app_private.has_permission('damage.record');
    driver_transit := app_private.has_permission('deliveries.execute')
      and header.assigned_to is not distinct from auth.uid();

    if not gm_transit and not driver_transit then
      raise exception 'not authorized' using errcode = '42501';
    end if;

    return;
  end if;

  if scenario = 'shop_return' then
    shop_return_salesperson :=
      app_private.has_permission('damage.shop_return.record')
      and not app_private.has_permission('damage.verify');

    if shop_return_salesperson then
      perform app_private.assert_shop_return_receive_godown(target_godown);
      return;
    end if;

    if not app_private.has_permission('damage.record') then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    if not app_private.can_work_at_branch(target_godown) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    select branches.is_active
    into godown_active
    from public.branches
    where branches.id = target_godown;
    if godown_active is not true then
      raise exception 'godown is inactive' using errcode = '23514';
    end if;
    if not app_private.has_permission('damage.verify') then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    return;
  end if;

  if not app_private.has_permission('damage.record') then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if scenario in ('refill_supply', 'unloading') then
    perform app_private.assert_operational_active_branch(target_godown);
  else
    if not app_private.can_work_at_branch(target_godown) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    select branches.is_active
    into godown_active
    from public.branches
    where branches.id = target_godown;
    if godown_active is not true then
      raise exception 'godown is inactive' using errcode = '23514';
    end if;
  end if;

  if scenario in ('refill_supply', 'unloading') then
    if not (
      app_private.has_permission('receiving.execute')
      or app_private.has_permission('damage.verify')
    ) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
  elsif scenario = 'loading' then
    if not (
      app_private.has_permission('loading.assist')
      or app_private.has_permission('damage.verify')
    ) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
  elsif scenario = 'storage' then
    null;
  else
    raise exception 'damage scenario is invalid' using errcode = '23514';
  end if;
end;
$$;

comment on function app_private.assert_damage_create_auth(text, uuid, uuid) is
  'Create/update/submit/list-source auth. Shop-return: salesperson with damage.shop_return.record at an active godown, or damage.record+damage.verify at an authorized godown.';

create or replace function app_private.validate_damage_sources(
  scenario text,
  target_godown uuid,
  receipt_id uuid,
  picking_request_id uuid,
  dispatch_id uuid,
  order_id uuid,
  shop_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  receipt public.stock_receipts;
  picking public.stock_picking_requests;
  header public.stock_dispatch_requests;
  shop_order public.orders;
begin
  if scenario in ('refill_supply', 'unloading') then
    if receipt_id is null
      or picking_request_id is not null
      or dispatch_id is not null
      or order_id is not null
      or shop_id is not null
    then
      raise exception 'inbound damage requires a receipt only' using errcode = '23514';
    end if;

    select *
    into receipt
    from public.stock_receipts
    where stock_receipts.id = receipt_id;

    if not found
      or receipt.godown_id is distinct from target_godown
      or receipt.status is distinct from 'posted'
    then
      raise exception 'receipt is not eligible for damage reporting'
        using errcode = '23514';
    end if;
    return;
  end if;

  if scenario = 'storage' then
    if receipt_id is not null
      or picking_request_id is not null
      or dispatch_id is not null
      or order_id is not null
      or shop_id is not null
    then
      raise exception 'storage damage cannot reference another document'
        using errcode = '23514';
    end if;
    return;
  end if;

  if scenario = 'loading' then
    if receipt_id is not null or shop_id is not null or order_id is not null then
      raise exception 'loading damage cannot reference a receipt or shop'
        using errcode = '23514';
    end if;

    if picking_request_id is null and dispatch_id is null then
      raise exception 'loading damage requires picking or dispatch preparation'
        using errcode = '23514';
    end if;

    if dispatch_id is not null then
      select *
      into header
      from public.stock_dispatch_requests
      where stock_dispatch_requests.id = dispatch_id;

      if not found
        or header.branch_id is distinct from target_godown
        or header.stock_consumed
        or header.status is distinct from 'preparing'
      then
        raise exception 'dispatch is not eligible for loading damage'
          using errcode = '23514';
      end if;

      if picking_request_id is not null
        and header.picking_request_id is distinct from picking_request_id
      then
        raise exception 'loading damage dispatch does not match picking'
          using errcode = '23514';
      end if;
    end if;

    select *
    into picking
    from public.stock_picking_requests
    where stock_picking_requests.id = coalesce(
      picking_request_id,
      header.picking_request_id
    );

    if not found
      or picking.branch_id is distinct from target_godown
      or picking.status not in ('allocated', 'picking', 'picked', 'ready_for_dispatch')
    then
      raise exception 'picking is not eligible for loading damage'
        using errcode = '23514';
    end if;
    return;
  end if;

  if scenario = 'transit' then
    if dispatch_id is null
      or receipt_id is not null
      or picking_request_id is not null
      or order_id is not null
      or shop_id is not null
    then
      raise exception 'transit damage requires a dispatch only' using errcode = '23514';
    end if;
    return;
  end if;

  if scenario = 'shop_return' then
    if shop_id is null
      or receipt_id is not null
      or picking_request_id is not null
      or dispatch_id is not null
    then
      raise exception 'shop-return damage requires a shop and no inbound source'
        using errcode = '23514';
    end if;

    if not exists (
      select 1 from public.shops
      where shops.id = shop_id
        and shops.is_active
    ) then
      raise exception 'shop is inactive or missing' using errcode = '23514';
    end if;

    -- Salesperson may only reference actively assigned shops.
    if app_private.has_permission('damage.shop_return.record')
      and not app_private.has_permission('damage.verify')
      and not app_private.salesperson_assigned_to_shop(shop_id)
    then
      raise exception 'not authorized' using errcode = '42501';
    end if;

    if order_id is not null then
      select *
      into shop_order
      from public.orders
      where orders.id = order_id;

      if not found
        or shop_order.shop_id is distinct from shop_id
        or shop_order.branch_id is distinct from target_godown
      then
        raise exception 'shop return order does not match this godown'
          using errcode = '23514';
      end if;
    end if;
    return;
  end if;

  raise exception 'damage scenario is invalid' using errcode = '23514';
end;
$$;

create or replace function app_private.can_view_damage_report(
  target_godown uuid,
  scenario text,
  reporter uuid,
  target_dispatch uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    return false;
  end if;

  if app_private.has_permission('operations.monitor') then
    return true;
  end if;

  if app_private.has_permission('damage.read')
    and app_private.can_work_at_branch(target_godown)
  then
    return true;
  end if;

  if scenario = 'shop_return'
    and reporter = auth.uid()
    and app_private.has_permission('damage.shop_return.record')
  then
    return true;
  end if;

  if scenario = 'transit'
    and reporter = auth.uid()
    and app_private.has_permission('deliveries.execute')
    and target_dispatch is not null
    and exists (
      select 1
      from public.stock_dispatch_requests
      where stock_dispatch_requests.id = target_dispatch
        and stock_dispatch_requests.assigned_to = auth.uid()
        and stock_dispatch_requests.branch_id = target_godown
    )
  then
    return true;
  end if;

  return false;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Receive-godown catalog for salesperson picker
-- ---------------------------------------------------------------------------

create or replace function public.list_shop_return_receive_godowns()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if not (
    app_private.has_permission('damage.shop_return.record')
    or app_private.has_permission('damage.record')
    or app_private.has_permission('damage.verify')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', branches.id,
      'code', branches.code,
      'name', branches.name,
      'is_active', branches.is_active
    ) order by branches.name, branches.code)
    from public.branches
    where branches.is_active
      and (
        app_private.has_permission('damage.shop_return.record')
        or app_private.can_work_at_branch(branches.id)
      )
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.list_shop_return_receive_godowns()
  from public, anon, service_role;
grant execute on function public.list_shop_return_receive_godowns() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. list_damage_report_sources (prior body + salesperson shop filter)
-- ---------------------------------------------------------------------------

create or replace function public.list_damage_report_sources(scenario text, target_godown uuid, search_text text DEFAULT NULL::text, page integer DEFAULT 1, page_size integer DEFAULT 50, catalog_search text DEFAULT NULL::text, catalog_page integer DEFAULT 1)

returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
  salesperson_only boolean;
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

  salesperson_only :=
    cleaned_scenario = 'shop_return'
    and app_private.has_permission('damage.shop_return.record')
    and not app_private.has_permission('damage.verify');

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
        not salesperson_only
        or app_private.salesperson_assigned_to_shop(shops.id)
      )
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
          not salesperson_only
          or app_private.salesperson_assigned_to_shop(shops.id)
        )
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
$$;

-- ---------------------------------------------------------------------------
-- 5. Readiness + submit (shop_return skips stock on submit)
-- ---------------------------------------------------------------------------

create or replace function public.damage_stock_hold_ready_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if not (
    app_private.has_permission('damage.read')
    or app_private.has_permission('damage.record')
    or app_private.has_permission('damage.shop_return.record')
    or app_private.has_permission('damage.verify')
    or app_private.has_permission('operations.monitor')
    or app_private.has_permission('deliveries.execute')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'stock_hold_ready', app_private.damage_stock_hold_ready()
  );
end;
$$;

create or replace function public.submit_damage_report(
  target_report uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
  cleaned_key text;
begin
  perform set_config('app.damage_write', 'on', true);
  selected := app_private.lock_damage_report(target_report);
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  if selected.status = 'submitted'
    and selected.submit_idempotency_key = cleaned_key
  then
    return app_private.damage_report_payload(selected.id);
  end if;

  perform app_private.assert_damage_version(selected, expected_version);

  if selected.status not in ('draft', 'returned')
    or selected.reporter_user_id is distinct from auth.uid()
  then
    raise exception 'damage report cannot be submitted' using errcode = '42501';
  end if;

  if selected.submit_idempotency_key is not null
    and selected.submit_idempotency_key is distinct from cleaned_key
    and selected.status = 'submitted'
  then
    raise exception 'idempotency key already used for a different request'
      using errcode = '23505';
  end if;

  perform app_private.assert_damage_create_auth(
    selected.scenario, selected.godown_id, selected.dispatch_id
  );
  perform app_private.validate_damage_sources(
    selected.scenario, selected.godown_id, selected.receipt_id,
    selected.picking_request_id, selected.dispatch_id, selected.order_id,
    selected.shop_id
  );

  -- Shop-return claim only. Quarantine intake posts on independent verify.
  if app_private.damage_requires_stock_hold(selected.scenario)
    and selected.scenario is distinct from 'shop_return'
  then
    perform app_private.apply_damage_stock_isolation(selected.id);
  end if;

  if not exists (
    select 1 from public.damage_report_lines
    where damage_report_lines.damage_report_id = selected.id
  ) then
    raise exception 'a damage report needs at least one line' using errcode = '23514';
  end if;

  update public.damage_reports
  set
    status = 'submitted',
    submitted_at = pg_catalog.clock_timestamp(),
    submitted_by = auth.uid(),
    submit_idempotency_key = cleaned_key,
    version = selected.version + 1
  where damage_reports.id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'submitted', selected.status, 'submitted', '{}'::jsonb
  );
  perform app_private.write_audit(
    auth.uid(), 'submit_damage_report', 'damage_reports', selected.id, '{}'::jsonb
  );

  return app_private.damage_report_payload(selected.id);
end;
$$;

comment on function public.submit_damage_report(uuid, integer, text) is
  'Submit draft/returned reports. Storage/loading isolate on submit. Shop-return does not post stock; quarantine intake occurs on verify after custody.';

-- ---------------------------------------------------------------------------
-- 6. Custody on submitted shop_return (GM only; no stock)
-- ---------------------------------------------------------------------------

create or replace function public.confirm_shop_return_custody(
  target_report uuid,
  expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
begin
  perform set_config('app.damage_write', 'on', true);
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);

  perform app_private.assert_permission('damage.record');
  perform app_private.assert_permission('damage.verify');
  perform app_private.assert_damage_godown_active_unlocked(selected.godown_id);

  if selected.scenario is distinct from 'shop_return'
    or selected.status is distinct from 'submitted'
  then
    raise exception 'physical custody cannot be confirmed' using errcode = '42501';
  end if;

  -- Salesperson cannot reach this RPC (needs damage.record + damage.verify).
  -- A Godown Manager who created a shop_return may confirm their own report.

  if selected.physical_custody_confirmed_at is not null then
    return app_private.damage_report_payload(selected.id);
  end if;

  update public.damage_reports
  set
    physical_custody_confirmed_at = pg_catalog.clock_timestamp(),
    physical_custody_confirmed_by = auth.uid(),
    version = selected.version + 1
  where id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'custody_confirmed', selected.status, selected.status, '{}'::jsonb
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

comment on function public.confirm_shop_return_custody(uuid, integer) is
  'GM confirms physical receipt of submitted shop-return goods. Requires damage.record+damage.verify. No stock posting. Idempotent when already confirmed.';

-- ---------------------------------------------------------------------------
-- 7. Verify posts shop_return quarantine intake once
-- ---------------------------------------------------------------------------

create or replace function public.verify_damage_report(
  target_report uuid,
  expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.damage_reports;
begin
  perform set_config('app.damage_write', 'on', true);
  perform app_private.assert_permission('damage.verify');
  selected := app_private.lock_damage_report(target_report);
  perform app_private.assert_damage_version(selected, expected_version);
  perform app_private.assert_damage_godown_active_unlocked(selected.godown_id);

  if selected.status is distinct from 'submitted' then
    raise exception 'damage report cannot be verified' using errcode = '42501';
  end if;

  if selected.reporter_user_id is not distinct from auth.uid() then
    raise exception 'the reporter cannot verify this damage report' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.damage_evidence
    where damage_evidence.damage_report_id = selected.id
      and damage_evidence.verified_at is not null
  ) then
    raise exception 'photographic evidence is required' using errcode = '23514';
  end if;

  if selected.scenario = 'shop_return' then
    if selected.physical_custody_confirmed_at is null
      or selected.physical_custody_confirmed_by is null
    then
      raise exception 'shop-return damage requires confirmed physical custody'
        using errcode = '23514';
    end if;

    -- Post quarantine intake exactly once (existing holds short-circuit).
    perform app_private.apply_damage_stock_isolation(selected.id);
  end if;

  if app_private.damage_requires_stock_hold(selected.scenario)
    and not exists (
      select 1 from public.damage_stock_holds
      where damage_report_id = selected.id
        and status in ('active', 'transferred')
    )
  then
    raise exception 'damage stock isolation is not ready' using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.damage_report_lines
    where damage_report_id = selected.id
      and quantity_cases is distinct from (
        select coalesce(sum(damage_stock_holds.quantity_cases), 0)
        from public.damage_stock_holds
        where damage_stock_holds.damage_report_line_id = damage_report_lines.id
          and damage_stock_holds.status in ('active', 'transferred')
      )
      and app_private.damage_requires_stock_hold(selected.scenario)
  ) then
    raise exception 'verified quantities cannot exceed isolated quantities'
      using errcode = '23514';
  end if;

  update public.damage_reports
  set
    status = 'verified',
    verifier_user_id = auth.uid(),
    verified_at = pg_catalog.clock_timestamp(),
    version = selected.version + 1
  where damage_reports.id = selected.id;

  perform app_private.record_damage_event(
    selected.id, 'verified', selected.status, 'verified', '{}'::jsonb
  );
  perform app_private.write_audit(
    auth.uid(), 'verify_damage_report', 'damage_reports', selected.id, '{}'::jsonb
  );
  return app_private.damage_report_payload(selected.id);
end;
$$;

comment on function public.verify_damage_report(uuid, integer) is
  'Independent verification. Shop-return posts quarantine intake once after custody. Reporter cannot self-verify. Storage/loading still require holds from submit.';

-- ---------------------------------------------------------------------------
-- 8. Dashboard (prior totals + shop_return.record + submitted custody queue)
-- ---------------------------------------------------------------------------

create or replace function public.get_damage_dashboard(target_godown uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  visible_ids uuid[];
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if not (
    app_private.has_permission('damage.read')
    or app_private.has_permission('damage.record')
    or app_private.has_permission('damage.shop_return.record')
    or app_private.has_permission('damage.verify')
    or app_private.has_permission('operations.monitor')
    or app_private.has_permission('deliveries.execute')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select coalesce(array_agg(damage_reports.id), '{}'::uuid[])
  into visible_ids
  from public.damage_reports
  where (target_godown is null or damage_reports.godown_id = target_godown)
    and app_private.can_view_damage_report(
      damage_reports.godown_id,
      damage_reports.scenario,
      damage_reports.reporter_user_id,
      damage_reports.dispatch_id
    );

  return pg_catalog.jsonb_build_object(
    'stock_hold_ready', app_private.damage_stock_hold_ready(),
    'totals', pg_catalog.jsonb_build_object(
      'reports', coalesce(pg_catalog.cardinality(visible_ids), 0),
      'pending_verification', (
        select count(*)::integer from public.damage_reports
        where id = any (visible_ids) and status = 'submitted'
      ),
      'verified', (
        select count(*)::integer from public.damage_reports
        where id = any (visible_ids) and status = 'verified'
      ),
      'active_hold_cases', coalesce((
        select sum(damage_stock_holds.quantity_cases)::integer
        from public.damage_stock_holds
        where damage_stock_holds.damage_report_id = any (visible_ids)
          and damage_stock_holds.status in ('active', 'transferred')
      ), 0),
      'quarantined_cases', coalesce((
        select sum(damage_stock_holds.quantity_cases)::integer
        from public.damage_stock_holds
        join public.crates on crates.id = damage_stock_holds.crate_id
        where damage_stock_holds.damage_report_id = any (visible_ids)
          and damage_stock_holds.status in ('active', 'transferred')
          and (
            damage_stock_holds.hold_kind = 'quarantine_intake'
            or crates.location_role = 'quarantine'
          )
      ), 0),
      'pending_exceptional', (
        select count(*)::integer
        from public.damage_exceptional_requests
        where damage_exceptional_requests.damage_report_id = any (visible_ids)
          and damage_exceptional_requests.status in ('requested', 'approved')
      ),
      -- Historical posted cartons. Never added into active_hold_cases.
      'ordinary_writeoff_cases', coalesce((
        select sum(damage_stock_holds.quantity_cases)::integer
        from public.damage_stock_holds
        where damage_stock_holds.damage_report_id = any (visible_ids)
          and damage_stock_holds.status = 'written_off'
          and exists (
            select 1
            from public.damage_report_events
            where damage_report_events.damage_report_id =
              damage_stock_holds.damage_report_id
              and damage_report_events.action = 'ordinary_writeoff'
          )
      ), 0),
      'exceptional_writeoff_cases', coalesce((
        select sum(damage_stock_holds.quantity_cases)::integer
        from public.damage_stock_holds
        where damage_stock_holds.damage_report_id = any (visible_ids)
          and damage_stock_holds.status = 'written_off'
          and exists (
            select 1
            from public.damage_report_events
            where damage_report_events.damage_report_id =
              damage_stock_holds.damage_report_id
              and damage_report_events.action = 'exceptional_posted'
          )
      ), 0),
      'returned_supplier_cases', coalesce((
        select sum(damage_stock_holds.quantity_cases)::integer
        from public.damage_stock_holds
        where damage_stock_holds.damage_report_id = any (visible_ids)
          and damage_stock_holds.status = 'returned_supplier'
      ), 0)
    ),
    'queues', pg_catalog.jsonb_build_object(
      'recent_submitted', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', q.id,
          'report_number', q.report_number,
          'scenario', q.scenario,
          'status', q.status,
          'godown_name', q.godown_name,
          'created_at', q.created_at
        ))
        from (
          select damage_reports.id, damage_reports.report_number, damage_reports.scenario,
            damage_reports.status, branches.name as godown_name, damage_reports.created_at
          from public.damage_reports
          join public.branches on branches.id = damage_reports.godown_id
          where damage_reports.id = any (visible_ids)
            and damage_reports.status = 'submitted'
          order by damage_reports.created_at desc
          limit 8
        ) q
      ), '[]'::jsonb),
      'awaiting_verification', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', q.id,
          'report_number', q.report_number,
          'scenario', q.scenario,
          'status', q.status,
          'godown_name', q.godown_name,
          'created_at', q.created_at
        ))
        from (
          select damage_reports.id, damage_reports.report_number, damage_reports.scenario,
            damage_reports.status, branches.name as godown_name, damage_reports.created_at
          from public.damage_reports
          join public.branches on branches.id = damage_reports.godown_id
          where damage_reports.id = any (visible_ids)
            and damage_reports.status = 'submitted'
          order by damage_reports.created_at asc
          limit 8
        ) q
      ), '[]'::jsonb),
      'awaiting_custody', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', q.id,
          'report_number', q.report_number,
          'scenario', q.scenario,
          'status', q.status,
          'godown_name', q.godown_name,
          'created_at', q.created_at
        ))
        from (
          select damage_reports.id, damage_reports.report_number, damage_reports.scenario,
            damage_reports.status, branches.name as godown_name, damage_reports.created_at
          from public.damage_reports
          join public.branches on branches.id = damage_reports.godown_id
          where damage_reports.id = any (visible_ids)
            and damage_reports.scenario = 'shop_return'
            and damage_reports.status = 'submitted'
            and damage_reports.physical_custody_confirmed_at is null
          order by damage_reports.created_at asc
          limit 8
        ) q
      ), '[]'::jsonb),
      'awaiting_disposition', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', q.id,
          'report_number', q.report_number,
          'scenario', q.scenario,
          'status', q.status,
          'godown_name', q.godown_name,
          'created_at', q.created_at
        ))
        from (
          select damage_reports.id, damage_reports.report_number, damage_reports.scenario,
            damage_reports.status, branches.name as godown_name, damage_reports.created_at
          from public.damage_reports
          join public.branches on branches.id = damage_reports.godown_id
          where damage_reports.id = any (visible_ids)
            and damage_reports.status = 'verified'
            and exists (
              select 1 from public.damage_stock_holds
              where damage_stock_holds.damage_report_id = damage_reports.id
                and damage_stock_holds.status in ('active', 'transferred')
            )
          order by damage_reports.created_at asc
          limit 8
        ) q
      ), '[]'::jsonb),
      'exceptional_pending', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', q.id,
          'report_number', q.report_number,
          'scenario', q.scenario,
          'status', q.status,
          'godown_name', q.godown_name,
          'disposition_kind', q.disposition_kind,
          'exceptional_status', q.exceptional_status,
          'created_at', q.created_at
        ))
        from (
          select damage_reports.id, damage_reports.report_number, damage_reports.scenario,
            damage_reports.status, branches.name as godown_name,
            damage_exceptional_requests.disposition_kind,
            damage_exceptional_requests.status as exceptional_status,
            damage_exceptional_requests.requested_at as created_at
          from public.damage_exceptional_requests
          join public.damage_reports
            on damage_reports.id = damage_exceptional_requests.damage_report_id
          join public.branches on branches.id = damage_reports.godown_id
          where damage_reports.id = any (visible_ids)
            and damage_exceptional_requests.status in ('requested', 'approved')
          order by damage_exceptional_requests.requested_at asc
          limit 8
        ) q
      ), '[]'::jsonb),
      'recently_resolved', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', q.id,
          'report_number', q.report_number,
          'scenario', q.scenario,
          'status', q.status,
          'godown_name', q.godown_name,
          'created_at', q.created_at
        ))
        from (
          select damage_reports.id, damage_reports.report_number, damage_reports.scenario,
            damage_reports.status, branches.name as godown_name, damage_reports.updated_at as created_at
          from public.damage_reports
          join public.branches on branches.id = damage_reports.godown_id
          where damage_reports.id = any (visible_ids)
            and damage_reports.status in ('verified', 'rejected', 'cancelled')
            and not exists (
              select 1 from public.damage_stock_holds
              where damage_stock_holds.damage_report_id = damage_reports.id
                and damage_stock_holds.status in ('active', 'transferred')
            )
          order by damage_reports.updated_at desc
          limit 8
        ) q
      ), '[]'::jsonb)
    )
  );
end;
$$;

revoke all on function public.list_damage_report_sources(
  text, uuid, text, integer, integer, text, integer
) from public, anon, service_role;
grant execute on function public.list_damage_report_sources(
  text, uuid, text, integer, integer, text, integer
) to authenticated;

revoke all on function public.get_damage_dashboard(uuid)
  from public, anon, service_role;
grant execute on function public.get_damage_dashboard(uuid) to authenticated;
