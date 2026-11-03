# M8.2E — Orders and Order Verification as separate responsibilities

Owner-approved UI split. Same `public.orders` rows. No second order table. No second lifecycle. No Git commit, push, deploy, or new migration applied in this pass. Operational flags, stock rows, owner data, and cloud schema were not changed.

**HEAD:** `498dfb404ec7ec5b6bb41830f60788df856e627a` on `main`.

**Preserved uncommitted work:** M8.2C isolated UAT scripts, M8.2D Accounts visibility files, Godown-1 UAT cutover notes.

---

## 1. Final sidebar responsibilities

| Sidebar | Path | Who sees it | Purpose |
|---|---|---|---|
| **Orders** | `/orders` | `orders.capture` or `orders.verify` or `operations.monitor` | Create, submit, and track shop orders. |
| **Order verification** | `/orders/verification` | `orders.verify` only | Accounts review and approval. |
| New order | `/orders/new` | `orders.capture` only | Draft capture. Not listed under verification. |
| Capture detail | `/orders/:orderId` | capture / verify / monitor | History, submit, edit. No Verify / Hold. |
| Verification detail | `/orders/verification/:orderId` | `orders.verify` only | ATP, Verify, Hold, delivery-note handover. |

Orders stays inactive while the verification queue or verification detail is open (`isNavigationPathActive`).

Direct URLs:

- Salesperson `/orders/verification` or `/orders/verification/:id` → Access denied.
- Accounts without `orders.capture` `/orders/new` → Access denied.
- Hidden buttons are not the gate. RPCs still assert `orders.capture` / `orders.verify` / `delivery_notes.issue`.

---

## 2. Role and permission matrix

Catalog grants are unchanged. This pass does **not** auto-grant Accounts capture and does **not** migrate a revoke.

| Role | `orders.capture` | `orders.verify` | `delivery_notes.issue` | Orders sidebar | Verification sidebar | New Order |
|---|---|---|---|---|---|---|
| Salesperson | yes | no | no | yes | no | yes |
| Accounts | **yes (catalog today)** | yes | yes | yes | yes | **yes, because capture is still granted** |
| Admin | no | no | no | yes (`operations.monitor`) | no | no |
| Godown Manager | no | no | no | no | no | no |
| Store Keeper | no | no | no | no | no | no |
| Delivery Person | no | no | no | no | no | no |

UI rule: New Order renders only when `shouldShowNewOrderAction({ mode: "capture", canCapture })`. Verification never shows it. Accounts can still create on `/orders` until the owner revokes `('accounts','orders.capture')`.

---

## 3. Orders versus Order Verification behaviour

Both modules read the same order, lines, and events.

**Orders (`/orders`)**

- Default status: all.
- New Order if `orders.capture`.
- Drafts, shop/product/godown capture, submit, creator edit/cancel.
- History and statuses inside existing RLS.
- Godown shown as the readable name. Missing catalog rows fall back to `Godown`, never a UUID.
- Submitted/verified rows offer **Open in Order verification** only when the actor has `orders.verify`.

**Order verification (`/orders/verification`)**

- Default status: submitted (awaiting verification).
- Cards show order number, shop name, godown name, requested cases, submission timestamp, status.
- No New Order.
- Opens `/orders/verification/:orderId`.
- ATP from `check_order_availability` (packing-eligible, non-reserving).
- Verify and Hold only with `orders.verify` and status `submitted`.
- After verify with no active DN: **Create delivery note**.
- If a non-voided DN exists: create is hidden; open-existing is shown. RPC unique index still rejects a second open DN.

---

## 4. Verification-to-Delivery-Note handover

Implemented path (unchanged RPCs):

1. `verify_order` → status `verified`. Ordered quantity is not rewritten.
2. Next action: create and send the delivery note; GM must acknowledge before allocation.
3. `create_delivery_note` copies verified lines.
4. Duplicate prevention:
   - UI: `openNote == null` on verification detail; New DN page disables create when `open_delivery_note` is active.
   - RPC: `order already has an active delivery note`.
   - DB: `delivery_notes_open_order_key` unique on `order_id` where status is not voided.

GST invoice / credit-note issuance remains off.

---

## 5. ATP discrepancy findings

Reported: **20 on-hand vs 2 eligible**, versus earlier **zero eligible**.

Read-only cloud check for `SO-20261030-000025` (not modified):

| Field | Value |
|---|---|
| Status | `submitted` |
| SKU | `GOODLIFE-MILK-500ML` |
| Requested | **2** |
| On-hand (`order_line_on_hand_cases`) | **20** |
| Lot `UAT-GL500-20261102` | **20**, expiry 2026-12-31, available |
| Godown | Godown-1 |
| `stock.lots.dual_write_enabled` | true (already on from Godown-1 UAT cutover) |
| `stock.lots.aggregate_only_blocked` | true |
| `damage.stock_hold_ready` | false (unchanged) |

This is **not** a missing-stock defect.

- `on_hand_cases` is informational crate stock (quarantine excluded).
- `eligible_cases` is `picking_line_plan.allocated_cases`: the coverable portion of **this request**, `least(requested, packing-available lot stock)`.
- Requested 2 with 20 pickable lot cases → eligible **2**, shortfall **0**. The extra 18 stay warehouse stock, not extra ATP for this line.
- Earlier zero eligible was fail-closed cutover: dual-write off sets `eligible_cases = 0` even when gross on-hand is 20.

The verification screen now states that eligible is coverable quantity for this request and on-hand is informational.

---

## 6. Test results

Isolated / local only. Cloud was not written. Flags were not flipped.

| Suite | Result |
|---|---|
| Vitest `accounts-verification`, `order-availability`, `navigation`, `m8-2c-workflow`, `picking`, `orders-verification`, `dashboard` | **38 passed** |
| Playwright `m82d-accounts-verification.spec.ts` + `order-verification-dn-handover.spec.ts` on `127.0.0.1:4173` / API `54321` | **7 passed** |

Playwright evidence:

- Salesperson has no Order verification nav; `/orders/verification` is access-denied; capture/submit still works.
- Unassigned Accounts sees the verification queue and not Admin screens.
- Assigned Accounts opens `/orders/verification/:id`, sees ATP, Verify stays fail-closed on the local dual-write-off fixture.
- Unauthenticated `/orders/new` → login.
- GM DN acknowledgement still works.

---

## 7. Remaining UAT blockers

1. **Accounts still has `orders.capture` in the role catalog.** UI no longer assumes that grant, but Accounts can still open New Order until the owner revokes it (requires an approved permission change; not done here).
2. **Credit / overdue at verify** is still missing. `verify_order` is ATP only.
3. **Godown-1 cloud UAT** still needs selling prices for invoice notes and a Delivery Person user for POD. GST issuance stays disabled.
4. **Local Playwright DB (54321)** still has dual-write off, so local Verify remains fail-closed. That is expected and is not the 20-vs-2 cloud ATP case.
5. Uncommitted M8.2C/D/E scripts and the two unapplied-in-this-pass SQL files stay owner-commit decisions.

**Not claimed:** cloud Verify click for `SO-20261030-000025` (Accounts still performs that in the UI). Eligible 2 vs on-hand 20 is explained and covering.

---

## 8. Files touched in this pass

- `src/app/navigation.ts`, `src/app/router.tsx`, `src/app/lazy-pages.ts`
- `src/features/orders/OrdersPage.tsx`, `src/features/orders/OrderDetailPage.tsx`
- `src/features/delivery-notes/NewDeliveryNotePage.tsx`
- `src/lib/orders/verification.ts`, `src/lib/orders/availability.ts`
- Tests listed in section 6
- This document

No commit, push, deploy, or migration.

STOP FOR OWNER REVIEW.
