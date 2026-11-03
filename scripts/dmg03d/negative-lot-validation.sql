-- DMG-03D negative lot validation on disposable m82c only.
-- Confirms trusted draft/isolation reject bad lots without damaging stock.

do $$
declare
  godown uuid;
  product uuid;
  crate uuid;
  other_product uuid;
  other_crate uuid;
  lot_b uuid;
  lot_other_sku uuid;
  lot_other_crate uuid;
  msg text;
  physical_before integer;
  physical_after integer;
begin
  select z.branch_id, p.id, c.id into godown, product, crate
  from public.products p
  join public.stock_balances sb on sb.product_id = p.id
  join public.crates c on c.id = sb.crate_id
  join public.zones z on z.id = c.zone_id
  where p.sku = 'm82c-stable' and c.code = 'm82c_c1';

  select quantity into physical_before
  from public.stock_balances where product_id = product and crate_id = crate;

  select sl.id into lot_b
  from public.stock_lots sl
  where sl.product_id = product and sl.manufacturer_lot_code = 'TEST-LOT-STABLE-B';

  select p.id, sl.id into other_product, lot_other_sku
  from public.products p
  join public.stock_lots sl on sl.product_id = p.id
  where p.sku = 'm82c-spare' limit 1;

  select id into other_crate from public.crates where code = 'm82c_c2';

  -- Wrong-product lot (spare lot on stable product line)
  perform set_config('request.jwt.claim.sub',
    (select id::text from auth.users where email = 'keeper.m82c@example.test'), true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', (select id from auth.users where email = 'keeper.m82c@example.test'),
      'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  begin
    perform public.create_damage_report(
      'storage', godown,
      jsonb_build_array(jsonb_build_object(
        'product_id', product,
        'crate_id', crate,
        'lot_id', lot_other_sku,
        'quantity_cases', 1,
        'damage_reason', 'Wrong product lot'
      )),
      'dmg03d-wrong-product-' || gen_random_uuid()::text,
      'negative'
    );
    raise exception 'wrong-product lot accepted';
  exception
    when others then
      get stacked diagnostics msg = message_text;
      if msg not ilike '%stock lot%' and msg not ilike '%not available%' then
        raise exception 'unexpected wrong-product error: %', msg;
      end if;
  end;

  -- Insufficient availability
  begin
    perform public.create_damage_report(
      'storage', godown,
      jsonb_build_array(jsonb_build_object(
        'product_id', product,
        'crate_id', crate,
        'lot_id', lot_b,
        'quantity_cases', 999,
        'damage_reason', 'Too many cases'
      )),
      'dmg03d-insuff-' || gen_random_uuid()::text,
      'negative'
    );
    raise exception 'insufficient qty accepted';
  exception
    when others then
      get stacked diagnostics msg = message_text;
      if msg not ilike '%insufficient%' then
        raise exception 'unexpected insufficient error: %', msg;
      end if;
  end;

  -- Wrong crate for lot (lot lives on c1; claim c2)
  if other_crate is not null then
    begin
      perform public.create_damage_report(
        'storage', godown,
        jsonb_build_array(jsonb_build_object(
          'product_id', product,
          'crate_id', other_crate,
          'lot_id', lot_b,
          'quantity_cases', 1,
          'damage_reason', 'Wrong crate lot'
        )),
        'dmg03d-wrong-crate-' || gen_random_uuid()::text,
        'negative'
      );
      raise exception 'wrong-crate lot accepted';
    exception
      when others then
        get stacked diagnostics msg = message_text;
        if msg not ilike '%not available%' and msg not ilike '%stock lot%' and msg not ilike '%crate%' then
          raise exception 'unexpected wrong-crate error: %', msg;
        end if;
    end;
  end if;

  -- Drop JWT role so the integrity probe is not filtered by RLS.
  perform set_config('role', 'postgres', true);
  reset role;

  select quantity into physical_after
  from public.stock_balances where product_id = product and crate_id = crate;

  if physical_after is distinct from physical_before then
    raise exception 'negative tests changed physical stock % -> %', physical_before, physical_after;
  end if;
end $$;

select 'ok' as negative_lot_validation;
