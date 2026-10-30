-- M7.7 authorized development-cloud master import. Not a schema migration.
-- Calls create_product_category, create_supplier, set_supplier_active,
-- create_product, set_product_billing_conversion. Rolls back on flag or stock drift.
do $$
declare
  admin_id uuid := 'cdc087c0-0295-425d-8dbe-9a91030bf012';
  ledger_before bigint;
  balance_before bigint;
  lot_before bigint;
  price_before bigint;
  note_before bigint;
  flag_before integer;
  cat_tea uuid;
  cat_coffee uuid;
  cat_edible_oils uuid;
  cat_rice uuid;
  cat_sugar uuid;
  cat_jaggery uuid;
  cat_dairy uuid;
  cat_ghee uuid;
  cat_whitener uuid;
  cat_coconut uuid;
  cat_spices uuid;
  cat_atta uuid;
  cat_desserts uuid;
  product_id uuid;
  supplier_id uuid;
begin
  select count(*) into ledger_before from public.stock_ledger;
  select count(*) into balance_before from public.stock_balances;
  select count(*) into lot_before from public.stock_lots;
  select count(*) into price_before from public.product_selling_prices;
  select count(*) into note_before from public.invoice_notes;
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

  cat_tea := public.create_product_category('Tea & Tea Bags', 'Catalogue code TEA.');
  cat_coffee := public.create_product_category('Coffee', 'Catalogue code COFFEE.');
  cat_edible_oils := public.create_product_category('Edible Oils', 'Catalogue code EDIBLE_OILS.');
  cat_rice := public.create_product_category('Rice & Grains', 'Catalogue code RICE.');
  cat_sugar := public.create_product_category('Sugar & Sweeteners', 'Catalogue code SUGAR.');
  cat_jaggery := public.create_product_category('Jaggery', 'Catalogue code JAGGERY.');
  cat_dairy := public.create_product_category('Dairy & Milk Products', 'Catalogue code DAIRY.');
  cat_ghee := public.create_product_category('Ghee', 'Catalogue code GHEE.');
  cat_whitener := public.create_product_category('Dairy Whitener', 'Catalogue code WHITENER.');
  cat_coconut := public.create_product_category('Coconut Products', 'Catalogue code COCONUT.');
  cat_spices := public.create_product_category('Spices & Masalas', 'Catalogue code SPICES.');
  cat_atta := public.create_product_category('Wheat Flour & Atta', 'Catalogue code ATTA.');
  cat_desserts := public.create_product_category('Desserts & Mixes', 'Catalogue code DESSERTS.');

  supplier_id := public.create_supplier('AVT (pending invoicing confirmation)', null, null);
  perform public.set_supplier_active(supplier_id, false);
  supplier_id := public.create_supplier('Kera (pending invoicing confirmation)', null, null);
  perform public.set_supplier_active(supplier_id, false);
  supplier_id := public.create_supplier('MK Agrotech Pvt Ltd (manufacturer; invoicing pending)', null, null);
  perform public.set_supplier_active(supplier_id, false);
  supplier_id := public.create_supplier('Parry''s (pending invoicing confirmation)', null, null);
  perform public.set_supplier_active(supplier_id, false);
  supplier_id := public.create_supplier('Nandini (pending invoicing confirmation)', null, null);
  perform public.set_supplier_active(supplier_id, false);
  supplier_id := public.create_supplier('MattaNaad (pending invoicing confirmation)', null, null);
  perform public.set_supplier_active(supplier_id, false);

  product_id := public.create_product('AVT-PREM-DUST-100G', 'AVT Premium Tea Dust 100g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 240);
  product_id := public.create_product('AVT-PREM-DUST-250G', 'AVT Premium Tea Dust 250g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 96);
  product_id := public.create_product('AVT-PREM-DUST-500G', 'AVT Premium Tea Dust 500g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 48);
  product_id := public.create_product('AVT-PREM-DUST-1KG', 'AVT Premium Tea Dust 1kg', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 24);
  product_id := public.create_product('AVT-PREM-JAR-100G', 'AVT Premium Tea Jar 100g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 120);
  product_id := public.create_product('AVT-PREM-JAR-250G', 'AVT Premium Tea Jar 250g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 48);
  product_id := public.create_product('AVT-PREM-JAR-500G', 'AVT Premium Tea Jar 500g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 24);
  product_id := public.create_product('AVT-CATER-BLEND-1KG', 'AVT Catering Blend 1kg', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 24);
  product_id := public.create_product('AVT-PREM-LEAF-100G', 'AVT Premium Leaf 100g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 120);
  product_id := public.create_product('AVT-PREM-LEAF-250G', 'AVT Premium Leaf 250g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 48);
  product_id := public.create_product('AVT-PREM-SEL-100G', 'AVT Premium Select 100g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 120);
  product_id := public.create_product('AVT-PREM-SEL-250G', 'AVT Premium Select 250g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 48);
  product_id := public.create_product('AVT-RAJA-DUST-250G', 'AVT Raja Tea Dust 250g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 96);
  product_id := public.create_product('AVT-RAJA-DUST-1KG', 'AVT Raja Tea Dust 1kg', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 24);
  product_id := public.create_product('AVT-SUPR-DUST-100G', 'AVT Supreme Tea Dust 100g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 240);
  product_id := public.create_product('AVT-SUPR-DUST-250G', 'AVT Supreme Tea Dust 250g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 96);
  product_id := public.create_product('AVT-SUPR-DUST-500G', 'AVT Supreme Tea Dust 500g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 48);
  product_id := public.create_product('AVT-SUPR-DUST-1KG', 'AVT Supreme Tea Dust 1kg', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 24);
  product_id := public.create_product('AVT-COFFEE-50G', 'AVT Coffee Powder 50g', null, cat_coffee);
  perform public.set_product_billing_conversion(product_id, 'nos', 320);
  product_id := public.create_product('AVT-COFFEE-100G', 'AVT Coffee Powder 100g', null, cat_coffee);
  perform public.set_product_billing_conversion(product_id, 'nos', 120);
  product_id := public.create_product('AVT-COFFEE-200G', 'AVT Coffee Powder 200g', null, cat_coffee);
  perform public.set_product_billing_conversion(product_id, 'nos', 60);
  product_id := public.create_product('AVT-COFFEE-500G', 'AVT Coffee Powder 500g', null, cat_coffee);
  perform public.set_product_billing_conversion(product_id, 'nos', 24);
  product_id := public.create_product('AVT-TEABAG-25', 'AVT Tea Bags 25', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'box', 36);
  product_id := public.create_product('AVT-TEABAG-100', 'AVT Tea Bags 100', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'box', 18);
  product_id := public.create_product('AVT-GOLD-100G', 'AVT Gold Cup 100g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 120);
  product_id := public.create_product('AVT-GOLD-250G', 'AVT Gold Cup 250g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 48);
  product_id := public.create_product('AVT-GOLD-500G', 'AVT Gold Cup 500g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 24);
  product_id := public.create_product('AVT-GTEA-LEAF-100G', 'AVT Green Tea Leaf 100g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 30);
  product_id := public.create_product('AVT-GTEA-LEAF-250G', 'AVT Green Tea Leaf 250g', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'nos', 48);
  product_id := public.create_product('AVT-GTEA-BAG-10', 'AVT Green Tea Bags 10', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'box', 24);
  product_id := public.create_product('AVT-GTEA-BAG-30', 'AVT Green Tea Bags 30', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'box', 30);
  product_id := public.create_product('AVT-GTEA-BAG-100', 'AVT Green Tea Bags 100', null, cat_tea);
  perform public.set_product_billing_conversion(product_id, 'box', 12);
  product_id := public.create_product('AVT-GHEE-50ML', 'AVT Ghee 50ml', null, cat_ghee);
  perform public.set_product_billing_conversion(product_id, 'nos', 72);
  product_id := public.create_product('AVT-GHEE-100ML', 'AVT Ghee 100ml', null, cat_ghee);
  perform public.set_product_billing_conversion(product_id, 'nos', 120);
  product_id := public.create_product('AVT-GHEE-200ML', 'AVT Ghee 200ml', null, cat_ghee);
  perform public.set_product_billing_conversion(product_id, 'nos', 72);
  product_id := public.create_product('AVT-GHEE-500ML', 'AVT Ghee 500ml', null, cat_ghee);
  perform public.set_product_billing_conversion(product_id, 'nos', 36);
  product_id := public.create_product('AVT-WHITENER-10G', 'AVT Dairy Whitener 10g', null, cat_whitener);
  perform public.set_product_billing_conversion(product_id, 'nos', 38);
  product_id := public.create_product('AVT-WHITENER-200G', 'AVT Dairy Whitener 200g', null, cat_whitener);
  perform public.set_product_billing_conversion(product_id, 'nos', 45);
  product_id := public.create_product('AVT-WHITENER-400G', 'AVT Dairy Whitener 400g', null, cat_whitener);
  perform public.set_product_billing_conversion(product_id, 'nos', 24);
  product_id := public.create_product('DSURE-MS-STRW-200ML', 'Dairy Sure Milkshake Strawberry 200ml', null, cat_dairy);
  perform public.set_product_billing_conversion(product_id, 'nos', 27);
  product_id := public.create_product('DSURE-MS-VAN-200ML', 'Dairy Sure Milkshake Vanilla 200ml', null, cat_dairy);
  perform public.set_product_billing_conversion(product_id, 'nos', 27);
  product_id := public.create_product('DSURE-MS-CHOC-200ML', 'Dairy Sure Milkshake Chocolate 200ml', null, cat_dairy);
  perform public.set_product_billing_conversion(product_id, 'nos', 27);
  product_id := public.create_product('DSURE-MS-BTRSC-200ML', 'Dairy Sure Milkshake Butterscotch 200ml', null, cat_dairy);
  perform public.set_product_billing_conversion(product_id, 'nos', 27);
  product_id := public.create_product('KERA-COIL-500ML-PCH', 'Kera Coconut Oil 500ml Pouch', null, cat_edible_oils);
  perform public.set_product_billing_conversion(product_id, 'nos', 40);
  product_id := public.create_product('KERA-COIL-1L-PCH', 'Kera Coconut Oil 1L Pouch', null, cat_edible_oils);
  perform public.set_product_billing_conversion(product_id, 'nos', 20);
  product_id := public.create_product('KERA-DESS-100G', 'Kera Desiccated Coconut Powder 100g', null, cat_coconut);
  perform public.set_product_billing_conversion(product_id, 'nos', 48);
  product_id := public.create_product('KERA-CMPOW-100G', 'Kera Coconut Milk Powder 100g', null, cat_coconut);
  perform public.set_product_billing_conversion(product_id, 'nos', 48);
  product_id := public.create_product('PARRY-WHITE-500G', 'Parry''s White Label Sugar 500g', null, cat_sugar);
  perform public.set_product_billing_conversion(product_id, 'nos', 40);
  product_id := public.create_product('PARRY-WHITE-1KG', 'Parry''s White Label Sugar 1kg', null, cat_sugar);
  perform public.set_product_billing_conversion(product_id, 'nos', 20);
  product_id := public.create_product('PARRY-WHITE-5KG', 'Parry''s White Label Sugar 5kg', null, cat_sugar);
  perform public.set_product_billing_conversion(product_id, 'nos', 6);
  product_id := public.create_product('PARRY-REF-1KG', 'Parry''s Pure Refined Sugar 1kg', null, cat_sugar);
  perform public.set_product_billing_conversion(product_id, 'nos', 20);
  product_id := public.create_product('PARRY-REF-1KG-JAR', 'Parry''s Pure Refined Sugar 1kg Jar', null, cat_sugar);
  perform public.set_product_billing_conversion(product_id, 'nos', 12);
  product_id := public.create_product('PARRY-REF-5KG', 'Parry''s Pure Refined Sugar 5kg', null, cat_sugar);
  perform public.set_product_billing_conversion(product_id, 'nos', 6);
  product_id := public.create_product('PARRY-CUBE-500G', 'Parry''s Pure Refined Sugar Cubes 500g', null, cat_sugar);
  perform public.set_product_billing_conversion(product_id, 'nos', 24);
  product_id := public.create_product('PARRY-AMRIT-500G', 'Parry''s Amrit Sugar 500g', null, cat_sugar);
  perform public.set_product_billing_conversion(product_id, 'nos', 40);
  product_id := public.create_product('PARRY-AMRIT-750G-JR', 'Parry''s Amrit Sugar 750g Jar', null, cat_sugar);
  perform public.set_product_billing_conversion(product_id, 'nos', 12);
  product_id := public.create_product('PARRY-JAG-500G', 'Parry''s Amrit Jaggery 500g', null, cat_jaggery);
  perform public.set_product_billing_conversion(product_id, 'nos', 24);
  product_id := public.create_product('GOODLIFE-MILK-180ML', 'GoodLife Milk 180ml', null, cat_dairy);
  perform public.set_product_billing_conversion(product_id, 'nos', 36);
  product_id := public.create_product('GOODLIFE-MILK-500ML', 'GoodLife Milk 500ml', null, cat_dairy);
  perform public.set_product_billing_conversion(product_id, 'nos', 24);
  product_id := public.create_product('GOODLIFE-MILK-1L', 'GoodLife Milk 1L', null, cat_dairy);
  perform public.set_product_billing_conversion(product_id, 'nos', 12);
  product_id := public.create_product('GOODLIFE-SLIM-500ML', 'GoodLife Slim Milk 500ml', null, cat_dairy);
  perform public.set_product_billing_conversion(product_id, 'nos', 24);
  product_id := public.create_product('GOODLIFE-SLIM-1L', 'GoodLife Slim Milk 1L', null, cat_dairy);
  perform public.set_product_billing_conversion(product_id, 'nos', 12);
  product_id := public.create_product('GOODLIFE-GOLD-1L', 'GoodLife Gold Milk 1L', null, cat_dairy);
  perform public.set_product_billing_conversion(product_id, 'nos', 12);
  product_id := public.create_product('GOODLIFE-CREAM-500ML', 'GoodLife Fresh Cream 500ml', null, cat_dairy);
  perform public.set_product_billing_conversion(product_id, 'nos', 24);
  product_id := public.create_product('GOODLIFE-CREAM-1L', 'GoodLife Fresh Cream 1L', null, cat_dairy);
  perform public.set_product_billing_conversion(product_id, 'nos', 12);
  product_id := public.create_product('SUN-SFO-500ML-PCH', 'Sunpure Sunflower Oil 500ml Pouch', null, cat_edible_oils);
  perform public.set_product_billing_conversion(product_id, 'nos', 20);
  product_id := public.create_product('SUN-SFO-1L-PCH', 'Sunpure Sunflower Oil 1L Pouch', null, cat_edible_oils);
  perform public.set_product_billing_conversion(product_id, 'nos', 10);

  if (select count(*) from public.stock_ledger) is distinct from ledger_before
    or (select count(*) from public.stock_balances) is distinct from balance_before
    or (select count(*) from public.stock_lots) is distinct from lot_before
    or (select count(*) from public.product_selling_prices) is distinct from price_before
    or (select count(*) from public.invoice_notes) is distinct from note_before
  then
    raise exception 'master import changed stock, lots, prices, or invoice notes';
  end if;
  if exists (
    select 1 from public.app_configuration
    where key in ('damage.stock_hold_ready','stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked')
      and value = 'true'::jsonb
  ) then
    raise exception 'operational flags changed';
  end if;
end;
$$;
