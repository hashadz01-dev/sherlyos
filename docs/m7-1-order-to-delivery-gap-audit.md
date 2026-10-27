# M7.1 — Order-to-delivery BPM gap audit

Audit and planning only. No migrations, stock-writer changes, test-fixture mutations, commits, cloud work, or flag activation.

**M6.6 is committed.** Starting HEAD: `dec290afa3681f56d84141d0e7aafe1903456240`  
`test(m6.6): complete stock refill end-to-end QA and module closure` on `main`. Working tree was clean before this document.

Source of BPM statements: `reference/Sherlys_Distribution_Agents_BPM.pdf` v1.0, pages 2–3 and 8 (Branch 01 register and process-flow). Related registers: Branch 02–05 pages 4–7 and 9–12.

Flags at audit time (read-only):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`

---

## 1. Exact ORD-01–09 traceability

Statuses used below:

- **COMPLETE** — code, permissions, and tests exist for the BPM step as currently approved.
- **PARTIAL** — a real workflow exists but does not cover the BPM step, or it is unusable under current flags.
- **MISSING** — no table/RPC/UI for the BPM artefact.
- **BLOCKED BY OWNER DECISION** — implementation cannot proceed without a business choice.

### ORD-01 — Order request

| Field | Finding |
| --- | --- |
| BPM | “Receive product order from shop through Salesperson, Accounts, telecalling or enquiry.” Actor: Salesperson / Accounts. |
| Input | Shop, fulfilling godown, source channel, product lines, whole cases. |
| Output | Persisted shop order. |
| UI | `/orders`, `/orders/new`, `/orders/:orderId/edit` (`src/features/orders/*`, `src/app/router.tsx`). |
| RPC | `create_order`, `set_order`, `submit_order` (`supabase/migrations/20261017120000_shop_orders.sql`). |
| Tables | `orders`, `order_lines`, `order_events`. FORCE RLS. Authenticated SELECT only. |
| Permissions | `orders.capture` (Accounts, Salesperson). Shop via `assert_order_shop`. Godown via `assert_order_branch`. |
| Audit | `created`, `lines_revised`, `submitted`. |
| Tests | `phase_4_1a/b/c_shop_orders.sql`, concurrency mjs. **No** Playwright create journey. **No** Vitest form tests. |
| Stock | Zero. |
| Status | **COMPLETE** for capture. **PARTIAL** tests (no e2e create path). Salesperson is `created_by`, not a separate order field. Telecalling/enquiry are `orders.source` values only. |

### ORD-02 — Accounts verification

| Field | Finding |
| --- | --- |
| BPM | “Verify shop request and availability; hold invalid requests for correction.” Actor: Accounts. Diagram: HOLD / CORRECTION returns the request. |
| Input | Submitted order. |
| Output | `verified` or `held` for creator correction. |
| UI | `/orders/:orderId` Verify / Hold (`OrderDetailPage.tsx`). |
| RPC | `verify_order`, `hold_order`, `check_order_availability`. Availability Rule A: any shortfall rejects verify; status stays `submitted`; no auto-hold (`docs/phase-4-1-implementation-spec.md`). |
| Permissions | `orders.verify` (Accounts only). Self-verify allowed (approved Phase 4.1). |
| Audit | `verified`, `held`. |
| Tests | `phase_4_1c_shop_orders.sql`, `phase_4_1d_inventory_concurrency.mjs`. |
| Stock | **Read-only.** `app_private.order_line_availability` sums `stock_balances.quantity` for the godown. It does **not** subtract reservations or exclude quarantine crates. Helper was not replaced after M2/M5. |
| Status | **PARTIAL**. Workflow exists. ATP is gross on-hand, so two verified orders can claim the same cases until picking. |

### ORD-03 — Delivery note

| Field | Finding |
| --- | --- |
| BPM | “Generate delivery note for approved requested products.” Actor: Accounts. Document sequence starts here. |
| Input | Verified order. |
| Output | Delivery note document. |
| UI | `/deliveries/new`, `/deliveries/:noteId`, `/deliveries/:noteId/print` (`src/features/delivery-notes/*`). |
| RPC | `create_delivery_note`, `generate_delivery_note`, `void_delivery_note` (`20261018120000`, `20261018130000`). |
| Tables | `delivery_notes`, `delivery_note_lines`, `delivery_note_events`. Quantity-only. No prices. |
| Permissions | `delivery_notes.issue` (Accounts). |
| Audit | DN events. Order status stays `verified`. |
| Tests | `phase_4_2a/b_delivery_notes.sql`. **No** Playwright DN spec. |
| Stock | Zero. Paperwork only. |
| Status | **COMPLETE** locally as quantity-only DN. Official print requires configured `company.legal_name` / `company.registered_address` (not fictional). Cloud: 4.2E deployed on development; later M2+ not deployed. |

### ORD-04 — Godown handover

| Field | Finding |
| --- | --- |
| BPM | “Pass delivery note to Godown Manager.” Actor: Accounts. |
| Input | Generated DN. |
| Output | Godown acknowledgement of the **document**, not of stock. |
| UI | Accounts Send; GM `/deliveries` inbox. |
| RPC | `send_delivery_note`, `acknowledge_delivery_note` (`20261018140000_delivery_note_handover.sql`). |
| Permissions | Issue (Accounts); `delivery_notes.acknowledge` (Godown Manager, assigned godown). |
| Tests | `phase_4_2c_delivery_notes.sql`. |
| Stock | Zero. Godown ack is **not** customer POD and **not** picking authorization. |
| Status | **PARTIAL** vs BPM sequence. DN handover exists, but picking (`reserve_order_allocation`) does **not** require an acknowledged DN. Order detail offers Allocate and Create DN as independent links (`OrderDetailPage.tsx`). |

### ORD-05 — Stock preparation (FEFO/FIFO picking)

| Field | Finding |
| --- | --- |
| BPM | “Pick goods based on expiry and first-in receipt sequence (FEFO/FIFO).” Actor: Godown Manager. Store Keeper “loading support” is persona 06, not a separate ORD id. |
| Input | Verified order (implemented); BPM implies after DN handover. |
| Output | Reserved then picked goods ready for dispatch. |
| UI | `/picking`, `/picking/allocate/:orderId`, `/picking/:requestId`, `/picking/exceptions`. |
| RPC | `preview_order_allocation`, `reserve_order_allocation`, `assign_picking_request`, `start_picking`, `confirm_picking_quantity`, `report_picking_shortage`, `complete_picking`, `confirm_picking_handoff`, `cancel_picking_request` (`20261022230000_fefo_fifo_picking.sql`). |
| Tables | `stock_picking_requests`, `stock_reservations`, `stock_picking_exceptions`, `stock_picking_events`. |
| Permissions | `picking.allocate` / `manage` (Admin, GM); `picking.execute` (Keeper if assigned). |
| Audit | Picking events. Order status stays `verified`. |
| Tests | `phase_m2_fefo_fifo_picking.sql`, `phase_m2_http_integration.mjs`, `phase_m2_concurrency.mjs`, `tests/e2e/picking.spec.ts`. |
| Stock | **Reserve only.** No ledger. Consume is M3 `confirm_dispatch`. Fail-closed unless `stock.lots.dual_write_enabled=true`. Legacy `legacy_unattributed` lots are ineligible. Quarantine crates excluded after M5 (`20261026160000`). |
| Status | **PARTIAL**. Foundation + local UI are complete. **Operationally blocked** by current flags. Dispatch rejects shortage exceptions, so warehouse short-pick cannot complete the BPM chain. Schema **not** on development cloud. |

### ORD-06 — Delivery assignment

| Field | Finding |
| --- | --- |
| BPM | “Assign vehicle and Delivery Person for the goods.” Actor: Godown Manager. Catalog text for `deliveries.assign`: “Assign a vehicle and delivery person.” |
| Input | Consumed / dispatched goods (implemented after `confirm_dispatch`). |
| Output | Named driver (and vehicle, per BPM). |
| UI | `/dispatch/:dispatchId` assignee select; `/delivery-runs`. |
| RPC | `assign_dispatch_delivery`, `list_dispatch_assignees` (`20261022240000_dispatch_delivery.sql`). |
| Permissions | `deliveries.assign` (GM); `deliveries.execute` (assigned Delivery Person). |
| Tests | M3 SQL/HTTP/e2e assign path. |
| Stock | Zero. |
| Status | **PARTIAL**. Delivery Person assignment is complete. **MISSING** vehicle master / `vehicle_id`. M3 deferred this explicitly. |

### ORD-07 — Invoice note

| Field | Finding |
| --- | --- |
| BPM | “Prepare invoice note based on actual loaded goods and send to Accounts.” Actor: Godown Manager. |
| Permission catalog | `invoice_notes.prepare` granted to Godown Manager. **Unused.** |
| UI / RPC / tables | **None.** |
| Stock | N/A. |
| Status | **MISSING**. Phase 4.1 approved “quantity-only, no prices” and deferred this step. Loaded quantity today lives on picking reservations / dispatch, not on an invoice-note document. |

### ORD-08 — Final invoice

| Field | Finding |
| --- | --- |
| BPM | “Accounts creates, signs/seals and hands final invoice to Delivery Person.” Actor: Accounts. Diagram: Delivery note → invoice note → signed/sealed final invoice. |
| Permission catalog | `invoices.issue` granted to Accounts. **Unused.** |
| UI / RPC / tables | **None.** No amounts, tax, signature storage, or handover event. |
| Status | **MISSING**. Blocked until the owner decides whether invoices stay quantity-only or introduce prices. |

### ORD-09 — Shop delivery

| Field | Finding |
| --- | --- |
| BPM | “Deliver requested products correctly to shops and record outcome.” Actor: Delivery Person. Persona 05: with “the relevant invoice/documentation.” |
| Input | Assigned consumed dispatch; BPM also implies the signed invoice. |
| Output | Delivery outcome. |
| UI | `/delivery-runs`, `/dispatch/:dispatchId`. |
| RPC | `start_dispatch_delivery`, `acknowledge_dispatch_delivery` (recipient name + timestamp + notes), `report_dispatch_delivery_exception`. |
| Audit | `in_transit`, `delivered`, `exception_recorded`. `physical_return_status = pending_verification` on fail. |
| Tests | `phase_m3_dispatch_delivery.sql`, `tests/e2e/dispatch.spec.ts` (POD and fail without restock). |
| Stock | Confirm already posted `DISPATCH`. Fail does **not** restock. No return-receiving RPC. |
| Status | **PARTIAL**. Physical POD/fail exist. Missing: invoice-in-hand, signature/evidence, partial delivery, restock of undelivered goods. Related: DMG-05 transit damage is a separate M5 path. |

---

## 2. Current implementation evidence (reusable)

Do **not** rebuild these.

**Orders (Phase 4.1, development-cloud deployed):** capture, edit, submit, hold, verify Rule A, cancel with DN/picking/dispatch guards, shop assignment in masters, case-only lines, append-only `order_events`.

**Delivery notes (Phase 4.2, development-cloud deployed):** one open DN per verified order; draft → generated → sent → acknowledged; void-before-cancel; print gated on company identity.

**Picking (M2, local only):** order-linked sidecar; FEFO/FIFO; reservations; concurrent reserve serialization; shortage exception rows; handoff `ready_for_dispatch`.

**Dispatch/delivery (M3, local only):** `confirm_dispatch` sole order-fulfilment stock writer (`DISPATCH`, consume once); assign driver; in-transit; POD; failed delivery without restock; lock-order aligned with transfer/adjustment.

**Cross-module:** inactive-godown hardening (`20261026120000`); quarantine exclusion from picking plan; damage shop-return (DMG-06) is **not** dispatch restock.

---

## 3. Missing functionality

### Order workflows

- Playwright/Vitest for create → submit → hold → resubmit → verify → cancel.
- Per-order salesperson distinct from `created_by`.
- Customer master distinct from shop (BPM uses “shop”).
- Prices, credit, tax.
- Verify ATP aligned with picking-eligible stock.
- Order status does not track picking/dispatch/delivery (sidecar by design).

### Picking workflows

- Operational use while dual-write is false (fail-closed, **by design**).
- Cloud schema apply of `20261022230000`.
- First-class partial fulfilment / short-ship that dispatch will accept.
- `blocked` picking status is in the check constraint but no RPC sets it.
- DN-required-before-allocate (if the owner adopts BPM sequence).
- Assignee directory picker (raw profile UUID today).

### Dispatch / delivery workflows

- Vehicle master and assignment.
- Partial delivery.
- Signature / photo POD.
- Return-to-godown restock after failed delivery.
- Invoice documents on the run (ORD-07/08).
- HTTP coverage of fail-delivery (e2e exists; M3 HTTP does not assert fail).

### Documents

- Invoice note table/RPC/UI.
- Signed/sealed final invoice table/RPC/UI.
- Handover of invoice to Delivery Person.

---

## 4. Stock integrity risks

**Critical / high (do not change contracts in this phase):**

1. **Verify vs pick ATP mismatch.** `verify_order` uses gross `stock_balances`. Picking uses lot×crate minus active reservations, excluding quarantine and ineligible lots. Two orders can both verify; only one can reserve. Documented Phase 4.1 race; still true.
2. **ORD-05 unusable until lot cutover.** `picking_cutover_blockers()` refuses preview/reserve unless `stock.lots.dual_write_enabled=true`. Default false. Development inventory is unclassified (M1-S1 runbook). Enabling flags is **not** an M7 coding task.
3. **Failed delivery leaves deducted stock.** `report_dispatch_delivery_exception` sets `stock_restored=false`. No restock writer. Physical goods may return while ledger stays dispatched. Recovery today is later receiving/adjustment/damage — none of those is “undelivered order restock.”
4. **Shortage dead-end.** Warehouse may pick less. `assert_dispatch_handoff_ready` then rejects shortage exceptions and quantity mismatch. Operator must cancel-and-reallocate. No approved short-ship.
5. **Paper DN vs physical consume.** Creating/acking a DN never reserves or posts. Confirming dispatch without a DN is allowed (`preview_dispatch` treats DN as informational). Two documents can disagree.

**Mitigated:**

- Picking never posts ledger.
- `confirm_dispatch` consume-then-post in one transaction; unique `stock_consumed`; replay after lost HTTP.
- Reservation triggers block transfer/adjustment from eating held grain.
- Client DML denied (FORCE RLS + write GUCs).
- Delivery-note RPCs do not debit.

**Stock writers that must stay untouched in M7 unless a later phase explicitly authorizes a new one:** `verify_stock_receipt`, `confirm_dispatch`, `post_crate_transfer`, `post_stock_adjustment`, opening-stock posters, damage hold consume/write-off (gated). **Do not** make DN or invoice RPCs post stock.

---

## 5. Security risks

| Risk | Finding |
| --- | --- |
| Privilege escalation | Order/DN/picking/dispatch mutations are SECURITY DEFINER with permission + branch checks. Admin has `operations.monitor` only for orders (cannot capture/verify). Matches BPM Admin persona. |
| Cross-godown | `can_work_at_branch` / `can_view_order` / picking and dispatch view helpers. SQL suites cover denials. |
| Inactive godown | Operational writes hardened in `20261026120000`. Historical reads remain. Consumed dispatch may still complete POD/fail after deactivation. |
| Driver isolation | `deliveries.execute` sees only `assigned_to = auth.uid()`. Queue `/dispatch` does not use execute. |
| Idempotency after revoke | Order/DN/picking/dispatch keys re-check current auth on completed replay (same pattern as M6). Not re-proven in a dedicated M7 suite. |
| Invoice permissions | `invoices.issue` / `invoice_notes.prepare` exist with **no** RPC. Harmless until wired; do not grant extra roles “for convenience.” |
| Cloud drift | M2/M3/M5/M6 local-only. Development cloud is behind. Do not treat cloud JWT tests as covering picking/dispatch. |

No privilege-escalation blocker requiring an emergency patch was found in this audit. The ATP mismatch and failed-delivery restock gap are integrity/process issues, not open DML.

---

## 6. Financial and Accounts handoff

BPM page 2: Accounts “verifies shop orders, prepares billing documentation.” Page 8 document sequence: delivery note → invoice note → signed/sealed final invoice. Delivery Person delivers “with the relevant invoice/documentation.”

The PDF does **not** mention TallyPrime, payment collection, credit sales, outstanding balances, or bank reconciliation.

| Topic | Classification |
| --- | --- |
| Delivery note (ORD-03/04) | **REQUIRED BY BPM** — **ALREADY IMPLEMENTED** (quantity-only). |
| Invoice note from loaded goods (ORD-07) | **REQUIRED BY BPM** — **NOT IN CURRENT APPROVED SCOPE** (deferred Phase 4.1 decision 11 / 4.2). |
| Signed/sealed final invoice (ORD-08) | **REQUIRED BY BPM** — **NOT IN CURRENT APPROVED SCOPE**. |
| Prices / tax / discounts | **OWNER DECISION REQUIRED**. Phase 4.1 forbade them; ORD-08 cannot be a real invoice without a pricing rule. |
| Payment collection / credit / outstanding | **NOT IN CURRENT APPROVED SCOPE**. Not in the PDF five-module register. |
| TallyPrime integration | **NOT IN CURRENT APPROVED SCOPE**. Not in the PDF. Do not add in M7 unless the owner explicitly expands scope. |
| Accounts refill financials / supplier credits | M6 remaining limitation, not Branch 01. |

Do **not** automatically add a full accounting system to M7.

---

## 7. Required owner decisions

Only questions that change design. Already answered in M1–M6 are not repeated (case unit, shop as customer, Rule A, DN paperwork not stock, picking sidecar, consume-once at `confirm_dispatch`, flags stay false until named cutover).

| # | Business question | Current behavior | Options | Recommendation | Stock / security / workflow | Blocks implementation? |
| --- | --- | --- | --- | --- | --- | --- |
| D1 | Must an acknowledged delivery note exist before picking allocation? | Independent tracks. | (a) Keep independent. (b) Require generated/sent/acknowledged DN before `reserve_order_allocation`. | **(b)** to match BPM ORD-03→05, with a fail-closed RPC guard. | Tightens process; no new stock writer. | **Yes** for M7.3 coupling. |
| D2 | Is a vehicle master mandatory for ORD-06? | Driver only. | (a) Defer vehicle (M3). (b) Minimal vehicle table + assignment. (c) Free-text vehicle reference like refill dispatch. | **(c)** if operations need a label now; **(b)** if they need a reusable fleet. Do not invent GPS/ telematics. | No stock. | **Yes** for claiming ORD-06 complete. |
| D3 | Are invoice note and final invoice quantity-only, or must they carry prices? | No invoice documents. Products have no price. | (a) Quantity-only loaded-goods note + unsigned PDF. (b) Add product/shop prices and tax. (c) Keep invoices out of SherlysOS (external Tally). | **Ask the owner.** BPM requires the documents; Phase 4.1 forbade prices. **(c)** is only valid if the owner accepts that ORD-07/08 stay outside SherlysOS. | (b) is a new financial module, not a stock writer. | **Yes** for M7.5. |
| D4 | May a short pick / partial delivery fulfil an order? | Full-line reserve; dispatch rejects shortage; POD is whole-document. | (a) Keep full-fill only. (b) Reduce remaining order and allow short dispatch. (c) Split remaining to a new order. | **(a)** until sales operations define short-ship. Matches Phase 4.1 decision 9. | (b)/(c) touch reservation consume and possibly a new writer. | **Yes** if M7 tries to “finish” shortage. |
| D5 | What happens to stock on failed delivery? | Deducted; `pending_verification`; no restock. | (a) Keep fail-closed; operator uses adjustment/receiving. (b) Dedicated return-receipt posting accepted cases. (c) Route through DMG-05 then restock. | **(b)** or **(c)** need explicit stock-writer authorization. Do not silently restock in `report_dispatch_delivery_exception`. | High integrity risk. | **Yes** for ORD-09 closure. **Stop for owner** if a new writer is chosen. |
| D6 | Should `verify_order` use picking-eligible ATP? | Gross on-hand. | (a) Keep Rule A as-is. (b) Subtract reservations and quarantine. (c) Require dual-write and use lot ATP. | **(b)** is compatible with flags false. **(c)** waits on M1 cutover. | Reduces double-verify; does not reserve. | **No** for other phases; **yes** if M7.2 includes ATP. |
| D7 | TallyPrime / payments / credit ledgers in M7? | None. | In or out. | **Out of M7.** Not in the PDF five modules. | Scope explosion. | Only if the owner forces them in. |

---

## 8. Recommended M7 phase breakdown

Do not rebuild M2/M3. Do not flip cutover flags. Do not implement D5 restock without a later authorized writer.

### M7.2 — Order capture, verify ATP, and document-sequence coupling

- **Scope:** Playwright/HTTP for ORD-01/02; optional ATP change if D6=(b); RPC guard if D1=(b); do not add prices.
- **Dependencies:** D1, D6. Phase 4.1/4.2 remain.
- **Modules:** `orders`, `delivery_notes`, possibly `order_line_availability`.
- **Migrations:** Forward-only only if D1/D6 require guards. No stock-writer edits.
- **Security:** Unchanged grants. Tests for cross-godown and inactive writes.
- **Stock:** Read-only ATP; still no reserve at verify.
- **Tests:** New Playwright `orders.spec.ts`; SQL Rule A regression; DN still zero stock.
- **Acceptance:** Create→verify→DN send/ack still works; if D1=(b), allocate refused without required DN state.
- **Complexity:** Medium.

### M7.3 — Order-to-picking integration (no flag activation)

- **Scope:** UI/RPC coupling from D1; shortage operator path (cancel-and-reallocate copy); do **not** enable dual-write; do **not** implement short-ship unless D4≠(a).
- **Dependencies:** M7.2 if D1=(b). M2 already implemented.
- **Modules:** picking, orders detail links.
- **Migrations:** Guard only if D1 requires it.
- **Risks:** Operators will still be blocked until lot cutover. Document that as remaining, not as an M7.3 defect.
- **Tests:** Existing M2 suites plus DN-before-allocate if approved.
- **Acceptance:** Verified order can be allocated when (and only when) policy allows; flags remain false; picking still posts zero stock.
- **Complexity:** Low–medium (policy), high if D4 short-ship is forced.

### M7.4 — Dispatch and delivery completion

- **Scope:** Vehicle if D2≠defer; POD fields if owner wants evidence; fail-delivery UX; **no restock writer** unless D5 is separately approved.
- **Dependencies:** M3. D2, D5.
- **Modules:** `stock_dispatch_*`, maybe `vehicles`.
- **Migrations:** Vehicle table if D2=(b); none if D2=(c) column on dispatch.
- **Stock:** `confirm_dispatch` unchanged. Fail still no restock unless a later phase.
- **Tests:** Extend `phase_m3_*` and `dispatch.spec.ts`.
- **Acceptance:** Driver assignment + POD/fail remain exact-once consume; vehicle recorded if approved.
- **Complexity:** Medium (reference) / medium-high (vehicle master).

### M7.5 — Invoice note and final invoice (ORD-07/08)

- **Scope:** Only after D3. Godown invoice note from **loaded** (picked/consumed) quantities; Accounts sign/seal/handover. Reuse DN print identity pattern. No Tally. No payments.
- **Dependencies:** D3. Loaded quantities exist only after M2/M3; operational invoices also need lot cutover to pick in production.
- **Modules:** New invoice tables; `invoice_notes.prepare`; `invoices.issue`.
- **Migrations:** New. **No** ledger posting.
- **Risks:** Permission wiring; print identity; do not let invoice RPCs deduct stock.
- **Tests:** SQL RLS/grants; zero stock; Playwright print/handover; unauthorized GM cannot issue final invoice.
- **Acceptance:** Document sequence DN → invoice note → final invoice is auditable; Delivery Person can see that a final invoice was handed over.
- **Complexity:** High if prices; medium if quantity-only documents.

### M7.6 — Order-to-delivery end-to-end QA and closure

- **Scope:** Disposable local journey ORD-01→09 as far as flags allow; concurrency; RLS; no cloud; no flag flip.
- **Dependencies:** M7.2–M7.5 as approved.
- **Acceptance:** Same closure standard as M6.6: development complete ≠ production ready.
- **Complexity:** Medium.

If D3=(c) (invoices stay outside SherlysOS), skip M7.5 and record ORD-07/08 as owner-accepted external.

---

## 9. Remaining system-wide scope (is M7 the last feature phase?)

**No.** M7 can close **Branch 01 documents and delivery policy**, but it cannot close the ERP.

### A. Mandatory core BPM gaps (still after a full M7)

| Gap | Branch | Notes |
| --- | --- | --- |
| ORD-07/08 invoices | 01 | Unless D3=(c). |
| Vehicle if D2 requires it | 01 | |
| Failed-delivery restock | 01 / 02 | Needs writer authorization. |
| Operational FEFO picking | 01 / M1 | Dual-write + classification + seed/attribution. |
| DMG-03/04/06 isolation submit | 02 | Gated on `damage.stock_hold_ready`. |
| Isolated empty-DB migration replay | all | M6.6 cloud-migration blocker. |

Branch 03 receiving and Branch 05 refill are **development-complete** locally. Branch 04 daily verification exists locally. None of those are production-ready.

### B. Deferred owner-approved enhancements

- Automated refill reorder levels.
- Supplier messaging / credits.
- Damage companion actions (Repacking, Inspection, Other).
- Over-delivery exception on refill.
- Request auto-close.
- Payments, credit sales, TallyPrime.

### C. Production-readiness tasks for M8

1. Isolated empty-catalog migration replay.
2. Named-environment backups.
3. Development-cloud then production apply of pending local migrations (M2+).
4. Product classification, M1 seed/attribution, dual-write enablement (runbook `docs/m1-s1-cutover-runbook.md`).
5. Damage isolation enablement (`docs/m5-5-damage-management-module-closure.md` §14).
6. Company identity for official prints.
7. Netlify production deploy of the matching frontend.
8. Flag remains false until those named windows: `damage.stock_hold_ready`, `stock.lots.dual_write_enabled`, `stock.lots.aggregate_only_blocked`.

### D. Optional future improvements

- Signature/photo POD storage.
- Salesperson field on the order.
- Order status mirroring of sidecar progress.
- Assignee pickers.
- Playwright for delivery-note happy path (currently SQL-only).
- `get_picking_handoff` still advertises pre-dispatch consume state after M3.

---

## 10. M8 handoff considerations

M7 must not:

- Flip cutover or damage flags.
- Post stock from invoice or DN RPCs.
- Treat local picking e2e (tests force dual-write via replica DML) as production picking.
- Claim Branch 01 production-ready because UI routes exist.

M8 is operations cutover + cloud, not a place to silently invent invoices or restock.

---

## 11. Execution record

- No application code changed except this document.
- No migrations.
- No stock-writer modifications.
- No test fixture mutations.
- No commit, push, cloud migration, deploy, or flag activation.

---

**Verdict for owner review:** M7.1 GAP AUDIT COMPLETE — OWNER DECISIONS REQUIRED (D1–D7 before sequencing M7.2+).
