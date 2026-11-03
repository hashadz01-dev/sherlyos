-- DMG-03B: Transfer/adjustment pre-checks honor active reservations and
-- damage holds (same floor as picking_available_cases / balance triggers).
-- Triggers already fail closed; this fails earlier with a clear error.
-- Does not flip cutover flags or rewrite ledgers.

create or replace function app_private.unreserved_grain_cases(
  p_crate uuid,
  p_product uuid
)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select greatest(
    coalesce(
      (
        select stock_balances.quantity
        from public.stock_balances
        where stock_balances.crate_id = p_crate
          and stock_balances.product_id = p_product
      ),
      0
    )
      - app_private.active_reserved_grain_cases(p_crate, p_product)
      - app_private.active_damage_hold_grain_cases(p_crate, p_product),
    0
  );
$$;

create or replace function app_private.unreserved_lot_cases(
  p_lot uuid,
  p_crate uuid
)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select greatest(
    coalesce(
      (
        select stock_lot_balances.quantity
        from public.stock_lot_balances
        where stock_lot_balances.lot_id = p_lot
          and stock_lot_balances.crate_id = p_crate
      ),
      0
    )
      - app_private.active_reserved_lot_cases(p_lot, p_crate)
      - app_private.active_damage_hold_lot_cases(p_lot, p_crate),
    0
  );
$$;

revoke all on function app_private.unreserved_grain_cases(uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function app_private.unreserved_lot_cases(uuid, uuid)
  from public, anon, authenticated, service_role;

comment on function app_private.unreserved_grain_cases(uuid, uuid) is
  'Physical on-hand minus active reservations and active damage holds for a crate/product grain.';
comment on function app_private.unreserved_lot_cases(uuid, uuid) is
  'Lot on-hand minus active reservations and active damage holds for a lot/crate grain.';

CREATE OR REPLACE FUNCTION public.post_crate_transfer(target_product uuid, source_crate uuid, destination_crate uuid, carton_quantity integer, idempotency_key text, posting_notes text, lot_moves jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
declare
  cleaned_key text;
  cleaned_notes text;
  fingerprint text;
  replay jsonb;
  created_id uuid;
  reference_number text;
  source_quantity integer;
  first_crate uuid;
  second_crate uuid;
  conflict_name text;
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
  item jsonb;
  move_lot uuid;
  move_qty integer;
  move_total integer := 0;
  lot_qty integer;
  source_branch uuid;
  dest_branch uuid;
  lot_deltas jsonb := '[]'::jsonb;
  lot_fp text := '';
begin
  perform app_private.assert_permission('stock.transfer.post');
  perform app_private.assert_carton_quantity(carton_quantity);
  -- Shared cutover first so exclusive seed/cutover serializes ahead of row locks.
  perform app_private.acquire_stock_cutover_shared_lock();

  if source_crate is not distinct from destination_crate then
    raise exception 'source and destination must be different' using errcode = '23514';
  end if;

  if not dual_write then
    if lot_moves is not null then
      raise exception 'lot_moves is only accepted when lot-aware dual-write is enabled'
        using errcode = '23514';
    end if;
  else
    if lot_moves is null or jsonb_typeof(lot_moves) is distinct from 'array'
      or jsonb_array_length(lot_moves) < 1
    then
      raise exception 'lot_moves must be a non-empty json array when dual-write is enabled'
        using errcode = '23514';
    end if;
  end if;

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_notes := app_private.clean_optional_text(posting_notes, 500);
  fingerprint := app_private.stock_request_fingerprint(
    'CRATE_TRANSFER', target_product, source_crate, destination_crate,
    carton_quantity, cleaned_notes
  );

  if dual_write then
    for item in select value from jsonb_array_elements(lot_moves)
    loop
      move_lot := (item ->> 'lot_id')::uuid;
      move_qty := coalesce(item ->> 'quantity', item ->> 'carton_quantity')::integer;
      if move_lot is null or move_qty is null or move_qty < 1 then
        raise exception 'each lot move requires lot_id and positive quantity'
          using errcode = '23514';
      end if;
      move_total := move_total + move_qty;
      lot_fp := lot_fp || '|' || move_lot::text || ':' || move_qty::text;
    end loop;
    if move_total is distinct from carton_quantity then
      raise exception 'lot move quantities (%) must equal carton_quantity (%)',
        move_total, carton_quantity
        using errcode = '23514';
    end if;
    fingerprint := fingerprint || '|LOTS' || lot_fp;
  end if;

  replay := app_private.replay_stock_transaction(cleaned_key, fingerprint);
  if replay is not null then
    return replay;
  end if;

  if not exists (
    select 1 from public.products
    where products.id = target_product and products.is_active
  ) then
    raise exception 'product not found or inactive' using errcode = '23514';
  end if;

  -- Product row before locations: apply_lot_aware and confirm_dispatch lock
  -- products first. Holding crates while waiting on products deadlocked.
  perform products.id
  from public.products
  where products.id = target_product
  for update;

  if source_crate < destination_crate then
    first_crate := source_crate;
    second_crate := destination_crate;
  else
    first_crate := destination_crate;
    second_crate := source_crate;
  end if;

  perform app_private.prepare_stock_locations(array[first_crate, second_crate]);

  select zones.branch_id into source_branch
  from public.crates join public.zones on zones.id = crates.zone_id
  where crates.id = source_crate;
  select zones.branch_id into dest_branch
  from public.crates join public.zones on zones.id = crates.zone_id
  where crates.id = destination_crate;

  if source_branch is distinct from dest_branch then
    raise exception 'crate transfers across godowns are not allowed' using errcode = '23514';
  end if;

  replay := app_private.replay_stock_transaction(cleaned_key, fingerprint);
  if replay is not null then
    return replay;
  end if;

  -- Lots then lot_balances then aggregate balances. Source-then-dest balance
  -- locks inverted crate_id order used by apply_lot_aware.
  if dual_write then
    perform stock_lots.id
    from public.stock_lots
    where stock_lots.id in (
      select (move.value ->> 'lot_id')::uuid
      from jsonb_array_elements(lot_moves) as move
    )
    order by stock_lots.id
    for update;

    perform stock_lot_balances.lot_id
    from public.stock_lot_balances
    where stock_lot_balances.lot_id in (
      select (move.value ->> 'lot_id')::uuid
      from jsonb_array_elements(lot_moves) as move
    )
      and stock_lot_balances.crate_id in (source_crate, destination_crate)
    order by stock_lot_balances.crate_id, stock_lot_balances.lot_id
    for update;
  end if;

  perform stock_balances.crate_id
  from public.stock_balances
  where stock_balances.product_id = target_product
    and stock_balances.crate_id in (source_crate, destination_crate)
  order by stock_balances.crate_id, stock_balances.product_id
  for update;

  select stock_balances.quantity into source_quantity
  from public.stock_balances
  where stock_balances.crate_id = source_crate
    and stock_balances.product_id = target_product;

  if app_private.unreserved_grain_cases(source_crate, target_product) < carton_quantity then
    raise exception 'insufficient unreserved stock' using errcode = '23514';
  end if;

  reference_number := 'TR-'
    || to_char(pg_catalog.clock_timestamp() at time zone 'UTC', 'YYYYMMDD')
    || '-'
    || pg_catalog.lpad(pg_catalog.nextval('public.stock_reference_seq')::text, 6, '0');

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    notes, product_id, source_crate_id, destination_crate_id, quantity
  ) values (
    'CRATE_TRANSFER', reference_number, auth.uid(), cleaned_key, fingerprint,
    cleaned_notes, target_product, source_crate, destination_crate, carton_quantity
  )
  returning id into created_id;

  if dual_write then
    for item in select value from jsonb_array_elements(lot_moves)
    loop
      move_lot := (item ->> 'lot_id')::uuid;
      move_qty := coalesce(item ->> 'quantity', item ->> 'carton_quantity')::integer;

      if exists (
        select 1 from jsonb_array_elements(lot_deltas) existing
        where (existing ->> 'lot_id')::uuid = move_lot
          and (existing ->> 'crate_id')::uuid = source_crate
      ) then
        raise exception 'duplicate lot_id in lot_moves is not allowed' using errcode = '23514';
      end if;

      if not exists (
        select 1 from public.stock_lots
        where stock_lots.id = move_lot
          and stock_lots.product_id = target_product
          and stock_lots.branch_id = source_branch
      ) then
        raise exception 'stock lot not found for product/godown' using errcode = '23514';
      end if;

      -- Re-lock of rows already ordered above; still enforces unreserved qty.
      select stock_lot_balances.quantity into lot_qty
      from public.stock_lot_balances
      where stock_lot_balances.lot_id = move_lot
        and stock_lot_balances.crate_id = source_crate
      for update;

      if app_private.unreserved_lot_cases(move_lot, source_crate) < move_qty then
        raise exception 'insufficient unreserved lot stock' using errcode = '23514';
      end if;

      insert into public.stock_ledger (
        transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
      )
      select created_id, target_product, entries.crate_id, entries.quantity,
        stock_transactions.actor_id, stock_transactions.posted_at, move_lot
      from public.stock_transactions
      cross join (
        values (source_crate, -move_qty), (destination_crate, move_qty)
      ) as entries(crate_id, quantity)
      where stock_transactions.id = created_id;

      lot_deltas := lot_deltas || jsonb_build_array(
        jsonb_build_object(
          'product_id', target_product, 'lot_id', move_lot,
          'crate_id', source_crate, 'quantity', -move_qty
        ),
        jsonb_build_object(
          'product_id', target_product, 'lot_id', move_lot,
          'crate_id', destination_crate, 'quantity', move_qty
        )
      );
    end loop;

    perform app_private.apply_lot_aware_stock_deltas(created_id, lot_deltas);
  else
    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at
    )
    select created_id, target_product, entries.crate_id, entries.quantity,
      stock_transactions.actor_id, stock_transactions.posted_at
    from public.stock_transactions
    cross join (
      values (source_crate, -carton_quantity), (destination_crate, carton_quantity)
    ) as entries(crate_id, quantity)
    where stock_transactions.id = created_id;

    perform app_private.apply_stock_delta(source_crate, target_product, -carton_quantity);
    perform app_private.apply_stock_delta(destination_crate, target_product, carton_quantity);
  end if;

  perform app_private.write_audit(
    auth.uid(), 'post_crate_transfer', 'stock_transactions', created_id,
    pg_catalog.jsonb_build_object(
      'reference_number', reference_number,
      'product_id', target_product,
      'source_crate_id', source_crate,
      'destination_crate_id', destination_crate,
      'quantity', carton_quantity,
      'dual_write', dual_write
    )
  );

  return pg_catalog.jsonb_build_object('id', created_id, 'reference_number', reference_number);
exception
  when unique_violation then
    get stacked diagnostics conflict_name = constraint_name;
    if conflict_name = 'stock_transactions_idempotency_key' then
      replay := app_private.replay_stock_transaction(cleaned_key, fingerprint);
      if replay is not null then
        return replay;
      end if;
    end if;
    raise;
end;
$$;

CREATE OR REPLACE FUNCTION public.post_stock_adjustment(target_request uuid, expected_version integer, idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
declare
  selected public.stock_adjustment_requests;
  cleaned_key text;
  fingerprint text;
  replay jsonb;
  crate_ids uuid[];
  line record;
  allocation_row record;
  baseline_quantity integer;
  later_count integer;
  created_id uuid;
  absolute_quantity integer;
  single_crate uuid;
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
  alloc_total integer;
  lot_deltas jsonb := '[]'::jsonb;
begin
  perform set_config('app.adjustment_write', 'on', true);
  perform app_private.assert_permission('stock.adjustment.post');
  perform app_private.acquire_stock_cutover_shared_lock();

  select *
  into selected
  from public.stock_adjustment_requests
  where stock_adjustment_requests.id = target_request
  for update;

  if not found or not app_private.can_work_at_branch(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if selected.compensates_request_id is not null then
    raise exception 'compensation is not available' using errcode = '23514';
  end if;

  cleaned_key := app_private.clean_idempotency_key(idempotency_key);

  if selected.status = 'posted' then
    select pg_catalog.jsonb_build_object(
      'id', stock_transactions.id,
      'reference_number', stock_transactions.reference_number
    )
    into replay
    from public.stock_transactions
    where stock_transactions.adjustment_request_id = selected.id
      and stock_transactions.idempotency_key = cleaned_key;

    if replay is null then
      raise exception 'adjustment was already posted' using errcode = '23505';
    end if;
    return replay;
  end if;

  if selected.version is distinct from expected_version then
    raise exception 'adjustment was changed by someone else' using errcode = 'PT409';
  end if;

  if selected.status <> 'approved' then
    raise exception 'adjustment cannot be posted' using errcode = '42501';
  end if;

  fingerprint := 'ADJUSTMENT:' || selected.id::text || ':' || selected.version::text;

  select coalesce(pg_catalog.array_agg(distinct stock_adjustment_lines.crate_id), '{}')
  into crate_ids
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released;

  if pg_catalog.cardinality(crate_ids) < 1 then
    raise exception 'an adjustment line is required' using errcode = '23514';
  end if;

  perform products.id
  from public.products
  where products.id in (
    select stock_adjustment_lines.product_id
    from public.stock_adjustment_lines
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
  )
  order by products.id
  for update;

  if app_private.prepare_stock_locations(crate_ids) is distinct from selected.godown_id then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if dual_write then
    perform stock_lots.id
    from public.stock_lots
    where stock_lots.id in (
      select allocations.lot_id
      from public.stock_adjustment_line_lot_allocations allocations
      join public.stock_adjustment_lines
        on stock_adjustment_lines.id = allocations.adjustment_line_id
      where stock_adjustment_lines.request_id = selected.id
        and not stock_adjustment_lines.released
    )
    order by stock_lots.id
    for update;

    perform stock_lot_balances.lot_id
    from public.stock_lot_balances
    join public.stock_adjustment_line_lot_allocations allocations
      on allocations.lot_id = stock_lot_balances.lot_id
    join public.stock_adjustment_lines
      on stock_adjustment_lines.id = allocations.adjustment_line_id
     and stock_adjustment_lines.crate_id = stock_lot_balances.crate_id
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
    order by stock_lot_balances.crate_id, stock_lot_balances.lot_id
    for update of stock_lot_balances;
  end if;

  perform stock_balances.crate_id
  from public.stock_balances
  join public.stock_adjustment_lines
    on stock_adjustment_lines.crate_id = stock_balances.crate_id
    and stock_adjustment_lines.product_id = stock_balances.product_id
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released
  order by stock_balances.crate_id, stock_balances.product_id
  for update;

  for line in
    select
      stock_adjustment_lines.id as line_id,
      stock_adjustment_lines.requested_cases,
      stock_adjustment_lines.crate_id,
      stock_adjustment_lines.product_id,
      stock_verification_lines.reconciled_expected_cases,
      stock_verification_lines.acknowledged_ledger_ids,
      stock_verification_lines.recount_cases,
      stock_verification_lines.final_variance_cases
    from public.stock_adjustment_lines
    join public.stock_verification_lines
      on stock_verification_lines.id = stock_adjustment_lines.verification_line_id
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
    order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id
  loop
    if line.final_variance_cases is distinct from line.requested_cases
      or line.final_variance_cases is distinct from (line.recount_cases - line.reconciled_expected_cases)
    then
      raise exception 'verification line cannot be adjusted' using errcode = '23514';
    end if;

    select count(*) into later_count
    from public.stock_ledger
    where stock_ledger.crate_id = line.crate_id
      and stock_ledger.product_id = line.product_id
      and not (
        stock_ledger.id = any (coalesce(line.acknowledged_ledger_ids, '{}'))
        or exists (
          select 1 from public.stock_verification_snapshot_entries snapshot_entries
          where snapshot_entries.verification_id = selected.verification_id
            and snapshot_entries.ledger_id = stock_ledger.id
        )
      );

    if later_count > 0 then
      raise exception 'adjustment is stale and needs a new verification' using errcode = '23514';
    end if;

    select coalesce(sum(stock_ledger.quantity), 0) into baseline_quantity
    from public.stock_ledger
    where stock_ledger.crate_id = line.crate_id
      and stock_ledger.product_id = line.product_id;

    if baseline_quantity is distinct from line.reconciled_expected_cases then
      raise exception 'adjustment is stale and needs a new verification' using errcode = '23514';
    end if;

    if dual_write then
      select coalesce(sum(allocations.quantity), 0) into alloc_total
      from public.stock_adjustment_line_lot_allocations allocations
      where allocations.adjustment_line_id = line.line_id;

      if alloc_total is distinct from line.requested_cases then
        raise exception
          'adjustment line % requires lot allocations totaling requested_cases (%)',
          line.line_id, line.requested_cases
          using errcode = '23514';
      end if;
    end if;

    if line.requested_cases < 0
      and app_private.unreserved_grain_cases(line.crate_id, line.product_id)
        < abs(line.requested_cases)
    then
      raise exception 'insufficient unreserved stock' using errcode = '23514';
    end if;
  end loop;

  select coalesce(sum(pg_catalog.abs(stock_adjustment_lines.requested_cases)), 0)
  into absolute_quantity
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released;

  select case when count(distinct stock_adjustment_lines.crate_id) = 1
    then (pg_catalog.array_agg(stock_adjustment_lines.crate_id))[1] else null end
  into single_crate
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released;

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    notes, product_id, destination_crate_id, quantity, adjustment_request_id
  )
  select
    'ADJUSTMENT', selected.request_number, auth.uid(), cleaned_key, fingerprint,
    selected.note, stock_adjustment_lines.product_id, single_crate, absolute_quantity, selected.id
  from public.stock_adjustment_lines
  where stock_adjustment_lines.request_id = selected.id
    and not stock_adjustment_lines.released
  order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id
  limit 1
  returning id into created_id;

  if dual_write then
    for allocation_row in
      select
        stock_adjustment_lines.product_id,
        stock_adjustment_lines.crate_id,
        alloc_rows.lot_id,
        alloc_rows.quantity
      from public.stock_adjustment_lines
      join public.stock_adjustment_line_lot_allocations alloc_rows
        on alloc_rows.adjustment_line_id = stock_adjustment_lines.id
      where stock_adjustment_lines.request_id = selected.id
        and not stock_adjustment_lines.released
      order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id, alloc_rows.lot_id
    loop
      insert into public.stock_ledger (
        transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
      ) values (
        created_id, allocation_row.product_id, allocation_row.crate_id, allocation_row.quantity,
        auth.uid(), pg_catalog.clock_timestamp(), allocation_row.lot_id
      );

      lot_deltas := lot_deltas || jsonb_build_array(jsonb_build_object(
        'product_id', allocation_row.product_id,
        'lot_id', allocation_row.lot_id,
        'crate_id', allocation_row.crate_id,
        'quantity', allocation_row.quantity
      ));
    end loop;

    perform app_private.apply_lot_aware_stock_deltas(created_id, lot_deltas);
  else
    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at
    )
    select created_id, stock_adjustment_lines.product_id, stock_adjustment_lines.crate_id,
      stock_adjustment_lines.requested_cases, auth.uid(), pg_catalog.clock_timestamp()
    from public.stock_adjustment_lines
    where stock_adjustment_lines.request_id = selected.id
      and not stock_adjustment_lines.released
    order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id;

    for line in
      select stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id,
        stock_adjustment_lines.requested_cases
      from public.stock_adjustment_lines
      where stock_adjustment_lines.request_id = selected.id
        and not stock_adjustment_lines.released
      order by stock_adjustment_lines.crate_id, stock_adjustment_lines.product_id
    loop
      perform app_private.apply_stock_delta(line.crate_id, line.product_id, line.requested_cases);
    end loop;
  end if;

  update public.stock_adjustment_requests
  set
    status = 'posted',
    posted_by = auth.uid(),
    posted_at = pg_catalog.clock_timestamp(),
    posted_transaction_id = created_id,
    version = selected.version + 1,
    updated_at = pg_catalog.clock_timestamp()
  where stock_adjustment_requests.id = selected.id;

  perform app_private.adjustment_event(
    selected.id, 'posted', 'approved', 'posted', selected.version + 1, selected.note
  );
  perform app_private.write_audit(
    auth.uid(), 'post_stock_adjustment', 'stock_adjustment_requests', selected.id,
    pg_catalog.jsonb_build_object(
      'transaction_id', created_id,
      'request_number', selected.request_number,
      'dual_write', dual_write
    )
  );

  return pg_catalog.jsonb_build_object(
    'id', created_id,
    'reference_number', selected.request_number
  );
end;
$$;

