# M7.2 — Order verification, ATP, and delivery-note handover

Local-only implementation of ORD-01–04 after the M7.1 audit. This phase does **not** add vehicles, invoices, short-shipment dispatch, a return stock writer, TallyPrime, payments, cloud migration, Netlify deploy, Git commit, or feature-flag activation.

**Development completion is not operational activation.** Lot cutover flags stay false.

Starting HEAD: `8009e671f5a8666511080baf0b374d0e31961a54`  
`docs(m7.1): audit order-to-delivery BPM gaps and decisions` on `main`.

Flags at start and end (operational values):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`

Approved owner decisions honoured: D1–D7. D2/D3/D4/D5/D7 remain out of this phase.

---

## 1. ORD-01–04 implementation evidence

### ORD-01 — Order capture

Existing `create_order` / `submit_order` contract is unchanged. Salesperson, Accounts, telecalling, and enquiry sources remain. Case-only lines, shop, godown, audit, idempotency, and role grants are unchanged.

New coverage:

- SQL: salesperson and Accounts capture in `phase_m7_2_order_atp_dn_handover.sql`
- HTTP: authenticated salesperson capture
- Playwright: `tests/e2e/order-verification-dn-handover.spec.ts` (login, `/orders/new`, shop/godown/product/cases, submit)

No prices. No ownership-rule changes. No ORD-01 defect required a contract change.

### ORD-02 — Picking-eligible ATP

`verify_order` and `check_order_availability` no longer use gross on-hand as ATP.

Authoritative source: `app_private.picking_line_plan` + `app_private.picking_cutover_blockers` + `app_private.picking_available_cases` (reservations, quarantine crates, damage holds, expiry/FEFO/FIFO, unclassified lots).

Gross on-hand (`app_private.order_line_on_hand_cases`) is informational only.

Rule A is unchanged: any shortfall or ineligible line raises `P0001` `insufficient stock` and the order stays `submitted`. Verify does **not** reserve. `reserve_order_allocation` remains the TOCTOU authority.

### ORD-03 — Delivery note contract

Existing DN create / generate / send / void / print path is reused. No stock posting, no prices, no invoices. SQL asserts ledger quantity is unchanged across create/generate/send.

### ORD-04 / D1 — Mandatory GM acknowledgement

Existing `acknowledge_delivery_note` is the handover step. Replay re-checks permission and view. New acks lock the order then the DN, then call `assert_delivery_note_acknowledger` (permission, assignment, `assert_operational_active_branch`).

Picking is blocked until `delivery_notes.status = 'acknowledged'` at:

- `preview_order_allocation` (blocker, `eligible=false`)
- `reserve_order_allocation` (`23514`)
- `list_picking_requests('pending_allocation')` (verified + acknowledged only)

Frontend buttons are not the gate.

---

## 2. ATP formula and source of truth

`app_private.order_line_availability(order, branch)` returns:

```
{
  reserves_stock: false,
  picking_operational: <no cutover blockers>,
  cutover_blockers: [...],
  lines: [{
    product_id,
    requested_cases,
    on_hand_cases,      -- informational, excludes quarantine crates
    eligible_cases,     -- picking_line_plan.allocated_cases (coverable portion of this request)
    shortfall_cases,
    eligible,
    blockers
  }]
}
```

When cutover blockers exist (current operational flags): `eligible_cases=0`, `shortfall_cases=requested_cases`, `eligible=false`. Gross stock is not treated as pickable FEFO/FIFO.

When operational: `picking_available_cases` = lot×crate on-hand minus active reservations minus active damage holds, or 0 if the crate is quarantine. `picking_line_plan` applies expiry policy and allocates up to `requested_cases`.

---

## 3. Pre-cutover behavior

Flags remain false. Dual-write is not enabled. Verify fail-closes. Preview/reserve stay ineligible from existing cutover blockers **and** from the D1 DN gate.

Disposable tests may replica-enable dual-write inside a transaction or `finally` restore. That is not operational activation.

---

## 4. DN acknowledgement lifecycle

Unchanged statuses: `draft → generated → sent → acknowledged` (`voided` terminal).

Handshake for picking: Accounts create/generate/send, authorized GM acknowledge. Acknowledgement records `acknowledged_by = auth.uid()` and `acknowledged_at = clock_timestamp()`. Duplicate key replay is idempotent and re-checks authorization. Cross-godown, Accounts, Store Keeper, and revoked assignment are denied (`42501`). Inactive godown: assigned GM cannot work there (`can_work_at_branch` requires `is_active`); Admin inactive path remains `23514` via `assert_operational_active_branch` (M4.1).

---

## 5. Backend authorization

FORCE RLS retained. Trusted `SECURITY DEFINER` RPCs. `EXECUTE` granted to `authenticated` only on the public RPCs; `app_private` helpers revoked from `public/anon/authenticated/service_role`. No direct table writes. GM is not granted invoice or Accounts permissions. Accounts is not granted receiving. Monitor-only is not expanded.

---

## 6. Concurrency findings

Verify is non-reserving. Two 5-case orders against 5 eligible cases can both verify (TOCTOU). Documented; allocation is the authority.

Concurrent acknowledgement of the same sent DN: one winner (order then DN row locks). Concurrent reserve of two verified+acked orders against the same 5 cases: one winner.

Lock order: order `FOR UPDATE`, then DN, then lot grains. Matches cancel/picking. No second stock writer.

---

## 7. Stock-integrity invariants

- Verify does not insert reservations or ledger rows.
- DN paperwork does not write `stock_ledger`.
- `verify_stock_receipt` and `confirm_dispatch` posting were not modified.
- No new stock writer. No return writer. No short-ship mutation.
- Replica flag flips in tests are restored; leftover lot-attributed ledger from HTTP/concurrency is wiped in those suites’ `finally` so Rule C does not poison later tests.

---

## 8. Test results

Required 16 scenarios are covered by SQL, HTTP, concurrency, Vitest, and Playwright together.

**Final full Playwright** (this verification, current fixtures, Chromium, `http://127.0.0.1:4173`, `--mode m1s2`, 1 worker):

- **92 passed / 92 run / 0 failed / 0 skipped**
- Includes `tests/e2e/order-verification-dn-handover.spec.ts` (4): unauthenticated redirect, salesperson capture, fail-closed verify, GM acknowledgement.

Earlier implementation first-pass of the same suite was 88 passed, 1 failed, 3 not run, caused by `SET ROLE authenticated` still being in effect when the M7.2 seed tried `set session_replication_role = replica`. The fixture now `reset role` to postgres before replica flag DML, then restores JWT + `SET ROLE authenticated` for trusted RPCs. RLS, authentication, and cutover gates were not weakened.

M7.2 HTTP/concurrency/`afterAll` restore the three operational flags to false and delete disposable `m72%` lot-attributed ledger rows.

---

## 9. Remaining limitations

- Operational ATP is fail-closed until lot cutover flags are approved and enabled.
- Verify TOCTOU: two verifications can succeed against the same stock; only one allocation can.
- Vehicle master (D2 / M7.4), priced invoices (D3 / M7.5), controlled short-ship (D4 / M7.3–7.4), and return stock posting (D5) are not implemented.
- `eligible_cases` is the coverable portion of the current request (`allocated_cases`), not warehouse-total available.
- Inactive assigned GM acknowledgement is denied as `42501` (`can_work_at_branch` requires `is_active`), not M4.1 Admin `23514`. The operational refusal still holds.

---

## 10. M7.3 handoff

M7.3 should assume:

- Picking requires an acknowledged DN at every trusted entry point.
- ATP is picking-aligned; verify does not reserve.
- Short-shipment, vehicle assignment, and invoice numbering remain owner-gated.
- Do not treat DN acknowledgement as stock movement or customer POD (`acknowledge_dispatch_delivery` is distinct).
