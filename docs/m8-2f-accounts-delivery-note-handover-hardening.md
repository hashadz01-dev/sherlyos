# M8.2F — Accounts delivery-note handover hardening

No Git commit, push, deploy, or cloud write. No owner-order mutation. Operational flags were inspected read-only and were not changed. Uncommitted M8.2C / M8.2D / M8.2E work is preserved.

**HEAD:** `498dfb404ec7ec5b6bb41830f60788df856e627a` on `main`.

---

## 1. Root cause and affected code

The UAT symptoms were two separate frontend/RPC mismatches, not a missing verified order.

### Why `/deliveries` showed “No verified orders waiting”

`list_verified_orders_without_dn` (`supabase/migrations/20261018120000_delivery_notes.sql`) requires:

- `delivery_notes.issue`
- order `status = verified`
- `app_private.can_work_at_branch(orders.branch_id)`
- no non-voided delivery note

`create_delivery_note` uses the same site gate via `assert_delivery_note_issuer` (`godown is not authorized`, `42501`).

M8.2D allowed Accounts `get_order` / `list_orders` / `verify_order` without a godown assignment. Test Accounts (`testaccounts@gmail.com`) verified `SO-20261030-000025` that way. The user still has **zero** `user_branch_assignments`. The queue RPC therefore returned `[]` correctly. The landing page treated that empty array as “no orders waiting”.

### Why New Delivery Note showed “Select order” while details rendered

`/deliveries/new?orderId=…` loaded the order with `get_order` (allowed without assignment) and rendered shop, godown, and lines. The `<select>` options came only from the empty queue. The controlled value was the UUID, which had no matching `<option>`, so the browser displayed the first option: **Select order**. Details and submit were not bound to one selected ID.

### Affected frontend / RPC

| Surface | Before | After |
|---|---|---|
| `/deliveries` | Empty RPC result → “No verified orders waiting” | Distinct loading / error / unauthorized / no-assignment / empty / ready |
| `/deliveries/new` | URL `orderId` vs empty dropdown | URL is the only selected-order ID; deep-linked order is merged into options |
| `/orders/verification/:id` | Create DN if verified + `delivery_notes.issue` | Also requires own godown assignment (same contract as create RPC) |
| RPCs | Unchanged | Still `list_verified_orders_without_dn` and `create_delivery_note` |

No unrestricted table query replaced the queue RPC.

---

## 2. Actual database state of `SO-20261030-000025`

Read-only on development cloud `ypkfondrkhkydkgovwup`. The row was not updated.

| Field | Value |
|---|---|
| ID | `2558cf41-e600-4b92-9e2a-e12035123475` |
| Number | `SO-20261030-000025` |
| Status | `verified` |
| Version | 3 |
| Shop | Haritha Thevara |
| Godown | Godown-1 (`798bacf9-2212-43fc-9cbb-2fe1e7367a93`) |
| Product | `GOODLIFE-MILK-500ML` |
| Quantity | 2 whole cases |
| Events | `created` → `submitted` → `verified` at 2026-11-02 06:48:26 UTC |
| Verified by | Test Accounts (`a3f39eee-35a9-4296-a523-01a04009d23e`) |
| Delivery notes | **none** |

Test Accounts has **no** godown assignment. That is why the waiting queue is empty for this user even though the order is verified and has no delivery note.

---

## 3. Why the waiting queue was empty

Not stale cache. Not an existing note. Not a status bug.

The Accounts session can see and verify the order (M8.2D). It cannot **issue** a delivery note until assigned to Godown-1. The queue follows the issue RPC, not `list_orders`.

---

## 4. Why the selector showed “Select order”

The form displayed Order A from `get_order` while the `<select>` had no option for that UUID. After this pass the selected ID is the `orderId` search param, and `mergeHandoverOrderOptions` inserts the loaded order so the visible label is the order number.

If the caller is not assigned to that godown, the number is still shown and create stays disabled, with an explanation. That matches the server: `get_order` may succeed; `create_delivery_note` will not.

---

## 5. Changes made

Frontend only. Existing authorized RPCs. Isolated local fixtures for write-path tests.

1. `src/lib/delivery-notes/handover.ts` — shared eligibility, queue-state copy, option merge, line summaries.
2. `src/lib/access/godown-scope.ts` — `loadOwnAssignedBranchIds` (own `user_branch_assignments` only; does not grant branches).
3. `src/features/delivery-notes/DeliveriesPage.tsx` — **Verified Orders Awaiting Delivery Note** section distinct from created notes; shop/godown names; loading/error/assignment/empty/ready.
4. `src/features/delivery-notes/NewDeliveryNotePage.tsx` — URL is the selected order; create disabled until valid and loaded; duplicate-note banner preserved.
5. `src/features/orders/OrderDetailPage.tsx` — Create DN gated on assignment; invalidate the queue after verify; existing-note copy preserved.
6. `src/lib/orders/api.ts` — `loadOrderLineRows` for queue line/case counts (RLS `can_view_order`).

Accounts `orders.capture` was **not** revoked.

---

## 6. RLS and role-access verification

Local SQL (transaction rollback) on `supabase_db_sherlyos`:

| Actor | Queue | Create |
|---|---|---|
| Accounts assigned to Godown A | sees verified order without DN | draft linked to that order |
| Accounts with no assignment | empty queue (not a false “no orders” in UI) | `42501` |
| Accounts assigned only to Godown B | cannot see Godown A | `42501` |
| Salesperson | `42501` | `42501` |
| Store Keeper | `42501` | `42501` |
| Admin | queue `42501` (monitor is not issue) | not granted |

Duplicate create: same idempotency key returns the same draft; a second key hits `order already has an active delivery note` / unique open-order index. Draft create does not write `stock_ledger`.

Direct `/deliveries/new?orderId=` cannot bypass RPC authorization.

---

## 7. Test results

Isolated / local only. Cloud was not written. Flags were not flipped in this pass.

Cloud flags (read-only; already set by the earlier Godown-1 UAT cutover, **not** changed here):

- `damage.stock_hold_ready` = false
- `stock.lots.dual_write_enabled` = true
- `stock.lots.aggregate_only_blocked` = true
- `SHORT_SHIPMENT_OPERATIONAL` remains hardcoded false

| Suite | Result |
|---|---|
| SQL `phase_m8_2f_delivery_note_handover.sql` | **PASS** (rolled back) |
| SQL `phase_4_2a_delivery_notes.sql` | **PASS** |
| SQL `phase_4_2b_delivery_notes.sql` | **PASS** |
| Vitest full | **55 files, 324 passed, 0 failed** |
| Playwright `m82f-delivery-note-handover.spec.ts` | **10 passed** |
| Playwright `m82d-accounts-verification.spec.ts` + `order-verification-dn-handover.spec.ts` | **7 passed** |
| Typecheck | **PASS** |
| Lint | **PASS** (pre-existing warnings only; no new errors) |
| Production build | **PASS** |
| Full Playwright suite | **NOT RUN** |

### DN-01 … DN-12

| ID | Scenario | SQL | Vitest | Playwright |
|---|---|---|---|---|
| DN-01 | Verified order in waiting queue | PASS | PASS | PASS |
| DN-02 | Submitted order excluded | PASS | PASS | PASS |
| DN-03 | Active DN excludes order | PASS | PASS | PASS |
| DN-04 | Deep link preselects dropdown | — | PASS | PASS |
| DN-05 | Switching order updates form/payload | — | PASS | PASS |
| DN-06 | Invalid order ID fails safely | — | PASS | PASS |
| DN-07 | Unauthorized branch/role cannot create | PASS | PASS | PASS |
| DN-08 | Valid create links draft + lines | PASS | PASS | PASS |
| DN-09 | Duplicate rejected or idempotent | PASS | PASS | PASS |
| DN-10 | Queue drops order after create | PASS | — | PASS |
| DN-11 | No inventory mutation from draft | PASS | — | **NOT RUN** (SQL covers this) |
| DN-12 | Empty / error / unauthorized distinct | — | PASS | PASS |

Never labelled unexecuted Playwright DN-11 as PASS.

---

## 8. Remaining blockers

1. **Test Accounts is not assigned to Godown-1.** Owner must assign that user in Employees. Until then, cloud `/deliveries` shows **No godown assignment** (correct) and Create DN stays disabled. This agent must not write that assignment.
2. **Accounts still has catalog `orders.capture`.** Not revoked in this pass. Pending owner decision.
3. Cloud dual-write flags are already true from the earlier Godown-1 cutover. This pass did not enable, disable, or revert them.
4. Credit / overdue at verify is still missing (`verify_order` remains ATP-only).
5. Full Playwright regression beyond the 17 local specs above was not executed.
6. Uncommitted M8.2C/D/E scripts and unapplied-in-this-pass SQL files remain owner-commit decisions.

---

## 9. Manual UAT Stage-2 retest

Environment: `127.0.0.1:5173` → cloud `ypkfondrkhkydkgovwup`. Use Test Accounts after an administrator assigns that user to **Godown-1**. Do not create a second order.

1. Employees: assign Test Accounts to Godown-1. Confirm the user can still sign in.
2. Order Verification: open `SO-20261030-000025`. Status Verified. **Create delivery note** visible.
3. Delivery Notes: section **Verified Orders Awaiting Delivery Note** lists that order (shop Haritha Thevara, godown Godown-1, 1 line, 2 cases). Not “No verified orders waiting”.
4. Create Delivery Note from either entry. Dropdown shows `SO-20261030-000025`, not “Select order”. Refresh keeps the selection.
5. Create draft. Lands on the new DN detail. Status draft. Same order ID and 2 cases. Stock unchanged.
6. Return to `/deliveries`: the order has left the waiting queue; the draft is in **Delivery notes already created**.
7. Opening create again for the same order shows the existing note and does not create a second active note.
8. Negative: a user assigned only to another godown must not see or create this note. Salesperson / Store Keeper `/deliveries/new` is access denied.

If Test Accounts is still unassigned, expect **No godown assignment** on `/deliveries` and no Create action on the verification detail. That is the protected contract, not a queue bug.

---

## 10. Confirmation

- No owner-data writes
- No flag changes
- No deployments
- No commits
- No cloud migrations
- Owner order `SO-20261030-000025` untouched
- Stock writers, lots, crates, GST, and `orders.capture` untouched

STOP FOR OWNER REVIEW.
