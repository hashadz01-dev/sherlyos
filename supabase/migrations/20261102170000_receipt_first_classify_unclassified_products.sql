-- First-classify unclassified SKUs during receiving without granting
-- products.expiry_policy.manage to Godown Manager.
-- Dual-write lot attribution still fail-closes while expiry_policy is null.

create or replace function public.classify_unclassified_product_for_receiving(
  target_product uuid,
  new_policy text
)
returns public.products
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.products%rowtype;
  cleaned text;
  lot_count integer;
begin
  -- Receiving capture/verify, or Admin classify. Not a catalog-wide GM grant.
  if not (
    (select app_private.has_permission('receiving.execute'))
    or (select app_private.has_permission('receiving.verify'))
    or (select app_private.has_permission('products.expiry_policy.manage'))
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  cleaned := nullif(pg_catalog.btrim(coalesce(new_policy, '')), '');
  if cleaned is null or cleaned not in ('expiry_controlled', 'non_expiring') then
    raise exception 'expiry policy is invalid' using errcode = '23514';
  end if;

  select *
  into selected
  from public.products
  where products.id = target_product
  for update;

  if not found then
    raise exception 'product not found' using errcode = '42501';
  end if;

  if selected.expiry_policy is not distinct from cleaned then
    return selected;
  end if;

  -- Reclassification stays on set_product_expiry_policy (Admin).
  if selected.expiry_policy is not null then
    raise exception 'expiry policy is already classified' using errcode = '23514';
  end if;

  select count(*)::integer
  into lot_count
  from public.stock_lots
  where stock_lots.product_id = target_product;

  if lot_count > 0 then
    raise exception 'expiry policy cannot change while stock lots exist for this product'
      using errcode = '23514';
  end if;

  update public.products
  set expiry_policy = cleaned
  where products.id = target_product
  returning * into selected;

  perform app_private.write_audit(
    (select auth.uid()),
    'classify_unclassified_product_for_receiving',
    'products',
    target_product,
    pg_catalog.jsonb_build_object('expiry_policy', cleaned)
  );

  return selected;
end;
$$;

revoke all on function public.classify_unclassified_product_for_receiving(uuid, text)
  from public, anon;
grant execute on function public.classify_unclassified_product_for_receiving(uuid, text)
  to authenticated;

comment on function public.classify_unclassified_product_for_receiving(uuid, text) is
  'First-classifies an unclassified product as expiry_controlled or non_expiring. Requires receiving.execute, receiving.verify, or products.expiry_policy.manage. Idempotent when unchanged. Rejects reclassification and rejects changes once stock_lots exist. Does not grant Godown Manager products.expiry_policy.manage.';

comment on column public.products.expiry_policy is
  'NULL = unclassified. Admin sets or changes policy via set_product_expiry_policy (products.expiry_policy.manage) until stock_lots exist. Receiving staff may first-classify unclassified SKUs with no lots via classify_unclassified_product_for_receiving. Dual-write lot attribution still fail-closes while unclassified.';
