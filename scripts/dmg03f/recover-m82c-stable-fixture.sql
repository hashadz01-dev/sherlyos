-- DMG-03F disposable fixture recovery on supabase_db_sherlyos_m82c ONLY.
-- Replenishes m82c-stable @ m82c_c1 picking capacity after legitimate write-offs
-- via trusted opening (crate-2) + crate transfer. Does NOT delete ledger history,
-- touch owner/cloud DBs, or modify DMG-20261103-000013.

do $$
declare
  v_sysid text;
  v_product uuid;
  v_c1 uuid;
  v_c2 uuid;
  v_admin uuid;
  v_phys integer;
  v_held integer;
  v_avail integer;
  v_need integer := 10; -- free cases target on C1 after recovery
  v_open_qty integer := 20;
  v_lot uuid;
  v_move integer;
  v_payload jsonb;
begin
  select system_identifier::text into v_sysid from pg_control_system();
  if v_sysid = '7699785797738577957' then
    raise exception 'DMG-03F refused owner database';
  end if;
  if v_sysid = '7702023892197691429' then
    raise exception 'DMG-03F refused m81c database';
  end if;
  if v_sysid is distinct from '7702447407569928229' then
    raise exception 'DMG-03F refused unexpected system_identifier %', v_sysid;
  end if;

  select p.id, c1.id, c2.id
  into v_product, v_c1, v_c2
  from public.products p
  cross join public.crates c1
  cross join public.crates c2
  where p.sku = 'm82c-stable'
    and c1.code = 'm82c_c1'
    and c2.code = 'm82c_c2';

  if v_product is null or v_c1 is null or v_c2 is null then
    raise exception 'm82c-stable / m82c_c1 / m82c_c2 missing';
  end if;

  select id into v_admin from auth.users where email = 'admin.m82c@example.test';
  if v_admin is null then
    raise exception 'admin.m82c@example.test missing';
  end if;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_admin, 'role', 'authenticated')::text,
    true
  );
  perform set_config('role', 'authenticated', true);

  -- Opening on C2 is allowed once (idempotent replay via key).
  v_payload := public.post_opening_stock(
    v_product,
    v_c2,
    v_open_qty,
    'dmg03f-open-stable-c2',
    'DMG-03F disposable replenishment opening on Crate-2',
    'TEST-LOT-DMG03F',
    null,
    null
  );

  select id into v_lot
  from public.stock_lots
  where product_id = v_product
    and manufacturer_lot_code = 'TEST-LOT-DMG03F'
  order by created_at desc
  limit 1;

  if v_lot is null then
    raise exception 'TEST-LOT-DMG03F missing after opening';
  end if;

  -- Capacity math uses hold rows (authenticated cannot call app_private helpers).
  select sb.quantity into v_phys
  from public.stock_balances sb
  where sb.product_id = v_product and sb.crate_id = v_c1;

  select coalesce(sum(h.quantity_cases), 0) into v_held
  from public.damage_stock_holds h
  where h.product_id = v_product
    and h.crate_id = v_c1
    and h.status = 'active';

  v_avail := coalesce(v_phys, 0) - coalesce(v_held, 0);
  if v_avail >= v_need then
    raise notice 'DMG-03F skip transfer: C1 avail % already >= %', v_avail, v_need;
    return;
  end if;

  v_move := least(
    v_need - v_avail,
    coalesce((
      select slb.quantity
      from public.stock_lot_balances slb
      where slb.lot_id = v_lot and slb.crate_id = v_c2
    ), 0)
  );

  if v_move < 1 then
    raise exception 'DMG-03F no C2 lot quantity available to transfer (payload %)', v_payload;
  end if;

  -- Fresh idempotency key per deficit so partial prior runs can finish.
  perform public.post_crate_transfer(
    v_product,
    v_c2,
    v_c1,
    v_move,
    'dmg03f-xfer-c2-c1-' || v_move::text || '-' || coalesce(v_phys, 0)::text,
    'DMG-03F disposable transfer replenishing Crate-1 after write-offs',
    jsonb_build_array(
      jsonb_build_object('lot_id', v_lot, 'quantity', v_move)
    )
  );
end $$;

reset role;

select
  'after_recovery' as step,
  c.code as crate,
  sl.manufacturer_lot_code,
  slb.quantity as physical,
  app_private.active_damage_hold_lot_cases(sl.id, c.id) as held,
  app_private.picking_available_cases(sl.id, c.id) as available
from public.stock_lot_balances slb
join public.stock_lots sl on sl.id = slb.lot_id
join public.products p on p.id = sl.product_id
join public.crates c on c.id = slb.crate_id
where p.sku = 'm82c-stable'
order by c.code, sl.manufacturer_lot_code;

select
  'c1_aggregate' as step,
  sb.quantity as physical,
  (
    select sum(slb.quantity)::int
    from public.stock_lot_balances slb
    join public.stock_lots sl on sl.id = slb.lot_id
    where sl.product_id = sb.product_id and slb.crate_id = sb.crate_id
  ) as lot_sum
from public.stock_balances sb
join public.products p on p.id = sb.product_id
join public.crates c on c.id = sb.crate_id
where p.sku = 'm82c-stable' and c.code = 'm82c_c1';
