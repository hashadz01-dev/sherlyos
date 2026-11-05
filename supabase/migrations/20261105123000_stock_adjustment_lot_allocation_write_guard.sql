-- Save lot allocation updates stock_adjustment_requests.version.
-- guard_adjustment_write rejects that update unless app.adjustment_write is on,
-- and it raises 42501. The client shows every 42501 as a permission error.
-- Godown Managers who already hold stock.adjustment.request were failing here
-- after the permission and godown checks had passed.
--
-- This does not grant a new permission, does not post stock, and does not
-- change approval or posting rules. Shortage quantities still cannot exceed
-- the lot quantity left after active reservations and damage holds.

create or replace function public.set_stock_adjustment_line_lot_allocations(
  target_adjustment_line uuid,
  allocations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_line public.stock_adjustment_lines%rowtype;
  selected_request public.stock_adjustment_requests%rowtype;
  item jsonb;
  target_lot uuid;
  qty integer;
  total integer := 0;
  lot_product uuid;
  lot_branch uuid;
  eligible_cases integer;
begin
  -- Same transaction-local writer permit used by create, revise, and post.
  -- The guard trigger reads it. The setting ends when this transaction ends.
  perform set_config('app.adjustment_write', 'on', true);
  perform app_private.assert_permission('stock.adjustment.request');

  if allocations is null or jsonb_typeof(allocations) is distinct from 'array' then
    raise exception 'allocations must be a json array' using errcode = '23514';
  end if;

  select *
  into selected_line
  from public.stock_adjustment_lines
  where stock_adjustment_lines.id = target_adjustment_line
  for update;

  if not found then
    raise exception 'adjustment line not found' using errcode = '42501';
  end if;

  select *
  into selected_request
  from public.stock_adjustment_requests
  where stock_adjustment_requests.id = selected_line.request_id
  for update;

  if not app_private.can_work_at_branch(selected_request.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if selected_request.status not in ('draft', 'returned') then
    raise exception 'lot allocations cannot change in status %', selected_request.status
      using errcode = '42501';
  end if;

  if selected_line.released then
    raise exception 'adjustment line is released' using errcode = '23514';
  end if;

  delete from public.stock_adjustment_line_lot_allocations
  where stock_adjustment_line_lot_allocations.adjustment_line_id = target_adjustment_line;

  for item in select value from jsonb_array_elements(allocations)
  loop
    begin
      target_lot := (item ->> 'lot_id')::uuid;
      qty := (item ->> 'quantity')::integer;
    exception
      when invalid_text_representation or datatype_mismatch then
        raise exception 'allocation fields must be valid uuid/integer values'
          using errcode = '23514';
    end;

    if target_lot is null or qty is null or qty = 0 then
      raise exception 'each allocation requires lot_id and non-zero quantity'
        using errcode = '23514';
    end if;

    if (selected_line.requested_cases > 0 and qty < 1)
      or (selected_line.requested_cases < 0 and qty > -1)
      or (selected_line.requested_cases > 0) <> (qty > 0)
    then
      raise exception 'allocation quantity sign must match adjustment line'
        using errcode = '23514';
    end if;

    select stock_lots.product_id, stock_lots.branch_id
    into lot_product, lot_branch
    from public.stock_lots
    where stock_lots.id = target_lot;

    if not found then
      raise exception 'stock lot not found' using errcode = '23514';
    end if;

    if lot_product is distinct from selected_line.product_id then
      raise exception 'lot product does not match adjustment line' using errcode = '23514';
    end if;

    if lot_branch is distinct from selected_request.godown_id then
      raise exception 'lot branch does not match adjustment godown' using errcode = '23514';
    end if;

    -- Eligible cases are on-hand minus active reservations and damage holds
    -- for this lot in the adjustment line's crate. Positive surplus is not capped.
    if qty < 0 then
      eligible_cases := app_private.unreserved_lot_cases(target_lot, selected_line.crate_id);
      if pg_catalog.abs(qty) > eligible_cases then
        raise exception 'allocation exceeds eligible lot quantity'
          using errcode = '23514';
      end if;
    end if;

    insert into public.stock_adjustment_line_lot_allocations (
      adjustment_line_id, lot_id, quantity
    ) values (target_adjustment_line, target_lot, qty);

    total := total + qty;
  end loop;

  if total is distinct from selected_line.requested_cases then
    raise exception 'allocation quantities (%) must equal requested_cases (%)',
      total, selected_line.requested_cases
      using errcode = '23514';
  end if;

  update public.stock_adjustment_requests
  set
    version = selected_request.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where stock_adjustment_requests.id = selected_request.id;

  return coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'lot_id', alloc.lot_id,
      'quantity', alloc.quantity
    ) order by alloc.lot_id)
    from public.stock_adjustment_line_lot_allocations alloc
    where alloc.adjustment_line_id = target_adjustment_line
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.set_stock_adjustment_line_lot_allocations(uuid, jsonb)
  from public, anon, service_role;
grant execute on function public.set_stock_adjustment_line_lot_allocations(uuid, jsonb)
  to authenticated;

comment on function public.set_stock_adjustment_line_lot_allocations(uuid, jsonb) is
  'Replaces lot quantities on a draft or returned adjustment line. Requires stock.adjustment.request and godown scope. Does not approve, post, or change stock balances.';
