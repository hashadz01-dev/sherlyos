-- M1: Lot-aware operational stock posting (local-first).
-- Forward-only after 20261022180000.
-- Wires opening / crate transfer / receipt verify / adjustment post to
-- app_private.apply_lot_aware_stock_deltas when stock.lots.dual_write_enabled.
-- Allows dual_write_enabled=true via configuration (still defaults false).
-- Does NOT seed inventory or flip flags on apply.

-- ---------------------------------------------------------------------------
-- 1. Cutover helpers + allow dual-write enable (implementation now exists)
-- ---------------------------------------------------------------------------

create or replace function app_private.stock_lots_dual_write_enabled()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  dual_write boolean := false;
begin
  select coalesce(app_configuration.value, 'false'::jsonb) = 'true'::jsonb
  into dual_write
  from public.app_configuration
  where app_configuration.key = 'stock.lots.dual_write_enabled';

  return coalesce(dual_write, false);
end;
$$;

revoke all on function app_private.stock_lots_dual_write_enabled()
  from public, anon, authenticated, service_role;

create or replace function app_private.reject_premature_dual_write_enable()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Dual-write posting paths are implemented (M1). Enabling remains an
  -- operational cutover decision; no longer rejected solely for "not implemented".
  return new;
end;
$$;

update public.app_configuration
set description = 'Phase 4.3E M1. When true, stock posting RPCs require lot-aware dual-write and aggregate-only apply_stock_delta is closed. Default false until owner cutover.'
where key = 'stock.lots.dual_write_enabled';

create or replace function public.get_stock_lot_cutover_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  dual_write boolean := false;
  blocked boolean := false;
begin
  if auth.uid() is null then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select coalesce(app_configuration.value, 'false'::jsonb) = 'true'::jsonb
  into dual_write
  from public.app_configuration
  where app_configuration.key = 'stock.lots.dual_write_enabled';

  select coalesce(app_configuration.value, 'false'::jsonb) = 'true'::jsonb
  into blocked
  from public.app_configuration
  where app_configuration.key = 'stock.lots.aggregate_only_blocked';

  return pg_catalog.jsonb_build_object(
    'dual_write_enabled', coalesce(dual_write, false),
    'aggregate_only_blocked', coalesce(blocked, false)
  );
end;
$$;

revoke all on function public.get_stock_lot_cutover_state()
  from public, anon, service_role;
grant execute on function public.get_stock_lot_cutover_state() to authenticated;

create or replace function app_private.require_product_expiry_policy(target_product uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  policy text;
begin
  select products.expiry_policy
  into policy
  from public.products
  where products.id = target_product;

  if not found then
    raise exception 'product not found' using errcode = '23514';
  end if;

  if policy is null then
    raise exception 'product expiry policy is unclassified' using errcode = '23514';
  end if;

  return policy;
end;
$$;

revoke all on function app_private.require_product_expiry_policy(uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_lot_metadata_for_policy(
  product_policy text,
  manufacturer_lot_code text,
  manufactured_on date,
  expiry_date date
)
returns text
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  cleaned_code text;
begin
  cleaned_code := nullif(pg_catalog.btrim(coalesce(manufacturer_lot_code, '')), '');

  if product_policy = 'expiry_controlled' and expiry_date is null then
    raise exception 'expiry_date is required for expiry_controlled products'
      using errcode = '23514';
  end if;

  if product_policy = 'non_expiring' and expiry_date is not null then
    raise exception 'expiry_date must be null for non_expiring products'
      using errcode = '23514';
  end if;

  if manufactured_on is not null and expiry_date is not null and manufactured_on > expiry_date then
    raise exception 'manufactured_on cannot be after expiry_date' using errcode = '23514';
  end if;

  return cleaned_code;
end;
$$;

revoke all on function app_private.assert_lot_metadata_for_policy(text, text, date, date)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. List lot balances (for transfer / adjustment UI)
-- ---------------------------------------------------------------------------

create or replace function public.list_stock_lot_balances(
  filter_branch uuid default null,
  filter_crate uuid default null,
  filter_product uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform app_private.assert_permission('stock.read');

  return coalesce((
    select pg_catalog.jsonb_agg(row_to_json(q)::jsonb order by q.product_sku, q.crate_code, q.lot_id)
    from (
      select
        stock_lots.id as lot_id,
        stock_lots.product_id,
        products.sku as product_sku,
        products.name as product_name,
        products.expiry_policy,
        stock_lots.status as lot_status,
        stock_lots.origin as lot_origin,
        stock_lots.manufacturer_lot_code,
        stock_lots.manufactured_on,
        stock_lots.expiry_date,
        stock_lots.received_on,
        stock_lots.branch_id as godown_id,
        branches.code as godown_code,
        stock_lot_balances.crate_id,
        crates.code as crate_code,
        stock_lot_balances.quantity
      from public.stock_lot_balances
      join public.stock_lots on stock_lots.id = stock_lot_balances.lot_id
      join public.products on products.id = stock_lots.product_id
      join public.crates on crates.id = stock_lot_balances.crate_id
      join public.zones on zones.id = crates.zone_id
      join public.branches on branches.id = zones.branch_id
      where stock_lot_balances.quantity >= 0
        and (filter_branch is null or stock_lots.branch_id = filter_branch)
        and (filter_crate is null or stock_lot_balances.crate_id = filter_crate)
        and (filter_product is null or stock_lots.product_id = filter_product)
        and (
          app_private.has_permission('branches.access_all')
          or app_private.can_work_at_branch(stock_lots.branch_id)
        )
    ) q
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.list_stock_lot_balances(uuid, uuid, uuid)
  from public, anon, service_role;
grant execute on function public.list_stock_lot_balances(uuid, uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Adjustment lot allocations (explicit lots before post)
-- ---------------------------------------------------------------------------

create table public.stock_adjustment_line_lot_allocations (
  adjustment_line_id uuid not null
    references public.stock_adjustment_lines (id) on delete cascade,
  lot_id uuid not null references public.stock_lots (id) on delete restrict,
  quantity integer not null,
  primary key (adjustment_line_id, lot_id),
  constraint stock_adjustment_line_lot_allocations_qty_check
    check (quantity <> 0 and quantity >= -1000000 and quantity <= 1000000)
);

comment on table public.stock_adjustment_line_lot_allocations is
  'M1. Explicit lot quantities for an adjustment line. Required when dual-write is enabled at post time. Sum must equal the line requested_cases.';

alter table public.stock_adjustment_line_lot_allocations enable row level security;
alter table public.stock_adjustment_line_lot_allocations force row level security;

create policy stock_adjustment_line_lot_allocations_select
  on public.stock_adjustment_line_lot_allocations
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.stock_adjustment_lines
      join public.stock_adjustment_requests
        on stock_adjustment_requests.id = stock_adjustment_lines.request_id
      where stock_adjustment_lines.id = stock_adjustment_line_lot_allocations.adjustment_line_id
        and app_private.can_view_stock_adjustment(stock_adjustment_requests.godown_id)
    )
  );

revoke all on table public.stock_adjustment_line_lot_allocations
  from public, anon, authenticated, service_role;
grant select on table public.stock_adjustment_line_lot_allocations to authenticated;

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
begin
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
-- ---------------------------------------------------------------------------
-- 4. post_opening_stock (lot-aware when dual-write enabled)
-- ---------------------------------------------------------------------------

drop function if exists public.post_opening_stock(uuid, uuid, integer, text, text);

create or replace function public.post_opening_stock(
  target_product uuid,
  target_crate uuid,
  carton_quantity integer,
  idempotency_key text,
  posting_notes text,
  manufacturer_lot_code text default null,
  manufactured_on date default null,
  expiry_date date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_key text;
  cleaned_notes text;
  cleaned_code text;
  fingerprint text;
  replay jsonb;
  created_id uuid;
  reference_number text;
  conflict_name text;
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
  product_policy text;
  crate_branch uuid;
  new_lot uuid;
  lot_deltas jsonb;
begin
  perform app_private.assert_permission('stock.opening.post');
  perform app_private.assert_carton_quantity(carton_quantity);
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  cleaned_notes := app_private.clean_optional_text(posting_notes, 500);

  if not dual_write then
    if manufacturer_lot_code is not null or manufactured_on is not null or expiry_date is not null then
      raise exception 'lot metadata is only accepted when lot-aware dual-write is enabled'
        using errcode = '23514';
    end if;
  end if;

  fingerprint := app_private.stock_request_fingerprint(
    'OPENING_STOCK',
    target_product,
    null,
    target_crate,
    carton_quantity,
    cleaned_notes
  );

  if dual_write then
    fingerprint := fingerprint
      || '|LOT:'
      || coalesce(nullif(pg_catalog.btrim(coalesce(manufacturer_lot_code, '')), ''), '')
      || '|'
      || coalesce(manufactured_on::text, '')
      || '|'
      || coalesce(expiry_date::text, '');
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

  perform app_private.prepare_stock_locations(array[target_crate]);

  select zones.branch_id into crate_branch
  from public.crates
  join public.zones on zones.id = crates.zone_id
  where crates.id = target_crate;

  replay := app_private.replay_stock_transaction(cleaned_key, fingerprint);
  if replay is not null then
    return replay;
  end if;

  perform stock_balances.quantity
  from public.stock_balances
  where stock_balances.crate_id = target_crate
    and stock_balances.product_id = target_product
  for update;

  if exists (
    select 1 from public.stock_transactions
    where stock_transactions.transaction_type = 'OPENING_STOCK'
      and stock_transactions.product_id = target_product
      and stock_transactions.destination_crate_id = target_crate
  ) then
    raise exception 'opening stock was already posted for this product and crate'
      using errcode = '23505';
  end if;

  reference_number := 'OS-'
    || to_char(pg_catalog.clock_timestamp() at time zone 'UTC', 'YYYYMMDD')
    || '-'
    || pg_catalog.lpad(pg_catalog.nextval('public.stock_reference_seq')::text, 6, '0');

  insert into public.stock_transactions (
    transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
    notes, product_id, destination_crate_id, quantity
  ) values (
    'OPENING_STOCK', reference_number, auth.uid(), cleaned_key, fingerprint,
    cleaned_notes, target_product, target_crate, carton_quantity
  )
  returning id into created_id;

  if dual_write then
    product_policy := app_private.require_product_expiry_policy(target_product);
    cleaned_code := app_private.assert_lot_metadata_for_policy(
      product_policy, manufacturer_lot_code, manufactured_on, expiry_date
    );

    insert into public.stock_lots (
      product_id, branch_id, manufacturer_lot_code, manufactured_on, expiry_date,
      received_on, status, origin, source_transaction_id, created_by
    ) values (
      target_product, crate_branch, cleaned_code, manufactured_on, expiry_date,
      pg_catalog.clock_timestamp(), 'available', 'opening', created_id, auth.uid()
    )
    returning id into new_lot;

    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
    )
    select created_id, target_product, target_crate, carton_quantity,
      stock_transactions.actor_id, stock_transactions.posted_at, new_lot
    from public.stock_transactions
    where stock_transactions.id = created_id;

    lot_deltas := jsonb_build_array(jsonb_build_object(
      'product_id', target_product,
      'lot_id', new_lot,
      'crate_id', target_crate,
      'quantity', carton_quantity
    ));

    perform app_private.apply_lot_aware_stock_deltas(created_id, lot_deltas);
  else
    insert into public.stock_ledger (
      transaction_id, product_id, crate_id, quantity, actor_id, posted_at
    )
    select created_id, target_product, target_crate, carton_quantity,
      stock_transactions.actor_id, stock_transactions.posted_at
    from public.stock_transactions
    where stock_transactions.id = created_id;

    perform app_private.apply_stock_delta(target_crate, target_product, carton_quantity);
  end if;

  perform app_private.write_audit(
    auth.uid(), 'post_opening_stock', 'stock_transactions', created_id,
    pg_catalog.jsonb_build_object(
      'reference_number', reference_number,
      'product_id', target_product,
      'crate_id', target_crate,
      'quantity', carton_quantity,
      'dual_write', dual_write,
      'lot_id', new_lot
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
    if conflict_name = 'stock_transactions_opening_once' then
      raise exception 'opening stock was already posted for this product and crate'
        using errcode = '23505';
    end if;
    raise;
end;
$$;

revoke all on function public.post_opening_stock(uuid, uuid, integer, text, text, text, date, date)
  from public, anon, service_role;
grant execute on function public.post_opening_stock(uuid, uuid, integer, text, text, text, date, date)
  to authenticated;

comment on function public.post_opening_stock(uuid, uuid, integer, text, text, text, date, date) is
  'Posts opening stock. Aggregate-only when dual_write_enabled=false. When true, requires classified expiry policy and lot metadata; creates opening lot and dual-writes balances.';

-- ---------------------------------------------------------------------------
-- 5. post_crate_transfer (explicit lot moves when dual-write enabled)
-- ---------------------------------------------------------------------------

drop function if exists public.post_crate_transfer(uuid, uuid, uuid, integer, text, text);

create or replace function public.post_crate_transfer(
  target_product uuid,
  source_crate uuid,
  destination_crate uuid,
  carton_quantity integer,
  idempotency_key text,
  posting_notes text,
  lot_moves jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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

  select stock_balances.quantity into source_quantity
  from public.stock_balances
  where stock_balances.crate_id = source_crate
    and stock_balances.product_id = target_product
  for update;

  perform stock_balances.quantity
  from public.stock_balances
  where stock_balances.crate_id = destination_crate
    and stock_balances.product_id = target_product
  for update;

  if coalesce(source_quantity, 0) < carton_quantity then
    raise exception 'insufficient stock' using errcode = '23514';
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

      select stock_lot_balances.quantity into lot_qty
      from public.stock_lot_balances
      where stock_lot_balances.lot_id = move_lot
        and stock_lot_balances.crate_id = source_crate
      for update;

      if coalesce(lot_qty, 0) < move_qty then
        raise exception 'insufficient lot stock' using errcode = '23514';
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

revoke all on function public.post_crate_transfer(uuid, uuid, uuid, integer, text, text, jsonb)
  from public, anon, service_role;
grant execute on function public.post_crate_transfer(uuid, uuid, uuid, integer, text, text, jsonb)
  to authenticated;

comment on function public.post_crate_transfer(uuid, uuid, uuid, integer, text, text, jsonb) is
  'Same-godown crate transfer. When dual_write_enabled, requires explicit lot_moves summing to carton_quantity (no FEFO).';

-- ---------------------------------------------------------------------------
-- 6. verify_stock_receipt (multi-lot from attributions when dual-write)
-- ---------------------------------------------------------------------------

create or replace function public.verify_stock_receipt(
  target_receipt uuid,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.stock_receipts;
  cleaned_key text;
  fingerprint text;
  selected_branch uuid;
  crate_ids uuid[];
  line_record record;
  attribution_row record;
  created_id uuid;
  reference_number text;
  dual_write boolean := app_private.stock_lots_dual_write_enabled();
  product_policy text;
  cleaned_code text;
  new_lot uuid;
  attr_total integer;
  lot_deltas jsonb;
begin
  perform app_private.assert_permission('receiving.verify');
  cleaned_key := app_private.clean_idempotency_key(idempotency_key);
  selected := app_private.lock_stock_receipt(target_receipt);

  if not app_private.can_work_at_branch(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  fingerprint := app_private.receipt_posting_fingerprint(selected.id);

  if selected.status = 'posted' then
    if selected.posting_idempotency_key = cleaned_key
      and selected.posting_fingerprint = fingerprint then
      return app_private.stock_receipt_payload(selected.id);
    end if;
    raise exception 'idempotency key was already used for a different request'
      using errcode = '23505';
  end if;

  if selected.status is distinct from 'submitted' then
    raise exception 'receipt cannot be verified' using errcode = '42501';
  end if;

  perform suppliers.id from public.suppliers
  where suppliers.id = selected.supplier_id for update;

  if not exists (
    select 1 from public.suppliers
    where suppliers.id = selected.supplier_id and suppliers.is_active
  ) then
    raise exception 'supplier is inactive or missing' using errcode = '23514';
  end if;

  perform products.id
  from public.products
  where products.id in (
    select stock_receipt_lines.product_id from public.stock_receipt_lines
    where stock_receipt_lines.receipt_id = selected.id
  )
  order by products.id
  for update;

  if exists (
    select 1 from public.stock_receipt_lines
    left join public.products on products.id = stock_receipt_lines.product_id
    where stock_receipt_lines.receipt_id = selected.id
      and (products.id is null or not products.is_active)
  ) then
    raise exception 'product is inactive or missing' using errcode = '23514';
  end if;

  select coalesce(array_agg(distinct stock_receipt_lines.destination_crate_id), '{}')
  into crate_ids
  from public.stock_receipt_lines
  where stock_receipt_lines.receipt_id = selected.id;

  selected_branch := app_private.prepare_stock_locations(crate_ids);
  if selected_branch is distinct from selected.godown_id then
    raise exception 'destination crate is outside this godown' using errcode = '23514';
  end if;

  if exists (
    select 1 from public.stock_receipt_lines
    join public.crates on crates.id = stock_receipt_lines.destination_crate_id
    join public.zones on zones.id = crates.zone_id
    join public.branches on branches.id = zones.branch_id
    where stock_receipt_lines.receipt_id = selected.id
      and (
        not crates.is_active or not zones.is_active or not branches.is_active
        or zones.branch_id is distinct from selected.godown_id
      )
  ) then
    raise exception 'location is inactive' using errcode = '23514';
  end if;

  for line_record in
    select
      stock_receipt_lines.id,
      stock_receipt_lines.product_id,
      stock_receipt_lines.destination_crate_id,
      stock_receipt_lines.accepted_cases
    from public.stock_receipt_lines
    where stock_receipt_lines.receipt_id = selected.id
      and stock_receipt_lines.accepted_cases > 0
    order by
      stock_receipt_lines.destination_crate_id,
      stock_receipt_lines.product_id,
      stock_receipt_lines.id
  loop
    reference_number := 'RR-'
      || pg_catalog.to_char(pg_catalog.clock_timestamp(), 'YYYYMMDD')
      || '-'
      || pg_catalog.lpad(pg_catalog.nextval('public.stock_reference_seq')::text, 6, '0');

    insert into public.stock_transactions (
      transaction_type, reference_number, actor_id, idempotency_key, request_fingerprint,
      notes, product_id, destination_crate_id, quantity, receipt_id, receipt_line_id
    ) values (
      'RECEIPT', reference_number, auth.uid(),
      selected.id::text || '-' || line_record.id::text,
      fingerprint || '|' || line_record.id::text,
      selected.receipt_number, line_record.product_id,
      line_record.destination_crate_id, line_record.accepted_cases,
      selected.id, line_record.id
    )
    returning id into created_id;

    if dual_write then
      product_policy := app_private.require_product_expiry_policy(line_record.product_id);

      select coalesce(sum(attributions.carton_quantity), 0) into attr_total
      from public.stock_receipt_line_lot_attributions attributions
      where attributions.receipt_line_id = line_record.id;

      if attr_total is distinct from line_record.accepted_cases then
        raise exception
          'receipt line % requires lot attributions totaling accepted_cases (%)',
          line_record.id, line_record.accepted_cases
          using errcode = '23514';
      end if;

      lot_deltas := '[]'::jsonb;

      for attribution_row in
        select *
        from public.stock_receipt_line_lot_attributions
        where stock_receipt_line_lot_attributions.receipt_line_id = line_record.id
        order by sort_order, id
      loop
        cleaned_code := app_private.assert_lot_metadata_for_policy(
          product_policy,
          attribution_row.manufacturer_lot_code,
          attribution_row.manufactured_on,
          attribution_row.expiry_date
        );

        insert into public.stock_lots (
          product_id, branch_id, supplier_id, manufacturer_lot_code, manufactured_on,
          expiry_date, received_on, status, origin, source_receipt_line_id,
          source_transaction_id, created_by
        ) values (
          line_record.product_id, selected.godown_id, selected.supplier_id,
          cleaned_code, attribution_row.manufactured_on, attribution_row.expiry_date,
          pg_catalog.clock_timestamp(), 'available', 'receipt',
          line_record.id, created_id, auth.uid()
        )
        returning id into new_lot;

        insert into public.stock_ledger (
          transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
        )
        select created_id, line_record.product_id, line_record.destination_crate_id,
          attribution_row.carton_quantity, stock_transactions.actor_id, stock_transactions.posted_at, new_lot
        from public.stock_transactions
        where stock_transactions.id = created_id;

        lot_deltas := lot_deltas || jsonb_build_array(jsonb_build_object(
          'product_id', line_record.product_id,
          'lot_id', new_lot,
          'crate_id', line_record.destination_crate_id,
          'quantity', attribution_row.carton_quantity
        ));
      end loop;

      perform app_private.apply_lot_aware_stock_deltas(created_id, lot_deltas);
    else
      insert into public.stock_ledger (
        transaction_id, product_id, crate_id, quantity, actor_id, posted_at
      )
      select created_id, line_record.product_id, line_record.destination_crate_id,
        line_record.accepted_cases, stock_transactions.actor_id, stock_transactions.posted_at
      from public.stock_transactions
      where stock_transactions.id = created_id;

      perform app_private.apply_stock_delta(
        line_record.destination_crate_id,
        line_record.product_id,
        line_record.accepted_cases
      );
    end if;
  end loop;

  update public.stock_receipts
  set
    status = 'posted',
    verified_by = auth.uid(),
    verified_at = pg_catalog.clock_timestamp(),
    posted_at = pg_catalog.clock_timestamp(),
    posting_idempotency_key = cleaned_key,
    posting_fingerprint = fingerprint
  where stock_receipts.id = selected.id;

  perform app_private.write_audit(
    auth.uid(), 'verify_stock_receipt', 'stock_receipts', selected.id,
    pg_catalog.jsonb_build_object(
      'receipt_number', selected.receipt_number,
      'idempotency_key', cleaned_key,
      'dual_write', dual_write
    )
  );

  return app_private.stock_receipt_payload(selected.id);
exception
  when unique_violation then
    raise exception 'idempotency key was already used for a different request'
      using errcode = '23505';
end;
$$;

revoke all on function public.verify_stock_receipt(uuid, text)
  from public, anon, service_role;
grant execute on function public.verify_stock_receipt(uuid, text)
  to authenticated;

comment on function public.verify_stock_receipt(uuid, text) is
  'Verifies a submitted receipt. Aggregate-only when dual_write_enabled=false. When true, requires matching lot attributions, creates receipt lots, and dual-writes balances.';

-- ---------------------------------------------------------------------------
-- 7. post_stock_adjustment (lot allocations when dual-write)
-- ---------------------------------------------------------------------------

create or replace function public.post_stock_adjustment(
  target_request uuid,
  expected_version integer,
  idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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

revoke all on function public.post_stock_adjustment(uuid, integer, text)
  from public, anon, service_role;
grant execute on function public.post_stock_adjustment(uuid, integer, text)
  to authenticated;

comment on function public.post_stock_adjustment(uuid, integer, text) is
  'Posts an approved adjustment. When dual_write_enabled, requires lot allocations per line summing to requested_cases. Stale version returns PT409.';

-- ---------------------------------------------------------------------------
-- 8. Payload enrichments for FE lot UI
-- ---------------------------------------------------------------------------

create or replace function app_private.stock_receipt_payload(target uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'id', stock_receipts.id,
    'receipt_number', stock_receipts.receipt_number,
    'godown_id', stock_receipts.godown_id,
    'godown_code', branches.code,
    'godown_name', branches.name,
    'supplier_id', stock_receipts.supplier_id,
    'supplier_name', suppliers.name,
    'document_reference', stock_receipts.document_reference,
    'received_date', stock_receipts.received_date,
    'status', stock_receipts.status,
    'notes', stock_receipts.notes,
    'hold_reason', stock_receipts.hold_reason,
    'created_by', stock_receipts.created_by,
    'creator_name', creator.full_name,
    'created_at', stock_receipts.created_at,
    'updated_at', stock_receipts.updated_at,
    'verified_by', stock_receipts.verified_by,
    'verifier_name', verifier.full_name,
    'verified_at', stock_receipts.verified_at,
    'posted_at', stock_receipts.posted_at,
    'cancelled_by', stock_receipts.cancelled_by,
    'canceller_name', canceller.full_name,
    'cancelled_at', stock_receipts.cancelled_at,
    'cancellation_reason', stock_receipts.cancellation_reason,
    'lines', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', stock_receipt_lines.id,
          'product_id', stock_receipt_lines.product_id,
          'product_sku', products.sku,
          'product_name', products.name,
          'expiry_policy', products.expiry_policy,
          'zone_id', zones.id,
          'zone_code', zones.code,
          'destination_crate_id', stock_receipt_lines.destination_crate_id,
          'crate_code', crates.code,
          'document_cases', stock_receipt_lines.document_cases,
          'counted_cases', stock_receipt_lines.counted_cases,
          'damaged_cases', stock_receipt_lines.damaged_cases,
          'accepted_cases', stock_receipt_lines.accepted_cases,
          'lot_attributions', coalesce((
            select pg_catalog.jsonb_agg(
              pg_catalog.jsonb_build_object(
                'id', attr.id,
                'carton_quantity', attr.carton_quantity,
                'manufacturer_lot_code', attr.manufacturer_lot_code,
                'manufactured_on', attr.manufactured_on,
                'expiry_date', attr.expiry_date,
                'sort_order', attr.sort_order
              )
              order by attr.sort_order, attr.id
            )
            from public.stock_receipt_line_lot_attributions attr
            where attr.receipt_line_id = stock_receipt_lines.id
          ), '[]'::jsonb)
        )
        order by stock_receipt_lines.created_at, stock_receipt_lines.id
      )
      from public.stock_receipt_lines
      join public.products on products.id = stock_receipt_lines.product_id
      join public.crates on crates.id = stock_receipt_lines.destination_crate_id
      join public.zones on zones.id = crates.zone_id
      where stock_receipt_lines.receipt_id = stock_receipts.id
    ), '[]'::jsonb),
    'transactions', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', stock_transactions.id,
          'reference_number', stock_transactions.reference_number,
          'receipt_line_id', stock_transactions.receipt_line_id,
          'quantity', stock_transactions.quantity
        )
        order by stock_transactions.reference_number
      )
      from public.stock_transactions
      where stock_transactions.receipt_id = stock_receipts.id
    ), '[]'::jsonb),
    'audit', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'action', audit_logs.action,
          'actor_name', profiles.full_name,
          'occurred_at', audit_logs.occurred_at,
          'metadata', audit_logs.metadata
        )
        order by audit_logs.occurred_at, audit_logs.id
      )
      from public.audit_logs
      left join public.profiles on profiles.id = audit_logs.actor_id
      where audit_logs.entity_table = 'stock_receipts'
        and audit_logs.entity_id = stock_receipts.id
    ), '[]'::jsonb)
  )
  from public.stock_receipts
  join public.branches on branches.id = stock_receipts.godown_id
  join public.suppliers on suppliers.id = stock_receipts.supplier_id
  join public.profiles as creator on creator.id = stock_receipts.created_by
  left join public.profiles as verifier on verifier.id = stock_receipts.verified_by
  left join public.profiles as canceller on canceller.id = stock_receipts.cancelled_by
  where stock_receipts.id = target;
$$;

create or replace function public.get_stock_adjustment(target_request uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected public.stock_adjustment_requests;
begin
  select *
  into selected
  from public.stock_adjustment_requests
  where stock_adjustment_requests.id = target_request;

  if not found or not app_private.can_view_stock_adjustment(selected.godown_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'id', selected.id,
    'request_number', selected.request_number,
    'godown_id', selected.godown_id,
    'godown_name', (select branches.name from public.branches where branches.id = selected.godown_id),
    'verification_id', selected.verification_id,
    'verification_number', (
      select stock_verifications.verification_number
      from public.stock_verifications
      where stock_verifications.id = selected.verification_id
    ),
    'evidence_id', selected.evidence_id,
    'compensates_request_id', selected.compensates_request_id,
    'status', selected.status,
    'exceptional', selected.exceptional,
    'version', selected.version,
    'reason_code', selected.reason_code,
    'note', selected.note,
    'requested_by', selected.requested_by,
    'requested_by_name', (select profiles.full_name from public.profiles where profiles.id = selected.requested_by),
    'approved_by_name', (select profiles.full_name from public.profiles where profiles.id = selected.approved_by),
    'posted_by_name', (select profiles.full_name from public.profiles where profiles.id = selected.posted_by),
    'other_manager_exists', app_private.other_adjustment_manager_exists(selected.godown_id, selected.requested_by),
    'lines', (
      select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', stock_adjustment_lines.id,
        'verification_line_id', stock_adjustment_lines.verification_line_id,
        'crate_id', stock_adjustment_lines.crate_id,
        'product_id', stock_adjustment_lines.product_id,
        'crate_code', crates.code,
        'sku', products.sku,
        'product_name', products.name,
        'requested_cases', stock_adjustment_lines.requested_cases,
        'current_cases', (
          select stock_balances.quantity
          from public.stock_balances
          where stock_balances.crate_id = stock_adjustment_lines.crate_id
            and stock_balances.product_id = stock_adjustment_lines.product_id
        ),
        'lot_allocations', coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'lot_id', alloc.lot_id,
            'quantity', alloc.quantity
          ) order by alloc.lot_id)
          from public.stock_adjustment_line_lot_allocations alloc
          where alloc.adjustment_line_id = stock_adjustment_lines.id
        ), '[]'::jsonb)
      ) order by crates.code, products.sku), '[]'::jsonb)
      from public.stock_adjustment_lines
      join public.crates on crates.id = stock_adjustment_lines.crate_id
      join public.products on products.id = stock_adjustment_lines.product_id
      where stock_adjustment_lines.request_id = selected.id
        and not stock_adjustment_lines.released
    ),
    'events', (
      select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'event_type', stock_adjustment_events.event_type,
        'actor_name', profiles.full_name,
        'from_status', stock_adjustment_events.from_status,
        'to_status', stock_adjustment_events.to_status,
        'request_version', stock_adjustment_events.request_version,
        'note', stock_adjustment_events.note,
        'created_at', stock_adjustment_events.created_at
      ) order by stock_adjustment_events.created_at), '[]'::jsonb)
      from public.stock_adjustment_events
      join public.profiles on profiles.id = stock_adjustment_events.actor_id
      where stock_adjustment_events.request_id = selected.id
    )
  );
end;
$$;

revoke all on function public.get_stock_adjustment(uuid)
  from public, anon, service_role;
grant execute on function public.get_stock_adjustment(uuid)
  to authenticated;

create or replace function public.list_receiving_options()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not (
    app_private.has_permission('receiving.execute')
    or app_private.has_permission('receiving.verify')
    or app_private.has_permission('operations.monitor')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'godowns', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('id', branches.id, 'code', branches.code, 'name', branches.name)
        order by branches.name
      )
      from public.branches
      where branches.is_active and app_private.can_work_at_branch(branches.id)
    ), '[]'::jsonb),
    'suppliers', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('id', suppliers.id, 'name', suppliers.name)
        order by suppliers.name
      )
      from public.suppliers where suppliers.is_active
    ), '[]'::jsonb),
    'products', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', products.id, 'sku', products.sku, 'name', products.name,
          'expiry_policy', products.expiry_policy
        )
        order by products.name
      )
      from public.products where products.is_active
    ), '[]'::jsonb),
    'zones', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', zones.id, 'branch_id', zones.branch_id, 'code', zones.code, 'name', zones.name
        )
        order by zones.code
      )
      from public.zones
      where zones.is_active and app_private.can_work_at_branch(zones.branch_id)
    ), '[]'::jsonb),
    'crates', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', crates.id, 'zone_id', crates.zone_id, 'code', crates.code, 'name', crates.name
        )
        order by crates.code
      )
      from public.crates
      join public.zones on zones.id = crates.zone_id
      where crates.is_active and zones.is_active
        and app_private.can_work_at_branch(zones.branch_id)
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.list_receiving_options() from public, anon, service_role;
grant execute on function public.list_receiving_options() to authenticated;
