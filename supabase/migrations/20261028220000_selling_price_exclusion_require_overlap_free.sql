-- M7.5C.3A: install product_selling_prices_active_window_excl now that the
-- owner-approved overlapping test prices are inactive.
--
-- 20261028210000 already ran on the owner database and skipped installation
-- while overlaps remained. This follow-up must not rewrite that history.
-- On a clean replay, 20261028210000 may already have installed the constraint;
-- this file then verifies the catalog definition instead of adding a duplicate.
--
-- Fails (does not silent-skip) when active windows still overlap or when the
-- constraint is missing after the install attempt. Advisory locks remain.

create extension if not exists btree_gist with schema extensions;

do $$
declare
  conflict_text text;
  constraint_def text;
  normalized text;
begin
  if not exists (select 1 from pg_extension where extname = 'btree_gist') then
    raise exception 'btree_gist is required for product_selling_prices_active_window_excl';
  end if;

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
    raise exception
      'product_selling_prices_active_window_excl cannot be installed; overlapping active rows remain: %',
      conflict_text
      using errcode = '23514';
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'product_selling_prices_active_window_excl'
  ) then
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
  end if;

  select pg_get_constraintdef(oid)
  into constraint_def
  from pg_constraint
  where conname = 'product_selling_prices_active_window_excl'
    and conrelid = 'public.product_selling_prices'::regclass;

  if constraint_def is null then
    raise exception
      'product_selling_prices_active_window_excl is missing after install'
      using errcode = 'P0001';
  end if;

  normalized := upper(replace(constraint_def, ' ', ''));
  if normalized not like '%EXCLUDEUSINGGIST%'
     or normalized not like '%PRODUCT_IDWITH=%'
     or normalized not like '%00000000-0000-0000-0000-000000000000%'
     or normalized not like '%SELLING_PRICE_WINDOW(EFFECTIVE_FROM,EFFECTIVE_TO)WITH&&%'
     or normalized not like '%WHERE(IS_ACTIVE)%'
  then
    raise exception
      'product_selling_prices_active_window_excl definition mismatch: %',
      constraint_def
      using errcode = 'P0001';
  end if;

  comment on constraint product_selling_prices_active_window_excl on public.product_selling_prices is
    'Active default and shop-specific selling-price windows cannot overlap.';
end;
$$;
