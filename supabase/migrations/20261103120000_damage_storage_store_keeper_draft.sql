-- DMG-03 storage: allow damage.record (Store Keeper) to create/edit drafts
-- at an authorized godown. Shop-return still requires damage.verify.
-- Submission remains gated by damage.stock_hold_ready / stock isolation.
-- Does not flip cutover flags or post stock.

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

  if not app_private.has_permission('damage.record') then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  -- Inbound does not lock picking/dispatch/products, so a branch row lock
  -- cannot invert confirm_dispatch. Hold scenarios freeze the branch later
  -- inside prepare_stock_locations (zones → crates → branch).
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
    -- damage.record already asserted. Store Keepers may draft warehouse
    -- damage in an authorized godown; submit still requires isolation ready.
    null;
  elsif scenario = 'shop_return' then
    if not app_private.has_permission('damage.verify') then
      raise exception 'not authorized' using errcode = '42501';
    end if;
  else
    raise exception 'damage scenario is invalid' using errcode = '23514';
  end if;
end;
$$;

comment on function app_private.assert_damage_create_auth(text, uuid, uuid) is
  'Create/update/submit/list-source auth for damage scenarios. Storage drafts need damage.record at an authorized godown; shop-return still needs damage.verify. Stock isolation remains a separate submit gate.';
