-- Serialize inbound damage claims on the receipt line so two drafts cannot
-- over-claim the same damaged carton cases. List remaining still includes the
-- current draft; editors subtract own saved quantity in the UI.
-- Does not change stock posting, RLS, or cutover flags.

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

      -- Lock the receipt line before reading open claims so concurrent
      -- drafts cannot both take the last remaining damaged cases.
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

comment on function app_private.replace_damage_lines(uuid, text, uuid, uuid, uuid, uuid, jsonb) is
  'Replaces damage lines. Inbound claims lock the receipt line so remaining damaged cases cannot be over-claimed.';
