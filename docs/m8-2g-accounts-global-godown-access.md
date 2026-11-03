# M8.2G — Accounts company-wide godown access

No Git commit, push, deploy, or development-cloud write. Owner order `SO-20261030-000025` was not modified. A draft delivery note was not created on cloud. Operational flags were not changed. Uncommitted M8.2C–M8.2F work is preserved.

**HEAD:** `498dfb404ec7ec5b6bb41830f60788df856e627a` on `main`.

**Local migration applied:** `20261102130000_accounts_company_wide_godown_access` on `supabase_db_sherlyos` only.

**Cloud migration:** applied to development cloud `ypkfondrkhkydkgovwup` on owner request to unblock live 5173 UAT. Authorization only. No order, stock, or flag writes.

---

## 1. Existing authorization architecture

Two independent checks:

| Check | Meaning |
|---|---|
| Action permission (`orders.verify`, `delivery_notes.issue`, `picking.execute`, …) | What the caller may do |
| Site scope (`app_private.can_work_at_branch`) | Where they may do it |

`can_work_at_branch` (before this pass):

- `branches.access_all` **or**
- a `user_branch_assignments` row on an **active** branch

`branches.access_all` is granted only to **Admin**. It also:

- includes **inactive** godowns
- allows SELECT of **all** `user_branch_assignments` (employee assignment data)
- is used as a staff shortcut in some warehouse/refill paths

Action RPCs still call `assert_permission` for the write. Expanding site scope does not by itself grant picking, dispatch, opening stock, or employee administration.

M8.2D already let Accounts **view/verify** without assignment (`can_view_order` / `verify_order`). Delivery-note **issue** still used `can_work_at_branch`, so Test Accounts could verify `SO-20261030-000025` and then hit an empty DN queue.

---

## 2. Root cause

Accounts required individual godown rows because issue/list RPCs (`list_verified_orders_without_dn`, `create_delivery_note`, invoice-note and dashboard filters) call `can_work_at_branch`. Test Accounts has **zero** assignments. That is a policy gap, not a missing order.

---

## 3. Selected implementation

**Do not grant `branches.access_all` to Accounts.**

Add a narrowly scoped permission:

`accounts.godowns.all` — *Work across every **active** godown for authorized Accounts actions.*

Granted **only** to the Accounts role.

`can_work_at_branch` now returns true when:

1. `branches.access_all` (Admin, including inactive), or
2. `accounts.godowns.all` **and** the target branch exists and `is_active`, or
3. an explicit active assignment (warehouse roles)

`branches` SELECT RLS: Accounts may read **active** godowns for filters. `user_branch_assignments` staff-wide SELECT is **not** opened.

This cannot grant stock-writing or Admin: those RPCs still `assert_permission` on `picking.execute`, `dispatch.confirm`, `stock.opening.post`, `employees.manage`, `roles.assign`, `stock.adjustment.post`, etc. Accounts does not receive those grants.

---

## 4. Backend changes

Forward-only local file:

`supabase/migrations/20261102130000_accounts_company_wide_godown_access.sql`

- Insert permission + Accounts grant
- Replace `can_work_at_branch`
- Recreate `branches_select_assigned_or_all`

No other RLS policies, no `service_role` grants, no stock writers, no GST finalize RPC.

---

## 5. Employee management UI

Admin → Employees → user details:

- **Role:** Accounts (or the actual role names)
- **Godown access: All godowns — Company-wide**
- **Explicit assignments:** listed separately, or None

Does not insert seven assignment rows. Godown Manager / Store Keeper keep the existing assign-godown controls.

---

## 6. RPC/RLS security findings

| Actor | Result |
|---|---|
| Unassigned Accounts | Lists submitted orders on Godowns 1–7; sees verified DN queue; can create a draft DN locally; dashboard includes those orders |
| New godown | Visible and in `can_work_at_branch` with no assignment row |
| Inactive Accounts | Loses `accounts.godowns.all` and queue RPC |
| Store Keeper / Godown Manager | Remain assignment-scoped; cannot work at Godown 2 |
| Accounts | Cannot `start_picking`, `confirm_dispatch`, `post_opening_stock`, `assign_user_role`, `create_stock_adjustment` |
| Accounts | Cannot read other employees' assignment rows |
| GST | No `finalize_statutory_invoice` / `issue_tax_invoice` public RPC |

Draft DN create did not write `stock_ledger`.

---

## 7. Role permission matrix (Accounts)

**Added:** `accounts.godowns.all`

**Unchanged (still granted):** `orders.verify`, `delivery_notes.issue`, `orders.capture` *(owner decision, not revoked)*, invoice-note review/issue, refill.request, shops/products/suppliers/stock.read, selling prices, statutory **prepare/read**, shipments.view/approve.

**Still not granted:** `branches.access_all`, `employees.*`, `roles.assign`, `branches.manage`, `picking.*`, `dispatch.confirm`, `stock.opening.post`, `stock.adjustment.post`, `stock.adjustment.approve_exceptional`, `audit.read`, `operations.monitor`.

---

## 8. Test results

Isolated / local only. Cloud not written.

### Operational flags (read-only)

| Flag | Cloud | Local test snapshot |
|---|---|---|
| `damage.stock_hold_ready` | **false** | unchanged |
| `stock.lots.dual_write_enabled` | **true** (prior Godown-1 UAT cutover) | unchanged in SQL tests |
| `stock.lots.aggregate_only_blocked` | **true** | unchanged |
| `SHORT_SHIPMENT_OPERATIONAL` | hardcoded **false** | not flipped |

Discrepancy vs some earlier milestone text that listed dual-write as false: cloud dual-write was already true from the Godown-1 UAT cutover. This pass did not change it.

| Suite | Result |
|---|---|
| SQL `phase_m8_2g_accounts_global_godown.sql` | **PASS** (rolled back) |
| SQL `phase_m8_2f_delivery_note_handover.sql` (updated for company-wide Accounts) | **PASS** |
| Vitest full | **56 files, 329 passed, 0 failed** |
| Playwright `m82g-accounts-global-godown.spec.ts` | **3 passed** |
| Playwright `m82f-delivery-note-handover.spec.ts` | **10 passed** (earlier same session; DN-12 updated) |
| Playwright `m82d-accounts-verification.spec.ts` | **3 passed** (earlier same session) |
| Typecheck / lint / production build | **PASS** / **PASS** / **PASS** |
| Full Playwright suite | **NOT RUN** |

### ACC-01 … ACC-20

| ID | Result | Where |
|---|---|---|
| ACC-01 Godown-1 submitted | PASS | SQL |
| ACC-02 Godown-2 submitted | PASS | SQL |
| ACC-03 all seven godowns | PASS | SQL |
| ACC-04 newly created godown | PASS | SQL |
| ACC-05 verify authorized (ATP fail-closed, not 42501) | PASS | SQL |
| ACC-06 verified DN queue | PASS | SQL + Playwright |
| ACC-07 draft DN create (local only) | PASS | SQL |
| ACC-08 cannot pick | PASS | SQL + Playwright `/picking` |
| ACC-09 cannot dispatch | PASS | SQL + Playwright `/dispatch` |
| ACC-10 cannot opening stock | PASS | SQL + Playwright `/inventory/opening` |
| ACC-11 cannot manage employees | PASS | SQL + Playwright `/employees` |
| ACC-12 cannot adjustments | PASS | SQL |
| ACC-13 inactive loses access | PASS | SQL |
| ACC-14 GM/SK site-scoped | PASS | SQL |
| ACC-15 RPC cannot bypass action permission | PASS | SQL |
| ACC-16 dashboard scope | PASS | SQL |
| ACC-17 verification + DN workflow | PASS | Playwright |
| ACC-18 no legal GST issuance RPC | PASS | SQL |
| ACC-19 no stock ledger from DN draft / policy SQL | PASS | SQL |
| ACC-20 not Admin | PASS | SQL + Vitest nav |

Cloud DN create for `SO-20261030-000025` was **not** executed.

---

## 9. Migration / deployment requirements

`accounts_company_wide_godown_access` is applied on development cloud `ypkfondrkhkydkgovwup`. Test Accounts has `accounts.godowns.all`. Impersonated `list_verified_orders_without_dn` returns `SO-20261030-000025`. Hard-refresh 5173 so the signed-in session reloads permissions.

Do not grant `branches.access_all` to Accounts as a shortcut. Netlify UAT still needs a frontend deploy for the Order Verification default filter; 5173 already has that UI change.

---

## 10. Manual UAT Stage-2 retest

1. Hard-refresh 5173 as Test Accounts (no Godown-1 assignment required).
2. Confirm `SO-20261030-000025` is visible on Order Verification under All verification statuses.
3. Delivery Notes → **Verified Orders Awaiting Delivery Note** lists that order (Haritha Thevara, Godown-1, 2 cases) if no active DN exists.
4. Create Delivery Note is available; the new-note form selects that order number.
5. Owner may create the **draft** DN manually. Automated work did not.
6. Confirm Employees (Admin) shows Test Accounts: **Godown access: All godowns — Company-wide**.
7. Confirm Accounts still cannot open Employees, Packing, Dispatch, or Opening stock.

---

## 11. Remaining owner approvals

1. Manual Stage-2 DN create on `SO-20261030-000025`.
2. Whether to revoke Accounts `orders.capture` (not changed here).
3. Git commit of M8.2C–G uncommitted work.
4. Netlify deploy if UAT should match 5173.

STOP FOR OWNER REVIEW.
