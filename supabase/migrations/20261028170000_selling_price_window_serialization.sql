-- M7.5C.2 price-window concurrency hardening.
-- Does not delete or deactivate historical selling prices.
-- Exclusion is installed only when the local table is already overlap-free.

create extension if not exists btree_gist with schema extensions;

comment on extension btree_gist is
  'Gist equality for uuid so selling-price exclusion can mix scalar keys with daterange.';

-- Transaction-scoped lock for one product + shop (null shop = default list).
create or replace function app_private.lock_selling_price_scope(
  p_product_id uuid,
  p_shop_id uuid
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'selling-price:' || p_product_id::text || ':' || coalesce(p_shop_id::text, ''),
      0
    )
  );
end;
$$;

revoke all on function app_private.lock_selling_price_scope(uuid, uuid)
  from public, anon, authenticated, service_role;

create or replace function app_private.assert_selling_price_no_overlap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'selling prices cannot be deleted' using errcode = '42501';
  end if;

  -- Serialize overlapping writers before the EXISTS check so a second session
  -- sees the first committed row. The previous trigger-only check raced.
  perform app_private.lock_selling_price_scope(new.product_id, new.shop_id);

  if new.is_active
    and exists (
      select 1
      from public.product_selling_prices other
      where other.product_id = new.product_id
        and other.shop_id is not distinct from new.shop_id
        and other.is_active
        and other.id is distinct from new.id
        and app_private.selling_price_window(other.effective_from, other.effective_to)
          && app_private.selling_price_window(new.effective_from, new.effective_to)
    )
  then
    raise exception 'selling price window overlaps an active price for this product and shop'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create or replace function public.upsert_product_selling_price(
  p_product_id uuid,
  p_shop_id uuid,
  p_unit_amount numeric,
  p_effective_from date,
  p_effective_to date default null,
  p_price_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  row_price public.product_selling_prices;
  event_name text;
begin
  perform app_private.assert_permission('products.price.manage');
  perform set_config('app.invoice_write', 'on', true);
  perform app_private.lock_selling_price_scope(p_product_id, p_shop_id);

  if p_unit_amount is null or p_unit_amount <= 0 then
    raise exception 'unit amount must be a positive INR amount' using errcode = '23514';
  end if;
  if p_effective_from is null then
    raise exception 'effective from date is required' using errcode = '23514';
  end if;
  if p_effective_to is not null and p_effective_to < p_effective_from then
    raise exception 'effective to cannot precede effective from' using errcode = '23514';
  end if;

  if not exists (select 1 from public.products where products.id = p_product_id) then
    raise exception 'product not found' using errcode = 'P0002';
  end if;

  if p_shop_id is not null
    and not exists (select 1 from public.shops where shops.id = p_shop_id) then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;

  if p_price_id is null then
    event_name := 'price_created';
    insert into public.product_selling_prices (
      product_id,
      shop_id,
      unit_amount,
      effective_from,
      effective_to,
      created_by,
      updated_by
    )
    values (
      p_product_id,
      p_shop_id,
      p_unit_amount,
      p_effective_from,
      p_effective_to,
      auth.uid(),
      auth.uid()
    )
    returning * into row_price;
  else
    event_name := 'price_updated';
    update public.product_selling_prices
    set
      product_id = p_product_id,
      shop_id = p_shop_id,
      unit_amount = p_unit_amount,
      effective_from = p_effective_from,
      effective_to = p_effective_to,
      updated_at = now(),
      updated_by = auth.uid()
    where product_selling_prices.id = p_price_id
    returning * into row_price;

    if not found then
      raise exception 'selling price not found' using errcode = 'P0002';
    end if;
  end if;

  insert into public.product_selling_price_events (
    price_id,
    event_type,
    payload,
    created_by
  )
  values (
    row_price.id,
    event_name,
    jsonb_build_object(
      'unit_amount', row_price.unit_amount,
      'shop_id', row_price.shop_id,
      'effective_from', row_price.effective_from,
      'effective_to', row_price.effective_to
    ),
    auth.uid()
  );

  perform app_private.write_audit(
    auth.uid(),
    event_name,
    'product_selling_prices',
    row_price.id,
    jsonb_build_object('product_id', row_price.product_id, 'shop_id', row_price.shop_id)
  );

  return jsonb_build_object(
    'id', row_price.id,
    'product_id', row_price.product_id,
    'shop_id', row_price.shop_id,
    'currency_code', row_price.currency_code,
    'unit_amount', row_price.unit_amount,
    'effective_from', row_price.effective_from,
    'effective_to', row_price.effective_to,
    'is_active', row_price.is_active
  );
end;
$$;

-- Exclusion is the durable constraint. It is not installed while leftover
-- overlapping rows exist; those rows are not deleted in this migration.
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
    raise notice 'selling-price exclusion skipped; overlapping active rows were not deleted: %', conflict_text;
  else
    if not exists (
      select 1
      from pg_constraint
      where conname = 'product_selling_prices_active_window_excl'
    ) then
      alter table public.product_selling_prices
        add constraint product_selling_prices_active_window_excl
        exclude using gist (
          product_id with =,
          coalesce(shop_id, '00000000-0000-0000-0000-000000000000'::uuid) with =,
          app_private.selling_price_window(effective_from, effective_to) with &&
        )
        where (is_active);
    end if;
  end if;
end;
$$;

notify pgrst, 'reload schema';
