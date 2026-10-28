-- M7.5C.3A exclusion-constraint proofs. Rolls back. Does not flip flags.

begin;

do $$
declare
  product_a uuid := gen_random_uuid();
  product_b uuid := gen_random_uuid();
  shop_id uuid := gen_random_uuid();
  price_id uuid;
  resolved record;
  overlap_sqlstate text;
begin
  if exists (
    select 1 from public.app_configuration
    where key in (
      'damage.stock_hold_ready',
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked'
    )
      and value = 'true'::jsonb
  ) then
    raise exception 'operational stock flags must remain false';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'product_selling_prices_active_window_excl'
      and contype = 'x'
  ) then
    raise exception 'product_selling_prices_active_window_excl is not installed';
  end if;

  perform set_config('app.invoice_write', 'on', true);

  insert into public.products (id, sku, name, is_active)
  values
    (product_a, 'm75c3a-excl-a', 'C3A exclusion A', true),
    (product_b, 'm75c3a-excl-b', 'C3A exclusion B', true);

  insert into public.shops (id, name, is_active)
  values (shop_id, 'C3A exclusion shop', true);

  insert into public.product_selling_prices (
    product_id, shop_id, unit_amount, effective_from, effective_to, is_active
  )
  values (product_a, null, 10, date '2026-01-01', date '2026-06-30', true)
  returning id into price_id;

  -- Same product, same list, overlapping active window (open-ended) must fail.
  begin
    insert into public.product_selling_prices (
      product_id, shop_id, unit_amount, effective_from, effective_to, is_active
    )
    values (product_a, null, 11, date '2026-06-01', null, true);
    raise exception 'overlapping open-ended insert must be rejected';
  exception
    when exclusion_violation then
      overlap_sqlstate := sqlstate;
    when check_violation then
      overlap_sqlstate := sqlstate;
  end;
  if overlap_sqlstate is null then
    raise exception 'overlapping insert did not raise';
  end if;

  -- Non-overlapping later window on the same default list is allowed.
  insert into public.product_selling_prices (
    product_id, shop_id, unit_amount, effective_from, effective_to, is_active
  )
  values (product_a, null, 12, date '2026-07-01', date '2026-12-31', true);

  -- Different product, same window, allowed.
  insert into public.product_selling_prices (
    product_id, shop_id, unit_amount, effective_from, effective_to, is_active
  )
  values (product_b, null, 10, date '2026-01-01', date '2026-06-30', true);

  -- Shop-specific list may share the default window.
  insert into public.product_selling_prices (
    product_id, shop_id, unit_amount, effective_from, effective_to, is_active
  )
  values (product_a, shop_id, 13, date '2026-01-01', date '2026-06-30', true);

  -- Inactive historical row may overlap an active window.
  insert into public.product_selling_prices (
    product_id, shop_id, unit_amount, effective_from, effective_to, is_active
  )
  values (product_a, null, 9, date '2026-01-01', date '2026-06-30', false);

  -- Owner survivors resolve to a single default price (fail-closed would raise).
  select * into resolved
  from app_private.resolve_selling_price(
    '53d2dfe5-53db-4335-964d-0a2f3c0124a8'::uuid,
    null,
    date '2026-10-28'
  );
  if resolved.price_id is distinct from 'cf73921d-b8c8-4f50-a800-1e718bb57e50'::uuid
     or resolved.unit_amount is distinct from 11.0000 then
    raise exception 'group A survivor resolution changed: %', resolved;
  end if;

  select * into resolved
  from app_private.resolve_selling_price(
    '8559cc64-d9bb-4cec-9e1a-1d81acc4b196'::uuid,
    null,
    date '2026-10-28'
  );
  if resolved.price_id is distinct from 'fd8cf747-5a23-4515-bec4-c4059ebf460a'::uuid
     or resolved.unit_amount is distinct from 10.0000 then
    raise exception 'group B survivor resolution changed: %', resolved;
  end if;
end;
$$;

rollback;
