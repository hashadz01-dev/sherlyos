import { spawnSync } from "node:child_process"

/**
 * Prefixes used by local SQL/HTTP/Playwright fixtures. Never matches
 * operational SKUs. Cleanup and unmatched-seed allowlists share this list.
 */
export const DISPOSABLE_SKU_PATTERNS = [
  "m1s2qa-%",
  "m1s2c%",
  "m1s3c%",
  "m1s3qa%",
  "m2e2e_%",
  "m2pk%",
  "m3e2e_%",
  "m3qa%",
  "m3c_%",
  "m3ds%",
  "m4e2e_%",
  "m41ig_%",
  "m41c_%",
  "m52%",
  "m53%",
  "m54%",
  "m55%",
  "m62%",
  "m63%",
  "m64%",
  "m65%",
  "m66%",
  "m14e2e%",
  "m72%",
  "m73%",
] as const

export function runLocalSql(sql: string, label: string) {
  const result = spawnSync(
    "docker",
    [
      "exec",
      "-i",
      "supabase_db_sherlyos",
      "psql",
      "-U",
      "postgres",
      "-d",
      "postgres",
      "-v",
      "ON_ERROR_STOP=1",
      "-tA",
    ],
    { input: sql, encoding: "utf8" },
  )
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || `${label} failed`)
  }
  return result.stdout.trim()
}

export function disposableSkuSql(alias: string) {
  return DISPOSABLE_SKU_PATTERNS.map(
    (pattern) => `${alias}.sku like '${pattern}'`,
  ).join("\n          or ")
}

/** Unmatched-seed refuse clause: leftover disposable SKUs are allowed. */
export function disposableSkuExcludeSql(alias: string) {
  return DISPOSABLE_SKU_PATTERNS.map(
    (pattern) => `${alias}.sku not like '${pattern}'`,
  ).join("\n          and ")
}

function skuFamilySql(alias: string, patterns: readonly string[]) {
  return patterns
    .map((pattern) => `${alias}.sku like '${pattern}'`)
    .join("\n          or ")
}

/**
 * Prefix-scoped interference cleanup.
 *
 * Removes leftover disposable stock that breaks later suites:
 * unmatched aggregate/lot grains, and disposable balances on inactive
 * branches or crates (seed_legacy cannot write those locations).
 *
 * Matched stock on active test godowns is left in place. Does not delete
 * operational products, branches, or non-test SKUs. Restores cutover and
 * damage readiness flags to false.
 */
export function cleanupDisposableTestStock(
  label = "disposable test stock cleanup",
  options?: { skuPatterns?: readonly string[] },
) {
  const skuPred = skuFamilySql("p", options?.skuPatterns ?? DISPOSABLE_SKU_PATTERNS)
  runLocalSql(
    `
    set session_replication_role = replica;
    select set_config('app.picking_write', 'on', true);
    -- Released disposable reservations still FK to lots and block later wipes.
    delete from public.stock_picking_exceptions
    where reservation_id in (
      select r.id
      from public.stock_reservations r
      join public.products p on p.id = r.product_id
      where ${skuPred}
    )
      or picking_request_id in (
        select spr.id
        from public.stock_picking_requests spr
        join public.orders o on o.id = spr.order_id
        join public.order_lines ol on ol.order_id = o.id
        join public.products p on p.id = ol.product_id
        where ${skuPred}
      );
    delete from public.stock_reservations r
    using public.products p
    where p.id = r.product_id
      and (${skuPred});
    with disposable as (
      select p.id as product_id
      from public.products p
      where ${skuPred}
    ),
    leftover as (
      select sb.crate_id, sb.product_id
      from public.stock_balances sb
      join disposable d on d.product_id = sb.product_id
      join public.crates c on c.id = sb.crate_id
      join public.zones z on z.id = c.zone_id
      join public.branches b on b.id = z.branch_id
      where sb.quantity > 0
        and (
          b.is_active is not true
          or c.is_active is not true
          or z.is_active is not true
          or sb.quantity is distinct from coalesce((
            select sum(lb.quantity)
            from public.stock_lot_balances lb
            join public.stock_lots l on l.id = lb.lot_id
            where lb.crate_id = sb.crate_id
              and l.product_id = sb.product_id
          ), 0)
        )
    )
    delete from public.stock_ledger sl
    using leftover
    where sl.product_id = leftover.product_id
      and sl.crate_id = leftover.crate_id;

    with disposable as (
      select p.id as product_id
      from public.products p
      where ${skuPred}
    ),
    leftover as (
      select sb.crate_id, sb.product_id
      from public.stock_balances sb
      join disposable d on d.product_id = sb.product_id
      join public.crates c on c.id = sb.crate_id
      join public.zones z on z.id = c.zone_id
      join public.branches b on b.id = z.branch_id
      where sb.quantity > 0
        and (
          b.is_active is not true
          or c.is_active is not true
          or z.is_active is not true
          or sb.quantity is distinct from coalesce((
            select sum(lb.quantity)
            from public.stock_lot_balances lb
            join public.stock_lots l on l.id = lb.lot_id
            where lb.crate_id = sb.crate_id
              and l.product_id = sb.product_id
          ), 0)
        )
    )
    delete from public.stock_lot_balances lb
    using leftover, public.stock_lots l
    where lb.lot_id = l.id
      and l.product_id = leftover.product_id
      and lb.crate_id = leftover.crate_id;

    with disposable as (
      select p.id as product_id
      from public.products p
      where ${skuPred}
    )
    delete from public.stock_lots l
    using disposable
    where l.product_id = disposable.product_id
      and not exists (
        select 1 from public.stock_lot_balances lb where lb.lot_id = l.id
      );

    with disposable as (
      select p.id as product_id
      from public.products p
      where ${skuPred}
    ),
    leftover as (
      select sb.crate_id, sb.product_id
      from public.stock_balances sb
      join disposable d on d.product_id = sb.product_id
      join public.crates c on c.id = sb.crate_id
      join public.zones z on z.id = c.zone_id
      join public.branches b on b.id = z.branch_id
      where sb.quantity > 0
        and (
          b.is_active is not true
          or c.is_active is not true
          or z.is_active is not true
          or sb.quantity is distinct from coalesce((
            select sum(lb.quantity)
            from public.stock_lot_balances lb
            join public.stock_lots l on l.id = lb.lot_id
            where lb.crate_id = sb.crate_id
              and l.product_id = sb.product_id
          ), 0)
        )
    )
    delete from public.stock_balances sb
    using leftover
    where sb.crate_id = leftover.crate_id
      and sb.product_id = leftover.product_id;

    update public.app_configuration
    set value = 'false'::jsonb
    where key in (
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked',
      'damage.stock_hold_ready'
    );
    set session_replication_role = origin;
    `,
    label,
  )
}

/**
 * Full prefix-family stock wipe. Use from the suite that owns the family
 * (reports e2e owns m4e2e_%). Does not delete products or branches.
 */
export function wipeDisposableSkuStock(
  skuPatterns: readonly string[],
  label = "disposable sku stock wipe",
) {
  const skuPred = skuFamilySql("p", skuPatterns)
  runLocalSql(
    `
    set session_replication_role = replica;
    delete from public.stock_ledger
    where product_id in (select p.id from public.products p where ${skuPred});
    delete from public.stock_lot_balances
    where lot_id in (
      select l.id from public.stock_lots l
      join public.products p on p.id = l.product_id
      where ${skuPred}
    );
    delete from public.stock_lots
    where product_id in (select p.id from public.products p where ${skuPred});
    delete from public.stock_balances
    where product_id in (select p.id from public.products p where ${skuPred});
    delete from public.stock_transactions
    where product_id in (select p.id from public.products p where ${skuPred});
    update public.app_configuration
    set value = 'false'::jsonb
    where key in (
      'stock.lots.dual_write_enabled',
      'stock.lots.aggregate_only_blocked',
      'damage.stock_hold_ready'
    );
    set session_replication_role = origin;
    `,
    label,
  )
}
