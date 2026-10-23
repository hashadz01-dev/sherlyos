-- M4 operational intelligence. Read-only reporting. Does not post stock,
-- create operational documents, or change cutover flags.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function app_private.report_require_auth()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

create or replace function app_private.report_can_view_inventory()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app_private.has_permission('stock.read')
    or app_private.has_permission('operations.monitor');
$$;

create or replace function app_private.report_can_view_orders()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app_private.has_permission('operations.monitor')
    or app_private.has_permission('orders.verify')
    or app_private.has_permission('orders.capture')
    or app_private.has_permission('picking.allocate')
    or app_private.has_permission('picking.manage')
    or app_private.has_permission('picking.execute');
$$;

create or replace function app_private.report_can_view_dispatch()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app_private.has_permission('dispatch.view')
    or app_private.has_permission('dispatch.confirm')
    or app_private.has_permission('deliveries.execute')
    or app_private.has_permission('deliveries.assign')
    or app_private.has_permission('operations.monitor');
$$;

create or replace function app_private.report_can_view_operations()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app_private.report_can_view_inventory()
    or app_private.has_permission('receiving.execute')
    or app_private.has_permission('receiving.verify')
    or app_private.has_permission('stock.verify')
    or app_private.has_permission('stock.adjustment.request')
    or app_private.has_permission('stock.adjustment.post')
    or app_private.has_permission('stock.lots.physical_reconcile')
    or app_private.has_permission('stock.lots.legacy.reconcile')
    or app_private.has_permission('operations.monitor');
$$;

-- Capture/verify/monitor keep can_view_order. Warehouse roles see operational
-- pipeline rows at their branch, not salesperson drafts or held capture.
create or replace function app_private.report_can_see_order(target_order uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app_private.can_view_order(target_order)
    or exists (
      select 1
      from public.orders
      where orders.id = target_order
        and app_private.can_work_at_branch(orders.branch_id)
        and orders.status not in ('draft', 'submitted', 'held')
        and (
          app_private.has_permission('picking.allocate')
          or app_private.has_permission('picking.manage')
          or app_private.has_permission('picking.execute')
          or app_private.has_permission('dispatch.view')
          or app_private.has_permission('dispatch.confirm')
        )
    );
$$;

create or replace function app_private.report_clamp_page(
  requested_page integer,
  requested_size integer
)
returns table (page integer, page_size integer, row_offset integer)
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  safe_page integer := greatest(coalesce(requested_page, 1), 1);
  safe_size integer := least(greatest(coalesce(requested_size, 50), 1), 100);
begin
  return query select safe_page, safe_size, (safe_page - 1) * safe_size;
end;
$$;

create or replace function app_private.report_assert_window(
  posted_from timestamptz,
  posted_to timestamptz
)
returns void
language plpgsql
immutable
security definer
set search_path = ''
as $$
begin
  if posted_from is not null and posted_to is not null and posted_from >= posted_to then
    raise exception 'date range end must be after start' using errcode = '23514';
  end if;
end;
$$;

-- Refuse an unauthorized branch filter instead of returning a silent empty set.
create or replace function app_private.report_assert_branch(filter_branch uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if filter_branch is not null and not app_private.can_work_at_branch(filter_branch) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

-- Prefix formula-triggering cells so spreadsheet apps treat them as text.
-- Leading whitespace, C0 controls, NBSP, and BOM still count as formula prefixes.
create or replace function app_private.report_csv_cell(raw text)
returns text
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  value text := coalesce(raw, '');
  stripped text;
begin
  stripped := regexp_replace(
    value,
    E'^([[:cntrl:][:space:]]|' || chr(160) || '|' || chr(65279) || ')+',
    ''
  );
  if stripped ~ '^[=+\-@]' then
    value := '''' || value;
  end if;
  return '"' || replace(value, '"', '""') || '"';
end;
$$;

create or replace function app_private.report_near_expiry_days()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select (app_configuration.value #>> '{}')::integer
    from public.app_configuration
    where app_configuration.key = 'stock.near_expiry_warning_days'
  ), 90);
$$;

create or replace function app_private.report_txn_branch(txn public.stock_transactions)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select zones.branch_id
      from public.crates
      join public.zones on zones.id = crates.zone_id
      where crates.id = coalesce(txn.destination_crate_id, txn.source_crate_id)
    ),
    (
      select stock_dispatch_requests.branch_id
      from public.stock_dispatch_requests
      where stock_dispatch_requests.id = txn.dispatch_request_id
    )
  );
$$;

revoke all on function app_private.report_require_auth() from public, anon, authenticated, service_role;
revoke all on function app_private.report_can_view_inventory() from public, anon, authenticated, service_role;
revoke all on function app_private.report_can_view_orders() from public, anon, authenticated, service_role;
revoke all on function app_private.report_can_view_dispatch() from public, anon, authenticated, service_role;
revoke all on function app_private.report_can_view_operations() from public, anon, authenticated, service_role;
revoke all on function app_private.report_can_see_order(uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.report_clamp_page(integer, integer) from public, anon, authenticated, service_role;
revoke all on function app_private.report_assert_window(timestamptz, timestamptz) from public, anon, authenticated, service_role;
revoke all on function app_private.report_assert_branch(uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.report_csv_cell(text) from public, anon, authenticated, service_role;
revoke all on function app_private.report_near_expiry_days() from public, anon, authenticated, service_role;
revoke all on function app_private.report_txn_branch(public.stock_transactions) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Dashboard
-- ---------------------------------------------------------------------------

create or replace function public.get_operations_dashboard(filter_branch uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
  inventory jsonb := jsonb_build_object('visible', false);
  orders jsonb := jsonb_build_object('visible', false);
  picking jsonb := jsonb_build_object('visible', false);
  dispatch jsonb := jsonb_build_object('visible', false);
  operations jsonb := jsonb_build_object('visible', false);
  deliveries jsonb := jsonb_build_object('visible', false);
  available_pick jsonb;
begin
  perform app_private.report_require_auth();

  if not (
    app_private.report_can_view_inventory()
    or app_private.report_can_view_orders()
    or app_private.report_can_view_dispatch()
    or app_private.report_can_view_operations()
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  perform app_private.report_assert_branch(filter_branch);

  if app_private.report_can_view_inventory() then
    if dual_write then
      available_pick := jsonb_build_object(
        'state', 'available',
        'value', coalesce((
          select sum(app_private.picking_available_cases(stock_lot_balances.lot_id, stock_lot_balances.crate_id))
          from public.stock_lot_balances
          join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
          join public.crates on crates.id = stock_lot_balances.crate_id
          join public.zones on zones.id = crates.zone_id
          where app_private.can_work_at_branch(zones.branch_id)
            and (filter_branch is null or zones.branch_id = filter_branch)
            and stock_lots.status = 'available'
        ), 0)
      );
    else
      -- Cutover inactive: aggregate on-hand is not available-to-pick.
      available_pick := jsonb_build_object(
        'state', 'not_applicable',
        'reason', 'lot_aware_allocation_inactive',
        'value', null
      );
    end if;

    inventory := jsonb_build_object(
      'visible', true,
      'total_cartons_on_hand', coalesce((
        select sum(stock_balances.quantity)
        from public.stock_balances
        join public.crates on crates.id = stock_balances.crate_id
        join public.zones on zones.id = crates.zone_id
        where app_private.can_work_at_branch(zones.branch_id)
          and (filter_branch is null or zones.branch_id = filter_branch)
      ), 0),
      'products_with_positive_stock', coalesce((
        select count(distinct stock_balances.product_id)
        from public.stock_balances
        join public.crates on crates.id = stock_balances.crate_id
        join public.zones on zones.id = crates.zone_id
        where stock_balances.quantity > 0
          and app_private.can_work_at_branch(zones.branch_id)
          and (filter_branch is null or zones.branch_id = filter_branch)
      ), 0),
      'stock_by_godown', coalesce((
        select jsonb_agg(jsonb_build_object(
          'branch_id', rows.branch_id,
          'branch_code', rows.branch_code,
          'branch_name', rows.branch_name,
          'cartons', rows.cartons
        ) order by rows.branch_name)
        from (
          select
            branches.id as branch_id,
            branches.code as branch_code,
            branches.name as branch_name,
            coalesce(sum(stock_balances.quantity), 0) as cartons
          from public.branches
          left join public.zones on zones.branch_id = branches.id
          left join public.crates on crates.zone_id = zones.id
          left join public.stock_balances on stock_balances.crate_id = crates.id
          where app_private.can_work_at_branch(branches.id)
            and (filter_branch is null or branches.id = filter_branch)
          group by branches.id, branches.code, branches.name
        ) rows
      ), '[]'::jsonb),
      'lot_attributed_cartons', coalesce((
        select sum(stock_lot_balances.quantity)
        from public.stock_lot_balances
        join public.crates on crates.id = stock_lot_balances.crate_id
        join public.zones on zones.id = crates.zone_id
        where app_private.can_work_at_branch(zones.branch_id)
          and (filter_branch is null or zones.branch_id = filter_branch)
      ), 0),
      'legacy_unattributed_cartons', coalesce((
        select sum(stock_lot_balances.quantity)
        from public.stock_lot_balances
        join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
        join public.crates on crates.id = stock_lot_balances.crate_id
        join public.zones on zones.id = crates.zone_id
        where stock_lots.status = 'legacy_unattributed'
          and app_private.can_work_at_branch(zones.branch_id)
          and (filter_branch is null or zones.branch_id = filter_branch)
      ), 0),
      'active_reserved_cartons', coalesce((
        select sum(stock_reservations.reserved_cases)
        from public.stock_reservations
        where stock_reservations.status = 'active'
          and app_private.can_work_at_branch(stock_reservations.branch_id)
          and (filter_branch is null or stock_reservations.branch_id = filter_branch)
      ), 0),
      'available_to_pick', available_pick
    );
  end if;

  if app_private.report_can_view_orders() then
    orders := jsonb_build_object(
      'visible', true,
      'draft', coalesce((select count(*) from public.orders where app_private.report_can_see_order(orders.id) and orders.status = 'draft' and (filter_branch is null or orders.branch_id = filter_branch)), 0),
      'submitted', coalesce((select count(*) from public.orders where app_private.report_can_see_order(orders.id) and orders.status = 'submitted' and (filter_branch is null or orders.branch_id = filter_branch)), 0),
      'held', coalesce((select count(*) from public.orders where app_private.report_can_see_order(orders.id) and orders.status = 'held' and (filter_branch is null or orders.branch_id = filter_branch)), 0),
      'verified', coalesce((select count(*) from public.orders where app_private.report_can_see_order(orders.id) and orders.status = 'verified' and (filter_branch is null or orders.branch_id = filter_branch)), 0),
      'cancelled', coalesce((select count(*) from public.orders where app_private.report_can_see_order(orders.id) and orders.status = 'cancelled' and (filter_branch is null or orders.branch_id = filter_branch)), 0),
      'awaiting_picking', coalesce((
        select count(*)
        from public.orders
        where app_private.report_can_see_order(orders.id)
          and orders.status = 'verified'
          and (filter_branch is null or orders.branch_id = filter_branch)
          and not exists (
            select 1
            from public.stock_picking_requests
            where stock_picking_requests.order_id = orders.id
              and stock_picking_requests.status is distinct from 'cancelled'
          )
      ), 0)
    );

    if app_private.has_permission('picking.allocate')
      or app_private.has_permission('picking.manage')
      or app_private.has_permission('picking.execute')
      or app_private.has_permission('operations.monitor')
    then
      picking := jsonb_build_object(
        'visible', true,
        'allocated', coalesce((select count(*) from public.stock_picking_requests where status = 'allocated' and app_private.can_work_at_branch(branch_id) and (filter_branch is null or branch_id = filter_branch)), 0),
        'picking', coalesce((select count(*) from public.stock_picking_requests where status = 'picking' and app_private.can_work_at_branch(branch_id) and (filter_branch is null or branch_id = filter_branch)), 0),
        'picked', coalesce((select count(*) from public.stock_picking_requests where status = 'picked' and app_private.can_work_at_branch(branch_id) and (filter_branch is null or branch_id = filter_branch)), 0),
        'ready_for_dispatch', coalesce((select count(*) from public.stock_picking_requests where status = 'ready_for_dispatch' and app_private.can_work_at_branch(branch_id) and (filter_branch is null or branch_id = filter_branch)), 0),
        'blocked', coalesce((select count(*) from public.stock_picking_requests where status = 'blocked' and app_private.can_work_at_branch(branch_id) and (filter_branch is null or branch_id = filter_branch)), 0),
        'active_reserved_cartons', coalesce((
          select sum(stock_reservations.reserved_cases)
          from public.stock_reservations
          where stock_reservations.status = 'active'
            and app_private.can_work_at_branch(stock_reservations.branch_id)
            and (filter_branch is null or stock_reservations.branch_id = filter_branch)
        ), 0),
        'exception_rows', coalesce((
          select count(*)
          from public.stock_picking_exceptions
          join public.stock_picking_requests
            on stock_picking_requests.id = stock_picking_exceptions.picking_request_id
          where app_private.can_work_at_branch(stock_picking_requests.branch_id)
            and (filter_branch is null or stock_picking_requests.branch_id = filter_branch)
        ), 0)
      );
    end if;
  end if;

  if app_private.report_can_view_dispatch() then
    dispatch := jsonb_build_object(
      'visible', true,
      'preparing', coalesce((
        select count(*) from public.stock_dispatch_requests
        where status = 'preparing' and stock_consumed = false
          and app_private.can_work_at_branch(branch_id)
          and (filter_branch is null or branch_id = filter_branch)
          and (
            app_private.has_permission('dispatch.view')
            or app_private.has_permission('operations.monitor')
            or assigned_to = auth.uid()
          )
      ), 0),
      'dispatched', coalesce((
        select count(*) from public.stock_dispatch_requests
        where status = 'dispatched' and stock_consumed
          and app_private.can_work_at_branch(branch_id)
          and (filter_branch is null or branch_id = filter_branch)
          and (
            app_private.has_permission('dispatch.view')
            or app_private.has_permission('operations.monitor')
            or assigned_to = auth.uid()
          )
      ), 0),
      'in_transit', coalesce((
        select count(*) from public.stock_dispatch_requests
        where status = 'in_transit' and stock_consumed
          and app_private.can_work_at_branch(branch_id)
          and (filter_branch is null or branch_id = filter_branch)
          and (
            app_private.has_permission('dispatch.view')
            or app_private.has_permission('operations.monitor')
            or assigned_to = auth.uid()
          )
      ), 0),
      'delivered', coalesce((
        select count(*) from public.stock_dispatch_requests
        where status = 'delivered' and stock_consumed
          and app_private.can_work_at_branch(branch_id)
          and (filter_branch is null or branch_id = filter_branch)
          and (
            app_private.has_permission('dispatch.view')
            or app_private.has_permission('operations.monitor')
            or assigned_to = auth.uid()
          )
      ), 0),
      'exception', coalesce((
        select count(*) from public.stock_dispatch_requests
        where status = 'exception'
          and app_private.can_work_at_branch(branch_id)
          and (filter_branch is null or branch_id = filter_branch)
          and (
            app_private.has_permission('dispatch.view')
            or app_private.has_permission('operations.monitor')
            or assigned_to = auth.uid()
          )
      ), 0),
      'pending_proof_of_delivery', coalesce((
        select count(*) from public.stock_dispatch_requests
        where status in ('dispatched', 'in_transit') and stock_consumed
          and app_private.can_work_at_branch(branch_id)
          and (filter_branch is null or branch_id = filter_branch)
          and (
            app_private.has_permission('dispatch.view')
            or app_private.has_permission('operations.monitor')
            or assigned_to = auth.uid()
          )
      ), 0),
      'dispatched_cartons', coalesce((
        select sum(stock_transactions.quantity)
        from public.stock_transactions
        where stock_transactions.transaction_type = 'DISPATCH'
          and app_private.can_work_at_branch(app_private.report_txn_branch(stock_transactions))
          and (filter_branch is null or app_private.report_txn_branch(stock_transactions) = filter_branch)
          and (
            app_private.has_permission('dispatch.view')
            or app_private.has_permission('operations.monitor')
            or exists (
              select 1
              from public.stock_dispatch_requests
              where stock_dispatch_requests.id = stock_transactions.dispatch_request_id
                and stock_dispatch_requests.assigned_to = auth.uid()
            )
          )
      ), 0)
    );
  end if;

  if app_private.has_permission('deliveries.execute')
    and not app_private.has_permission('dispatch.view')
    and not app_private.has_permission('operations.monitor')
  then
    deliveries := jsonb_build_object(
      'visible', true,
      'assigned_open', coalesce((
        select count(*) from public.stock_dispatch_requests
        where assigned_to = auth.uid()
          and status in ('dispatched', 'in_transit')
          and stock_consumed
          and app_private.can_work_at_branch(branch_id)
          and (filter_branch is null or branch_id = filter_branch)
      ), 0),
      'delivered', coalesce((
        select count(*) from public.stock_dispatch_requests
        where assigned_to = auth.uid()
          and status = 'delivered'
          and app_private.can_work_at_branch(branch_id)
          and (filter_branch is null or branch_id = filter_branch)
      ), 0),
      'exception', coalesce((
        select count(*) from public.stock_dispatch_requests
        where assigned_to = auth.uid()
          and status = 'exception'
          and app_private.can_work_at_branch(branch_id)
          and (filter_branch is null or branch_id = filter_branch)
      ), 0)
    );
  end if;

  if app_private.report_can_view_operations() then
    operations := jsonb_build_object(
      'visible', true,
      'pending_receiving', coalesce((
        select count(*) from public.stock_receipts
        where stock_receipts.status in ('draft', 'submitted', 'held')
          and app_private.can_work_at_branch(stock_receipts.godown_id)
          and (filter_branch is null or stock_receipts.godown_id = filter_branch)
      ), 0),
      'pending_adjustments', coalesce((
        select count(*) from public.stock_adjustment_requests
        where stock_adjustment_requests.status in ('draft', 'submitted', 'returned', 'approved')
          and app_private.can_work_at_branch(stock_adjustment_requests.godown_id)
          and (filter_branch is null or stock_adjustment_requests.godown_id = filter_branch)
      ), 0),
      'pending_verification', coalesce((
        select count(*) from public.stock_verifications
        where stock_verifications.status is distinct from 'closed'
          and app_private.can_work_at_branch(stock_verifications.godown_id)
          and (filter_branch is null or stock_verifications.godown_id = filter_branch)
      ), 0),
      'unclassified_products', coalesce((
        select count(*) from public.products
        where products.expiry_policy is null
          and (
            app_private.has_permission('products.read')
            or app_private.has_permission('stock.read')
            or app_private.has_permission('operations.monitor')
          )
      ), 0),
      'pending_physical_returns', coalesce((
        select count(*) from public.stock_dispatch_requests
        where physical_return_status = 'pending_verification'
          and app_private.can_work_at_branch(branch_id)
          and (filter_branch is null or branch_id = filter_branch)
          and (
            app_private.has_permission('dispatch.view')
            or app_private.has_permission('operations.monitor')
            or assigned_to = auth.uid()
          )
      ), 0)
    );
  end if;

  return jsonb_build_object(
    'timezone', 'UTC',
    'authorized_branches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', branches.id,
        'code', branches.code,
        'name', branches.name
      ) order by branches.name)
      from public.branches
      where branches.is_active
        and app_private.can_work_at_branch(branches.id)
        and (filter_branch is null or branches.id = filter_branch)
    ), '[]'::jsonb),
    'cutover', jsonb_build_object(
      'dual_write_enabled', dual_write,
      'aggregate_only_blocked', coalesce((
        select (app_configuration.value #>> '{}')::boolean
        from public.app_configuration
        where app_configuration.key = 'stock.lots.aggregate_only_blocked'
      ), false)
    ),
    'filter_branch', filter_branch,
    'inventory', inventory,
    'orders', orders,
    'picking', picking,
    'dispatch', dispatch,
    'deliveries', deliveries,
    'operations', operations
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Inventory report
-- ---------------------------------------------------------------------------

create or replace function public.list_inventory_report(
  grain text default 'crate',
  filter_branch uuid default null,
  filter_zone uuid default null,
  filter_crate uuid default null,
  filter_product uuid default null,
  filter_category uuid default null,
  filter_supplier uuid default null,
  include_zero boolean default false,
  page integer default 1,
  page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cleaned_grain text := coalesce(nullif(btrim(grain), ''), 'crate');
  paging record;
  total integer := 0;
  rows jsonb := '[]'::jsonb;
begin
  perform app_private.report_require_auth();
  if not app_private.report_can_view_inventory() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform app_private.report_assert_branch(filter_branch);
  if cleaned_grain not in ('crate', 'zone', 'godown', 'product') then
    raise exception 'inventory grain is invalid' using errcode = '23514';
  end if;

  select * into paging from app_private.report_clamp_page(page, page_size);

  with scoped as (
    select
      branches.id as branch_id,
      branches.code as branch_code,
      branches.name as branch_name,
      zones.id as zone_id,
      zones.code as zone_code,
      zones.name as zone_name,
      crates.id as crate_id,
      crates.code as crate_code,
      crates.name as crate_name,
      products.id as product_id,
      products.sku as product_sku,
      products.name as product_name,
      products.expiry_policy,
      products.category_id,
      products.supplier_id,
      stock_balances.quantity
    from public.stock_balances
    join public.crates on crates.id = stock_balances.crate_id
    join public.zones on zones.id = crates.zone_id
    join public.branches on branches.id = zones.branch_id
    join public.products on products.id = stock_balances.product_id
    where app_private.can_work_at_branch(branches.id)
      and (filter_branch is null or branches.id = filter_branch)
      and (filter_zone is null or zones.id = filter_zone)
      and (filter_crate is null or crates.id = filter_crate)
      and (filter_product is null or products.id = filter_product)
      and (filter_category is null or products.category_id = filter_category)
      and (filter_supplier is null or products.supplier_id = filter_supplier)
      and (include_zero or stock_balances.quantity > 0)
  ),
  grouped as (
    select
      case cleaned_grain
        when 'godown' then branch_id::text
        when 'zone' then zone_id::text
        when 'product' then product_id::text
        else crate_id::text || ':' || product_id::text
      end as row_key,
      branch_id,
      max(branch_code) as branch_code,
      max(branch_name) as branch_name,
      case when cleaned_grain in ('crate', 'zone') then zone_id else null end as zone_id,
      case when cleaned_grain in ('crate', 'zone') then max(zone_code) else null end as zone_code,
      case when cleaned_grain = 'crate' then crate_id else null end as crate_id,
      case when cleaned_grain = 'crate' then max(crate_code) else null end as crate_code,
      case when cleaned_grain in ('crate', 'product') then product_id else null end as product_id,
      case when cleaned_grain in ('crate', 'product') then max(product_sku) else null end as product_sku,
      case when cleaned_grain in ('crate', 'product') then max(product_name) else null end as product_name,
      sum(quantity)::integer as quantity,
      count(*)::integer as grain_rows
    from scoped
    group by 1, 2,
      case when cleaned_grain in ('crate', 'zone') then zone_id else null end,
      case when cleaned_grain = 'crate' then crate_id else null end,
      case when cleaned_grain in ('crate', 'product') then product_id else null end
  ),
  counted as (
    select count(*)::integer as total_count from grouped
  ),
  paged as (
    select *
    from grouped
    order by branch_name, zone_code nulls first, crate_code nulls first, product_sku nulls first, row_key
    offset paging.row_offset
    limit paging.page_size
  )
  select counted.total_count,
    coalesce((
      select jsonb_agg(to_jsonb(paged) order by paged.branch_name, paged.zone_code, paged.crate_code, paged.product_sku)
      from paged
    ), '[]'::jsonb)
  into total, rows
  from counted;

  return jsonb_build_object(
    'timezone', 'UTC',
    'grain', cleaned_grain,
    'page', paging.page,
    'page_size', paging.page_size,
    'total_count', total,
    'rows', rows
  );
end;
$$;

create or replace function public.list_lot_stock_report(
  filter_branch uuid default null,
  filter_crate uuid default null,
  filter_product uuid default null,
  filter_lot_status text default null,
  expiry_bucket text default null,
  page integer default 1,
  page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  paging record;
  total integer := 0;
  rows jsonb := '[]'::jsonb;
  warn_days integer := app_private.report_near_expiry_days();
  cleaned_status text := nullif(btrim(coalesce(filter_lot_status, '')), '');
  cleaned_bucket text := nullif(btrim(coalesce(expiry_bucket, '')), '');
begin
  perform app_private.report_require_auth();
  if not app_private.report_can_view_inventory() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform app_private.report_assert_branch(filter_branch);
  if cleaned_status is not null and cleaned_status not in (
    'available', 'quarantined', 'expired_blocked', 'legacy_unattributed'
  ) then
    raise exception 'lot status is invalid' using errcode = '23514';
  end if;
  if cleaned_bucket is not null and cleaned_bucket not in (
    'expired', 'approaching', 'unknown_expiry', 'none'
  ) then
    raise exception 'expiry bucket is invalid' using errcode = '23514';
  end if;

  select * into paging from app_private.report_clamp_page(page, page_size);

  with scoped as (
    select
      stock_lots.id as lot_id,
      stock_lots.status as lot_status,
      stock_lots.origin,
      stock_lots.manufacturer_lot_code,
      stock_lots.expiry_date,
      stock_lots.received_on,
      products.id as product_id,
      products.sku as product_sku,
      products.name as product_name,
      products.expiry_policy,
      branches.id as branch_id,
      branches.code as branch_code,
      crates.id as crate_id,
      crates.code as crate_code,
      stock_lot_balances.quantity,
      case
        when products.expiry_policy is distinct from 'expiry_controlled' then 'none'
        when stock_lots.expiry_date is null then 'unknown_expiry'
        when stock_lots.expiry_date < (pg_catalog.timezone('UTC', clock_timestamp()))::date then 'expired'
        when stock_lots.expiry_date <= (pg_catalog.timezone('UTC', clock_timestamp()))::date + warn_days then 'approaching'
        else 'none'
      end as expiry_bucket
    from public.stock_lot_balances
    join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
    join public.products on products.id = stock_lots.product_id
    join public.crates on crates.id = stock_lot_balances.crate_id
    join public.zones on zones.id = crates.zone_id
    join public.branches on branches.id = zones.branch_id
    where app_private.can_work_at_branch(branches.id)
      and (filter_branch is null or branches.id = filter_branch)
      and (filter_crate is null or crates.id = filter_crate)
      and (filter_product is null or products.id = filter_product)
      and (cleaned_status is null or stock_lots.status = cleaned_status)
  ),
  filtered as (
    select *
    from scoped
    where cleaned_bucket is null or scoped.expiry_bucket = cleaned_bucket
  ),
  counted as (
    select count(*)::integer as total_count from filtered
  ),
  paged as (
    select *
    from filtered
    order by branch_code, crate_code, product_sku, lot_id
    offset paging.row_offset
    limit paging.page_size
  )
  select counted.total_count,
    coalesce((
      select jsonb_agg(to_jsonb(paged) order by paged.branch_code, paged.crate_code, paged.product_sku, paged.lot_id)
      from paged
    ), '[]'::jsonb)
  into total, rows
  from counted;

  return jsonb_build_object(
    'timezone', 'UTC',
    'near_expiry_warning_days', warn_days,
    'page', paging.page,
    'page_size', paging.page_size,
    'total_count', total,
    'rows', rows
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Movement report (document grain — transfers counted once)
-- ---------------------------------------------------------------------------

create or replace function public.list_stock_movement_report(
  filter_branch uuid default null,
  filter_product uuid default null,
  movement_type text default null,
  posted_from timestamptz default null,
  posted_to timestamptz default null,
  page integer default 1,
  page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  paging record;
  total integer := 0;
  rows jsonb := '[]'::jsonb;
  cleaned_type text := nullif(btrim(coalesce(movement_type, '')), '');
  summary jsonb;
begin
  perform app_private.report_require_auth();
  if not app_private.report_can_view_inventory() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform app_private.report_assert_branch(filter_branch);
  perform app_private.report_assert_window(posted_from, posted_to);
  if cleaned_type is not null and cleaned_type not in (
    'OPENING_STOCK', 'CRATE_TRANSFER', 'RECEIPT', 'ADJUSTMENT', 'DISPATCH'
  ) then
    raise exception 'movement type is invalid' using errcode = '23514';
  end if;

  select * into paging from app_private.report_clamp_page(page, page_size);

  with scoped as (
    select
      stock_transactions.id as transaction_id,
      stock_transactions.reference_number,
      stock_transactions.transaction_type,
      stock_transactions.posted_at,
      stock_transactions.quantity,
      products.id as product_id,
      products.sku as product_sku,
      products.name as product_name,
      stock_transactions.source_crate_id,
      source_crate.code as source_crate_code,
      dest_crate.code as destination_crate_code,
      app_private.report_txn_branch(stock_transactions) as branch_id,
      branches.code as branch_code,
      branches.name as branch_name,
      profiles.full_name as actor_name,
      stock_transactions.dispatch_request_id,
      stock_dispatch_requests.request_number as dispatch_number,
      orders.id as order_id,
      orders.order_number,
      (
        select string_agg(distinct coalesce(stock_lots.manufacturer_lot_code, stock_ledger.lot_id::text), ',')
        from public.stock_ledger
        left join public.stock_lots on stock_lots.id = stock_ledger.lot_id
        where stock_ledger.transaction_id = stock_transactions.id
          and stock_ledger.lot_id is not null
      ) as lot_references
    from public.stock_transactions
    join public.products on products.id = stock_transactions.product_id
    left join public.crates as source_crate on source_crate.id = stock_transactions.source_crate_id
    left join public.crates as dest_crate on dest_crate.id = stock_transactions.destination_crate_id
    left join public.stock_dispatch_requests
      on stock_dispatch_requests.id = stock_transactions.dispatch_request_id
    left join public.orders on orders.id = stock_dispatch_requests.order_id
    left join public.branches on branches.id = app_private.report_txn_branch(stock_transactions)
    left join public.profiles on profiles.id = stock_transactions.actor_id
    where app_private.can_work_at_branch(app_private.report_txn_branch(stock_transactions))
      and (filter_branch is null or app_private.report_txn_branch(stock_transactions) = filter_branch)
      and (filter_product is null or products.id = filter_product)
      and (cleaned_type is null or stock_transactions.transaction_type = cleaned_type)
      and (posted_from is null or stock_transactions.posted_at >= posted_from)
      and (posted_to is null or stock_transactions.posted_at < posted_to)
  ),
  counted as (
    select count(*)::integer as total_count from scoped
  ),
  summed as (
    select jsonb_build_object(
      'document_count', count(*),
      'opening_cartons', coalesce(sum(quantity) filter (where transaction_type = 'OPENING_STOCK'), 0),
      'receipt_cartons', coalesce(sum(quantity) filter (where transaction_type = 'RECEIPT'), 0),
      'transfer_cartons', coalesce(sum(quantity) filter (where transaction_type = 'CRATE_TRANSFER'), 0),
      'adjustment_cartons', coalesce(sum(quantity) filter (where transaction_type = 'ADJUSTMENT'), 0),
      'dispatch_cartons', coalesce(sum(quantity) filter (where transaction_type = 'DISPATCH'), 0)
    ) as payload
    from scoped
  ),
  paged as (
    select *
    from scoped
    order by posted_at desc, reference_number desc
    offset paging.row_offset
    limit paging.page_size
  )
  select counted.total_count,
    summed.payload,
    coalesce((
      select jsonb_agg(to_jsonb(paged) order by paged.posted_at desc, paged.reference_number desc)
      from paged
    ), '[]'::jsonb)
  into total, summary, rows
  from counted, summed;

  return jsonb_build_object(
    'timezone', 'UTC',
    'interval', 'half_open',
    'page', paging.page,
    'page_size', paging.page_size,
    'total_count', total,
    'summary', summary,
    'rows', rows
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Orders and picking
-- ---------------------------------------------------------------------------

create or replace function public.list_order_picking_report(
  filter_branch uuid default null,
  filter_shop uuid default null,
  filter_salesperson uuid default null,
  order_status text default null,
  picking_status text default null,
  posted_from timestamptz default null,
  posted_to timestamptz default null,
  page integer default 1,
  page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  paging record;
  total integer := 0;
  rows jsonb := '[]'::jsonb;
  cleaned_order text := nullif(btrim(coalesce(order_status, '')), '');
  cleaned_pick text := nullif(btrim(coalesce(picking_status, '')), '');
begin
  perform app_private.report_require_auth();
  if not app_private.report_can_view_orders() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform app_private.report_assert_branch(filter_branch);
  perform app_private.report_assert_window(posted_from, posted_to);
  if cleaned_order is not null and cleaned_order not in (
    'draft', 'submitted', 'held', 'verified', 'cancelled'
  ) then
    raise exception 'order status is invalid' using errcode = '23514';
  end if;
  if cleaned_pick is not null and cleaned_pick not in (
    'none', 'allocated', 'picking', 'picked', 'ready_for_dispatch', 'blocked', 'cancelled'
  ) then
    raise exception 'picking status is invalid' using errcode = '23514';
  end if;
  if filter_salesperson is not null
    and not (
      app_private.has_permission('operations.monitor')
      or app_private.has_permission('orders.verify')
    )
  then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select * into paging from app_private.report_clamp_page(page, page_size);

  with scoped as (
    select
      orders.id as order_id,
      orders.order_number,
      orders.status as order_status,
      orders.shop_id,
      shops.name as shop_name,
      orders.branch_id,
      branches.name as branch_name,
      orders.created_by as salesperson_id,
      creator.full_name as salesperson_name,
      orders.created_at,
      orders.verified_at,
      case
        when orders.verified_at is not null then
          floor(extract(epoch from (clock_timestamp() - orders.verified_at)) / 86400)::integer
        else
          floor(extract(epoch from (clock_timestamp() - orders.created_at)) / 86400)::integer
      end as age_days,
      stock_picking_requests.id as picking_request_id,
      stock_picking_requests.request_number as picking_number,
      stock_picking_requests.status as picking_status,
      coalesce((
        select sum(stock_reservations.reserved_cases)
        from public.stock_reservations
        where stock_reservations.picking_request_id = stock_picking_requests.id
          and stock_reservations.status = 'active'
      ), 0) as active_reserved_cases,
      exists (
        select 1
        from public.stock_dispatch_requests
        where stock_dispatch_requests.picking_request_id = stock_picking_requests.id
          and stock_dispatch_requests.stock_consumed
      ) as stock_dispatched,
      (
        orders.status = 'verified'
        and stock_picking_requests.id is null
      ) as awaiting_allocation
    from public.orders
    join public.shops on shops.id = orders.shop_id
    join public.branches on branches.id = orders.branch_id
    left join public.profiles as creator on creator.id = orders.created_by
    left join public.stock_picking_requests
      on stock_picking_requests.order_id = orders.id
      and stock_picking_requests.status is distinct from 'cancelled'
    where app_private.report_can_see_order(orders.id)
      and (filter_branch is null or orders.branch_id = filter_branch)
      and (filter_shop is null or orders.shop_id = filter_shop)
      and (filter_salesperson is null or orders.created_by = filter_salesperson)
      and (cleaned_order is null or orders.status = cleaned_order)
      and (
        cleaned_pick is null
        or (cleaned_pick = 'none' and stock_picking_requests.id is null)
        or stock_picking_requests.status = cleaned_pick
      )
      and (posted_from is null or orders.created_at >= posted_from)
      and (posted_to is null or orders.created_at < posted_to)
  ),
  counted as (
    select count(*)::integer as total_count from scoped
  ),
  paged as (
    select *
    from scoped
    order by created_at desc, order_number desc
    offset paging.row_offset
    limit paging.page_size
  )
  select counted.total_count,
    coalesce((
      select jsonb_agg(to_jsonb(paged) order by paged.created_at desc, paged.order_number desc)
      from paged
    ), '[]'::jsonb)
  into total, rows
  from counted;

  return jsonb_build_object(
    'timezone', 'UTC',
    'page', paging.page,
    'page_size', paging.page_size,
    'total_count', total,
    'rows', rows
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Dispatch and delivery
-- ---------------------------------------------------------------------------

create or replace function public.list_dispatch_delivery_report(
  filter_branch uuid default null,
  dispatch_status text default null,
  posted_from timestamptz default null,
  posted_to timestamptz default null,
  page integer default 1,
  page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  paging record;
  total integer := 0;
  rows jsonb := '[]'::jsonb;
  cleaned_status text := nullif(btrim(coalesce(dispatch_status, '')), '');
  driver_only boolean :=
    app_private.has_permission('deliveries.execute')
    and not app_private.has_permission('dispatch.view')
    and not app_private.has_permission('operations.monitor');
begin
  perform app_private.report_require_auth();
  if not app_private.report_can_view_dispatch() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform app_private.report_assert_branch(filter_branch);
  perform app_private.report_assert_window(posted_from, posted_to);
  if cleaned_status is not null and cleaned_status not in (
    'preparing', 'dispatched', 'in_transit', 'delivered', 'exception', 'cancelled'
  ) then
    raise exception 'dispatch status is invalid' using errcode = '23514';
  end if;

  select * into paging from app_private.report_clamp_page(page, page_size);

  with scoped as (
    select
      stock_dispatch_requests.id as dispatch_id,
      stock_dispatch_requests.request_number,
      stock_dispatch_requests.status,
      stock_dispatch_requests.stock_consumed,
      stock_dispatch_requests.branch_id,
      branches.name as branch_name,
      stock_dispatch_requests.order_id,
      orders.order_number,
      stock_dispatch_requests.assigned_to,
      assignee.full_name as assigned_to_name,
      stock_dispatch_requests.created_at,
      stock_dispatch_requests.dispatched_at,
      stock_dispatch_requests.delivered_at,
      stock_dispatch_requests.physical_return_status,
      coalesce(stock_transactions.quantity, 0) as dispatched_cartons,
      case
        when stock_dispatch_requests.dispatched_at is not null
          and stock_dispatch_requests.delivered_at is not null
        then floor(extract(epoch from (
          stock_dispatch_requests.delivered_at - stock_dispatch_requests.dispatched_at
        )))::integer
        else null
      end as turnaround_seconds
    from public.stock_dispatch_requests
    join public.branches on branches.id = stock_dispatch_requests.branch_id
    join public.orders on orders.id = stock_dispatch_requests.order_id
    left join public.profiles as assignee on assignee.id = stock_dispatch_requests.assigned_to
    left join public.stock_transactions
      on stock_transactions.dispatch_request_id = stock_dispatch_requests.id
      and stock_transactions.transaction_type = 'DISPATCH'
    where app_private.can_work_at_branch(stock_dispatch_requests.branch_id)
      and (filter_branch is null or stock_dispatch_requests.branch_id = filter_branch)
      and (cleaned_status is null or stock_dispatch_requests.status = cleaned_status)
      and (posted_from is null or stock_dispatch_requests.created_at >= posted_from)
      and (posted_to is null or stock_dispatch_requests.created_at < posted_to)
      and (
        not driver_only
        or stock_dispatch_requests.assigned_to = auth.uid()
      )
  ),
  counted as (
    select count(*)::integer as total_count from scoped
  ),
  paged as (
    select *
    from scoped
    order by created_at desc, request_number desc
    offset paging.row_offset
    limit paging.page_size
  )
  select counted.total_count,
    coalesce((
      select jsonb_agg(to_jsonb(paged) order by paged.created_at desc, paged.request_number desc)
      from paged
    ), '[]'::jsonb)
  into total, rows
  from counted;

  return jsonb_build_object(
    'timezone', 'UTC',
    'page', paging.page,
    'page_size', paging.page_size,
    'total_count', total,
    'rows', rows
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Operational exceptions (existing workflow owners only)
-- ---------------------------------------------------------------------------

create or replace function public.list_operations_exceptions(
  filter_branch uuid default null,
  page integer default 1,
  page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  paging record;
  total integer := 0;
  rows jsonb := '[]'::jsonb;
begin
  perform app_private.report_require_auth();
  if not (
    app_private.report_can_view_inventory()
    or app_private.report_can_view_orders()
    or app_private.report_can_view_dispatch()
    or app_private.report_can_view_operations()
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  perform app_private.report_assert_branch(filter_branch);

  select * into paging from app_private.report_clamp_page(page, page_size);

  with items as (
    select
      'picking_blocked'::text as kind,
      '/picking/exceptions'::text as href,
      stock_picking_requests.id::text as item_id,
      stock_picking_requests.request_number as label,
      stock_picking_requests.blocked_reason as detail,
      stock_picking_requests.branch_id,
      stock_picking_requests.updated_at as occurred_at
    from public.stock_picking_requests
    where stock_picking_requests.status = 'blocked'
      and app_private.report_can_view_orders()
      and app_private.can_work_at_branch(stock_picking_requests.branch_id)
      and (filter_branch is null or stock_picking_requests.branch_id = filter_branch)

    union all
    select
      'delivery_exception',
      '/dispatch',
      stock_dispatch_requests.id::text,
      stock_dispatch_requests.request_number,
      stock_dispatch_requests.physical_return_status,
      stock_dispatch_requests.branch_id,
      coalesce(stock_dispatch_requests.updated_at, stock_dispatch_requests.created_at)
    from public.stock_dispatch_requests
    where stock_dispatch_requests.status = 'exception'
      and app_private.report_can_view_dispatch()
      and app_private.can_work_at_branch(stock_dispatch_requests.branch_id)
      and (filter_branch is null or stock_dispatch_requests.branch_id = filter_branch)
      and (
        app_private.has_permission('dispatch.view')
        or app_private.has_permission('operations.monitor')
        or stock_dispatch_requests.assigned_to = auth.uid()
      )

    union all
    select
      'pending_physical_return',
      '/dispatch',
      stock_dispatch_requests.id::text,
      stock_dispatch_requests.request_number,
      stock_dispatch_requests.physical_return_status,
      stock_dispatch_requests.branch_id,
      coalesce(stock_dispatch_requests.updated_at, stock_dispatch_requests.created_at)
    from public.stock_dispatch_requests
    where stock_dispatch_requests.physical_return_status = 'pending_verification'
      and app_private.report_can_view_dispatch()
      and app_private.can_work_at_branch(stock_dispatch_requests.branch_id)
      and (filter_branch is null or stock_dispatch_requests.branch_id = filter_branch)
      and (
        app_private.has_permission('dispatch.view')
        or app_private.has_permission('operations.monitor')
        or stock_dispatch_requests.assigned_to = auth.uid()
      )

    union all
    select
      'unclassified_product',
      '/masters/products',
      products.id::text,
      products.sku,
      products.name,
      null::uuid,
      products.updated_at
    from public.products
    where products.expiry_policy is null
      and (
        app_private.has_permission('products.read')
        or app_private.has_permission('stock.read')
        or app_private.has_permission('operations.monitor')
      )

    union all
    select
      'legacy_unattributed_lot',
      '/inventory',
      stock_lots.id::text,
      coalesce(stock_lots.manufacturer_lot_code, 'unattributed'),
      products.sku,
      stock_lots.branch_id,
      stock_lots.created_at
    from public.stock_lots
    join public.products on products.id = stock_lots.product_id
    where stock_lots.status = 'legacy_unattributed'
      and app_private.report_can_view_inventory()
      and app_private.can_work_at_branch(stock_lots.branch_id)
      and (filter_branch is null or stock_lots.branch_id = filter_branch)

    union all
    select
      'quarantined_lot',
      '/inventory',
      stock_lots.id::text,
      coalesce(stock_lots.manufacturer_lot_code, stock_lots.id::text),
      products.sku,
      stock_lots.branch_id,
      stock_lots.created_at
    from public.stock_lots
    join public.products on products.id = stock_lots.product_id
    where stock_lots.status = 'quarantined'
      and app_private.report_can_view_inventory()
      and app_private.can_work_at_branch(stock_lots.branch_id)
      and (filter_branch is null or stock_lots.branch_id = filter_branch)

    union all
    select
      'expired_lot',
      '/inventory',
      stock_lots.id::text,
      coalesce(stock_lots.manufacturer_lot_code, stock_lots.id::text),
      products.sku,
      stock_lots.branch_id,
      stock_lots.created_at
    from public.stock_lots
    join public.products on products.id = stock_lots.product_id
    where (
        stock_lots.status = 'expired_blocked'
        or (
          products.expiry_policy = 'expiry_controlled'
          and stock_lots.expiry_date is not null
          and stock_lots.expiry_date < (pg_catalog.timezone('UTC', clock_timestamp()))::date
        )
      )
      and app_private.report_can_view_inventory()
      and app_private.can_work_at_branch(stock_lots.branch_id)
      and (filter_branch is null or stock_lots.branch_id = filter_branch)

    union all
    select
      'pending_adjustment',
      '/stock-adjustments',
      stock_adjustment_requests.id::text,
      stock_adjustment_requests.request_number,
      stock_adjustment_requests.status,
      stock_adjustment_requests.godown_id,
      stock_adjustment_requests.updated_at
    from public.stock_adjustment_requests
    where stock_adjustment_requests.status in ('draft', 'submitted', 'returned', 'approved')
      and app_private.report_can_view_operations()
      and app_private.can_work_at_branch(stock_adjustment_requests.godown_id)
      and (filter_branch is null or stock_adjustment_requests.godown_id = filter_branch)
  ),
  counted as (
    select count(*)::integer as total_count from items
  ),
  paged as (
    select *
    from items
    order by occurred_at desc, kind, item_id
    offset paging.row_offset
    limit paging.page_size
  )
  select counted.total_count,
    coalesce((
      select jsonb_agg(to_jsonb(paged) order by paged.occurred_at desc, paged.kind, paged.item_id)
      from paged
    ), '[]'::jsonb)
  into total, rows
  from counted;

  return jsonb_build_object(
    'timezone', 'UTC',
    'page', paging.page,
    'page_size', paging.page_size,
    'total_count', total,
    'rows', rows
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- CSV export (same authorization and filters as the matching list RPC)
-- ---------------------------------------------------------------------------

create or replace function public.export_operations_report(
  report_kind text,
  grain text default 'crate',
  filter_branch uuid default null,
  filter_zone uuid default null,
  filter_crate uuid default null,
  filter_product uuid default null,
  filter_category uuid default null,
  filter_supplier uuid default null,
  include_zero boolean default false,
  filter_lot_status text default null,
  expiry_bucket text default null,
  movement_type text default null,
  posted_from timestamptz default null,
  posted_to timestamptz default null,
  filter_shop uuid default null,
  filter_salesperson uuid default null,
  order_status text default null,
  picking_status text default null,
  dispatch_status text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cleaned text := btrim(coalesce(report_kind, ''));
  payload jsonb;
  header text;
  body text := '';
  row_count integer := 0;
  truncated boolean := false;
  item jsonb;
  page_no integer := 1;
  total integer := 0;
  export_cap integer := 5000;
begin
  perform app_private.report_require_auth();
  if cleaned not in (
    'inventory', 'lots', 'movements', 'orders_picking', 'dispatch', 'exceptions'
  ) then
    raise exception 'report kind is invalid' using errcode = '23514';
  end if;

  if cleaned = 'inventory' then
    header := 'grain,branch_code,branch_name,zone_code,crate_code,product_sku,product_name,quantity';
  elsif cleaned = 'lots' then
    header := 'lot_id,lot_status,expiry_policy,expiry_date,expiry_bucket,product_sku,crate_code,quantity';
  elsif cleaned = 'movements' then
    header := 'reference_number,transaction_type,posted_at_utc,product_sku,quantity,branch_code,source_crate_code,destination_crate_code,actor_name,order_number,lot_references';
  elsif cleaned = 'orders_picking' then
    header := 'order_number,order_status,shop_name,branch_name,age_days,picking_status,active_reserved_cases,stock_dispatched,awaiting_allocation';
  elsif cleaned = 'dispatch' then
    header := 'request_number,status,stock_consumed,dispatched_cartons,order_number,assigned_to_name,turnaround_seconds,physical_return_status';
  else
    header := 'kind,label,detail,href,occurred_at_utc';
  end if;

  loop
    payload := case cleaned
      when 'inventory' then public.list_inventory_report(
        grain, filter_branch, filter_zone, filter_crate, filter_product,
        filter_category, filter_supplier, include_zero, page_no, 100
      )
      when 'lots' then public.list_lot_stock_report(
        filter_branch, filter_crate, filter_product, filter_lot_status, expiry_bucket, page_no, 100
      )
      when 'movements' then public.list_stock_movement_report(
        filter_branch, filter_product, movement_type, posted_from, posted_to, page_no, 100
      )
      when 'orders_picking' then public.list_order_picking_report(
        filter_branch, filter_shop, filter_salesperson, order_status, picking_status,
        posted_from, posted_to, page_no, 100
      )
      when 'dispatch' then public.list_dispatch_delivery_report(
        filter_branch, dispatch_status, posted_from, posted_to, page_no, 100
      )
      else public.list_operations_exceptions(filter_branch, page_no, 100)
    end;
    total := coalesce((payload ->> 'total_count')::integer, 0);

    for item in select value from jsonb_array_elements(coalesce(payload -> 'rows', '[]'::jsonb))
    loop
      row_count := row_count + 1;
      if row_count > export_cap then
        truncated := true;
        exit;
      end if;
      if cleaned = 'inventory' then
        body := body || E'\n' || concat_ws(',',
          app_private.report_csv_cell(payload ->> 'grain'),
          app_private.report_csv_cell(item ->> 'branch_code'),
          app_private.report_csv_cell(item ->> 'branch_name'),
          app_private.report_csv_cell(item ->> 'zone_code'),
          app_private.report_csv_cell(item ->> 'crate_code'),
          app_private.report_csv_cell(item ->> 'product_sku'),
          app_private.report_csv_cell(item ->> 'product_name'),
          app_private.report_csv_cell(item ->> 'quantity')
        );
      elsif cleaned = 'lots' then
        body := body || E'\n' || concat_ws(',',
          app_private.report_csv_cell(item ->> 'lot_id'),
          app_private.report_csv_cell(item ->> 'lot_status'),
          app_private.report_csv_cell(item ->> 'expiry_policy'),
          app_private.report_csv_cell(item ->> 'expiry_date'),
          app_private.report_csv_cell(item ->> 'expiry_bucket'),
          app_private.report_csv_cell(item ->> 'product_sku'),
          app_private.report_csv_cell(item ->> 'crate_code'),
          app_private.report_csv_cell(item ->> 'quantity')
        );
      elsif cleaned = 'movements' then
        body := body || E'\n' || concat_ws(',',
          app_private.report_csv_cell(item ->> 'reference_number'),
          app_private.report_csv_cell(item ->> 'transaction_type'),
          app_private.report_csv_cell(item ->> 'posted_at'),
          app_private.report_csv_cell(item ->> 'product_sku'),
          app_private.report_csv_cell(item ->> 'quantity'),
          app_private.report_csv_cell(item ->> 'branch_code'),
          app_private.report_csv_cell(item ->> 'source_crate_code'),
          app_private.report_csv_cell(item ->> 'destination_crate_code'),
          app_private.report_csv_cell(item ->> 'actor_name'),
          app_private.report_csv_cell(item ->> 'order_number'),
          app_private.report_csv_cell(item ->> 'lot_references')
        );
      elsif cleaned = 'orders_picking' then
        body := body || E'\n' || concat_ws(',',
          app_private.report_csv_cell(item ->> 'order_number'),
          app_private.report_csv_cell(item ->> 'order_status'),
          app_private.report_csv_cell(item ->> 'shop_name'),
          app_private.report_csv_cell(item ->> 'branch_name'),
          app_private.report_csv_cell(item ->> 'age_days'),
          app_private.report_csv_cell(item ->> 'picking_status'),
          app_private.report_csv_cell(item ->> 'active_reserved_cases'),
          app_private.report_csv_cell(item ->> 'stock_dispatched'),
          app_private.report_csv_cell(item ->> 'awaiting_allocation')
        );
      elsif cleaned = 'dispatch' then
        body := body || E'\n' || concat_ws(',',
          app_private.report_csv_cell(item ->> 'request_number'),
          app_private.report_csv_cell(item ->> 'status'),
          app_private.report_csv_cell(item ->> 'stock_consumed'),
          app_private.report_csv_cell(item ->> 'dispatched_cartons'),
          app_private.report_csv_cell(item ->> 'order_number'),
          app_private.report_csv_cell(item ->> 'assigned_to_name'),
          app_private.report_csv_cell(item ->> 'turnaround_seconds'),
          app_private.report_csv_cell(item ->> 'physical_return_status')
        );
      else
        body := body || E'\n' || concat_ws(',',
          app_private.report_csv_cell(item ->> 'kind'),
          app_private.report_csv_cell(item ->> 'label'),
          app_private.report_csv_cell(item ->> 'detail'),
          app_private.report_csv_cell(item ->> 'href'),
          app_private.report_csv_cell(item ->> 'occurred_at')
        );
      end if;
    end loop;

    exit when truncated;
    exit when row_count >= total;
    exit when jsonb_array_length(coalesce(payload -> 'rows', '[]'::jsonb)) < 100;
    page_no := page_no + 1;
  end loop;

  if total > export_cap then
    truncated := true;
    row_count := least(row_count, export_cap);
  end if;

  return jsonb_build_object(
    'timezone', 'UTC',
    'report_kind', cleaned,
    'row_count', row_count,
    'total_count', total,
    'truncated', truncated,
    'csv', header || body
  );
end;
$$;

-- Export walks list RPCs in pages of 100 up to 5000 authorized rows.

revoke all on function public.get_operations_dashboard(uuid) from public, anon, service_role;
revoke all on function public.list_inventory_report(text, uuid, uuid, uuid, uuid, uuid, uuid, boolean, integer, integer) from public, anon, service_role;
revoke all on function public.list_lot_stock_report(uuid, uuid, uuid, text, text, integer, integer) from public, anon, service_role;
revoke all on function public.list_stock_movement_report(uuid, uuid, text, timestamptz, timestamptz, integer, integer) from public, anon, service_role;
revoke all on function public.list_order_picking_report(uuid, uuid, uuid, text, text, timestamptz, timestamptz, integer, integer) from public, anon, service_role;
revoke all on function public.list_dispatch_delivery_report(uuid, text, timestamptz, timestamptz, integer, integer) from public, anon, service_role;
revoke all on function public.list_operations_exceptions(uuid, integer, integer) from public, anon, service_role;
revoke all on function public.export_operations_report(text, text, uuid, uuid, uuid, uuid, uuid, uuid, boolean, text, text, text, timestamptz, timestamptz, uuid, uuid, text, text, text) from public, anon, service_role;

grant execute on function public.get_operations_dashboard(uuid) to authenticated;
grant execute on function public.list_inventory_report(text, uuid, uuid, uuid, uuid, uuid, uuid, boolean, integer, integer) to authenticated;
grant execute on function public.list_lot_stock_report(uuid, uuid, uuid, text, text, integer, integer) to authenticated;
grant execute on function public.list_stock_movement_report(uuid, uuid, text, timestamptz, timestamptz, integer, integer) to authenticated;
grant execute on function public.list_order_picking_report(uuid, uuid, uuid, text, text, timestamptz, timestamptz, integer, integer) to authenticated;
grant execute on function public.list_dispatch_delivery_report(uuid, text, timestamptz, timestamptz, integer, integer) to authenticated;
grant execute on function public.list_operations_exceptions(uuid, integer, integer) to authenticated;
grant execute on function public.export_operations_report(text, text, uuid, uuid, uuid, uuid, uuid, uuid, boolean, text, text, text, timestamptz, timestamptz, uuid, uuid, text, text, text) to authenticated;

comment on function public.get_operations_dashboard(uuid) is
  'M4 read-only KPI payload. Hides unauthorized groups. available_to_pick is not_applicable while dual-write is off.';
comment on function public.list_inventory_report(text, uuid, uuid, uuid, uuid, uuid, uuid, boolean, integer, integer) is
  'M4 paginated aggregate inventory. Grain crate/zone/godown/product. Requires stock.read.';
comment on function public.export_operations_report(text, text, uuid, uuid, uuid, uuid, uuid, uuid, boolean, text, text, text, timestamptz, timestamptz, uuid, uuid, text, text, text) is
  'M4 CSV export with the same permission and branch scope as the matching list RPC. Pages list RPCs up to 5000 authorized rows.';
