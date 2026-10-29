-- Shops have a name, not a code. list_product_selling_prices selected shops.code
-- and the selling-price screen failed with "column shops.code does not exist".

create or replace function public.list_product_selling_prices(
  p_product_id uuid default null,
  p_shop_id uuid default null,
  p_include_inactive boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (
    app_private.has_permission('products.price.manage')
    or app_private.has_permission('products.price.read')
  ) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  return coalesce(
    (
      select jsonb_agg(row_to_json(price_rows)::jsonb order by price_rows.effective_from desc, price_rows.created_at desc)
      from (
        select
          product_selling_prices.id,
          product_selling_prices.product_id,
          products.sku,
          products.name as product_name,
          product_selling_prices.shop_id,
          null::text as shop_code,
          shops.name as shop_name,
          product_selling_prices.currency_code,
          product_selling_prices.unit_amount,
          product_selling_prices.effective_from,
          product_selling_prices.effective_to,
          product_selling_prices.is_active,
          product_selling_prices.created_at
        from public.product_selling_prices
        join public.products on products.id = product_selling_prices.product_id
        left join public.shops on shops.id = product_selling_prices.shop_id
        where (p_product_id is null or product_selling_prices.product_id = p_product_id)
          and (
            p_shop_id is null
            or product_selling_prices.shop_id = p_shop_id
            or product_selling_prices.shop_id is null
          )
          and (p_include_inactive or product_selling_prices.is_active)
      ) price_rows
    ),
    '[]'::jsonb
  );
end;
$$;

comment on function public.list_product_selling_prices(uuid, uuid, boolean) is
  'List selling prices. Shop identity is name-only; shops have no code column.';
