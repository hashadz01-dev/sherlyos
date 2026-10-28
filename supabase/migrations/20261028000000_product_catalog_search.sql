-- M7.4C. Server-side product search so pickers do not depend on PostgREST's
-- first 1,000 rows. DEFINER only to call app_private.has_permission; visibility
-- matches products_select_readers (manage sees inactive, read sees active).
-- Does not change stock posting, cutover flags, or global max_rows.

create or replace function public.search_products(
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
  supplier_id uuid
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
  elsif capped_limit > 100 then
    capped_limit := 100;
  end if;
  if capped_offset < 0 then
    capped_offset := 0;
  end if;

  -- products.read never sees inactive rows, matching the table policy.
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
    products.supplier_id
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
  'Paged SKU/name product search. Visibility matches products_select_readers. active_only defaults true so operational pickers never offer inactive rows. Does not raise PostgREST max_rows.';
