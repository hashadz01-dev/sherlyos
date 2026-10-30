-- Authorized development-cloud follow-up: show Sunpure as the supplier
-- and insert SKU'd SUNPURE catalogue rows. No stock, prices, or flag flips.
do $$
declare
  admin_id uuid := 'cdc087c0-0295-425d-8dbe-9a91030bf012';
  supplier_id uuid := 'e2b70c1a-b24f-4f49-b634-25776b1ffb62';
  ledger_before bigint;
  balance_before bigint;
  lot_before bigint;
  price_before bigint;
  flag_before integer;
  rec record;
  cat uuid;
  pid uuid;
begin
  select count(*) into ledger_before from public.stock_ledger;
  select count(*) into balance_before from public.stock_balances;
  select count(*) into lot_before from public.stock_lots;
  select count(*) into price_before from public.product_selling_prices;
  select count(*) into flag_before from public.app_configuration
    where key in ('damage.stock_hold_ready','stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked')
      and value = 'true'::jsonb;
  if flag_before is distinct from 0 then
    raise exception 'operational flags must remain false';
  end if;
  if not exists (select 1 from auth.users where id = admin_id and email = 'jeffinpappachan110@gmail.com') then
    raise exception 'Jeffin admin id mismatch';
  end if;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true);

  perform public.update_supplier(
    supplier_id,
    'Sunpure (MK Agrotech; invoicing pending)',
    null,
    null
  );
  perform public.set_supplier_active(supplier_id, true);

  for rec in
    select * from (values
      ('SUN-SFO-500ML-PCH', 'Sunpure Sunflower Oil 500ml Pouch', 'Edible Oils'),
      ('SUN-SFO-1L-PCH', 'Sunpure Sunflower Oil 1L Pouch', 'Edible Oils'),
      ('SUN-SFO-100ML-PCH', 'Sunpure Sunflower Oil 100ml Pouch', 'Edible Oils'),
      ('SUN-SFO-200ML-PCH', 'Sunpure Sunflower Oil 200ml Pouch', 'Edible Oils'),
      ('SUN-SFO-1L-PET', 'Sunpure Sunflower Oil 1L PET Jar', 'Edible Oils'),
      ('SUN-SFO-2L-PET', 'Sunpure Sunflower Oil 2L PET Jar', 'Edible Oils'),
      ('SUN-SFO-5L', 'Sunpure Sunflower Oil 5L PET/HDPE', 'Edible Oils'),
      ('SUN-SFO-10L-BKT', 'Sunpure Sunflower Oil 10L Bucket', 'Edible Oils'),
      ('SUN-SFO-15L-TIN', 'Sunpure Sunflower Oil 15L/15kg Tin', 'Edible Oils'),
      ('SUN-SFO-15L-TAP', 'Sunpure Sunflower Oil 15L Tap Jar', 'Edible Oils'),
      ('SUN-GNO-500ML', 'Sunpure Filtered Groundnut Oil 500ml', 'Edible Oils'),
      ('SUN-GNO-1L', 'Sunpure Filtered Groundnut Oil 1L', 'Edible Oils'),
      ('SUN-GNO-5L', 'Sunpure Filtered Groundnut Oil 5L', 'Edible Oils'),
      ('SUN-GNO-15', 'Sunpure Filtered Groundnut Oil 15kg/15L', 'Edible Oils'),
      ('SUN-MST-200ML-PET', 'Sunpure Kachi Ghani Mustard Oil 200ml PET', 'Edible Oils'),
      ('SUN-MST-500ML-PET', 'Sunpure Kachi Ghani Mustard Oil 500ml PET', 'Edible Oils'),
      ('SUN-MST-1L-PET', 'Sunpure Kachi Ghani Mustard Oil 1L PET', 'Edible Oils'),
      ('SUN-MST-500ML-PCH', 'Sunpure Kachi Ghani Mustard Oil 500ml Pouch', 'Edible Oils'),
      ('SUN-MST-1L-PCH', 'Sunpure Kachi Ghani Mustard Oil 1L Pouch', 'Edible Oils'),
      ('SUN-VAN-50ML', 'Sunpure Vanaspati 50ml', 'Edible Oils'),
      ('SUN-VAN-100ML', 'Sunpure Vanaspati 100ml', 'Edible Oils'),
      ('SUN-VAN-200ML', 'Sunpure Vanaspati 200ml', 'Edible Oils'),
      ('SUN-VAN-500ML', 'Sunpure Vanaspati 500ml', 'Edible Oils'),
      ('SUN-VAN-1L-PCH', 'Sunpure Vanaspati 1L Pouch', 'Edible Oils'),
      ('SUN-VAN-15KG', 'Sunpure Vanaspati 15kg Tin', 'Edible Oils'),
      ('SUN-ATTA-1KG', 'Sunpure Swaad Chakki Atta 1kg', 'Wheat Flour & Atta'),
      ('SUN-ATTA-5KG', 'Sunpure Swaad Chakki Atta 5kg', 'Wheat Flour & Atta'),
      ('SUN-ATTA-10KG', 'Sunpure Swaad Chakki Atta 10kg', 'Wheat Flour & Atta'),
      ('SUN-SUGAR-250G', 'Sunpure Premium Sugar 250g', 'Sugar & Sweeteners'),
      ('SUN-SUGAR-500G', 'Sunpure Premium Sugar 500g', 'Sugar & Sweeteners'),
      ('SUN-SUGAR-1KG', 'Sunpure Premium Sugar 1kg', 'Sugar & Sweeteners'),
      ('SUN-SUGAR-5KG', 'Sunpure Premium Sugar 5kg', 'Sugar & Sweeteners'),
      ('SUN-KHAND-500G', 'Sunpure Khandsari Sugar 500g', 'Sugar & Sweeteners'),
      ('SUN-KHAND-1KG', 'Sunpure Khandsari Sugar 1kg', 'Sugar & Sweeteners'),
      ('SUN-JAGPOW-500G', 'Sunpure Jaggery Powder 500g', 'Jaggery'),
      ('SUN-GULAB-90G', 'Sunpure Gulab Jamun Mix Kesar Badam 90g', 'Desserts & Mixes'),
      ('SUN-GULAB-120G', 'Sunpure Gulab Jamun Mix Kesar Badam 120g', 'Desserts & Mixes')
    ) as rows(sku, product_name, category_name)
  loop
    select id into cat from public.product_categories where name = rec.category_name;
    if cat is null then
      raise exception 'missing category %', rec.category_name;
    end if;
    select products.id into pid from public.products where lower(products.sku) = lower(rec.sku);
    if pid is null then
      pid := public.create_product(rec.sku, rec.product_name, supplier_id, cat);
    else
      perform public.update_product(pid, rec.sku, rec.product_name, supplier_id, cat);
    end if;
  end loop;

  perform public.set_supplier_active(supplier_id, false);

  if (select count(*) from public.stock_ledger) is distinct from ledger_before
    or (select count(*) from public.stock_balances) is distinct from balance_before
    or (select count(*) from public.stock_lots) is distinct from lot_before
    or (select count(*) from public.product_selling_prices) is distinct from price_before
  then
    raise exception 'stock or prices drifted';
  end if;
end;
$$;
