-- Browse needs billed_units_per_case on the product list. Return type change
-- requires drop; visibility and stock writers stay the same.

drop function if exists public.search_products(text, integer, integer, boolean, uuid);

create function public.search_products(
  product_query text default null,
  result_limit integer default 50,
  result_offset integer default 0,
  active_only boolean default true,
  filter_supplier uuid default null
)
returns table (
  id uuid,
  sku text,
  name text,
  is_active boolean,
  expiry_policy text,
  category_id uuid,
  supplier_id uuid,
  billing_unit text,
  billed_units_per_case numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cleaned text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(product_query, ''))), '');
  escaped text;
  capped_limit integer := coalesce(result_limit, 50);
  capped_offset integer := coalesce(result_offset, 0);
  can_manage boolean := app_private.has_permission('products.manage');
  restrict_active boolean;
begin
  if not (
    can_manage
    or app_private.has_permission('products.read')
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if capped_limit < 1 then
    capped_limit := 1;
  elsif capped_limit > 200 then
    capped_limit := 200;
  end if;
  if capped_offset < 0 then
    capped_offset := 0;
  end if;

  restrict_active := active_only or not can_manage;
  escaped := replace(replace(replace(coalesce(cleaned, ''), '\', '\\'), '%', '\%'), '_', '\_');

  return query
  select
    products.id,
    products.sku,
    products.name,
    products.is_active,
    products.expiry_policy,
    products.category_id,
    products.supplier_id,
    products.billing_unit,
    products.billed_units_per_case
  from public.products
  where (not restrict_active or products.is_active)
    and (filter_supplier is null or products.supplier_id = filter_supplier)
    and (
      cleaned is null
      or pg_catalog.lower(products.sku) like '%' || escaped || '%' escape '\'
      or pg_catalog.lower(products.name) like '%' || escaped || '%' escape '\'
    )
  order by products.name, products.sku, products.id
  offset capped_offset
  limit capped_limit;
end;
$$;

revoke all on function public.search_products(text, integer, integer, boolean, uuid)
  from public, anon, authenticated, service_role;

grant execute on function public.search_products(text, integer, integer, boolean, uuid)
  to authenticated;

comment on function public.search_products(text, integer, integer, boolean, uuid) is
  'Paged SKU/name product search including billed case pack. Visibility matches products_select_readers.';
