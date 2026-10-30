# M8.2C — Order-to-delivery workflow alignment

Assessment only. No operational activation. Development-cloud flags were not changed. No Git commit.

**HEAD:** `234cbaededafec5c21ecafc2d239406089dfcb13` on `main` (`shop data added and sales statement option added`).

**Uncommitted at start of this phase:** `docs/m8-2b-branch1-uat-data-readiness.md` (preserved).

**BPM sources in this workspace:** `docs/m7-1-order-to-delivery-gap-audit.md` (extracted from `reference/Sherlys_Distribution_Agents_BPM.pdf`, which is **not** in the repository). No Excel UI-layout workbook was found under the workspace or `Hashdev`.

**5173 target:** development cloud `ypkfondrkhkydkgovwup.supabase.co`. Cloud flags remain `damage.stock_hold_ready=false`, `stock.lots.dual_write_enabled=false`, `stock.lots.aggregate_only_blocked=false`. `SHORT_SHIPMENT_OPERATIONAL=false` in `src/lib/picking/rules.ts`.

---

## 1. Actual workflow versus the approved six-stage blueprint

Owner sequence (Admin monitors, not a seventh stage):

1. Salesperson — Order Entry
2. Accounts — Order Approval (credit, outstanding, overdue)
3. Store Keeper — Loading Preparation (godown / zone / crate, FEFO/FIFO)
4. Store Keeper → Accounts — Invoice Note (physically loaded cases become billable; ordered qty stays)
5. Accounts — Billing / Invoice (GST issuance stays disabled)
6. Delivery Person — Delivery Confirmation (delivered / returned / short, receiver, POD)

Implemented sequence today (do **not** silently replace it):

1. Salesperson or Accounts `create_order` / `set_order` / `submit_order` (`/orders/new`)
2. Accounts `verify_order` or `hold_order` (`/orders/:orderId`) — ATP, **not** credit
3. Accounts `create_delivery_note` → generate → send (`/deliveries`)
4. Godown Manager `acknowledge_delivery_note`
5. Godown Manager `reserve_order_allocation` (`/picking/allocate/:orderId`)
6. Store Keeper `start_picking` / `confirm_picking_quantity` (`/picking/:requestId`)
7. Optional short-shipment: GM confirm, Accounts `approve_short_shipment` (UI constant remains false)
8. Godown Manager `confirm_dispatch` — **stock writer** (`/dispatch`)
9. Godown Manager `assign_dispatch_delivery` (vehicle + driver)
10. Godown Manager `prepare_invoice_note` from **posted DISPATCH** (`/invoices`)
11. Accounts `review_invoice_note`; GST preview; statutory issuance blocked
12. Delivery Person POD / partial / fail (`/delivery-runs`); returns via `post_delivery_return`

### Stage-by-stage matrix

| Stage | Owner blueprint | Existing UI | Statuses | RPCs | Authorized roles | Transition rules | Audit | Missing / mismatch |
|---|---|---|---|---|---|---|---|---|
| 1 Order entry | Salesperson multi-SKU for assigned shop | `/orders`, `/orders/new`, `/orders/:id/edit` | `draft → submitted` | `create_order`, `set_order`, `submit_order` | `orders.capture`: Salesperson, Accounts | Shop via `assert_order_shop` (assignment or `shops.read_all`). Godown via `assert_order_branch`. Whole cases. | `order_events` created / lines_revised / submitted | Accounts can also capture. No separate salesperson field; `created_by` is the actor. |
| 2 Accounts approval | Review credit, outstanding, overdue; approve / hold / reject | `/orders/:id` Verify / Hold / Cancel | `submitted → verified \| held`; cancel from submitted/verified | `verify_order`, `hold_order`, `check_order_availability`, `cancel_order` | `orders.verify`: Accounts only | Verify requires picking-eligible ATP (`picking_line_plan`). Dual-write off → fail closed. Hold returns to creator. **No credit/outstanding/overdue fields.** | `verified`, `held`; `availability_snapshot` | **Credit gate is missing.** Shop statement outstanding is explicitly unavailable (`shops.statement.read`, Admin+Accounts). Payments are not implemented. |
| 3 Loading preparation | Store Keeper prepares FEFO/FIFO by crate | `/picking` Packing | picking: pending_allocation → allocated → picking → picked → ready_for_dispatch | `preview_order_allocation`, `reserve_order_allocation`, `assign_picking_request`, `start_picking`, `confirm_picking_quantity`, `complete_picking`, `confirm_picking_handoff` | Allocate/manage: Admin, GM. Execute: assigned Store Keeper | **Acknowledged DN required** before allocate. Dual-write required. Reserve is a hold, not a debit. | `stock_picking_events` | **GM allocates; SK executes.** Extra DN paperwork stage is not in the six-stage list. Picking is blocked on development cloud. |
| 4 Invoice note from loaded cases | Store Keeper confirms loaded cases; billable := loaded; ordered stays | No SK invoice-note screen | Invoice notes: `draft → submitted → reviewed \| cancelled` | `prepare_invoice_note` **after** `confirm_dispatch` | `invoice_notes.prepare`: **Godown Manager** | Billable snapshot is DISPATCH consume qty (full reserved, or approved short-ship lots). `order_lines.requested_cases` is never rewritten. | `invoice_note_events` | **Store Keeper cannot prepare invoice notes.** Loaded confirmation is picking + GM dispatch, not a SK→Accounts document. Invoice is after stock consume, not after physical load confirmation alone. |
| 5 Accounts billing | Review loaded-case pricing; GST off | `/invoices/:noteId`, `/preview`, GST preview, handover PDF | reviewed draft | `review_invoice_note`, `get_invoice_note_preview`, tax preview RPCs | `invoices.review`: Accounts, Admin | Re-resolves prices as-of dispatch; fingerprint mismatch fails closed. `tax_amount` stays 0. Watermark `DRAFT INVOICE NOTE — NOT A TAX INVOICE`. No issue/finalize/allocate RPCs. | invoice events | Matches “GST stays disabled”. Does **not** produce a legal invoice for the driver to carry. |
| 6 Delivery confirmation | Delivered / returned / short, receiver, POD | `/delivery-runs`, `/dispatch/:id` | dispatch: dispatched → in_transit → delivered \| exception | `start_dispatch_delivery`, `acknowledge_dispatch_delivery`, `record_partial_dispatch_delivery`, `report_dispatch_delivery_exception`, `post_delivery_return` | Execute: assigned Delivery Person. Assign: GM. Return post: GM path | Full POD: delivered = dispatched. Partial/fail does not restock until `post_delivery_return`. Proof is a string reference, not a photo. | dispatch / return events | Can run **before or after** invoice-note review. BPM wants invoice in-hand before leaving; implemented invoice is independent after dispatch. |

Admin: `operations.monitor` plus opening-stock, employees, locations. Admin is **not** a capture/verify actor.

---

## 2. Missing or mismatched stage gates

Do **not** patch these without owner approval. Stock and financial writers stay untouched.

1. **Credit / overdue at verify.** `verify_order` only checks ATP. Receivables are not implemented. Proposed later: a fail-closed credit snapshot once payment posting exists. Not now.
2. **Delivery note gate.** Implemented: no allocate without acknowledged DN. Six-stage omits DN. Proposed: keep DN as Accounts paperwork between verify and warehouse (matches BPM ORD-03/04). Do not remove the gate for UAT convenience.
3. **Allocator vs loader.** Six-stage gives Store Keeper loading preparation. Implemented GM allocate + SK execute. Proposed: keep split; UAT script uses both roles.
4. **Billable quantity source.** Six-stage: SK confirms loaded cases, then Accounts bills. Implemented: GM `confirm_dispatch` consume, then GM `prepare_invoice_note` from DISPATCH. Changing the snapshot to `picked_cases` before consume would bill goods still in the crate. **Do not change.**
5. **Short load (Scenario B).** Ordered 12 / load 11 is the short-shipment workflow (`order_shipments`, backorder). `SHORT_SHIPMENT_OPERATIONAL` stays false, so the UI must not claim live warehouse short-shipment. RPCs exist. Dispatch of a shortage without an approved shipment still fails closed.
6. **Invoice-in-hand before transit.** Not enforced. Driver can start delivery with no reviewed invoice note.
7. **Partial delivery vs invoice.** Invoice-at-load bills van contents. Returns create internal credit-adjustment previews, not GST credit notes.

---

## 3. Quantity authority (must hold in UAT)

| Quantity | Source | Mutable after submit? |
|---|---|---|
| Ordered | `order_lines.requested_cases` | No (except hold/edit before verify) |
| DN | copy of ordered | No |
| Reserved / picked | picking reservations | Warehouse only |
| Billable | DISPATCH consume / approved shipped lots | Invoice snapshot; not a rewrite of ordered |
| Delivered | outcome lines | POD / partial |
| Returned | `post_delivery_return` | After fail/partial |

Scenario B expected: ordered **12**, billable **11**. That requires the short-shipment path, not rewriting the order.

---

## 4. Role and permission matrix (workflow subset)

Hidden navigation is not authorization. RPCs are SECURITY DEFINER with permission + branch checks. FORCE RLS remains.

| Action | Admin | Accounts | GM | Sales | Store keeper | Delivery |
|---|---|---|---|---|---|---|
| Capture order | monitor only | yes | no | yes (assigned shops) | no | no |
| Verify / hold | no | yes | no | no | no | no |
| Issue DN | no | yes | no | no | no | no |
| Ack DN | no | no | yes | no | no | no |
| Allocate picking | yes | no | yes | no | no | no |
| Execute pick | yes (manage) | no | yes | no | execute if assigned | no |
| Confirm dispatch | yes | no | yes | no | **no** | no |
| Prepare invoice note | no | no | yes | no | **no** | no |
| Review invoice note | yes | yes | no | no | no | no |
| Assign vehicle/driver | no | no | yes | no | no | no |
| POD | no | no | no | no | no | assigned only |
| Opening stock | yes | no | no | no | no | no |
| Enable dual-write via JWT | no | no | no | no | no | no |

Salesperson isolation is `assert_order_shop` against `shop_salesperson_assignments`. Store Keeper cannot verify or dispatch. Delivery Person cannot prepare/review invoices. Accounts cannot allocate or `confirm_dispatch`.

---

## 5. Proposed minimal corrections (owner review only)

Not implemented in this phase.

| ID | Proposal | Stock/financial write? | Recommend for isolated UAT? |
|---|---|---|---|
| C1 | Keep implemented sequence; document extra DN and GM invoice-note steps in the UAT script | No | **Yes** |
| C2 | Do not add a fake credit balance to `verify_order` | Would invent finance | **Yes — skip credit until receipts exist** |
| C3 | Do not move `prepare_invoice_note` to Store Keeper or to pre-dispatch picked qty | Yes (billable source) | **Do not** |
| C4 | Do not enable `SHORT_SHIPMENT_OPERATIONAL` on cloud. Isolated UAT may exercise the existing short-shipment RPCs with the UI constant still false | Dispatch already posts shipped lots when approved | Owner must accept Scenario B as the implemented short-shipment document, not a silent 12→11 rewrite |
| C5 | Do not flip development-cloud dual-write | Yes | **Do not** |

---

## 6. UAT scenarios and execution status

None of A–F were executed against a live isolated Branch-1 database. That environment does not exist yet (see the companion preparation doc). Unit tests below only lock the alignment contract.

| Scenario | Designed against | Automated status | Manual status |
|---|---|---|---|
| A Full delivery | Implemented sequence including DN + dispatch + invoice note + POD | **NOT RUN** | **NOT RUN** |
| B Loading shortage 12→11 | Short-shipment RPCs; ordered remains 12 | **NOT RUN** | **NOT RUN** |
| C Bill 11, deliver 10, return 1 | Partial POD + `post_delivery_return` + credit-adjustment preview | **NOT RUN** | **NOT RUN** |
| D Accounts hold/reject blocks warehouse | `hold_order` / unverified; allocate requires verified + DN ack | Unit next-action **PASS**. HTTP/e2e **NOT RUN** | **NOT RUN** |
| E Role isolation | Playwright spec `tests/e2e/m82c-isolated-uat.spec.ts` | **NOT RUN** (stack absent) | **NOT RUN** |
| F Stock integrity (ATP, FEFO/FIFO, unclassified, crate, concurrency, idempotent retry) | Existing M2/M3/M8.1C suites on other databases | **NOT RUN on M82C** | **NOT RUN** |

---

## 7. Owner decisions required

1. Accept the implemented sequence (with DN + GM invoice note after dispatch) as the Branch-1 UAT path, **or** commission a later workflow change (not M8.2C).
2. Accept that Accounts verify does **not** show credit/outstanding/overdue.
3. Authorize creating isolated local stack `sherlyos_m82c` (ports 57321/57322), not reuse of `sherlyos_m81c`.
4. Authorize TEST ONLY dual-write **only** on that stack (`aggregate_only_blocked` stays false).
5. For Scenario B, authorize using the existing short-shipment RPCs while `SHORT_SHIPMENT_OPERATIONAL` remains false.
6. Do not activate development-cloud flags, production suppliers, or GST issuance.

---

**Verdict for this document:** workflow is implementable as currently coded, with documented mismatches. Isolated execution is not available yet.
