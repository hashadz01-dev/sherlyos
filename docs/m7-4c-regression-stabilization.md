# M7.4C — Regression stabilization and test environment cleanup

Local-only test-stabilization milestone after committed M7.4B. This phase does **not** add business features, invoices, pricing/GST, lot cutover, or stock-posting writers. The dedicated `DELIVERY_RETURN` writer is unchanged.

Starting HEAD: `d24888dd31b575a93c23a4d5ae03112fa31081ae`  
`feat(m7.4b): implement verified delivery returns and stock reconciliation` on `main`.

Working tree was clean at start. Owner had already committed M7.4B. This phase does not commit.

Migration applied locally (Docker only): `20261028000000_product_catalog_search.sql`.

Flags at start and end (operational values):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false` (hardcoded in `src/lib/picking/rules.ts`; not an `app_configuration` row)

---

## 1. Root causes identified

### 1.1 Product picker missing SKUs beyond 1,000

PostgREST `max_rows = 1000`. `loadRows("products")` and `useStockLocations().products` dumped the first name-ordered page. Local catalog is ~1,026 products, so `m1s2qa-found` (late name sort) was absent from native `<select>`s. That was the lot-reconciliation unexpected-product failure.

**Fix:** `public.search_products` RPC (paged ILIKE on sku/name, order `name, sku, id`, limit clamped 1–100). Visibility matches `products_select_readers` (`products.manage` sees inactive; `products.read` sees active only). Global `max_rows` was not raised. UI pickers use `ProductSearchField` / `searchProducts`. Duplicate names stay distinct via option `id` and label `sku · name`.

SQL proof (transactional, rolled back): insert 1,001 page products plus `zzz-m74c-tail`; empty search returns 50 and does not include the tail; query `zzz-m74c-tail` returns that one row.

### 1.2 Fixture pollution

HTTP, concurrency, and Playwright `create_product` commits persist. SQL suites `BEGIN`/`ROLLBACK`. Posted `stock_transactions` are never deleted just to tidy the catalog. Product master rows are shared reference data, so leftover disposable SKUs accumulate by design. The picker bug was caused by that accumulation plus the 1,000-row dump, not by a missing TRUNCATE.

**Fix:** unique run prefixes (`Date.now().toString(36)` / `m74c%`). `cleanupDisposableTestStock` stays prefix-scoped and still does not delete operational products or posted business ledgers. Documented fresh-database strategy: `npx supabase db reset --local` only on a disposable instance — never the owner's development database.

### 1.3 Playwright serial failures (M7.4B 91 passed / 2 failed / 5 did not run)

1. Lot-reconciliation unexpected product: product dump vs `max_rows` (1.1).
2. Damage-exceptional stale-version execute: confirm ran after reload before the report payload arrived, so the dialog used a stale version. Wait for posted-or-execute, then `Approved — pending execution`, then confirm.

### 1.4 M5.4C/D/E concurrency harness

After M7.2, `verify_order` applies `picking_cutover_blockers()`. Dual-write off ⇒ eligible 0. Held lots are also unpickable. The old leftover-0 + hold-first seed could not both verify and assert reserved=0. Undeclared `payload` in dispatch DO blocks was a separate harness bug (already declared before this phase; picking still failed ATP).

**Fix (harness only):** lot-attributed opening → verify order → attach hold → race → `restoreDualWrite()`. Exceptional attach-hold inserts verified photographic evidence so `request_exceptional_damage_disposition` is ready. Production ATP, lot attribution, and damage isolation are unchanged.

---

## 2. Exact files changed

New:

- `src/lib/masters/product-search.ts`
- `src/components/forms/ProductSearchField.tsx`
- `supabase/migrations/20261028000000_product_catalog_search.sql`
- `supabase/tests/phase_m7_4c_product_search.sql`
- `tests/unit/product-search.test.ts`
- `tests/e2e/product-search.spec.ts`
- `docs/m7-4c-regression-stabilization.md`

Modified pickers / catalog loads:

- `src/features/inventory/location-options.ts` (products dump removed)
- `src/features/inventory/OpeningStockPage.tsx`
- `src/features/inventory/TransfersPage.tsx`
- `src/features/masters/products/ProductsPage.tsx`
- `src/features/orders/OrderForm.tsx`
- `src/features/orders/OrderEditorPage.tsx` (no longer blocks on a 1,000-row product dump)
- `src/features/receiving/ReceiptForm.tsx`
- `src/features/refill/components/RefillForm.tsx`
- `src/features/stock-lot-reconciliation/LotReconciliationDetailPage.tsx`

Modified harness / e2e:

- `supabase/tests/phase_m5_4c_concurrency.mjs`
- `supabase/tests/phase_m5_4d_concurrency.mjs`
- `supabase/tests/phase_m5_4e_concurrency.mjs`
- `tests/e2e/disposable-stock.ts`
- `tests/e2e/lot-reconciliation.spec.ts`
- `tests/e2e/damage-exceptional.spec.ts`
- `tests/e2e/order-verification-dn-handover.spec.ts`
- `tests/e2e/refill-request-lifecycle.spec.ts`
- `tests/e2e/refill-receiving-integration.spec.ts`
- `tests/unit/lot-reconciliation-pages.test.tsx`

---

## 3. Fixture isolation approach

| Suite type | Isolation |
|---|---|
| SQL | `BEGIN` … `ROLLBACK`. No committed masters. |
| HTTP / concurrency | Unique `PREFIX` per process. Replica-enable dual-write only inside the seed; `finally` restores the three operational flags to false. |
| Playwright | Unique `RUN` / `PREFIX` per file. Shared QA identities (`m1s2qa-*`) are reused and scoped. |
| Cleanup | Prefix-only interference cleanup for unmatched leftover on inactive locations. Does **not** DELETE posted stock transactions of operational SKUs. Does **not** TRUNCATE the development catalog. |

Repeatable fresh-test-database strategy (disposable instance only):

```
npx supabase db reset --local
```

Do not run that against the owner's existing local database.

---

## 4. Product search fix

`search_products(product_query, result_limit, result_offset, active_only, filter_supplier)`:

- `SECURITY DEFINER` solely to call `app_private.has_permission`; otherwise 42501.
- `active_only or not can_manage` so readers never see inactive rows.
- Optional supplier filter for refill brand SKUs.
- Escaped ILIKE; deterministic `order by name, sku, id`.
- Limit 1–100, offset ≥ 0.

Client: `searchProducts` RPC + `getProduct` RLS single-row for a selected id not on the current page. Combobox options keyed by `id`.

Linked receiving still rejects SKUs that are not on the approved refill request.

Store Keepers have `stock.receive` and not `products.read`. Receiving therefore keeps the `list_receiving_options` catalog `<select>` (SECURITY DEFINER RPC, not PostgREST `max_rows`). Search is used where the actor already has `products.read` or `products.manage`.

---

## 5. M5 harness corrections

Picking races in 4C/4D/4E:

1. Replica-enable dual-write.
2. Lot-attributed `post_opening_stock`.
3. Create/verify the order while lots are pickable.
4. Attach the storage hold (4E also inserts verified evidence).
5. Race the original pairing.
6. Restore dual-write / aggregate-only / damage-hold flags to false.

No production posting functions were modified. ATP, FEFO, and hold exclusion remain fail-closed.

One sequential-matrix attempt of M5.4D `write-off vs quarantine transfer` threw `both transfer and write-off posted`. Isolated re-runs of the same file then passed 9/9 twice (and once before the matrix). The race already serializes on `lock_damage_report`; the assertion is fail-closed. Production write-off / quarantine writers were not changed. Treat the matrix miss as a non-reproduced first-pass flake, not a passing-by-retry of a weakened rule.

---

## 6. Before / after test results

Before (M7.4B hardening session):

| Suite | Result |
|---|---|
| Playwright full Chromium | 91 passed / 2 failed / 5 did not run |
| Isolated `damage-exceptional` | 9/9 |
| Isolated `lot-reconciliation` unexpected product | FAIL (`m1s2qa-found` missing from native select) |
| Vitest | 224 passed / 36 files |
| M5.4C/D/E later picking races | Not counted PASS (payload / dual-write-off ATP) |

After (this phase): recorded in section 8 and the Playwright section below. Skipped tests are not counted as passing.

---

## 7. Clean migration replay status

**NOT RUN** against a second database. **Not feasible** on a bare extra Postgres without a full Supabase stack.

Blocker: `supabase/migrations/20261014150000_access_control.sql` creates `public.profiles` with `id uuid primary key references auth.users (id)`. Later migrations use `extensions.crypt` / `auth.users` inserts. Foundation `20261014000000` is comment-only and does not create `auth`.

A disposable replay requires a second `npx supabase start` (auth schema + extensions), not `docker run postgres` plus `psql`. The owner's current local database was **not** reset.

Recommended remediation: a later tooling milestone that stands up a throwaway Supabase instance on unused ports and applies `supabase/migrations` there.

---

## 8. SQL / HTTP / concurrency matrix (this phase)

SQL files executed with `ON_ERROR_STOP=1` and completed (suites that wrap work in a transaction rolled back):

| Suite | Result |
|---|---|
| M2 `phase_m2_fefo_fifo_picking.sql` | PASS |
| M3 `phase_m3_dispatch_delivery.sql` | PASS |
| M5.2–M5.5 listed SQL files | PASS |
| M6.2–M6.6 listed SQL files | PASS |
| M7.2 `phase_m7_2_order_atp_dn_handover.sql` | PASS |
| M7.3 `phase_m7_3_picking_integration.sql` | PASS |
| M7.3B `phase_m7_3b_short_shipment.sql` | PASS |
| M7.4A `phase_m7_4a_delivery.sql` | PASS |
| M7.4B `phase_m7_4b_delivery.sql` | PASS |
| M7.4C `phase_m7_4c_product_search.sql` | PASS ROLLBACK |

HTTP / concurrency:

| Suite | Result |
|---|---|
| M2 HTTP | 5/5 PASS |
| M2 concurrency | 2/2 PASS |
| M3 HTTP | 9/9 PASS |
| M3 concurrency | PASS (confirm once, vs transfer, vs order cancel, vs picking cancel, vs cutover lock) |
| M3 adjustment concurrency | PASS |
| M3 transfer-lock concurrency | PASS (4+2 conserved, no deadlock) |
| M5.2 HTTP | 8/8 PASS |
| M5.2 concurrency | 1/1 PASS |
| M5.3 HTTP | 4/4 PASS |
| M5.3 concurrency | 9/9 PASS |
| M5.4B HTTP | 14/14 PASS |
| M5.4C HTTP | 5/5 PASS |
| M5.4C concurrency | 7/7 PASS (matrix and isolated) |
| M5.4D HTTP | 13/13 PASS |
| M5.4D concurrency | Isolated 9/9 PASS (three executions). One sequential-matrix attempt FAIL on write-off vs transfer; not counted as the suite PASS for that matrix row. |
| M5.4E HTTP | 20/20 PASS |
| M5.4E concurrency | 12/12 PASS |
| M5.4F HTTP | 4/4 PASS |
| M6.2–M6.6 HTTP | 16, 12, 10, 8, 9 PASS |
| M7.2 HTTP / concurrency | 7/7 PASS, 3/3 PASS |
| M7.3 HTTP / concurrency | 7/7 PASS, 5/5 PASS |
| M7.3B HTTP / concurrency | 5/5 PASS, 6/6 PASS |
| M7.4A HTTP / concurrency | 9/9 PASS, 5/5 PASS |
| M7.4B HTTP / concurrency / hardening | 7/7 PASS, 4/4 PASS, 7/7 PASS |

M6 concurrency files were **NOT RUN** (M6 request was SQL/HTTP only).

---

## 9. Playwright, unit, typecheck, lint, build

| Check | Result |
|---|---|
| Vitest | 225 passed / 37 files / 0 failed / 0 skipped |
| Typecheck `tsc -b` | PASS |
| Lint `oxlint` | 4 warnings, pre-existing react-compiler/set-state patterns; 0 errors |
| Production build | PASS (`ProductSearchField-CA2eNVYN.js` 1.98 kB; `DispatchDetailPage` 28.21 kB unchanged return panel) |
| Playwright Chromium run 1 | **100 passed / 0 failed / 0 skipped / 0 did not run** (6.4m) |
| Playwright Chromium run 2 | **100 passed / 0 failed / 0 skipped / 0 did not run** (6.5m) |

---

## 10. Remaining technical debt

- Catalog product rows from HTTP/Playwright still accumulate. Search, do not wipe.
- `OrderDetailPage` / `NewDeliveryNotePage` still resolve display names from `loadOrderProducts` (first PostgREST page). Selection no longer uses that dump; line labels for a SKU beyond page 1 may still show a raw id until those screens fetch by id.
- Damage report line pickers remain server-paged catalogs from M5.4B, not `search_products`.
- `list_stock_refill_options` / receiving options still return a products array the UI no longer maps for picking.
- M5.4D write-off vs quarantine first-pass race produced one non-reproduced dual-post assertion in a long sequential matrix.
- Clean historical migration replay needs a second Supabase instance.
- Operational flags remain false; no production dual-write or return posting is authorized.

---

## 11. Confirmation: no business rules changed

- `post_delivery_return`, `confirm_dispatch`, and `verify_stock_receipt` were not modified.
- ATP, lot attribution, damage-stock isolation, and FORCE RLS were not weakened.
- Invoice, pricing, and GST were not touched.
- Cutover flags were replica-set only inside disposable tests and restored false.
- No cloud migration, Netlify deploy, Git commit, push, fetch, rebase, or reset.
- No broad DELETE/TRUNCATE of the development database.
