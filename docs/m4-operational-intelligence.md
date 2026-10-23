# M4 — Operational intelligence and reporting

Local implementation. **Not deployed** to development cloud `ypkfondrkhkydkgovwup`. Does not seed, attribute, classify, flip cutover flags, or post operational stock on development.

## Actual M4 scope

Approved Phase 1 left Dashboard and Reports as empty placeholders. No later approved document defined a conflicting M4. This milestone fills those screens as a **read-only** operational intelligence layer:

- Operational dashboards (role-authorized KPI groups)
- Inventory, lot, and stock-movement reports
- Order and picking reports
- Dispatch and delivery reports
- Operational exception monitoring (existing workflow owners only)
- Permission-aware CSV export

Inventory balances (`/inventory`) and stock history (`/inventory/history`) stay operational screens. M4 does not rebuild them.

Not included: Excel/XLSX (no existing dependency), charts library, background jobs, materialized views, new exception state machines, new order statuses, `reports.read` permission, vehicle KPIs, customer POD beyond M3 `delivered`.

## Existing features reused

- Permissions: `stock.read`, `operations.monitor`, `orders.capture` / `orders.verify`, `picking.*`, `dispatch.view` / `dispatch.confirm`, `deliveries.execute` / `deliveries.assign`, receiving / verification / adjustment / lot-reconcile reads. No new permission catalog rows.
- `app_private.can_work_at_branch` and `branches.access_all` (Admin). Godown Manager, Store Keeper, and Delivery Person see assigned branches only.
- `app_private.can_view_order` (monitor all; verify + branch; capture = own rows). Warehouse picking/dispatch roles see verified-or-later branch orders via `report_can_see_order`, not capture drafts.
- Aggregate `stock_balances`, lot `stock_lot_balances` / `stock_lots`, `stock_reservations`, `stock_transactions`, M2 picking, M3 dispatch.
- Approved `stock.near_expiry_warning_days` = 90.
- Cutover flags `stock.lots.dual_write_enabled` and `stock.lots.aggregate_only_blocked` remain **false**. Reporting works with cutover inactive.

## Architecture

M4 is PostgreSQL `SECURITY DEFINER` RPCs, `search_path = ''`, EXECUTE to `authenticated` only. Helpers live in `app_private` and are revoked from `public` / `anon` / `authenticated` / `service_role`.

Reporting never posts stock, never creates operational documents, and never changes cutover flags. Official figures are computed in PostgreSQL. The browser does not aggregate ledgers.

## Stock accounting semantics

These quantities are never combined into a single “stock” figure:

| Quantity | Source | Cutover inactive |
|---|---|---|
| Aggregate on-hand | `sum(stock_balances.quantity)` | Displayed |
| Lot-attributed | `sum(stock_lot_balances.quantity)` | 0 (no operational lots) |
| Legacy unattributed | lot balances with `status = legacy_unattributed` | 0 |
| Active reserved | `stock_reservations.status = active` | 0 unless M2 holds exist |
| Available-to-pick | `picking_available_cases` | `{state:'not_applicable', reason:'lot_aware_allocation_inactive'}` |
| Dispatched cartons | unique `stock_transactions` type `DISPATCH` | 0 unless a consumed dispatch exists |

Do not treat aggregate on-hand as available-to-pick while dual-write is off. Reservations are not stock deductions. Preparing dispatches are not dispatched stock. Delivery-note acknowledgement is paperwork, not customer POD.

## Date and time

All report timestamps are UTC. Date filters are half-open `[posted_from, posted_to)`. The UI converts a calendar end date to the next UTC midnight. Unknown expiry stays unknown; no default expiry is invented. Approaching-expiry uses the approved 90-day configuration.

## Export

`export_operations_report` reuses the matching list RPC (same auth, branch, filters), pages 100 rows at a time, caps at 5000 rows, prefixes CSV cells whose first non-whitespace/control character is `= + - @` (leading space, tab, CR/LF, C0, NBSP, BOM included), and quotes commas/newlines. Filename on the client is `<kind>-utc.csv`. Truncation is explicit (`truncated: true` plus `row_count` of `total_count`).

## Performance

Aggregation and pagination happen in PostgreSQL (`page_size` max 100). No new materialized views. Existing indexes (`stock_transactions_posted_at_idx`, unique DISPATCH-once, dispatch branch/status) cover the report grains. Local fixtures are small; do not treat them as a production-scale proof.

## Reporting RPC contracts

| RPC | Authorization | Notes |
|---|---|---|
| `get_operations_dashboard` | Any report group permission | Omits unauthorized groups (`visible: false`). Unauthorized `filter_branch` is `42501`. |
| `list_inventory_report` | `stock.read` or `operations.monitor` | Grain `crate` / `zone` / `godown` / `product`. |
| `list_lot_stock_report` | same | Empty while there are no lots. |
| `list_stock_movement_report` | same | Document grain; transfers once; includes `DISPATCH`. |
| `list_order_picking_report` | capture / verify / picking / monitor | Salesperson filter requires monitor or verify. `stock_dispatched` from consumed dispatch. |
| `list_dispatch_delivery_report` | dispatch / deliveries / monitor | Drivers see assigned rows only. |
| `list_operations_exceptions` | any report group | Union of existing workflow rows + `href`. No resolve actions. |
| `export_operations_report` | same as the list RPC it pages | Bounded CSV. |

## KPI data dictionary

| Name | Source | Filters | Aggregation | Status conditions | Cutover | Auth |
|---|---|---|---|---|---|---|
| Cartons on hand | `stock_balances` | branch | `sum(quantity)` | none | aggregate always | inventory |
| Products with stock | `stock_balances` | branch | `count(distinct product_id)` | quantity > 0 | aggregate | inventory |
| Stock by godown | `stock_balances` × branches | branch | `sum` per authorized branch | none | aggregate | inventory |
| Lot-attributed cartons | `stock_lot_balances` | branch | `sum(quantity)` | none | 0 when no lots | inventory |
| Legacy unattributed cartons | lot balances | branch | `sum` | lot `legacy_unattributed` | 0 | inventory |
| Active reserved cartons | `stock_reservations` | branch | `sum(reserved_cases)` | `active` | holds only | inventory / picking |
| Available to pick | `picking_available_cases` | branch, lot `available` | `sum` | dual-write on | `not_applicable` when off | inventory |
| Draft / submitted / held / verified / cancelled orders | `orders` | branch | `count(*)` | matching `orders.status` | n/a | `can_view_order`; warehouse verified-or-later |
| Awaiting picking | `orders` | branch | `count(*)` | verified, no non-cancelled picking request | n/a | orders |
| Picking allocated / picking / picked / ready_for_dispatch / blocked | `stock_picking_requests` | branch | `count(*)` | matching status | n/a | picking perms |
| Preparing dispatches | `stock_dispatch_requests` | branch | `count(*)` | `preparing` and not `stock_consumed` | n/a | dispatch |
| Dispatched / in transit / delivered | dispatch requests | branch | `count(*)` | status + `stock_consumed` | n/a | dispatch / assigned |
| Delivery exceptions | dispatch requests | branch | `count(*)` | `exception` | n/a | dispatch / assigned |
| Pending proof of delivery | dispatch requests | branch | `count(*)` | dispatched or in_transit, consumed | n/a | dispatch / assigned |
| Dispatched cartons | `stock_transactions` | branch | `sum(quantity)` | type `DISPATCH` | unique txn | dispatch.view / monitor / assigned |
| Pending receiving | `stock_receipts` | branch | `count(*)` | draft/submitted/held | n/a | operations |
| Pending adjustments | `stock_adjustment_requests` | branch | `count(*)` | draft/submitted/returned/approved | n/a | operations |
| Pending verification | `stock_verifications` | branch | `count(*)` | not closed | n/a | operations |
| Unclassified products | `products` | none (master) | `count(*)` | `expiry_policy is null` | n/a | products/stock/monitor |
| Pending physical returns | dispatch requests | branch | `count(*)` | `physical_return_status = pending_verification` | n/a | dispatch.view / monitor / assigned |

## Branch and role views

| Role | Typical dashboard | Notes |
|---|---|---|
| Admin | Cross-branch (`branches.access_all`) | Not assumed for other roles. |
| Godown Manager | Assigned godown inventory, orders, picking, dispatch, operations | |
| Store Keeper | Inventory + picking workload | No dispatch report. |
| Delivery Person | Assigned deliveries | No inventory report. No unassigned dispatch rows. |
| Salesperson | Own orders | Cannot filter by another salesperson. |
| Accounts | Inventory + orders they can verify | |

Backend enforces independently of navigation.

## Known limitations

- Development-cloud stock is aggregate-only; lot and available-to-pick KPIs are empty / not applicable until operational cutover.
- Export stops at 5000 authorized rows (`truncated: true`).
- Unclassified product count is global master data, not branch-scoped.
- No vehicle or customer-invoice KPIs (no such masters).
- Playwright and HTTP suites use disposable local fixtures; leftover local data can inflate Admin cross-branch totals. Godown-scoped tests use a dedicated branch.
- Local inventory joins at ~40 extra product rows use existing `crates(zone_id)` / `zones(branch_id)` indexes. No new M4 indexes; larger production volumes should be re-planned before adding any.

## Deployment prerequisites

1. Apply `20261023200000_operational_intelligence.sql` to the target database (not done here).
2. Leave cutover flags false unless a later cutover gate authorizes them.
3. No stock seed, attribution, or frontend deploy is required for M4 itself.

## Test coverage

Local Docker / Vite `--mode m1s2` only. Development cloud was not migrated, seeded, or flag-flipped.

| Suite | Result |
|---|---|
| `phase_m4_operational_intelligence.sql` | Passed (rollback). Empty/cutover-off KPIs, on-hand vs available-to-pick, transfer-once, UTC date windows including midnight/month/year, pagination cap, CSV injection including leading whitespace/control/NBSP/BOM, warehouse draft isolation, driver/cross-branch denial, unknown expiry, preparing ≠ dispatched, DN paperwork ≠ POD, idempotent DISPATCH once, reporting cannot mutate stock. |
| `phase_m4_http_integration.mjs` | Passed (13). PostgREST contracts, export, keeper/driver/cross-branch/anon, driver export denial, cutover inactive. Opening seeded over `psql` because PostgREST loads `safeupdate`. |
| Playwright | `tests/e2e/reports.spec.ts` passed (4): unauthenticated redirect, godown dashboard/inventory/CSV, tablet inventory, driver denied inventory. |
| `npm run typecheck` / `lint` / `test` / `build` | Passed (91 unit tests). Lint warnings only in unrelated inventory/product pages. |
| M1 / M2 / M3 / 4.1 / 4.2 SQL | Passed on a clean local reset. Leftover HTTP ledger rows can make 4.1B's superuser-vs-RLS stock count fail until reset; that is fixture pollution, not an M4 writer defect. |

Concurrency suites were not re-run: M4 does not change stock writers.

## Operational cutover dependencies

Available-to-pick, lot expiry buckets, and lot-attributed totals become meaningful only after dual-write produces real lot rows. M4 already encodes the inactive state so those KPIs cannot be mistaken for aggregate on-hand.
