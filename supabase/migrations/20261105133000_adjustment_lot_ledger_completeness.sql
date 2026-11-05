-- Lot-aware adjustment posting writes one stock_ledger row per saved
-- allocation. The deferred completeness trigger still required one row per
-- adjustment line, so two lots on one line (-1 and -1) failed at commit with
-- "adjustment ledger is incomplete" even though the signed sum matched.
-- The insert rolls back with the posting transaction.
--
-- Aggregate adjustments still need one ledger row per line. Damage, dispatch,
-- and delivery-return rules are unchanged. This does not post or rewrite history.

create or replace function app_private.assert_stock_transaction_complete()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  selected_type text;
  entry_count integer;
  entry_sum integer;
  linked_receipt uuid;
  linked_line uuid;
  linked_adjustment uuid;
  linked_dispatch uuid;
  linked_damage uuid;
  linked_kind text;
  linked_return uuid;
  header_qty integer;
  line_count integer;
  line_sum integer;
  alloc_count integer;
begin
  select
    stock_transactions.transaction_type,
    stock_transactions.receipt_id,
    stock_transactions.receipt_line_id,
    stock_transactions.adjustment_request_id,
    stock_transactions.dispatch_request_id,
    stock_transactions.damage_report_id,
    stock_transactions.damage_posting_kind,
    stock_transactions.delivery_return_id,
    stock_transactions.quantity
  into
    selected_type, linked_receipt, linked_line, linked_adjustment, linked_dispatch,
    linked_damage, linked_kind, linked_return, header_qty
  from public.stock_transactions
  where stock_transactions.id = new.transaction_id;

  select count(*), coalesce(sum(stock_ledger.quantity), 0)
  into entry_count, entry_sum
  from public.stock_ledger
  where stock_ledger.transaction_id = new.transaction_id;

  if selected_type = 'OPENING_STOCK' and (entry_count <> 1 or entry_sum <= 0) then
    raise exception 'opening stock ledger is incomplete' using errcode = '23514';
  end if;

  if selected_type = 'CRATE_TRANSFER' and (entry_count <> 2 or entry_sum <> 0) then
    raise exception 'transfer ledger must net to zero' using errcode = '23514';
  end if;

  if selected_type = 'RECEIPT' and (
    entry_count <> 1
    or entry_sum <= 0
    or linked_receipt is null
    or linked_line is null
  ) then
    raise exception 'receipt ledger is incomplete' using errcode = '23514';
  end if;

  if selected_type = 'ADJUSTMENT' then
    if linked_adjustment is not null then
      select count(*), coalesce(sum(stock_adjustment_lines.requested_cases), 0)
      into line_count, line_sum
      from public.stock_adjustment_lines
      where stock_adjustment_lines.request_id = linked_adjustment
        and not stock_adjustment_lines.released;

      select count(*)
      into alloc_count
      from public.stock_adjustment_line_lot_allocations allocations
      join public.stock_adjustment_lines lines
        on lines.id = allocations.adjustment_line_id
      where lines.request_id = linked_adjustment
        and not lines.released;

      -- The signed total is the adjustment. Row count follows the posting shape:
      -- one row per line when no lots were saved, one row per allocation when they were.
      if line_count < 1
        or entry_count < 1
        or entry_sum is distinct from line_sum
        or (
          alloc_count = 0
          and entry_count <> line_count
        )
        or (
          alloc_count > 0
          and (
            entry_count <> alloc_count
            or exists (
              select 1
              from public.stock_adjustment_line_lot_allocations allocations
              join public.stock_adjustment_lines lines
                on lines.id = allocations.adjustment_line_id
              where lines.request_id = linked_adjustment
                and not lines.released
                and not exists (
                  select 1
                  from public.stock_ledger
                  where stock_ledger.transaction_id = new.transaction_id
                    and stock_ledger.lot_id = allocations.lot_id
                    and stock_ledger.crate_id = lines.crate_id
                    and stock_ledger.product_id = lines.product_id
                    and stock_ledger.quantity = allocations.quantity
                )
            )
          )
        )
      then
        raise exception 'adjustment ledger is incomplete' using errcode = '23514';
      end if;
    elsif linked_damage is not null
      and linked_kind = 'quarantine_intake'
    then
      if entry_count < 1 or entry_sum is distinct from header_qty or entry_sum <= 0 then
        raise exception 'adjustment ledger is incomplete' using errcode = '23514';
      end if;
    elsif linked_damage is not null
      and linked_kind in ('ordinary_writeoff', 'exceptional_writeoff')
    then
      if entry_count < 1 or entry_sum is distinct from (- header_qty) or entry_sum >= 0 then
        raise exception 'adjustment ledger is incomplete' using errcode = '23514';
      end if;
    else
      raise exception 'adjustment ledger is incomplete' using errcode = '23514';
    end if;
  end if;

  if selected_type = 'DISPATCH' then
    if linked_dispatch is null
      or entry_count < 1
      or entry_sum >= 0
      or entry_sum is distinct from (- header_qty)
    then
      raise exception 'dispatch ledger is incomplete' using errcode = '23514';
    end if;
  end if;

  if selected_type = 'DELIVERY_RETURN' then
    if linked_return is null
      or entry_count < 1
      or entry_sum <= 0
      or entry_sum is distinct from header_qty
    then
      raise exception 'delivery return ledger is incomplete' using errcode = '23514';
    end if;
  end if;

  if selected_type not in (
    'OPENING_STOCK', 'CRATE_TRANSFER', 'RECEIPT', 'ADJUSTMENT', 'DISPATCH', 'DELIVERY_RETURN'
  ) then
    raise exception 'stock transaction type is not supported' using errcode = '23514';
  end if;

  return null;
end;
$$;

revoke all on function app_private.assert_stock_transaction_complete()
  from public, anon, authenticated, service_role;
