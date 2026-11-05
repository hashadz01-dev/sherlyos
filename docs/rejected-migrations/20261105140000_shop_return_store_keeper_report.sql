-- DO NOT APPLY. This definition predates the cloud salesperson shop-return
-- functions and would delete that branch. Kept only as a rejected draft.
-- DMG-06: Store Keeper reports a shop return; Godown Manager verifies it.
-- damage.record is enough to create, edit, confirm own custody, and submit.
-- damage.verify stays on verification. damage.disposition stays on write-off.
-- Quarantine intake accounting is unchanged.

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
  elsif scenario in ('storage', 'shop_return') then
    -- damage.record and an authorized godown are enough. Verification and
    -- disposition use their own permissions, so a reporter cannot approve
    -- their own report or post an arbitrary adjustment.
    null;
  else
    raise exception 'damage scenario is invalid' using errcode = '23514';
  end if;
end;
$$;

comment on function app_private.assert_damage_create_auth(text, uuid, uuid) is
  'Create/update/submit/list-source auth. Storage and shop-return need damage.record at an authorized godown. Verification still needs damage.verify. Isolation remains a separate submit gate.';

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
  perform app_private.assert_damage_create_auth(
    selected.scenario, selected.godown_id, selected.dispatch_id
  );

  if selected.scenario is distinct from 'shop_return'
    or selected.status not in ('draft', 'returned')
  then
    raise exception 'physical custody cannot be confirmed' using errcode = '42501';
  end if;

  -- Only the reporter confirms custody. Another recorder at the same
  -- godown must not advance a report they did not create.
  if selected.reporter_user_id is distinct from auth.uid() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

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
