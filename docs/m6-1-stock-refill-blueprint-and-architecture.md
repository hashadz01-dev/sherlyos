# M6.1 — Stock Refill blueprint audit and architecture

Architecture and planning only. No migrations, permission grants, frontend routes, stock writers, commits, or feature-flag changes were made in this phase.

Labels used throughout:

- **BLUEPRINT REQUIREMENT** — stated in `reference/Sherlys_Distribution_Agents_BPM.pdf`
- **EXISTING SYSTEM CAPABILITY** — verified in SherlysOS migrations / UI
- **PROPOSED IMPLEMENTATION** — architecture recommendation, not an approved business rule
- **OWNER DECISION REQUIRED** — blueprint is silent or existing schema cannot support the step without a new rule

Do not treat a proposed implementation as an approved business rule.

---

## 1. Executive summary

SherlysOS M6 Stock Refill is **not** an internal godown transfer, salesperson allocation, picking job, or dispatch of existing inventory.

The PDF Branch 05 register and process-flow (page 12) define a **supplier replenishment request**:

1. Detect low stock or extra demand.
2. Accounts prepares an FMCG **brand-specific** SKU/quantity request.
3. Accounts submits it to Admin.
4. Admin **approves, holds, or rejects**. Hold/reject produces **no supplier order**.
5. Accounts sends an **approved** request to the FMCG company.
6. The FMCG supplier dispatches products to the godown.
7. **Branch 03 Stock Receiving** counts, verifies, and posts **accepted** stock.

The diagram rule is explicit: **“A refill approval is not a stock receipt; posting requires Branch 03 verification.”**

That rule forbids posting inventory at Admin approval and forbids inventing a new ledger type for refill. Stock is created only by the existing receiving path (`verify_stock_receipt` → `RECEIPT`). Damaged inbound cases remain excluded from accepted stock (Branch 03 + DMG-01/DMG-02).

M5 damage isolation flags stay false. Lot cutover flags stay false. M6 must not enable them.

**M6 baseline HEAD:** `f8eea4cc5ae6b8051a292d36f891c278db236d7d`  
`test(m5.5): validate damage management and document module closure` on `main`. Parent is M5.4F `c3f224ac8c8d37787d81ca5116fb0ba43ca9b983`. Working tree was clean at start.

Local Docker was not running during this audit. Schema and RPC contracts below are taken from migrations in the repository, which are the source of truth for what is implemented.

---

## 2. Exact REF-01–REF-07 blueprint extraction

Source: `reference/Sherlys_Distribution_Agents_BPM.pdf` v1.0.

Personas (page 2) used by Branch 05:

| ID | Persona | Relevant refill duty |
| --- | --- | --- |
| 01 | Admin | “approves stock refill requests” |
| 02 | Accounts | “prepares … stock refill requests” |
| 03 | Godown Manager | Receiving verification (Branch 03), not refill request authorship |
| 06 | Store Keeper | Receiving count/allocation (Branch 03) |
| External | FMCG supplier | REF-06 dispatch |

Companion structured BPM (`bpm-sherlys-distribution-agents`) has **no** stock-refill module. Do not import companion receiving/order nodes as refill requirements.

### REF-01 — Refill trigger

| Field | Extraction |
| --- | --- |
| Original title | Refill trigger |
| Flow name | Detect below-threshold stock or additional demand |
| Diagram | “Low stock threshold or extra demand identified” — **System / Accounts** |
| Business purpose | Start a replenishment when stock is below a threshold **or** extra demand exists |
| Initiating actor | System and/or Accounts (diagram lists both) |
| Responsible actor | Accounts (prepares the request in REF-02) |
| Trigger | Below-threshold stock **or** additional demand |
| Input data | Unspecified beyond “low stock” / “extra demand” |
| Required documents | None stated |
| Required stock information | Implied current stock vs threshold — threshold definition is not in the PDF |
| Approval | None at this step |
| Validation | Not specified |
| Physical / system stock movement | **None** |
| Output | Identified need |
| Next | REF-02 |
| Exceptions | Not specified |
| Audit | Not specified |

**OWNER DECISION REQUIRED:** How “below-threshold” is detected. `products` has **no reorder level** (`20261014210000_master_data.sql`). Automated REF-01 cannot be implemented without a new approved threshold store.

### REF-02 — Accounts request

| Field | Extraction |
| --- | --- |
| Original title | Accounts request |
| Flow name | Prepare FMCG brand-specific quantities and SKUs |
| Diagram | “Prepare brand-specific refill request” — **Accounts** |
| Business purpose | Turn the need into a supplier-facing request by brand, SKU, and quantity |
| Initiating / responsible actor | Accounts |
| Trigger | REF-01 identification |
| Input data | Brand, SKUs, quantities (case unit implied by SherlysOS inventory unit, not restated here) |
| Required documents | The refill request itself |
| Required stock information | Not specified beyond brand-specific SKUs/qty |
| Approval | None yet |
| Physical / system stock movement | **None** |
| Output | Prepared request |
| Next | REF-03 |

**OWNER DECISION REQUIRED:** What “brand” maps to (`suppliers`, `product_categories`, or a new brand master). Products have optional `supplier_id` only.

### REF-03 — Admin submission

| Field | Extraction |
| --- | --- |
| Original title | Admin submission |
| Flow name | Send refill request to Admin for authorization |
| Diagram | “Submit request for Admin approval” — **Accounts** |
| Business purpose | Place the prepared request in Admin’s decision queue |
| Initiating actor | Accounts |
| Responsible actor | Admin (receives it) |
| Physical / system stock movement | **None** |
| Output | Request awaiting Admin decision |
| Next | REF-04 |

### REF-04 — Admin decision

| Field | Extraction |
| --- | --- |
| Original title | Admin decision |
| Flow name | Approve, hold or reject refill request |
| Diagram | “Admin approves stock refill?” with **HOLD / REJECT**: “Return request for correction or reject; no supplier order.” |
| Business purpose | Authorize (or block) sending an order to the FMCG company |
| Initiating / responsible actor | Admin |
| Approval requirement | **Yes** — this is the authorization step |
| Physical / system stock movement | **None.** Approval is explicitly not a receipt |
| Output | Approved **or** held for correction **or** rejected |
| Next | REF-05 if approved; otherwise no supplier order |
| Exceptions | Hold (return for correction) or reject |

### REF-05 — Supplier request

| Field | Extraction |
| --- | --- |
| Original title | Supplier request |
| Flow name | Send approved request to FMCG company |
| Diagram | “Send approved request to FMCG supplier” — **Accounts** |
| Business purpose | Communicate the approved SKU/qty list to the supplier |
| Initiating / responsible actor | Accounts |
| Required previous state | Approved (REF-04) |
| Physical / system stock movement | **None** (external purchase communication) |
| Output | Supplier has the request |
| Next | REF-06 |
| Audit | Not specified |

**OWNER DECISION REQUIRED:** Whether SherlysOS records a “sent” event/status, or REF-05 is an out-of-band email/phone step with only an audit note.

### REF-06 — Supplier dispatch

| Field | Extraction |
| --- | --- |
| Original title | Supplier dispatch |
| Flow name | FMCG company dispatches products to godown |
| Diagram | “Supplier dispatches products to godown” — **FMCG supplier** |
| Business purpose | Physical movement from supplier to Sherlys godown |
| Initiating actor | FMCG supplier (external) |
| Physical stock movement | Supplier → godown (in transit under supplier/carrier, not Sherlys inventory) |
| System stock movement | **None in SherlysOS** until Branch 03 posts |
| Output | Goods arrive (STK-01) |
| Next | REF-07 |

**OWNER DECISION REQUIRED:** Whether SherlysOS tracks an in-transit/dispatched-by-supplier status, or waits until receiving records arrival. Blueprint does not require an internal in-transit balance.

### REF-07 — Receiving handover

| Field | Extraction |
| --- | --- |
| Original title | Receiving handover |
| Flow name | Branch 03 counts, verifies and posts actual accepted stock |
| Diagram | “Branch 03 verifies and posts accepted stock” — **Stock Receiving** |
| Business purpose | Convert arrived goods into usable inventory using the receiving workflow |
| Responsible actors | Store Keeper (count/allocate) and Godown Manager (verify) — Branch 03 |
| Physical stock movement | Unload, count, separate damage, allocate to Godown/Zone/Crate |
| System stock movement | **Only accepted, verified cases** enter available inventory (STK-06) |
| Output | Posted receipt; damaged cases excluded |
| Next | End of refill; damage may continue via DMG-01/DMG-02 |
| Exceptions | Receiving hold, damage/variance (Branch 03), unverified receipt cannot increase available stock |

---

## 3. Traceability matrix

| Step | Blueprint actor | Existing capability | Proposed (not approved) | Classification |
| --- | --- | --- | --- | --- |
| REF-01 | System / Accounts | `list_inventory_report`, `list_stock_balances`; **no** product reorder field | Accounts-identified demand in M6.2; optional later threshold alert | OWNER DECISION REQUIRED for automation |
| REF-02 | Accounts | Permission `refill.request` already granted to `accounts`. No table. Products + suppliers masters exist | `stock_refill_requests` + lines; brand = one supplier per request **if owner agrees** | PROPOSED IMPLEMENTATION |
| REF-03 | Accounts | No RPC | `submit_stock_refill_request` | PROPOSED IMPLEMENTATION |
| REF-04 | Admin | Permission `refill.approve` already granted to `admin` | `approve` / `hold` / `reject` RPCs; hold returns for correction; reject terminal; **no stock** | PROPOSED IMPLEMENTATION matching PDF |
| REF-05 | Accounts | None | Optional `mark_refill_sent_to_supplier` after approved | OWNER DECISION REQUIRED |
| REF-06 | FMCG supplier | None | Do **not** invent Sherlys in-transit stock. Optional informational status only | OWNER DECISION REQUIRED |
| REF-07 | Branch 03 | Full receiving module (see §4) | Reuse `create_stock_receipt` … `verify_stock_receipt`. Optional `stock_receipts.refill_request_id` | EXISTING for posting; OWNER DECISION for request linkage |
| Stock at approval | Forbidden by PDF | N/A | No ledger write on approve | BLUEPRINT REQUIREMENT |
| Damaged inbound | STK-03 + DMG-01/02 | Receipt `damaged_cases` never posted; damage reports on posted receipts | Do not change M5 | EXISTING SYSTEM CAPABILITY |

Suggested M6.3 “allocation / picking / dispatch” from the prompt is **not** justified by Branch 05. Picking (ORD-05) is shop-order fulfillment, not refill.

---

## 4. Current system contract inventory

### 4.1 Inventory grain (EXISTING)

- Unit: one carton case. `stock_balances.quantity integer >= 0`. Primary key `(crate_id, product_id)`.
- Locations: `branches` (godown) → `zones` → `crates`. Quarantine crates use `location_role = quarantine` (M5.3); picking availability excludes them.
- Lots: `stock_lots` exist; dual-write **off**. Receiving can attribute lots before verify when dual-write is later enabled. M6 must not enable `stock.lots.dual_write_enabled` or `stock.lots.aggregate_only_blocked`.
- Reservations: picking allocations only (`stock_reservations`). Not used for supplier refill.
- Ledger: append-only `stock_transactions` + `stock_ledger`. Clients cannot DML balances.
- Products: SKU, name, optional `supplier_id`, optional `category_id`. **No quantity, price, unit, or reorder level.**

### 4.2 Permissions already catalogued (EXISTING)

From `supabase/migrations/20261014150000_access_control.sql`:

| Code | Description | Current grant |
| --- | --- | --- |
| `refill.request` | Prepare and submit a brand-specific refill request | `accounts` |
| `refill.approve` | Approve, hold, or reject a refill request | `admin` |

Do **not** reuse `products.manage`, `inventory.manage` (does not exist as a write grant), `picking.*`, `dispatch.*`, or `damage.dispose` for refill.

Related existing grants:

| Need | Existing permission | Notes |
| --- | --- | --- |
| See stock to decide refill | `stock.read` | Already on Accounts |
| Product catalog | `products.read` | Already on Accounts |
| Receiving count | `receiving.execute` | Store Keeper |
| Receiving verify/post | `receiving.verify` | Godown Manager |
| Damage on inbound | `damage.record` / `damage.verify` | M5; readiness gated for isolation scenarios |
| Monitor | `operations.monitor` | Admin |

**OWNER DECISION REQUIRED:** Whether `operations.monitor` may list refill requests (recommended yes, read-only). Not granted specifically today.

### 4.3 Receiving RPCs — REF-07 reuse (EXISTING)

Defined in `supabase/migrations/20261015200000_stock_receiving.sql`, with `verify_stock_receipt` replaced in `20261022190000_lot_aware_operational_posting.sql`. Frontend: `src/lib/receiving/api.ts`. Routes: `/receiving`, `/receiving/new`, `/receiving/:receiptId`.

| Function | Signature | Auth | Prerequisites | Stock / ledger | Idempotency / locks |
| --- | --- | --- | --- | --- | --- |
| `create_stock_receipt` | `(target_godown uuid, target_supplier uuid, supplier_document text, received_on date, receipt_notes text, line_items jsonb)` | `receiving.execute`; `can_work_at_branch`; active godown | Active supplier; unique `(godown, supplier, normalized document)` including cancelled | None | Insert header + lines |
| `update_stock_receipt` | same + `target_receipt uuid` | `receiving.execute`; creator; `draft` | Same | None | `lock_stock_receipt` FOR UPDATE |
| `submit_stock_receipt` | `(target_receipt uuid)` | `receiving.execute`; creator; `draft` | ≥1 line | None | Lock header |
| `hold_stock_receipt` | `(target_receipt uuid, reason text)` | `receiving.verify` | `draft` or `submitted` | None | Lock header |
| `release_stock_receipt` | `(target_receipt uuid)` | GM at branch, or creator keeper | `held` → `draft` | None | Lock header |
| `cancel_stock_receipt` | `(target_receipt uuid, reason text)` | GM any non-posted; keeper `draft` only | Not posted/cancelled | None; document key retained so same supplier document cannot post again | Lock header |
| `verify_stock_receipt` | `(target_receipt uuid, idempotency_key text)` | `receiving.verify` | `submitted`; active supplier/products/locations | Posts `RECEIPT` for each line with `accepted_cases > 0` (`counted - damaged`). Damaged cases **not** posted | Replay if posted + same key + fingerprint; else `23505`. Lock: receipt → supplier → products → `prepare_stock_locations` (zones/crates/branch) |
| `list_stock_receipts` | `()` | execute or verify | Branch scoped | None | Read |
| `get_stock_receipt` | `(target_receipt uuid)` | execute or verify | View predicate | None | Read |
| `list_receiving_options` | `()` | execute or verify | — | None | Catalog |
| `set_stock_receipt_line_lot_attributions` | `(target_receipt_line uuid, attributions jsonb)` | execute or verify | Before verify; dual-write path | None until verify | Lot metadata only |

`app_private.lock_stock_receipt(uuid)` → `stock_receipts` row `FOR UPDATE`.

Receipt statuses: `draft`, `submitted`, `held`, `posted`, `cancelled`. Line `accepted_cases` is generated (`counted_cases - damaged_cases`).

**Do not create a duplicate stock writer for refill arrivals.**

### 4.4 Other stock writers — do not use for refill (EXISTING)

| RPC | Why not refill |
| --- | --- |
| `post_opening_stock` | One-time opening |
| `post_crate_transfer` | Internal crate move; ledger nets to zero |
| `post_stock_adjustment` / adjustment request/approve | Variance correction, not supplier replenishment |
| `confirm_picking_quantity` / `confirm_picking_handoff` | Shop-order FEFO/FIFO |
| `confirm_dispatch` | Consumes reservations for shop delivery |
| Damage hold/write-off/exceptional post | M5 isolation; flags stay false |

### 4.5 Frontend placeholder (EXISTING)

- `src/features/refill/RefillPage.tsx` → empty `ModulePage`
- Nav `/refill` has **no** `permission` / `anyPermissions` (`src/app/navigation.ts`)
- Router `{ path: "refill", element: <RefillPage /> }` is unguarded (`src/app/router.tsx`)

**PROPOSED:** Guard with `refill.request` | `refill.approve` | `operations.monitor` when UI is built. Not applied in M6.1.

### 4.6 Audit (EXISTING)

`app_private.write_audit(actor, action, entity, entity_id, metadata)` used by receiving and other modules. Refill RPCs should use the same log. **PROPOSED**, not implemented.

---

## 5. Actor and permission matrix

Answers use blueprint evidence. Unsupported items are marked.

| # | Question | Answer | Source |
| --- | --- | --- | --- |
| 1 | Who initiates? | Accounts (and optionally System for threshold). | REF-01/02 |
| 2 | Who reviews? | Admin. | REF-03/04; persona 01 |
| 3 | Who approves? | Admin. Outcomes: approve, hold, reject. | REF-04 |
| 4 | Which location supplies? | **FMCG company**, not another Sherlys godown. | REF-05/06 |
| 5 | Which location receives? | Godown (Branch 03). Which godown on the **request** is unspecified. | REF-06/07; **OWNER DECISION** |
| 6 | Who picks cartons? | Not a Sherlys picking job. Supplier ships; Store Keeper counts on arrival. | REF-06 + STK-02 |
| 7 | Who verifies outgoing qty? | Not defined for Sherlys outbound. Incoming count is Store Keeper. | STK-02 |
| 8 | Who transports? | FMCG supplier (external). Delivery Person is shop delivery, not refill. | REF-06 vs ORD-09 |
| 9 | Who confirms receipt? | Store Keeper records; Godown Manager verifies/posts. | STK-01–06 |
| 10 | When does custody change? | Blueprint: goods become Sherlys **available stock** only after Branch 03 verification. | REF-07 rule + STK-06 |
| 11 | When is inventory deducted? | **Never for refill request/approval.** Deduction is unrelated shop dispatch. | PDF stock-control note |
| 12 | When is inventory added? | `verify_stock_receipt` posting accepted cases. | EXISTING receiving |
| 13 | Shortages | Receiving: counted vs document; variance logged; accepted = counted − damaged. | STK-03; EXISTING lines |
| 14 | Excess cartons | Same receiving variance (counted − document). Posted qty is accepted counted, not the refill-request qty, unless owner later requires a match rule. | OWNER DECISION for request vs receipt matching |
| 15 | Damaged cartons | Excluded from accepted stock; DMG-01/02 after receipt exists. | STK-03, M5 inbound |
| 16 | Rejected refill | No supplier order. | REF-04 hold/reject |
| 17 | Partial fulfillment | PDF posts **actual accepted** stock, not requested qty. Whether the refill request stays open is unspecified. | OWNER DECISION |
| 18 | Cancel | Hold/reject before supplier order. Cancel after approve/send: unspecified. Receipt cancel already exists pre-post. | OWNER DECISION for request cancel after approve |
| 19 | Reverse | Posted receipts are not reversed by receiving cancel. Adjustment/damage are separate modules. | EXISTING; do not invent refill reversal |
| 20 | Audit evidence | Not specified beyond Admin decision and Branch 03 verification. | PROPOSED: `audit_logs` on each refill RPC + reuse receipt audit |

GM and Store Keeper **do not** author refill requests in the PDF. Salesperson and Delivery Person have no refill role.

---

## 6. Refill state machine

**PROPOSED IMPLEMENTATION** aligned to REF-02–REF-07. Not an approved schema.

```
draft  --(Accounts submit)--> submitted
submitted --(Admin approve)--> approved
submitted --(Admin hold)--> held
submitted --(Admin reject)--> rejected     [terminal]
held --(Accounts update + resubmit)--> submitted
approved --(Accounts mark sent, IF owner agrees)--> sent_to_supplier
sent_to_supplier or approved --(receiving posted, IF linked)--> receiving_complete  [optional]
```

Blueprint-mandatory statuses: **submitted (awaiting Admin)**, **approved**, **held**, **rejected**.  
`draft` matches existing SherlysOS request patterns (orders, receipts).  
`sent_to_supplier` / `receiving_complete` are **OWNER DECISION REQUIRED**.

Invariants (**PROPOSED**):

- Optimistic `version`; stale `PT409`.
- Unique open request idempotency key per Accounts actor (same pattern as orders/damage).
- Rejected and held **must not** allow REF-05.
- **No** `stock_transactions` insert on any refill-request transition.

---

## 7. Inventory movement model

**Verified type:** supplier replenishment request + existing stock **receiving**.  
**Not:** internal location transfer, godown-to-salesperson allocation, or shop picking/dispatch.

| Topic | Finding |
| --- | --- |
| Source grain | FMCG supplier (external). No Sherlys crate is the source |
| Destination grain | Godown crate via receipt lines (`destination_crate_id`) |
| Reservation | None for refill. Do not convert shop-order reservations |
| Lot selection | At receiving, only if dual-write is later on. Keep flags **false** now |
| FEFO/FIFO | Applies to **outbound shop picking**, not to creating inbound stock |
| Physical custody | Supplier until Branch 03 posts accepted cases |
| Ledger transaction | Existing `RECEIPT` only, at verify |
| Quantity conservation | Refill request qty is a **document of demand**, not a conserved stock quantity. Conserved movement is receipt accepted vs ledger +1 |
| In-transit state | **Not required** as a stock balance. Optional request status only (**OWNER DECISION**) |
| Cancellation | Request: hold/reject before supplier order. Receipt: existing cancel before post |
| Partial fulfillment | Receipt may post fewer accepted cases than requested (**OWNER DECISION** how the request closes) |

---

## 8. Stock and ledger accounting invariants

Required by the verified process:

| Invariant | Required? | How |
| --- | --- | --- |
| No stock change on request/approve/send | **Yes** | Refill RPCs must not call `apply_stock_delta` / lot writers |
| No negative source stock on refill | N/A (no Sherlys source) | — |
| No duplicate receipt posting | **Yes** | Existing receipt document unique key + verify idempotency |
| No stock creation during “internal movement” | **Yes** — there is no internal refill movement | Do not add `CRATE_TRANSFER` for refill |
| Source and destination qty reconcile | N/A for request; receipt accepted vs ledger already enforced | `assert_stock_transaction_complete` for `RECEIPT` |
| In-transit quantity accounted as stock | **No** unless owner later requires a non-stock memo | Do not invent an in-transit balance table in M6.2 |
| Lot reconcile | Only if dual-write enabled later | Flags stay false |
| Case-only units | **Yes** | Integer cases on request lines, same as receipts |
| FEFO/FIFO on refill request | **No** | Not an allocation of on-hand stock |
| No unauthorized movement | **Yes** | `refill.*` vs `receiving.*` split |
| No movement from inactive godowns | **Yes** at receiving (`location is inactive`). Request targeting inactive godown: **OWNER DECISION** |
| No use of damaged/quarantined stock | **Yes** inbound: damaged never accepted; quarantine crates already blocked from ordinary receiving without damage GUC | Do not bypass |
| No consuming another workflow’s reservations | **Yes** | Refill must not touch `stock_reservations` |
| Exact-once receipt post | **Yes** | Existing |
| Concurrent allocation/picking/dispatch/receiving | Receiving already serializes via location lock order. Refill request rows need their own header lock only | See §13 |

Damage holds (`damage.stock_hold_ready=false`) stay fail-closed. Refill must not enable the flag to “make receiving work.”

---

## 9. Damage Management integration

| Topic | Contract |
| --- | --- |
| DMG-01 | Damage on manufacturer supply/refill movement. Existing scenario `refill_supply` against a **posted** receipt line; qty ≤ remaining `damaged_cases`. Never accepted stock |
| DMG-02 | Unloading damage; same remaining receipt damaged pool |
| Link to refill transaction | Today: receipt, not refill request. Optional `refill_request_id` on receipts is **OWNER DECISION** and must not become required for damage |
| Received / damaged / accepted | Receipt line fields already: `document_cases`, `counted_cases`, `damaged_cases`, generated `accepted_cases` |
| Quarantine | Inbound damaged cases were never posted; isolation-required scenarios remain gated |
| Evidence / GM verify | Existing M5 inbound path |
| Readiness | **Do not bypass** `damage.stock_hold_ready=false` |
| M5 rule changes | None identified as required for M6 |

---

## 10. Database architecture

**PROPOSED.** Do not create or apply in M6.1.

### Reuse

- `suppliers`, `products`, `branches`
- `stock_receipts` / `stock_receipt_lines` / `verify_stock_receipt`
- `permissions` `refill.request`, `refill.approve`
- `audit_logs`
- `app_private.assert_permission`, `can_work_at_branch`, `write_audit`, `assert_operational_active_branch` (for any operational write that names a godown)

### New objects (justified by REF-02–REF-04; REF-05/07 linkage optional)

**`public.stock_refill_requests`**

| Item | Proposal |
| --- | --- |
| Purpose | Header for one brand-specific refill request |
| PK | `id uuid` |
| FKs | `supplier_id` → `suppliers` (if owner confirms brand = supplier); `godown_id` → `branches` **if** one destination godown is required; `requested_by` / `decided_by` / `sent_by` → `profiles` |
| Unique | `request_number`; `idempotency_key` |
| State | `draft \| submitted \| held \| approved \| rejected` plus optional later statuses |
| Version | `integer` optimistic lock |
| Auth | FORCE RLS; SELECT for `refill.request`, `refill.approve`, `operations.monitor`; **no** authenticated INSERT/UPDATE/DELETE |
| Writes | Trusted SECURITY DEFINER RPCs only; `search_path = ''` |
| Stock | None |
| Audit | `write_audit` on each transition |

**`public.stock_refill_request_lines`**

- PK `id`; FK `refill_request_id`, `product_id`
- `quantity_cases integer` check `> 0`
- Unique grain `(refill_request_id, product_id)`
- Product should belong to the header supplier **if** that rule is approved

**Optional later:** `stock_receipts.refill_request_id` nullable FK, `on delete restrict`. Multiple receipts per request if partial deliveries are allowed (**OWNER DECISION**).

**Do not add:** refill reservation tables, in-transit balance tables, new `transaction_type`, picking/dispatch FKs, product reorder column (unless owner approves a separate master-data change for REF-01).

### Proposed RPCs (names not implemented)

| RPC | Actor | Effect |
| --- | --- | --- |
| `create_stock_refill_request` | `refill.request` | draft |
| `update_stock_refill_request` | requester, draft/held | lines/notes |
| `submit_stock_refill_request` | requester, draft/held | → submitted |
| `hold_stock_refill_request` | `refill.approve` | → held, reason required |
| `reject_stock_refill_request` | `refill.approve` | → rejected, reason required |
| `approve_stock_refill_request` | `refill.approve` | → approved; **no stock** |
| `list_stock_refill_requests` / `get_stock_refill_request` | request, approve, or monitor | paged reads |
| Optional `mark_stock_refill_sent` | `refill.request` on approved | REF-05 |

Idempotency: create key + fingerprint; submit/approve replay like damage/receiving.

Locking: `FOR UPDATE` on request header for transitions. **No** `prepare_stock_locations` in these RPCs.

---

## 11. Frontend architecture

**PROPOSED** after mapping blueprint steps. Placeholder remains empty until M6.5 (or earlier if owner pulls UI forward with M6.2 reads).

| Route | Purpose | Guard |
| --- | --- | --- |
| `/refill` | Queue: my drafts (Accounts) / pending decision (Admin) | `refill.request` \| `refill.approve` \| `operations.monitor` |
| `/refill/new` | Create brand-specific request | `refill.request` |
| `/refill/:id/edit` | Edit draft/held | `refill.request` |
| `/refill/:id` | Detail, timeline, Admin actions, link to receipts | same as list |
| `/receiving` (existing) | REF-07 | unchanged |

Not justified by blueprint: refill picking, dispatch, allocation, handover pages.

Reuse: `PageHeader`, `EmptyState`, `LoadingBlock`, `AppModal` (irreversible reject), `StatusBadge`, filter patterns from receiving/damage. Pagination/filtering server-side. No optimistic stock. Accounts must not see Admin approve buttons that the RPC would reject.

---

## 12. Security model

**PROPOSED** using existing permission codes. **No grants applied in M6.1.**

- FORCE RLS on new tables; authenticated SELECT only.
- RPCs: `SECURITY DEFINER`, `search_path = ''`, `GRANT EXECUTE` to `authenticated` only; `REVOKE` from `anon` / `public` / `service_role`.
- Private helpers revoked like M5.
- Admin `branches.access_all` may decide refill globally; if requests are godown-scoped, still call `assert_operational_active_branch` on operational submits (**OWNER DECISION** whether inactive godown may be requested).
- Accounts: no `refill.approve`.
- GM/Store Keeper: no refill write permissions unless owner expands the PDF (not recommended).
- Frontend: `callRpc` only; no direct table writes.
- JWT `auth.uid()` attribution on request/decision.

Do not grant `products.manage` to Accounts to “pick SKUs.” `products.read` is enough.

---

## 13. Concurrency and lock-order analysis

**Do not change existing inventory lock ordering in M6.1 or M6.2.**

Established stock posting order (receiving/picking/dispatch/damage):

1. Optional document/request row `FOR UPDATE`
2. Products `FOR UPDATE` ordered by `id`
3. `prepare_stock_locations` (shared cutover advisory, then zones → crates → branch)
4. Balance / hold / reservation rows

Refill **request** RPCs: lock **only** the refill header (and lines as needed). They must not take location locks.

Interactions:

| Pair | Risk | Design |
| --- | --- | --- |
| Refill vs refill | Duplicate submit/approve | Header `FOR UPDATE` + unique open-key |
| Refill vs picking/dispatch | None until receipt posts | No shared grain |
| Refill vs receiving | None unless linked; then receipt locks as today | Optional FK; receiving remains the stock writer |
| Refill vs damage | Damage attaches to posted receipt | Unchanged |
| Refill vs branch deactivation | Approve/send vs deactivate | Fail-closed active godown on submit/approve if godown is required |
| Duplicate receiving | Existing receipt document unique + verify idempotency | Reuse |

Deadlock risk if a future “create receipt from refill” RPC locks refill then locations in a different order than receiving. **Rule:** any stock-posting path must enter through `verify_stock_receipt` (or a thin wrapper that locks refill **after** the receipt lock protocol is finished, or refill first **then** calls verify without reversing location order). Prefer: receiving stays unchanged; link IDs only.

---

## 14. Testing strategy

Isolated disposable prefixes (extend `DISPOSABLE_SKU_PATTERNS`, e.g. `m61%`). Sequential if any flag touch — **tests must not leave flags true**. No operational stock deletion.

**SQL:** auth matrix; valid/invalid transitions; reject/hold cannot send; approve inserts zero `stock_transactions`; inactive godown; stale version; idempotent create/submit/approve; Accounts cannot approve; Admin cannot create (unless owner grants); line qty > 0; supplier/product active.

**HTTP:** PostgREST named args; JWT roles; cross-godown if scoped; PT409; replay.

**Concurrency:** two approves; approve vs reject; submit vs submit; refill vs `verify_stock_receipt` on a linked receipt (if FK exists); refill vs branch deactivation; duplicate receiving still exact-once.

**Frontend:** nav guards; Accounts vs Admin actions; empty/loading/error; no stock-complete copy on approve; a11y dialogs; optional e2e: create → submit → hold → resubmit → approve → open receiving (no post in refill test if flags/isolation not involved).

Receiving, picking, dispatch, and damage regression must stay green. Do not skip races.

---

## 15. Proposed M6 development stages

Adjusted to REF-01–REF-07. Internal picking/allocation is **removed**.

| Stage | Scope | DB | UI | Security | Tests | Done when | Risks |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **M6.1** | This audit | None | None | None | None | Owner review | Misreading refill as transfer |
| **M6.2** | REF-02–04 request lifecycle | `stock_refill_requests` + lines + RPCs | Optional empty-state replacement or wait for 6.5 | Use existing `refill.request` / `refill.approve` only | SQL/HTTP/concurrency on transitions, zero stock | Draft→submit→hold/reject/approve; flags false | Building without godown/brand decisions |
| **M6.3** | REF-05/06 tracking **if owner wants it** | Status/audit only | Send action | Same | No stock | Sent event cannot run before approve | Over-building supplier portal |
| **M6.4** | REF-07 handoff | Optional receipt FK; **no new stock writer** | Receiving: optional refill picker | `receiving.*` unchanged | Receipt still posts accepted only; unlinked receipts still valid | Damage DMG-01 still works | Tight coupling that blocks ordinary receiving |
| **M6.5** | Frontend + reporting | Read RPCs if needed | `/refill` list/new/detail; nav guards | Route permissions | Vitest + Playwright | Placeholder gone; no sample stock | Unguarded `/refill` today |
| **M6.6** | QA closure | None unless fixes | None unless fixes | Flags false | Full regression | Closure doc | Treating development-complete as production-ready |

Dependencies: M6.2 needs owner answers in §16 (blocking subset). M6.3–6.4 need M6.2. M5 remains fail-closed. Lot cutover remains off.

---

## 16. Owner decisions

**Confirm before M6.2 (blocking):**

1. Acknowledge movement model: supplier replenishment, **not** internal transfer/picking.
2. Brand mapping: one `supplier_id` per request vs category vs new brand table.
3. Destination godown: required on the request vs chosen only at receiving.
4. REF-01: Accounts-entered demand only for M6.2 vs automated threshold (would need a new approved reorder field — currently forbidden on `products`).
5. Hold = return to Accounts for edit/resubmit; reject = terminal; no supplier order.
6. May `operations.monitor` read refill queues?

**Before M6.3:**

7. Is REF-05 a recorded system status or out-of-band communication plus optional note?
8. Is REF-06 tracked, or is arrival only a receiving document?

**Before M6.4:**

9. Must a posted receipt optionally/mandatorily reference a refill request?
10. Partial supplier delivery: leave request open vs close on first receipt vs close when Accounts marks complete?
11. Cancel after approve but before send / after send?
12. Match rule: may accepted cases exceed requested cases?
13. Inactive godown: fail-closed on request submit/approve?

**Not required to invent:**

14. Refill reversal of posted stock (use existing adjustment/damage policy).
15. Enabling damage isolation or lot cutover.

---

## 17. Risks and dependencies

- Mis-implementing refill as crate transfer or picking would violate the PDF and duplicate stock writers.
- Automating REF-01 without a reorder field would be an unapproved master-data change.
- Linking receiving too tightly to refill could break ordinary supplier receipts (Branch 03 exists independently).
- `/refill` is currently unguarded — any signed-in user can open the empty placeholder.
- Companion BPM has no refill module; do not copy order/receiving companion extras into M6.
- M5 not operationally activated; inbound damage still works for posted receipts without isolation.
- Cloud/production may not have M5 migrations; M6 must still be local-first unless owner migrates.
- Docker was down during this audit; re-verify flags (`false`/`false`/`false`) when the local stack is up, before any later coding phase.

---

## 18. Recommended next implementation phase

**M6.2 — Refill foundation and request lifecycle (REF-02–REF-04)** after the owner confirms the blocking decisions in §16.

M6.2 should:

- Add request tables and trusted RPCs only.
- Post **zero** stock.
- Reuse `refill.request` / `refill.approve`.
- Leave receiving, picking, dispatch, damage, and flags unchanged.
- Keep `/refill` empty **or** add a thin guarded list if the owner wants UI in the same phase.

Do not start M6.2 without owner approval.

---

No implementation, migration, permission change, commit, push, deployment, or cutover occurred in M6.1.
