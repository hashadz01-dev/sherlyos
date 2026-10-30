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
  // M7.4A HTTP/SQL/concurrency leftovers (covers m74a- and m74ac_ families).
  "m74a%",
  // M7.4B HTTP/SQL/concurrency leftovers (covers m74b-, m74bc_, m74bh_).
  "m74b%",
  // M7.4C search-fixture leftovers (covers m74c-pg- and zzz-m74c-*).
  "m74c%",
  "zzz-m74c%",
  // M7.5B pricing / invoice-note fixtures.
  "m75b%",
  // M7.5C statutory / GST preview HTTP leftovers.
  "m75c%",
  // M7.5D handover / PDF HTTP leftovers.
  "m75d%",
  // M7.5E credit-adjustment HTTP/concurrency leftovers.
  "m75e%",
  // M7.5F commercial-workflow HTTP leftovers.
  "m75f%",
  // M7.6 readiness SQL/HTTP leftovers.
  "m76%",
  // phase_3_3 concurrency leftover (Phase 33 Race Soap). Test SKU only.
  "p33-race%",
  // M8.1C isolated full-stack fixtures.
  "m81c%",
  // M8.2C isolated Branch-1 UAT fixtures. Never matches operational SKUs.
  "m82c%",
] as const

const OWNER_PSQL_CONTAINER = "supabase_db_sherlyos"

/**
 * Isolated M8.1C runs must set SHERLYOS_PSQL_CONTAINER to the disposable
 * stack. Default remains the owner local container for historical specs.
 */
export function localPsqlContainer() {
  const container = process.env.SHERLYOS_PSQL_CONTAINER?.trim() || OWNER_PSQL_CONTAINER
  if (process.env.SHERLYOS_ISOLATED === "1" && container === OWNER_PSQL_CONTAINER) {
    throw new Error("isolated tests refused to use the owner Postgres container")
  }
  return container
}

export function runLocalSql(sql: string, label: string) {
  const result = spawnSync(
    "docker",
    [
      "exec",
      "-i",
      localPsqlContainer(),
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
 *
 * Product master rows from HTTP/Playwright runs accumulate by design:
 * posted stock_transactions are never deleted just to tidy fixtures, and
 * product rows are shared reference data. Pickers must search server-side
 * instead of loading the first PostgREST page. A fresh local database is
 * `npx supabase db reset --local` on a disposable instance only — never on
 * the owner's existing development database.
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
    select set_config('app.shipment_write', 'on', true);
    -- Disposable dual-write tests leave lot_id on ledger; later M1 wipes require it null.
    -- Invoice-note lines pin lot_id with ON DELETE RESTRICT. Do not detach those lots.
    update public.stock_ledger sl
    set lot_id = null
    from public.products p
    where p.id = sl.product_id
      and (${skuPred})
      and not exists (
        select 1 from public.invoice_note_lines n
        where n.lot_id = sl.lot_id
           or n.product_id = sl.product_id
      );
    delete from public.stock_delivery_return_events
    where return_id in (
      select r.id
      from public.stock_delivery_returns r
      join public.stock_delivery_return_lots l on l.return_id = r.id
      join public.products p on p.id = l.product_id
      where ${skuPred}
    );
    delete from public.stock_delivery_return_lots l
    using public.products p
    where p.id = l.product_id
      and (${skuPred});
    -- Shipment lots FK to reservations; remove disposable documents first.
    delete from public.order_shipment_events
    where shipment_id in (
      select s.id
      from public.order_shipments s
      join public.order_shipment_lots l on l.shipment_id = s.id
      join public.products p on p.id = l.product_id
      where ${skuPred}
    );
    delete from public.order_shipment_lots
    where product_id in (
      select p.id from public.products p where ${skuPred}
    );
    delete from public.order_shipment_lines
    where product_id in (
      select p.id from public.products p where ${skuPred}
    );
    delete from public.order_shipments
    where id in (
      select s.id
      from public.order_shipments s
      join public.orders o on o.id = s.order_id
      join public.order_lines ol on ol.order_id = o.id
      join public.products p on p.id = ol.product_id
      where ${skuPred}
    );
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
      )
      and not exists (
        select 1 from public.invoice_note_lines n where n.lot_id = l.id
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
    where product_id in (select p.id from public.products p where ${skuPred})
      and not exists (
        select 1 from public.invoice_note_lines n where n.lot_id = stock_lots.id
      );
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
