# M7.3 — Order-to-picking integration and controlled short-shipment

Local-only implementation after M7.2. This phase reuses the M2 picking engine, M3 dispatch foundation, and M7.2 DN acknowledgement gate. It does **not** add vehicles, invoices, a return stock writer, TallyPrime, payments, cloud migration, Netlify deploy, Git commit, or feature-flag activation.

**Development completion is not operational activation.** Lot cutover flags stay false.

Starting HEAD: `cd8cb1986aeef435171ac1a08b40f9b2b52f209d`  
`feat(m7.2): align order ATP and enforce DN acknowledgement before picking` on `main`.

Flags at start and end (operational values):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`

Owner decisions honoured: D1 (DN ack before picking), D6 (ATP aligned with reservations/quarantine/picking eligibility). D4 is approved **in principle** only. Dispatch-accepted short-shipment is **not** implemented.

---

## 1. Existing contract analysis

Lifecycle already enforced by trusted RPCs unless noted:

| Transition | Authority | Notes |
|---|---|---|
| Order created → submitted → verified | `create_order` / `submit_order` / `verify_order` | Verify uses picking-eligible ATP (M7.2). Does not reserve. |
| DN generated → sent → acknowledged | existing DN RPCs | Unique open (non-voided) DN. Acknowledged cannot be voided. |
| Picking allocation | `preview_order_allocation` / `reserve_order_allocation` | Sole allocation engine. Full-line FEFO/FIFO. D1 ack required. |
| Pick confirmation | `confirm_picking_quantity` / `report_picking_shortage` / `complete_picking` | Pick may be ≤ reserved. Shortage reduces/releases reserved. No ledger write. |
| Handoff | `confirm_picking_handoff` | Status only. M7.3 now refuses shortage exceptions. |
| Dispatch | `prepare_dispatch` / `confirm_dispatch` | `confirm_dispatch` remains the sole order-fulfilment stock writer and consumes **reserved_cases**. `assert_dispatch_handoff_ready` still requires reserved == ordered and picked == reserved. |
| Delivery / POD | existing dispatch delivery RPCs | Whole-document. Failed delivery does not restock (D5). |

Quantity fields:

| Label | Source | Mutable by picking? |
|---|---|---|
| A. Original ordered quantity | `order_lines.requested_cases` | No |
| B. Requested DN quantity | DN line snapshot of the order | Paperwork; voided rows remain |
| C. Allocated quantity | `stock_reservations.reserved_cases` (active) | Full-line at reserve; shortage may reduce/release |
| D. Picked quantity | `stock_reservations.picked_cases` | ≤ reserved |
| E. Approved shipped quantity | none distinct from reserved | `confirm_dispatch` posts reserved |
| F. Unfulfilled quantity | none (no remaining-order / backorder column) | Not tracked as a first-class field |
| G. Reservation release | shortage / cancel picking | Must not become a stock debit |
| H. Delivery reconciliation | POD on the dispatch document | Not line-level short-ship |

UI-only surfaces (queue, allocate button, next-action copy) are not authorization. Backend RPCs remain the gate.

---

## 2. Implemented picking improvements

- Read-only fulfilment snapshot on `get_picking_request`, `list_picking_requests`, and `get_order` (`ordered` / `allocated` / `picked` / `remaining` / `shortfall` / `has_shortage`).
- `get_order` also returns `picking_cutover` so verified orders can show the dual-write blocker without implying reserved stock.
- Queue rows show DN status and fill quantities. Pending allocation still requires an acknowledged DN and no open picking request.
- Order and picking screens show next permitted action. Copy states that verification does not reserve and that short-shipment is not operational.
- Shortage may still be recorded and picking may complete. GM handoff is refused. Cancel-and-reallocate remains the recovery path.
- `confirm_dispatch` posting, `verify_stock_receipt`, reservation-release semantics, and original order/DN quantities are unchanged.

---

## 3. DN enforcement evidence

Inspected entry points (no second picking engine):

- `preview_order_allocation` — ineligible until `status='acknowledged'`
- `reserve_order_allocation` — `23514` until acknowledged
- `list_picking_requests('pending_allocation')` — verified + acknowledged + no open picking

Voided / stale DN:

- Unique open DN excludes `voided`. Historical voided rows remain.
- After void, reserve still requires a new handshake. Tests cover sent → void → reserve denied → replacement ack → reserve allowed.
- Acknowledged DN cannot be voided (existing contract). Order cancel after ack is refused.

Client buttons are not the gate.

---

## 4. Short-shipment feasibility

A warehouse short pick is already possible: `confirm_picking_quantity` may pick less; `report_picking_shortage` reduces or releases reserved; `complete_picking` can succeed when picked == remaining reserved.

That path is **not** a dispatch-accepted short shipment. `assert_dispatch_handoff_ready` still requires `sum(active reserved) == order requested` and refuses shortage exceptions. `confirm_dispatch` still posts `reserved_cases`.

Implementing operational short-shipment would require one or more STOP-list changes:

- Changing `confirm_dispatch` stock posting (picked vs reserved vs original ordered)
- A remaining-order / backorder policy
- Reinterpreting DN quantities vs shipped quantities
- An approval role
- Automatic cancel of unfulfilled qty, automatic credits, or a new stock writer

None of those were implemented. Compatible slice only: fail closed at `confirm_picking_handoff` when a shortage exception exists, with cancel-and-reallocate recovery. Damage loading-conversion is not treated as a shortage exception, so that existing M5 path is not blocked by this gate.

---

## 5. Required owner decisions

D4 remains a business direction. Before any dispatch-accepted short-ship work:

1. May `confirm_dispatch` debit picked / reduced reserved instead of the original reserved quantity? That is a posting-semantics change.
2. Unfulfilled remainder: leave the order verified, reduce original lines, or split a backorder?
3. Does the acknowledged DN stay at original qty, or is a shipped-qty snapshot required without rewriting history?
4. Who approves a short shipment? Existing GM / Accounts permissions, or a new role?
5. Reservation release at short-handoff vs cancel-picking-only? Release must not cause stock loss or double consumption.

Do not implement speculative answers to these.

---

## 6. Stock integrity

- FEFO/FIFO, lot eligibility, quarantine, damage holds, case-only, and cross-godown isolation are unchanged M2/M3/M5/M7.2 rules.
- Picking does not post `stock_ledger`. Full-pick handoff SQL asserts no non-opening fulfilment ledger rows.
- `confirm_dispatch` remains the sole order-fulfilment stock writer.
- Shortage releases/reduces reservations without a debit. Cancel picking releases active holds. Reallocate restores a full-line reserve.
- Idempotent reserve and handoff replay covered. No negative stock. No second stock writer.
- Operational flags stay false. Disposable tests replica-enable dual-write and restore flags; leftover `m73%` lot-attributed ledger is wiped in HTTP/concurrency/e2e `finally`.

---

## 7. Concurrency

`phase_m7_3_concurrency.mjs` (local Docker, flags restored):

- Allocation against a voided DN refused
- Allocation after acknowledgement permitted
- Concurrent reservation of one acknowledged order: one winner (order/picking locks)
- Reservation replay of the winner's idempotency key
- Second order cannot allocate the same reserved stock

Established lock order preserved: order `FOR UPDATE`, then DN, then picking/lots. Handoff lock order was not changed (cutover share, then picking row) so it does not invert cancel_order.

---

## 8. Test results

| Suite | Result |
|---|---|
| SQL `phase_m7_3_picking_integration.sql` | PASS, rolled back |
| HTTP `phase_m7_3_http_integration.mjs` | 7/7 PASS, flags restored |
| Concurrency `phase_m7_3_concurrency.mjs` | 5/5 PASS, flags restored |
| Vitest | 217/217 PASS |
| Playwright | **96 passed / 96 run / 0 failed / 0 skipped** |
| Typecheck | PASS |
| Lint | PASS (pre-existing warnings only) |
| Production build | PASS |

Regressions (local, rollback or flag restore):

- M2 SQL `phase_m2_fefo_fifo_picking.sql` PASS
- M3 SQL `phase_m3_dispatch_delivery.sql` PASS
- M5.3 SQL `phase_m5_3_damage_stock_isolation.sql` PASS
- M6.6 SQL `phase_m6_6_module_closure.sql` PASS
- M7.2 SQL `phase_m7_2_order_atp_dn_handover.sql` PASS
- M2 HTTP, M3 HTTP, M7.2 HTTP PASS

Disposable SKU prefix `m73%` added to `tests/e2e/disposable-stock.ts`.

---

## 9. Remaining limitations

- Controlled short-shipment is **not** operational. UI and RPCs say so explicitly.
- Operational picking stays fail-closed until lot cutover flags are approved.
- Verify remains non-reserving (TOCTOU). Allocation is the authority.
- Shortage after complete is a dead-end at handoff until the picking request is cancelled and the full order is reallocated.
- Vehicle master (D2 / M7.4), priced invoices (D3 / M7.5), and failed-delivery return stock (D5) are out of scope.

---

## 10. M7.4 handoff

M7.4 should assume:

- DN acknowledgement remains mandatory before allocation.
- Full-pick handoff is required before dispatch. Short picks cannot be handed off.
- `confirm_dispatch` still posts reserved_cases for a full fill.
- Vehicle assignment (D2) is the next owner-gated operational gap. Do not treat it as a stock writer.
- Do not start invoice numbering (D3) or return-stock posting (D5) without a separate owner decision.
- If D4 is to become operational, resolve the five owner decisions in section 5 **before** touching `confirm_dispatch`.
