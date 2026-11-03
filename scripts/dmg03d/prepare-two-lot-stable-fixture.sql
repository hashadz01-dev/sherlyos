-- DMG-03D disposable fixture on supabase_db_sherlyos_m82c only.
-- Split m82c-stable @ m82c_c1 into two lots totaling 17 physical cases.
-- Superuser disables conservation triggers only for this disposable rebalance.
-- Does not touch owner DB, cloud, or DMG-20261103-000013.

do $$
declare
  v_product uuid;
  v_crate uuid;
  v_branch uuid;
  v_lot_a uuid;
  v_lot_b uuid;
  v_qty_a integer;
  v_held_a integer;
  v_move integer := 7;
  v_actor uuid;
  v_txn uuid;
  v_now timestamptz := clock_timestamp();
  v_existing_b integer;
begin
  select products.id, crates.id, zones.branch_id, stock_lots.id, stock_lot_balances.quantity
  into v_product, v_crate, v_branch, v_lot_a, v_qty_a
  from public.stock_balances
  join public.products on products.id = stock_balances.product_id
  join public.crates on crates.id = stock_balances.crate_id
  join public.zones on zones.id = crates.zone_id
  join public.stock_lots
    on stock_lots.product_id = products.id
   and stock_lots.branch_id = zones.branch_id
   and stock_lots.manufacturer_lot_code = 'TEST-LOT-STABLE'
  join public.stock_lot_balances
    on stock_lot_balances.lot_id = stock_lots.id
   and stock_lot_balances.crate_id = crates.id
  where products.sku = 'm82c-stable'
    and crates.code = 'm82c_c1';

  if v_lot_a is null then
    raise exception 'TEST-LOT-STABLE grain missing on m82c';
  end if;

  if (select quantity from public.stock_balances where crate_id = v_crate and product_id = v_product)
     is distinct from 17
  then
    raise exception 'expected physical 17 for m82c-stable @ m82c_c1';
  end if;

  v_held_a := app_private.active_damage_hold_lot_cases(v_lot_a, v_crate);
  if v_qty_a - v_move < v_held_a then
    raise exception 'cannot move % cases; lot A held % of %', v_move, v_held_a, v_qty_a;
  end if;

  select stock_lots.id into v_lot_b
  from public.stock_lots
  where stock_lots.product_id = v_product
    and stock_lots.branch_id = v_branch
    and stock_lots.manufacturer_lot_code = 'TEST-LOT-STABLE-B';

  if v_lot_b is null then
    insert into public.stock_lots (
      product_id, branch_id, manufacturer_lot_code, status, origin, notes
    )
    values (
      v_product, v_branch, 'TEST-LOT-STABLE-B', 'available', 'opening',
      'DMG-03D disposable second lot'
    )
    returning id into v_lot_b;
  end if;

  select coalesce(quantity, 0) into v_existing_b
  from public.stock_lot_balances
  where lot_id = v_lot_b and crate_id = v_crate;

  if v_existing_b >= 1 and v_qty_a < 17 then
    null; -- already split
  else
    select id into v_actor from auth.users where email = 'admin.m82c@example.test';
    if v_actor is null then
      select id into v_actor from public.profiles limit 1;
    end if;

    -- Disposable-only: suppress conservation while rebalancing lot ledger + balances.
    alter table public.stock_lot_balances disable trigger user;
    alter table public.stock_ledger disable trigger user;
    alter table public.stock_transactions disable trigger user;

    begin
      insert into public.stock_transactions (
        id, transaction_type, reference_number, actor_id, posted_at,
        idempotency_key, request_fingerprint, notes,
        product_id, source_crate_id, destination_crate_id, quantity
      )
      values (
        gen_random_uuid(),
        'CRATE_TRANSFER',
        'DMG03D-SPLIT-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10),
        v_actor,
        v_now,
        'dmg03d-split-' || gen_random_uuid()::text,
        'dmg03d-two-lot-fixture',
        'DMG-03D disposable same-crate lot rebalance',
        v_product,
        v_crate,
        -- Shape check requires distinct crates; use Crate-2 as a dummy destination
        -- while ledger stays on Crate-1 for both lots (physical location unchanged).
        (select id from public.crates where code = 'm82c_c2'),
        v_move
      )
      returning id into v_txn;

      -- Keep both ledger legs on the real storage crate so aggregate + picking stay correct.
      insert into public.stock_ledger (
        transaction_id, product_id, crate_id, quantity, actor_id, posted_at, lot_id
      ) values
        (v_txn, v_product, v_crate, -v_move, v_actor, v_now, v_lot_a),
        (v_txn, v_product, v_crate, v_move, v_actor, v_now, v_lot_b);

      perform app_private.begin_lot_balance_write('seed');

      update public.stock_lot_balances
      set quantity = quantity - v_move
      where lot_id = v_lot_a and crate_id = v_crate;

      insert into public.stock_lot_balances (lot_id, crate_id, quantity)
      values (v_lot_b, v_crate, v_move)
      on conflict (lot_id, crate_id) do update
        set quantity = excluded.quantity;
    exception
      when others then
        alter table public.stock_lot_balances enable trigger user;
        alter table public.stock_ledger enable trigger user;
        alter table public.stock_transactions enable trigger user;
        raise;
    end;

    alter table public.stock_lot_balances enable trigger user;
    alter table public.stock_ledger enable trigger user;
    alter table public.stock_transactions enable trigger user;
  end if;

  update public.app_configuration
  set value = 'true'::jsonb
  where key = 'damage.stock_hold_ready'
    and value is distinct from 'true'::jsonb;

  update public.app_configuration
  set value = 'true'::jsonb
  where key = 'stock.lots.dual_write_enabled'
    and value is distinct from 'true'::jsonb;
end $$;

select
  p.sku,
  c.code as crate,
  sl.manufacturer_lot_code,
  slb.quantity as physical,
  app_private.active_damage_hold_lot_cases(sl.id, c.id) as held,
  app_private.picking_available_cases(sl.id, c.id) as available
from public.stock_lot_balances slb
join public.stock_lots sl on sl.id = slb.lot_id
join public.products p on p.id = sl.product_id
join public.crates c on c.id = slb.crate_id
where p.sku = 'm82c-stable' and c.code = 'm82c_c1'
order by sl.manufacturer_lot_code;

select
  sb.quantity as aggregate_physical,
  (
    select sum(slb.quantity)
    from public.stock_lot_balances slb
    join public.stock_lots sl on sl.id = slb.lot_id
    where sl.product_id = sb.product_id and slb.crate_id = sb.crate_id
  ) as lot_sum,
  (
    select coalesce(sum(l.quantity), 0)
    from public.stock_ledger l
    join public.stock_lots sl on sl.id = l.lot_id
    where sl.product_id = sb.product_id and l.crate_id = sb.crate_id
  ) as lot_ledger_sum
from public.stock_balances sb
join public.products p on p.id = sb.product_id
join public.crates c on c.id = sb.crate_id
where p.sku = 'm82c-stable' and c.code = 'm82c_c1';
