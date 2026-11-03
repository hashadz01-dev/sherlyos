-- Owner-directed: make catalogue suppliers selectable for receiving.
-- Activates AVT / Kera / Sunpure / Parry's / Nandini / MattaNaad,
-- drops the pending-invoicing label, and links products by SKU prefix.
-- Does not invent GSTIN, phone, or email.

do $$
declare
  admin_id uuid;
  supplier_avt uuid;
  supplier_kera uuid;
  supplier_sunpure uuid;
  supplier_parrys uuid;
  supplier_nandini uuid;
  supplier_mattanaad uuid;
  rec record;
begin
  select ur.user_id
  into strict admin_id
  from public.user_roles ur
  join public.roles r on r.id = ur.role_id
  where r.code = 'admin'
  order by ur.user_id
  limit 1;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', admin_id, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';

  select id into supplier_avt from public.suppliers where name ilike 'AVT%' limit 1;
  select id into supplier_kera from public.suppliers where name ilike 'Kera%' limit 1;
  select id into supplier_sunpure from public.suppliers where name ilike 'Sunpure%' limit 1;
  select id into supplier_parrys from public.suppliers where name ilike 'Parry%' limit 1;
  select id into supplier_nandini from public.suppliers where name ilike 'Nandini%' limit 1;
  select id into supplier_mattanaad from public.suppliers where name ilike 'MattaNaad%' limit 1;

  if supplier_avt is null or supplier_kera is null or supplier_sunpure is null
     or supplier_parrys is null or supplier_nandini is null or supplier_mattanaad is null
  then
    raise exception 'catalogue suppliers are incomplete';
  end if;

  perform public.update_supplier(supplier_avt, 'AVT', null, null);
  perform public.update_supplier(supplier_kera, 'Kera', null, null);
  perform public.update_supplier(supplier_sunpure, 'Sunpure', null, null);
  perform public.update_supplier(supplier_parrys, 'Parry''s', null, null);
  perform public.update_supplier(supplier_nandini, 'Nandini', null, null);
  perform public.update_supplier(supplier_mattanaad, 'MattaNaad', null, null);

  perform public.set_supplier_active(supplier_avt, true);
  perform public.set_supplier_active(supplier_kera, true);
  perform public.set_supplier_active(supplier_sunpure, true);
  perform public.set_supplier_active(supplier_parrys, true);
  perform public.set_supplier_active(supplier_nandini, true);
  perform public.set_supplier_active(supplier_mattanaad, true);

  for rec in
    select products.id, products.sku, products.name, products.category_id
    from public.products
  loop
    if rec.sku like 'AVT-%' or rec.sku like 'DSURE-%' then
      perform public.update_product(rec.id, rec.sku, rec.name, supplier_avt, rec.category_id);
    elsif rec.sku like 'KERA-%' then
      perform public.update_product(rec.id, rec.sku, rec.name, supplier_kera, rec.category_id);
    elsif rec.sku like 'PARRY-%' then
      perform public.update_product(rec.id, rec.sku, rec.name, supplier_parrys, rec.category_id);
    elsif rec.sku like 'GOODLIFE-%' then
      perform public.update_product(rec.id, rec.sku, rec.name, supplier_nandini, rec.category_id);
    elsif rec.sku like 'SUN-%' or rec.sku like 'PALM-%' or rec.sku like 'RBH-%' then
      perform public.update_product(rec.id, rec.sku, rec.name, supplier_sunpure, rec.category_id);
    end if;
  end loop;
end $$;
