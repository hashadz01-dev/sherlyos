# M7.3B — Controlled short-shipment, linked backorders, partial-dispatch integrity

Local-only implementation after M7.3A. This phase reuses the M2 lot-attributed picking engine, M3 `confirm_dispatch` stock writer, M7.2 DN acknowledgement gate, and M7.3A shortage/handoff contract. It does **not** add vehicles, tax invoices, a return stock writer, TallyPrime, payments, cloud migration, Netlify deploy, Git commit, or feature-flag activation.

**Development completion is not operational activation.** Lot cutover flags stay false. `SHORT_SHIPMENT_OPERATIONAL` stays `false`. UI and fulfilment snapshots never claim live warehouse short-shipment.

Starting HEAD: `81d8d875003cdfd2b63ccb3fd7d60ce98bc71b0b`  
`feat(m7.3a): harden picking integration and short-pick safety` on `main`.

Parent: `cd8cb1986aeef435171ac1a08b40f9b2b52f209d`  
`feat(m7.2): align order ATP and enforce DN acknowledgement before picking`.

Working tree was clean at start. M7.3A checkpoint was committed.

Migration applied locally (Docker): `20261027220000_controlled_short_shipment_and_backorders.sql`.

Flags at start and end (operational values):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`

Owner decisions honoured: D4.1–D4.5 (approved). D2 (vehicles), D3 (invoices), D5 (failed-delivery restock) remain out of scope.

---

## 1. Approved D4.1–D4.5 mapping

| Policy | Implementation |
|---|---|
| **D4.1 Dispatch quantity** | Dual-path `confirm_dispatch`. Full shipment still consumes `reserved_cases`. Partial path deducts `order_shipment_lots.approved_cases` from the exact reserved lots. Original `order_lines.requested_cases` is never the posting quantity. |
| **D4.2 Unfulfilled remainder** | Original order quantities and events stay unchanged. `app_private.create_linked_backorder` inserts a child order (`source=backorder`) with remainder cases. No reservation, no supplier PO, no refill, no silent cancel. |
| **D4.3 Document history** | Acknowledged DN is not rewritten. `order_shipments` is a separate operational document linked to order, DN, picking, dispatch, and backorder. Not a GST tax invoice. |
| **D4.4 Approval** | GM `confirm_short_shipment_quantities` (`shipments.manage`). Accounts `approve_short_shipment` (`shipments.approve`). Actor and timestamps from `auth.uid()` / `clock_timestamp()`. Immutable `order_shipment_events`. Stale fingerprints invalidate later dispatch. |
| **D4.5 Reservation release** | Inside the same `confirm_dispatch` transaction. Unused remainder (`reserved_cases - approved_cases`) is marked `released` on the reservation grain; shipped remainder is `consumed`. No second ledger event for release. |

---

## 2. Existing architecture findings

Picked lots are identifiable without inference: `stock_reservations.lot_id` + `crate_id` + `picked_cases` after M2 confirm. M7.3B snapshots those grains into `order_shipment_lots` at create time. Aggregate-only fallback is not used.

Quantity sources:

| Label | Source | Mutable after create? |
|---|---|---|
| Ordered | `order_lines.requested_cases` | No |
| DN | DN line snapshot of the order | Paperwork; acknowledged cannot be voided |
| Reserved | `stock_reservations.reserved_cases` (active) | Shortage may reduce; dispatch consumes/releases |
| Picked | `stock_reservations.picked_cases` | ≤ reserved; not a ledger debit |
| Proposed | `order_shipment_lots.proposed_cases` | Draft snapshot of picked |
| Approved | `order_shipment_lots.approved_cases` | Accounts write; ≤ picked |
| Shipped | `order_shipment_lots.shipped_cases` | Set at dispatch = approved |
| Released unused | `order_shipment_lots.released_cases` | Set at dispatch = reserved − approved |
| Outstanding | ordered − approved (shipment) / linked backorder lines | Backorder, not original rewrite |
| Ledger | `stock_ledger` via existing DISPATCH writer | Dual-write still gated by cutover flags |

Lifecycle already enforced unless noted:

| Transition | Authority |
|---|---|
| Order → verified | existing M7.2 RPCs |
| DN → acknowledged | existing DN RPCs; unique open DN |
| Allocate / pick / shortage | M2; pick ≤ reserved; shortage not a debit |
| Short-shipment draft | `create_short_shipment` (GM, picked snapshot) |
| GM confirm | `confirm_short_shipment_quantities` |
| Accounts approve | `approve_short_shipment` |
| Handoff | `confirm_picking_handoff`; shortage allowed iff approved shipment fingerprint matches |
| Dispatch | `confirm_dispatch`; sole order-fulfilment stock writer |
| Delivery / POD | unchanged M3 whole-document; does not mark original order fulfilled by itself |

---

## 3. Quantity and lot-attribution invariants

For every affected order line:

```
0 <= shipped_cases <= confirmed_picked_cases
0 <= shipped_cases <= approved_shipment_cases
0 <= shipped_cases <= original_ordered_cases
unfulfilled_cases = original_ordered_cases - cumulative_dispatched_cases
```

For every affected stock lot:

```
dispatched_cases <= eligible_reserved_cases committed to that shipment
original_reserved = dispatched_from_reservation + released_unused + remaining_valid_reservation
```

All terms are non-negative integer case units. Picked quantity is not a stock-ledger deduction. FEFO/FIFO, quarantine, expiry, damage holds, and active-godown rules are unchanged M2/M3/M5/M7.2 gates.

`reserved_cases >= 1` remains on reservation rows, so a zero-ship grain is released in place rather than violating that check.

---

## 4. Shipment lifecycle

```
acknowledged DN
  → allocate / pick / shortage audit
  → create_short_shipment (draft, lot snapshot)
  → GM confirm_short_shipment_quantities
  → Accounts approve_short_shipment
  → confirm_picking_handoff
  → prepare_dispatch / confirm_dispatch
  → linked backorder + reservation reconcile
```

Statuses: `draft → gm_confirmed → approved → dispatched | cancelled`.

- One open (non-cancelled) shipment per picking request.
- Fingerprints: `picked_fingerprint` at GM confirm; `approval_fingerprint` at Accounts approve.
- Quantity or lot change after either approval fails later handoff/dispatch (`23514`) and requires cancel + recreate.
- Draft edits cannot mutate a finalized approved revision in place.
- Dispatch of draft / `gm_confirmed` / cancelled is refused.
- Full-pick path does not require a shipment document.

---

## 5. Backorder behaviour

- Reuses `public.orders` with `parent_order_id`, `originating_shipment_id`, `source='backorder'`, `fulfilment_status`.
- Same shop and godown as the parent. Cross-shop / cross-godown association is rejected by copying parent keys and by shipment/order branch checks.
- Line quantities = `ordered_cases - approved_cases` on the originating shipment.
- Unique open backorder per parent and per originating shipment. Replay returns the existing row.
- Created as `submitted` with no reservation, no supplier message, no financial settlement.
- Authorization follows existing order-management roles (Accounts verifies; GM allocates later).
- Short-shipment of a backorder **fails closed** (`23514`). Repeated partials of the same original order also fail closed (one open backorder). Do not stack remainder documents.

Original `fulfilment_status`: `open` → `partially_fulfilled` (backorder created) or `fulfilled` (no remainder). Independent of POD / `order.status`.

---

## 6. Versioned shipment document

Tables (FORCE RLS): `order_shipments`, `order_shipment_lines`, `order_shipment_lots`, `order_shipment_events`.

Each document carries: original order, acknowledged DN, picking request, revision/version, per-line quantities, lot attribution (`reservation_id` + `lot_id` + `crate_id`), GM confirm actor/time, Accounts approve actor/time, dispatch linkage, backorder linkage, audit events.

Numbering uses `shop_shipment_seq` (`SH-…`). Sequence is revoked from client roles.

This is an operational record. M7.5 owns priced invoice note, GST, and invoice numbering.

---

## 7. `confirm_dispatch` changes

Additive replacement in `20261027220000`. `verify_stock_receipt` is untouched. No second stock writer.

| Path | When | Debit |
|---|---|---|
| Full | No open shipment | Consume all active `reserved_cases` (existing semantics) |
| Partial | Open shipment `status='approved'` | Debit `approved_cases` per lot; release unused |

Shared contract preserved:

- SECURITY DEFINER, `search_path=''`
- FORCE RLS on new tables; existing dispatch/ledger RLS unchanged
- Lock order: order → DN → picking → shipment → dispatch → reservations → products → locations → lots → balances
- Idempotency: `stock_consumed` / unique transaction key `dispatch:{id}` / unique-violation replay returns original payload
- Concurrent second key after consume also returns original payload (no second debit)
- Cutover shared lock and `app_private.apply_lot_aware_stock_deltas`
- EXECUTE granted only to `authenticated`; revoked from `anon` / `public` / `service_role`
- `app_private` helpers revoked from clients

Partial-path extra gates: approved status, fingerprint match, lot still reserved, approved ≤ picked, physical availability, shop/godown match. Caller cannot choose arbitrary lots.

On any exception the whole posting rolls back, including reservation updates, ledger, backorder, and shipment status.

---

## 8. Reservation reconciliation

Performed only inside `confirm_dispatch` after locks:

```
shipped_cases = approved_cases
released_cases = reserved_cases - approved_cases
```

Active grains with `approved_cases > 0` become `consumed` with reserved/picked reduced to approved. Grains with `approved_cases = 0` become `released` **in place**: `reserved_cases` stays ≥ 1 so the M2 check is not bypassed, `status='released'` so they leave `stock_reservations_grain_active_idx`, and ATP (`active_reserved_lot_cases`) ignores them. Historical `reservation_id` / `lot_id` / `crate_id` on `order_shipment_lots` remain. No ledger debit for released-only grains. Replay does not re-release or re-debit.

Identity asserted in SQL: snapshot `reserved_cases = shipped_cases + released_cases` on shipment lots after posting. Direct SQL also asserts ATP returns the released cartons and that `reserved_cases >= 1` on the released row.

---

## 9. Authorization and RLS

New permissions:

- `shipments.view` — admin, GM, Accounts
- `shipments.manage` — admin, GM (create / GM-confirm / cancel)
- `shipments.approve` — admin, Accounts

Store Keepers see a thin shipment summary on picking payload so they can still load the task; they cannot create, confirm, or approve. Cross-godown GM is `42501`. GM cannot Accounts-approve. Accounts cannot create or GM-confirm. Revoked Accounts branch assignment cannot approve. Forged lot ids `23514`. Tampering `approved_cases` after approval makes `approval_fingerprint` stale and blocks `confirm_dispatch`. Direct `stock_ledger` / `stock_reservations` writes as `authenticated` are denied. Actor identity is `auth.uid()`.

Shipment table policies require branch assignment + permission. `app.shipment_write` GUC gates writes the same way as picking/dispatch.

---

## 10. Lock order, idempotency, failure handling

Lock order matches M3 and extends it with shipment after picking and before dispatch.

Replay keys:

- Create / GM confirm / Accounts approve: unique partial indexes on idempotency columns + `order_shipment_events`
- Dispatch: existing `confirm_idempotency_key` + `stock_consumed` + unique `stock_transactions.idempotency_key`
- Backorder: `bo-{hyphenless-uuid}` (colons are illegal in `clean_idempotency_key`)

Halfway failure across lots cannot commit: one function, one transaction. Unique-violation handling is scoped **only** to the `stock_transactions` insert (`dispatch:{id}`). A later backorder uniqueness failure aborts and rolls back stock posting; it is not treated as idempotent success. If remainder lines exist and `create_linked_backorder` returns null, dispatch raises.

Direct proofs:

- Injected `BEFORE INSERT` on `stock_ledger` after the first lot row: no net ledger, both reservations still `active`, no backorder, no negative stock.
- Pre-existing open parent backorder during `confirm_dispatch`: no stock transaction, reservations remain `active`.
- Replay after success: ledger unchanged, one backorder, released grain stays `released`.

---

## 11. UI

Picking detail: ordered / reserved / picked / proposed / approved / outstanding, GM/Accounts status, shipment number + revision, DN reference, cutover blocker, next action. GM create + confirm. Ready-for-dispatch only when there is no shortage **or** the shipment is approved.

Order detail: fulfilment badge, shipment document, Accounts approve (`lot_quantities: null` = approve GM-confirmed picked cases). Backorder linkage when present.

Dispatch prepare/detail: shipment vs full-shipment label, fulfilment status, approved total (not original ordered qty).

`short_shipment_operational` is hardcoded `false` in `picking_fulfilment_snapshot` and `SHORT_SHIPMENT_OPERATIONAL` in `src/lib/picking/rules.ts`.

---

## 12. Test results

| Suite | Result |
|---|---|
| SQL `phase_m7_3b_short_shipment.sql` | PASS, rolled back (includes zero-ship release, backorder remainder, stale approval, injected multi-lot rollback, dummy-backorder rollback, revoked Accounts, Accounts cannot GM-confirm) |
| HTTP `phase_m7_3b_http_integration.mjs` | 5/5 PASS, flags restored |
| Concurrency `phase_m7_3b_concurrency.mjs` | 6/6 PASS, flags restored |
| Vitest | 220 passed / 36 files / 0 failed / 0 skipped |
| Playwright | **96 passed / 96 run / 0 failed / 0 skipped** |
| Typecheck | PASS |
| Lint | PASS (pre-existing warnings only: TransfersPage, OpeningStockPage, DamageReportEditorPage, ProductsPage) |
| Production build | PASS |

M7.3B SQL covers: full-dispatch path (debit 2, no backorder, no shipment id), short-dispatch path (debit 1, DN preserved, original qty 2, linked backorder remainder 1, no auto-reserve, fulfilment `partially_fulfilled`), multi-lot zero-ship grain (debit 1, second grain `released` with `reserved_cases >= 1`, ATP restored, no ledger on released lot), backorder qty = ordered − dispatched, handoff-before-approval, Accounts cannot create/GM-confirm, revoked Accounts cannot approve, cross-godown GM cannot create, GM cannot approve, forged lot id, stale approval after tamper, competing second shipment, dummy parent backorder rolls back posting, injected second-lot ledger failure rolls back, approve/dispatch replay, duplicate backorder, reservation identity, backorder-of-backorder fail-closed, pre-cutover fail-closed, no negative stock, direct ledger/reservation writes denied.

M7.3B HTTP covers: Accounts cannot create, Accounts cannot GM-confirm, GM cannot approve, GM confirm + Accounts approve over PostgREST, partial `confirm_dispatch` deducts once and links a backorder.

M7.3B concurrency covers:

- Concurrent Accounts approve (one winner)
- Concurrent `confirm_dispatch` (one `posted_transaction_id`, ledger −1)
- Dispatch replay (no double post, one backorder)
- Concurrent `create_short_shipment` (one open document)
- `cancel_picking_request` racing `confirm_dispatch` after handoff (exactly one winner; ready-for-dispatch cannot be cancelled)

Backorder quantity derivation: `order_shipment_lines.ordered_cases - approved_cases`, asserted equal to original ordered minus `sum(shipped_cases)`. Unique open backorder per parent and per originating shipment. Short-shipment of a backorder is refused server-side.

Regressions re-run in final verification (local, rollback or flag restore):

- M7.3A SQL / HTTP 7/7 / concurrency 5/5 PASS
- M2 SQL / HTTP 5 PASS
- M3 SQL / HTTP 9 PASS (full confirm_dispatch consume + replay + POD)
- M7.2 SQL / HTTP 7/7 PASS

Disposable SKU prefix `m73%` already covered `m73b%`. E2E/HTTP/concurrency `finally` deletes shipment rows before reservations and restores flags.

---

## 13. Remaining limitations

- Controlled short-shipment is implemented but **not** live-operational until lot cutover flags are approved.
- Backorder-of-backorder and repeated partials of the same original order fail closed.
- Verify remains non-reserving (TOCTOU). Allocation is the authority.
- Delivery POD still applies to the dispatch document, not line-level original-order close.
- Failed-delivery return stock, vehicle master, tax invoicing, payments, and TallyPrime are out of scope.
- Clean-database migration replay was not independently tested in this phase.

---

## 14. M7.4 handoff

M7.4 should assume:

- DN acknowledgement remains mandatory before allocation.
- Full-pick handoff still works without a shipment document.
- Short-pick handoff requires an Accounts-approved shipment whose fingerprints still match.
- `confirm_dispatch` posts reserved_cases on the full path and approved lots on the partial path.
- Original orders may be `partially_fulfilled` with an outstanding backorder; POD on the partial dispatch does not fulfil the original.
- Vehicle assignment (D2) is the next owner-gated operational gap. Do not treat it as a stock writer.
- Do not start invoice numbering (D3) or return-stock posting (D5) without a separate owner decision.

---

## 15. Cutover blockers

Operational flags remain false. `picking_fulfilment_snapshot.short_shipment_operational` is always `false`. UI next-action copy states that stock deduction stays blocked until lot cutover even after Accounts approval.

Do not flip `damage.stock_hold_ready`, `stock.lots.dual_write_enabled`, or `stock.lots.aggregate_only_blocked` outside disposable replica DML that restores them.
