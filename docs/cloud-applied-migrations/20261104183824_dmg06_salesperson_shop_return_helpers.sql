-- Archived copy of an already-applied development-cloud migration statement.
-- Do not move this file into supabase/migrations and do not apply it again.

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