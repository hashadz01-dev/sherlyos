# M8.2D — Accounts order verification, role access, and Stage-2 UAT repair

Assessment plus the owner-directed Accounts visibility fix. No Git commit. No owner-data writes. Cutover flags were not changed. Cloud SQL `20261102120000_accounts_verify_without_branch` was applied so Accounts can list submitted salesperson orders without a godown assignment.

**Starting HEAD:** `498dfb404ec7ec5b6bb41830f60788df856e627a` on `main` (`top-bar Ui fix done`).

**Uncommitted at start (preserved):** M8.2C scripts/tests plus `OrderDetailPage` / `OrderEditorPage` back-button work.

---

## 1. Environments inspected

| Surface | Target | Role |
|---|---|---|
| Vite `.env` + `.env.local` (port 5173) | `https://ypkfondrkhkydkgovwup.supabase.co` | Development cloud. Read-only diagnostics only. |
| Playwright `--mode m1s2` (port 4173) | `http://127.0.0.1:54321` | Local disposable API. SQL/e2e writes allowed. |
| `https://sherlyos-uat.netlify.app` | Frontend hostname | Not an isolated database. Same cloud project as 5173 unless a different build env is used. |

Operational flags on development cloud (unchanged):

- `stock.lots.dual_write_enabled=false`
- `stock.lots.aggregate_only_blocked=false`
- `damage.stock_hold_ready=false`

---

## 2. Actual verification workflow (existing)

Accounts verification is not a missing engine. It already lives on:

1. `list_orders` / `get_order` (`app_private.can_view_order`)
2. `check_order_availability`
3. `verify_order` / `hold_order` / `cancel_order`
4. After verify: `create_delivery_note` → generate → send → GM acknowledge → allocate

`can_view_order` for Accounts is `orders.verify` only. Salesperson capture still sees own `created_by` rows. Admin `operations.monitor` sees all orders. Warehouse packing/dispatch still require godown assignment.

There was no dedicated verification route. Accounts had to open `/orders` (default status `all`) and then `/orders/:id`. Dashboard `Submitted` used the same scoped `report_can_see_order` count.

---

## 3. Root-cause findings

| Issue | Evidence | Location | Safe correction |
|---|---|---|---|
| `SO-20261030-000025` exists as `submitted` on Godown-1 | Cloud read: id `2558cf41-e600-4b92-9e2a-e12035123475`, shop Haritha Thevara, 2 cases GoodLife Milk 500ml, created/submitted by Test Salesperson | `public.orders` / `order_lines` / `order_events` on `ypkfondrkhkydkgovwup` | None. Order is present. |
| Accounts dashboard Submitted = 0 | Test Accounts had `orders.verify` but `can_view_order` also required a godown assignment | `app_private.can_view_order` | Owner directed: Accounts may read/verify without a site assignment. Applied `20261102120000_accounts_verify_without_branch`. |
| No obvious verification queue | `/orders` defaulted to all statuses; no Operations entry labeled verification | `OrdersPage`, `navigation.ts` | `/orders/verification` gated on `orders.verify` |
| Accounts nav looks wide | Cloud grants include stock/products/shops/prices/refill/statutory/invoices/DNs. Admin paths already require `employees.read` / `audit.read`, which Accounts lacks | `role_permissions` | Keep grants. Hide Admin. Add verification entry. |
| Verify still fail-closed after visibility | Godown-1 has 0 zones, 0 crates, 0 lots, 0 balances; dual-write false | `verify_order` ATP | Do not ignore lots. Do not enable dual-write. |

---

## 4. Order visibility analysis

**Order `SO-20261030-000025`**

- Internal id: `2558cf41-e600-4b92-9e2a-e12035123475`
- Shop: Haritha Thevara (`c2117a00-36ac-40f0-8c07-e38415cdb9ba`)
- Godown: Godown-1 (`798bacf9-2212-43fc-9cbb-2fe1e7367a93`)
- Status: `submitted` (version 2)
- Source: salesperson
- Created: 2026-10-30 13:11:49+00 by Test Salesperson
- Submitted: 2026-10-30 13:19:03+00
- Line: GOODLIFE-MILK-500ML, 2 cases
- Events: `created` → `submitted`

**Accounts `testaccounts@gmail.com`**

- Auth + active profile Test Accounts
- Role: `accounts` only
- `orders.verify`: yes
- `branches.access_all`: no
- Godown assignments: **0**
- Therefore the earlier empty queue was RLS, not a missing order

Owner override: Accounts verification is company-wide. `can_view_order` no longer requires `can_work_at_branch` for `orders.verify`. `list_orders`, `get_order`, dashboard submitted, `verify_order`, `hold_order`, and Accounts `cancel_order` follow that. Warehouse packing/dispatch still require a site assignment. Test Accounts was not assigned to Godown-1.

---

## 5. Accounts role / permission matrix

Cloud-observed Accounts grants (authority; not changed):

`orders.capture`, `orders.verify`, `delivery_notes.issue`, `invoices.issue`, `invoices.review`, `products.read`, `products.price.read`, `products.price.manage`, `shops.read`, `shops.read_all`, `shops.statement.read`, `suppliers.read`, `suppliers.manage`, `stock.read`, `refill.request`, `shipments.view`, `shipments.approve`, `statutory.config.read`, `statutory.config.prepare`

| Layer | Accounts |
|---|---|
| Navigation | Overview, Order verification, Orders, invoice notes, credit adjustments, delivery notes, refill, inventory/lot/history, products/categories/suppliers/shops/prices, reports, settings, statutory |
| Hidden | Packing, dispatch, delivery runs, damage, receiving, stock verification, opening stock, transfers, locations, vehicles, employees, godowns, users & role, audit |
| Page URL | `/orders/verification` requires `orders.verify`. `/employees` denied. |
| Data read | Submitted salesperson orders are visible to any Accounts user with `orders.verify`. Godown assignment is not required. |
| RPC | `verify_order` / `hold_order` require `orders.verify` only. ATP still fail-closed. Store keeper denied. |
| Godown | Warehouse site grants unchanged. No `access_all`. Test Accounts was not assigned. |

---

## 6. Navigation and dashboard changes

**Before:** Operations → Orders only. Overview label `Submitted`.

**After:** Operations → **Order verification** (`/orders/verification`, `orders.verify`) plus Orders. Overview metric **Submitted** (awaiting Accounts verification). No Godown-1 assignment banner.

Unauthorized URLs still hit `RequirePermission` / `RequireAnyPermission` → Access denied. Hidden nav is not the authorization layer.

---

## 7. Backend / RLS

`app_private.can_view_order` now grants `orders.verify` without `can_work_at_branch`. `check_order_availability`, `hold_order`, `verify_order`, and Accounts `cancel_order` match. `verify_order` uses `assert_active_branch` (lock + is_active) instead of `assert_operational_active_branch`, so Accounts can attempt verify without a site assignment. ATP still fail-closed. Warehouse DN/picking/dispatch still use site grants. Dual-write flags unchanged.

Local disposable SQL `supabase/tests/phase_m8_2d_accounts_verification.sql` proves the same rules and rolls back.

---

## 8. Files changed (this phase)

- `src/app/navigation.ts`
- `src/app/router.tsx`
- `src/app/lazy-pages.ts`
- `src/components/layout/SidebarNav.tsx`
- `src/features/orders/OrdersPage.tsx`
- `src/features/orders/OrderDetailPage.tsx`
- `src/lib/orders/api.ts`
- `src/lib/orders/verification.ts`
- `src/lib/access/godown-scope.ts`
- `src/lib/access/navigation-visibility.ts`
- `src/pages/dashboard/DashboardPage.tsx`
- `tests/unit/accounts-verification.test.ts`
- `tests/unit/navigation.test.ts`
- `tests/integration/orders-verification.test.tsx`
- `tests/integration/dashboard.test.tsx`
- `tests/e2e/m82d-accounts-verification.spec.ts`
- `tests/e2e/disposable-stock.ts`
- `supabase/tests/phase_m8_2d_accounts_verification.sql`
- `docs/m8-2d-accounts-verification-role-access-fix.md`
- `supabase/migrations/20261102120000_accounts_verify_without_branch.sql`
- `supabase/migrations/20261102121000_accounts_verify_active_godown_without_assignment.sql`

---

## 9. Test results

| Suite | Result |
|---|---|
| Focused Vitest (`accounts-verification`, `orders-verification`, `dashboard`, navigation) | PASS |
| Full Vitest | **53 files, 302 passed** (pre-final UI nits; focused re-run after nits PASS) |
| SQL `phase_m8_2d_accounts_verification.sql` against `supabase_db_sherlyos` | **PASS, ROLLBACK** |
| Playwright `tests/e2e/m82d-accounts-verification.spec.ts` | **3 passed** |
| Playwright `tests/e2e/order-verification-dn-handover.spec.ts` | **4 passed** |
| `tsc -b` | PASS |
| `oxlint` | PASS (existing warnings only; no new errors) |
| `npm run build` | PASS |

Playwright targeted local `127.0.0.1:54321`. Development cloud received only the Accounts visibility function replace. Flags and assignments were not changed.

---

## 10. Remaining operational blockers

1. Owner-directed M8.2E cutover on development cloud: dual-write and `aggregate_only_blocked` are **true**. Godown-1 has UAT zone/crate and 20 lot cases of GOODLIFE-MILK-500ML. ATP for `SO-20261030-000025` is now operational (eligible 2, shortfall 0). Damage holds stay false.
2. No selling price on GOODLIFE-MILK-500ML, so invoice-note review will still fail after dispatch until the owner states a unit amount.
3. No Delivery Person Auth user, so POD is still blocked.
4. UAT Netlify will not show this UI until a frontend deploy of this branch.

---

## 11. Owner approvals required

1. Separate later: stock lots / dual-write for Godown-1 before Stage-2 verify can succeed.
2. Deploy the frontend to UAT when ready.

---

## 12. Stage-2 manual UAT retest

Hard refresh as Test Accounts (still with dual-write off):

1. Sign in as Test Accounts.
2. Overview: **Submitted** should be ≥ 1. No Godown-1 assignment banner.
3. Operations → **Order verification**.
4. Locate `SO-20261030-000025` (Haritha Thevara, Godown-1, 2 cases, salesperson, submitted).
5. Open the order. Confirm ATP shows non-operational / insufficient eligible stock. Status stays **submitted**. Verify must not mark it verified.
6. Confirm Employees / Users & role / Opening stock remain inaccessible.
7. Stop. Do not enable dual-write to force an approval during this retest unless separately approved.

---

**Verdict:** `M8.2D VISIBILITY FIXED — VERIFY STILL STOCK-GATED`
