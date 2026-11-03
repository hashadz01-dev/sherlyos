-- DMG-03C disposable cutover on supabase_db_sherlyos_m82c only.
-- Does not touch owner DB or cloud. aggregate_only_blocked left unchanged.

-- 1) Reconciliation
with agg as (
  select crate_id, product_id, quantity as agg_qty
  from public.stock_balances where quantity <> 0
),
lots as (
  select slb.crate_id, sl.product_id, sum(slb.quantity)::integer as lot_qty
  from public.stock_lot_balances slb
  join public.stock_lots sl on sl.id = slb.lot_id
  group by slb.crate_id, sl.product_id
)
select
  'reconcile' as step,
  count(*) filter (where coalesce(lots.lot_qty, 0) is distinct from agg.agg_qty) as mismatched,
  coalesce(sum(agg.agg_qty), 0) as agg_cases,
  coalesce(sum(coalesce(lots.lot_qty, 0)), 0) as lot_cases
from agg
left join lots on lots.crate_id = agg.crate_id and lots.product_id = agg.product_id;

-- 2) Fixture grain (m82c-stable @ 17)
select
  'fixture' as step,
  p.sku,
  c.code as crate,
  b.code as godown,
  sb.quantity as physical
from public.stock_balances sb
join public.products p on p.id = sb.product_id
join public.crates c on c.id = sb.crate_id
join public.zones z on z.id = c.zone_id
join public.branches b on b.id = z.branch_id
where p.sku = 'm82c-stable';

-- 3) Enable hold-ready only (dual-write already true on this stack)
update public.app_configuration
set value = 'true'::jsonb
where key = 'damage.stock_hold_ready'
  and value is distinct from 'true'::jsonb;

select key, value #>> '{}' as val
from public.app_configuration
where key in (
  'damage.stock_hold_ready',
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked'
)
order by 1;

-- 4) Readiness RPC as Store Keeper
select set_config(
  'request.jwt.claim.sub',
  (select id::text from auth.users where email = 'keeper.m82c@example.test'),
  true
);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select id from auth.users where email = 'keeper.m82c@example.test'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;
select public.damage_stock_hold_ready_status();
reset role;
