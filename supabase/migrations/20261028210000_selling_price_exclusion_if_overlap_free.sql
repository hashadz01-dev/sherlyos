-- M7.5C.3 durable selling-price exclusion.
-- Installs only when the table has no overlapping active windows.
-- Does not deactivate or delete historical prices. Advisory locks remain.

do $$
declare
  conflict_text text;
begin
  select string_agg(
    format(
      '%s a=%s b=%s shop=%s %s-%s vs %s-%s amounts %s/%s',
      products.sku,
      a.id,
      b.id,
      coalesce(a.shop_id::text, 'default'),
      a.effective_from,
      coalesce(a.effective_to::text, 'open'),
      b.effective_from,
      coalesce(b.effective_to::text, 'open'),
      a.unit_amount,
      b.unit_amount
    ),
    '; '
  )
  into conflict_text
  from public.product_selling_prices a
  join public.product_selling_prices b
    on a.product_id = b.product_id
   and a.shop_id is not distinct from b.shop_id
   and a.id < b.id
   and a.is_active
   and b.is_active
   and app_private.selling_price_window(a.effective_from, a.effective_to)
     && app_private.selling_price_window(b.effective_from, b.effective_to)
  join public.products on products.id = a.product_id;

  if conflict_text is not null then
    raise notice
      'product_selling_prices_active_window_excl not installed; overlapping active rows remain (owner must approve deactivation, not deletion): %',
      conflict_text;
    return;
  end if;

  if exists (
    select 1 from pg_constraint where conname = 'product_selling_prices_active_window_excl'
  ) then
    return;
  end if;

  -- Default list uses a sentinel shop key so null shop_id still excludes.
  -- Inclusive daterange matches selling_price_window ('[]', open end = infinity).
  alter table public.product_selling_prices
    add constraint product_selling_prices_active_window_excl
    exclude using gist (
      product_id with =,
      coalesce(shop_id, '00000000-0000-0000-0000-000000000000'::uuid) with =,
      app_private.selling_price_window(effective_from, effective_to) with &&
    )
    where (is_active);

  comment on constraint product_selling_prices_active_window_excl on public.product_selling_prices is
    'Active default and shop-specific selling-price windows cannot overlap.';
end;
$$;
