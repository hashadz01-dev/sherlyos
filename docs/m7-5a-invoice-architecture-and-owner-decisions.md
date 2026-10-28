# M7.5A — Invoice architecture and owner decisions

Design and audit only. No invoice tables, writers, pricing, GST calculations, PDF generation, migrations, stock-posting changes, flag activation, cloud/Netlify work, or Git commit.

Starting HEAD: `195e9426293ec66d558b1512b63bd89d8d2fe67e`  
`test(m7.4c): stabilize product search and regression harnesses` on `main`.

Working tree was clean. M7.4C was owner-committed. Local migration tip: `20261028000000_product_catalog_search`.

Flags at audit time (operational values, not changed):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false` (hardcoded in `src/lib/picking/rules.ts`)

Legend used below:

- **Fact** — current repository behaviour.
- **Recommendation** — proposed M7.5B contract; not implemented.
- **Owner decision** — required before implementation.

Payment collection and TallyPrime remain outside M7.5 unless separately approved (M7.1 D7).

---

## 1. Existing workflow audit

BPM source for ORD-07/08 remains the M7.1 extraction (`docs/m7-1-order-to-delivery-gap-audit.md`). The PDF is not in this workspace. Sequence on BPM page 8: delivery note → invoice note (loaded goods, Godown Manager) → signed/sealed final invoice (Accounts) → Delivery Person leaves with the invoice.

### 1.1 Capture and edit (ORD-01)

| Item | Fact |
|---|---|
| Tables | `orders`, `order_lines`, `order_events`. FORCE RLS. Authenticated SELECT only. No `app.order_write` GUC. |
| Quantity | `order_lines.requested_cases` only. Unique `(order_id, product_id)`. Comment: no price, tax, or reserved quantity. |
| Statuses | `draft → submitted → held \| verified \| cancelled` |
| RPCs | `create_order`, `set_order`, `submit_order`. Permission `orders.capture` (Accounts, Salesperson). |
| Number | `SO-YYYYMMDD-######` via `shop_order_seq` (revoked from clients). Immutable. |
| Stock | Zero. |

### 1.2 Accounts verification (ORD-02)

| Item | Fact |
|---|---|
| RPC | `verify_order`, `hold_order`, `check_order_availability`. Permission `orders.verify` (Accounts). |
| ATP | `app_private.order_line_availability` → `picking_line_plan` + `picking_cutover_blockers`. Eligible FEFO/FIFO cases minus active reservations; quarantine, expired, unclassified, and dual-write-off stock fail closed. Gross on-hand is informational. |
| Rule A | Any shortfall or ineligible line keeps status `submitted`. Verify does **not** reserve. |
| Snapshot | `order_events.availability_snapshot` (`reserves_stock: false`). |
| Stock | Read-only. |

Operational ATP is fail-closed while dual-write is false. That does not change invoice design; production invoicing still depends on later cutover to pick and dispatch.

### 1.3 Delivery note and GM acknowledgement (ORD-03/04)

| Item | Fact |
|---|---|
| Tables | `delivery_notes`, `delivery_note_lines`, `delivery_note_events`. FORCE RLS. Quantity-only. |
| Quantity | `delivery_note_lines.requested_cases` copied from `order_lines.requested_cases` at `create_delivery_note`. Immutable after insert. |
| Statuses | `draft → generated → sent → acknowledged`; void from draft/generated/sent. Unique open DN per order. |
| RPCs | `create_delivery_note`, `generate_delivery_note`, `send_delivery_note`, `void_delivery_note`, `acknowledge_delivery_note`, `get_delivery_note_print`. |
| Permissions | `delivery_notes.issue` (Accounts); `delivery_notes.acknowledge` (Godown Manager, assigned godown). |
| Print identity | `company.legal_name`, `company.registered_address`, optional `company.tax_id`. `print_ready` false until name and address exist. No fictional seed. |
| Number | `DN-YYYYMMDD-######` via `delivery_note_seq`. |
| Stock | Zero. |
| Picking gate | Acknowledged DN is required at `preview_order_allocation`, `reserve_order_allocation`, and the pending-allocation queue. |

**Fact:** DN quantity is the original ordered quantity, not loaded, picked, or dispatched quantity. It must not be the priced-invoice quantity source.

### 1.4 FEFO/FIFO picking (ORD-05)

| Item | Fact |
|---|---|
| Tables | `stock_picking_requests`, `stock_reservations`, `stock_picking_exceptions`, `stock_picking_events`. FORCE RLS. Guard `app.picking_write`. |
| Reserved | `stock_reservations.reserved_cases` (hold). Reduces ATP. Not a ledger debit. |
| Picked | `stock_reservations.picked_cases` ≤ reserved. Warehouse confirmation only. |
| RPCs | `preview_order_allocation`, `reserve_order_allocation`, `assign_picking_request`, `start_picking`, `confirm_picking_quantity`, `report_picking_shortage`, `complete_picking`, `confirm_picking_handoff`, `cancel_picking_request`. |
| Permissions | `picking.allocate` / `manage` (Admin, GM); `picking.execute` (assigned Store Keeper). |
| Stock | Reserve only. Consume is `confirm_dispatch`. |

### 1.5 Short shipment and backorders (M7.3B)

| Item | Fact |
|---|---|
| Tables | `order_shipments`, `order_shipment_lines`, `order_shipment_lots`, `order_shipment_events`. FORCE RLS. Guard `app.shipment_write`. Comment: not a GST tax invoice. |
| Statuses | `draft → gm_confirmed → approved → dispatched \| cancelled` |
| Ordered on shipment | `order_shipment_lines.ordered_cases` copied from `order_lines.requested_cases`; never rewritten there. |
| Proposed / approved | `proposed_cases` = picked at create; `approved_cases` written by Accounts `approve_short_shipment` (≤ picked and ≤ ordered). |
| Number | `SH-YYYYMMDD-######` via `shop_shipment_seq`. |
| Flag | Workflow implemented. `SHORT_SHIPMENT_OPERATIONAL=false` so UI/fulfilment snapshots must not claim live warehouse short-shipment. |
| Full-pick path | No shipment document required. |
| Backorder | Child `orders` row (`source='backorder'`, `parent_order_id`, `originating_shipment_id`) created **inside** `confirm_dispatch` when remainder exists. Original `requested_cases` unchanged. `fulfilment_status` becomes `partially_fulfilled` or `fulfilled`. No reservation, no PO, no financial settlement. Short-shipment of a backorder fails closed. |

### 1.6 Dispatch, vehicle, driver (ORD-06)

| Item | Fact |
|---|---|
| Consume RPC | `confirm_dispatch` (current body in `20261027220000`). Sole order-fulfilment stock writer. Type `DISPATCH`. |
| Full path | No open shipment: debit `stock_reservations.reserved_cases`. |
| Short path | Approved shipment: debit `order_shipment_lots.approved_cases` as `shipped_cases`; unused reserved remainder `released` (not a receipt). |
| Idempotency | `stock_consumed` / unique `dispatch:{id}`; replay returns original payload. Whole posting rolls back on error, including backorder. |
| Assignment | `assign_dispatch_delivery` (GM, `deliveries.assign`) plus vehicle master from M7.4A. |
| Stock | Yes — DISPATCH debit only here. |

### 1.7 Delivery completion and exceptions (ORD-09 physical)

| Item | Fact |
|---|---|
| Outcome | `delivery_outcome` in `delivered \| failed \| partial`. `return_required` on exception. |
| Lines | `stock_dispatch_outcome_lines.dispatched_cases / delivered_cases / undelivered_cases`. Non-posting. `dispatched_cases` from shipment `approved_cases` or consumed reserved. |
| POD | `acknowledge_dispatch_delivery` — assigned driver only. Full `delivered_cases = dispatched_cases`. Optional `proof_reference` string, not photo bytes. |
| Fail / partial | `report_dispatch_delivery_exception`, `record_partial_dispatch_delivery`. Stock stays deducted. `stock_restored=false`. |
| Stock | Zero on POD/fail/partial. |

### 1.8 Failed-delivery returns (M7.4B)

| Item | Fact |
|---|---|
| Tables | `stock_delivery_returns`, `stock_delivery_return_lots`, `stock_delivery_return_events`. FORCE RLS. Guard `app.delivery_return_write`. Unique one return per dispatch. |
| Grain | Shipment `shipped_cases` else consumed reservation `reserved_cases`. Full-joined to DISPATCH ledger. |
| Buckets | `delivered_cases + saleable_cases + damaged_cases + uncertain_cases + missing_cases` must equal `dispatched_cases`. |
| Post | `post_delivery_return` credits saleable to storage crate; damaged/uncertain to quarantine. Type `DELIVERY_RETURN`. Missing credits nothing. |
| Close missing | `close_delivery_return_missing` — no stock txn. |
| Backorders | Writer does not create, cancel, or mutate backorders. |
| Invoices | Writer does not create, cancel, or reverse invoices (none exist). |

### 1.9 Invoice-related schema today

**Fact:** there are no invoice tables, columns, RPCs, or UI.

Unused permissions in `20261014150000_access_control.sql`:

| Permission | Grant | Description |
|---|---|---|
| `invoice_notes.prepare` | Godown Manager | Prepare the invoice note from goods actually loaded. |
| `invoices.issue` | Accounts | Create, sign, and hand over the final invoice. |

Admin is **not** granted either. No TypeScript references. `order_shipments` and Order Detail copy explicitly say the shipment is not a tax invoice.

---

## 2. Authoritative quantity-source matrix

All quantities are whole carton cases.

| Quantity | Authoritative source | Writer | Stock? | Use for priced invoice? |
|---|---|---|---|---|
| Original ordered | `order_lines.requested_cases` | `create_order` / `set_order` | No | Header/reference only. Not billable. |
| Accounts-verified ATP | `order_events.availability_snapshot` | `verify_order` | No | Eligibility check only. Not a billed qty. |
| Delivery note | `delivery_note_lines.requested_cases` | `create_delivery_note` | No | Paperwork of ordered qty. **Not billable.** |
| Reserved | `stock_reservations.reserved_cases` | `reserve_order_allocation` | Hold | Not billable. |
| Picked | `stock_reservations.picked_cases` | `confirm_picking_quantity` | No | Loaded candidate. Not yet consumed. |
| Accounts-approved short-ship | `order_shipment_lots.approved_cases` | `approve_short_shipment` | No | Becomes billable only after dispatch. |
| **Actual dispatched (full)** | Consumed `reserved_cases` + DISPATCH ledger | `confirm_dispatch` | **Yes** | **Billable loaded qty.** |
| **Actual dispatched (short)** | `order_shipment_lots.shipped_cases` (= approved) + DISPATCH ledger | `confirm_dispatch` | **Yes** | **Billable loaded qty.** |
| Outcome dispatched record | `stock_dispatch_outcome_lines.dispatched_cases` | POD / fail / partial RPCs | No | Must equal consume qty; secondary copy. |
| Successfully delivered | `stock_dispatch_outcome_lines.delivered_cases` | POD / partial | No | Physical shop receipt. **Not** automatically billable. |
| Undelivered / failed | `undelivered_cases` + `delivery_outcome` | fail / partial | No | Stock still deducted until return. |
| Returned saleable | `stock_delivery_return_lots.saleable_cases` then DELIVERY_RETURN credit | `post_delivery_return` | **Yes** | Credit-note candidate after post. |
| Returned damaged / uncertain | `damaged_cases` / `uncertain_cases` → quarantine | `post_delivery_return` | **Yes** | Credit-note / write-off candidate. Not automatic invoice cancel. |
| Missing | `missing_cases` | count / `close_delivery_return_missing` | No | Credit-note / loss candidate. No stock credit. |
| Backorder | child `order_lines.requested_cases` | `create_linked_backorder` inside dispatch | No | Separate future invoice after that child is dispatched. |

### 2.1 Partial delivery, failed delivery, short shipment

**Fact — these four quantities are not identical:** ordered ≠ DN ≠ picked ≠ dispatched ≠ delivered ≠ returned.

| Scenario | What left the godown | What the shop kept | Stock after | Invoice implication (recommendation) |
|---|---|---|---|---|
| Full pick, POD delivered | Consumed reserved | All dispatched | Deducted | Invoice note = dispatched. Final invoice same unless owner waits for POD. |
| Short shipment, POD delivered | `approved_cases` / `shipped_cases` | All shipped | Deducted shipped only | Invoice = shipped, **not** ordered. Remainder is a new backorder, invoiced later if dispatched. |
| Failed delivery | Dispatched | None | Still deducted until return post or close-missing | Do **not** auto-cancel invoice. If invoiced at load, owner needs a credit-note rule after return. |
| Partial delivery | Dispatched | `delivered_cases` | Remainder deducted until return | Invoice-at-load bills the van contents. Undelivered portion is return/credit, not a silent qty rewrite. |
| Return posted | n/a | n/a | Saleable/damage credited | Adjustment document, not rewrite of a finalized invoice. |
| Close missing | n/a | n/a | No credit | Loss / credit-note decision. |

**Recommendation (billable source):** snapshot **DISPATCH consume quantity at `confirm_dispatch`**, grain-for-grain:

- Full path: consumed reservation `(product, lot, crate, reserved_cases)`.
- Short path: `order_shipment_lots.shipped_cases`.

That matches BPM “actual loaded goods” and M7.1 ORD-07. DN ordered qty and POD delivered qty are different artefacts.

**Owner decision I1** must choose whether the **final** invoice waits for POD and/or the return wave. See section 10.

---

## 3. Pricing gap analysis

| Capability | Fact |
|---|---|
| Product sale price | **Absent.** `products` comment: no quantity, price, unit, or reorder level. Columns: sku, name, supplier, category, active, later `expiry_policy`. |
| Shop-specific prices | **Absent.** `shops`: name, phone, address, active. |
| Price lists / effective dates | **Absent.** |
| Discounts / free goods | **Absent.** |
| Case-level pricing | Unit of measure is carton case everywhere. No second unit. No price on the case. |
| Historical snapshots | **Absent** (nothing to snapshot). |
| Currency / rounding | **Absent.** No currency column. |
| Order/DN/shipment line prices | **Absent.** |

Phase 4.1 forbade prices. M7.1 D3 is still open: quantity-only documents vs priced/tax invoices vs keep invoices outside SherlysOS.

**Recommendation:** do not invent list prices, shop overrides, or discounts in M7.5B until the owner picks D3 and I2–I4. If D3=(b), minimum viable is a case-level exclusive product price with effective dating and an immutable snapshot copied onto the finalized invoice line. Shop overrides, schemes, and free goods are later unless the owner requires them now.

---

## 4. GST / tax gap analysis

| Capability | Fact |
|---|---|
| Product HSN/SAC | **Absent.** |
| GST rates | **Absent.** Nothing to hardcode; do not invent percentages. |
| Tax-inclusive vs exclusive | **Absent.** |
| Supplier GSTIN | **Absent.** Suppliers: name, phone, email only. Comment: no tax, bank, or credit columns. |
| Shop / customer GSTIN | **Absent.** |
| Billing vs shipping address | Shop has a single optional `address` (≤400). No billing/shipping split. |
| Place of supply / state code | **Absent.** `branches` are `code`, `name`, `is_active` only. |
| CGST / SGST / IGST split | **Absent.** |
| Exemptions | **Absent.** |
| Rounding | **Absent.** |
| Company GSTIN | Optional `company.tax_id` is print identity only, not a calculation input. |

**Recommendation:** statutory invoice format, HSN, GSTIN validation, intra- vs inter-state tax, and rounding **must be confirmed by the business’s accountant or tax adviser**. SherlysOS must not hardcode GST percentages.

If D3=(a) quantity-only, GST fields can wait. If D3=(b), M7.5B still must not guess rates; store owner-supplied masters and snapshot them at finalization.

---

## 5. Proposed invoice lifecycle

Documents (recommendation), matching unused permissions and BPM:

```
DISPATCH posted (loaded qty frozen)
  → invoice_note  draft        GM  invoice_notes.prepare
  → invoice_note  prepared     GM  submit for Accounts
  → invoice       in_review    Accounts
  → invoice       finalized    Accounts invoices.issue   ← numbering + immutable snapshot
  → print / reprint            authorized readers
  → handed_to_driver           Accounts or GM (owner I8)
  → [optional] cancelled       Accounts, before handover if owner allows
  → [optional] credit_note     Accounts, after posted return / missing
```

Invoice RPCs must **not** call stock writers. Returns must **not** rewrite a finalized invoice.

### 5.1 Transitions

| From → to | Role | Prerequisites | Idempotency | Concurrency | Audit | Immutability | Rollback |
|---|---|---|---|---|---|---|---|
| (none) → note draft | GM `invoice_notes.prepare` at dispatch godown | `confirm_dispatch` posted; unique open note per dispatch; assigned godown | `invoice_note:{dispatch_id}` | `lock dispatch → order → note`. Second key after create returns existing. | `invoice_note_events.created` | Qty copied from DISPATCH grain; not editable to arbitrary values | Statement abort; no number issued |
| draft → prepared | GM | Lines cover every dispatched grain; sum = DISPATCH qty | note id + version | Stale version `PT409` | `prepared` | Qty frozen | Abort |
| prepared → in_review | Accounts `invoices.issue` | Note prepared; shop/godown match | invoice idempotency key | Unique open invoice per note | `review_opened` | Still mutable prices only if owner allows pre-finalize edits | Abort |
| in_review → finalized | Accounts | Identity ready (`company.*` + owner tax fields); prices/tax if D3=(b); fingerprint of qty+price+tax | `invoice:{note_id}` unique | Report-row lock; unique invoice number; second finalize returns same invoice | `finalized` + `write_audit` | Header, lines, totals, number, date frozen | Abort leaves note prepared, no number consumed if insert fails after `nextval` — use the same sequence pattern as DN (assign in INSERT trigger inside the txn) |
| finalized → printed | issue or monitor | `finalized` | n/a | Read-only | `printed` (count reprints) | Original bytes/snapshot unchanged | n/a |
| finalized → handed | Accounts (recommended) | Finalized; dispatch not cancelled | `handover:{invoice_id}` | Once | `handed_to_driver` | n/a | Abort |
| draft/prepared → cancelled | GM (note) / Accounts (review) | Not finalized | version | Stale version fails | `cancelled` | Terminal | Abort |
| finalized → cancelled | **Owner I6** | If allowed at all: not handed, or statutory credit instead | n/a | n/a | n/a | Prefer credit note over delete | n/a |
| posted return → credit_note | Accounts | Return `posted` or `closed_missing`; original invoice `finalized` | `credit:{return_id}` | Unique per return | `credit_issued` | New document; original invoice remains | Abort; stock already posted independently |

**Fact to preserve:** `post_delivery_return` must stay independent of invoice state.

---

## 6. Proposed schema and RPC contracts

Recommendation only. No migration in this milestone.

### 6.1 Tables (FORCE RLS, client SELECT, GUC `app.invoice_write`)

- `invoice_notes` — `dispatch_id` unique for open notes; `order_id`; `godown_id`; `shop_id`; `delivery_note_id` (reference, not qty source); `status`; `version`; `idempotency_key`; prepared_by/at.
- `invoice_note_lines` — `product_id`, `lot_id`, `source_crate_id`, `dispatched_cases`, `order_line_id`, optional `shipment_lot_id`. Check sum of cases = DISPATCH grain.
- `invoice_note_events` — append-only.
- `invoices` — `invoice_note_id` unique; `invoice_number`; `invoice_date`; `status`; `handed_at/by`; snapshot jsonb of company, shop, tax, totals; `qty_fingerprint`; `price_fingerprint`.
- `invoice_lines` — copied dispatched cases plus **frozen** sku/name, HSN, rate, taxable value, tax components (zeros if D3=(a)).
- `invoice_events` — append-only.
- `invoice_credit_notes` / lines — only if owner I5=(yes). Linked `delivery_return_id` or `missing` close. Does not reverse `DELIVERY_RETURN` stock.

Unique indexes: open note per dispatch; one finalized invoice per note; `invoice_number` unique; credit unique per return.

### 6.2 RPCs (SECURITY DEFINER, `search_path=''`, GRANT EXECUTE authenticated only)

| RPC | Permission |
|---|---|
| `prepare_invoice_note` | `invoice_notes.prepare` |
| `submit_invoice_note` | `invoice_notes.prepare` |
| `cancel_invoice_note` | `invoice_notes.prepare` |
| `review_invoice` | `invoices.issue` |
| `finalize_invoice` | `invoices.issue` |
| `get_invoice` / `get_invoice_print` | issue, prepare, `deliveries.execute` (assigned driver, read), `operations.monitor` |
| `record_invoice_handover` | `invoices.issue` |
| `create_invoice_credit_note` | `invoices.issue` (if I5) |

Private helpers revoked from `public/anon/authenticated/service_role`. Number sequence revoked from clients.

### 6.3 Quantity copy rule

`prepare_invoice_note` reads DISPATCH ledger grains (or `dispatch_return_source_grains` equivalent used by returns) **inside the same lock order as dispatch**: order → DN → picking → shipment → dispatch → products. It does not accept client-supplied quantities except for rejecting mismatch.

---

## 7. Role and permission matrix

| Action | Admin | Accounts | Godown Manager | Store Keeper | Delivery Person | Salesperson |
|---|---|---|---|---|---|---|
| Prepare invoice note | no (today unused; recommend keep unused unless owner grants) | no | **yes** (`invoice_notes.prepare`) | no | no | no |
| Finalize / sign invoice | no | **yes** (`invoices.issue`) | no | no | no | no |
| Print finalized | monitor if granted | yes | yes (own godown) | no | assigned dispatch only | no |
| Record handover | no | yes | owner I8 | no | no | no |
| Credit note | no | yes | no | no | no | no |
| Change stock via invoice | **never** | **never** | **never** | **never** | **never** | **never** |
| Cross-godown | `branches.access_all` still should not issue another godown’s invoice unless owner says so | shop/godown on the order | `can_work_at_branch` | n/a | assigned only | n/a |

**Fact:** current grants already match BPM actors. Do not grant GM `invoices.issue` or Accounts `invoice_notes.prepare` for convenience (M7.1 warning).

---

## 8. Short-shipment, return, and backorder handling

| Event | Invoice behaviour (recommendation) |
|---|---|
| Full dispatch | One invoice note from consumed reserved qty. |
| Approved short-ship | One invoice note from `shipped_cases`. Do not bill `ordered_cases`. |
| Linked backorder | No invoice at creation (`submitted` child, zero stock). Invoice only after that child is dispatched. |
| Short-ship of a backorder | Already fail-closed in stock. No extra invoice rule. |
| `SHORT_SHIPMENT_OPERATIONAL=false` | Full path only in production. Invoice design must still accept the short path so enabling the flag later does not require a second invoice architecture. |
| Failed / partial delivery | Do not mutate invoice qty. Return workflow owns physical stock. |
| Posted return | Optional credit note (I5). Never `DELETE` invoice lines. Never call `post_delivery_return` from invoice RPCs. |
| Close missing | Optional credit / loss note. No stock txn. |
| Transit-damage overlap | Returns already fail-closed on overlap. Invoice remains based on DISPATCH until a credit is explicitly issued. |

---

## 9. Concurrency and idempotency design

Follow existing SherlysOS patterns (DN, dispatch, write-off completed-identification):

- Unique idempotency keys on create/finalize.
- Completed identification **before** stale-version reject on finalize (same lesson as `post_ordinary_damage_writeoff` in `20261026180800`).
- `PT409` on stale note/invoice version.
- Sequence `nextval` inside the inserting transaction; number column immutable.
- Advisory or row lock on `dispatch_id` so two GMs cannot create two open notes.
- Unique `(dispatch_id)` where note status not cancelled.
- Unique finalized invoice per note.
- Invoice writers set `app.invoice_write` only; they must not set `app.dispatch_write` / `app.delivery_return_write`.
- Exactly-once finalize: unique `request_fingerprint` of `(note_id, qty_fingerprint, price_fingerprint)`.
- Failure: PostgreSQL statement abort; no partial header without lines.

---

## 10. Explicit owner decisions

| # | Question | Options | Recommendation | Blocks M7.5B? |
|---|---|---|---|---|
| **D3** (carried) | Quantity-only note, priced+tax invoice, or keep invoices outside SherlysOS? | (a) Quantity-only loaded-goods note + unsigned PDF. (b) Case prices + GST snapshot. (c) External Tally only. | **Ask.** BPM requires documents; Phase 4.1 forbade prices. (c) skips M7.5B. | **Yes.** |
| **I1** | When is the **final** invoice dated/issued vs physical delivery? | (1) At dispatch (loaded). (2) After POD. (3) After return window closes. | **(1)** matches BPM (invoice in the driver’s hand). Returns then need credit notes (I5). | **Yes.** |
| **I2** | Price source if D3=(b)? | (1) Product case list price. (2) Shop-specific. (3) Manual Accounts entry per invoice. | **(1)** now; (2)/(3) only if operations require it. Snapshot at finalize. | If D3=(b). |
| **I3** | Tax-inclusive or exclusive? | Exclusive + GST components / inclusive / mix. | **Accountant.** Do not guess. | If D3=(b). |
| **I4** | Discounts, schemes, free cases? | None in M7.5 / header % / line schemes. | **None in M7.5B** unless owner has live schemes. | No if none. |
| **I5** | Credit notes after returns/missing? | (1) Yes, Accounts document linked to return. (2) External. (3) Rewrite invoice (reject). | **(1)** if I1=(1). **Never (3).** | If I1=(1). |
| **I6** | Cancel a finalized invoice? | Credit only / cancel if not handed / unrestricted void. | Credit-only after finalize. | Policy. |
| **I7** | Invoice numbering? | Company-wide `INV-YYYYMMDD-######` like DN; financial-year `INV/YY-YY/######`; per-godown series. | Company-wide sequence + **FY prefix confirmed by accountant** (Indian GST often wants FY series). Godown-specific only if statutory books are per branch. | **Yes.** |
| **I8** | Who records handover to driver? | Accounts / GM / either. | **Accounts** (`invoices.issue`) to match “hands final invoice to Delivery Person.” | No. |
| **I9** | Signature/seal? | Typed name + timestamp / scanned image later / wet-ink only. | Timestamp + actor name in M7.5B (same as DN). No public unsigned upload. | No. |
| **I10** | Invoice date? | Dispatch timestamp / Accounts clock / user-entered. | Server `clock_timestamp()` at finalize; timezone UTC stored, display IST owner choice. | Policy. |
| **I11** | Place of supply / GSTIN masters? | Defer / add shop GSTIN + company GSTIN + state. | Required if D3=(b). Accountant supplies validation rules. | If D3=(b). |
| **I12** | Currency? | INR implicit / explicit column. | Explicit `INR` snapshot on invoice; no FX. | If D3=(b). |

---

## 11. M5.4D unresolved risk

Carried from M7.4C. **Diagnostic only. M5 posting functions were not modified in this audit.**

### 11.1 Observation

`phase_m5_4d_concurrency.mjs` race `write-off vs quarantine transfer`:

- Isolated: 9/9 PASS (three executions in M7.4C).
- One sequential-matrix attempt FAIL: assertion `both transfer and write-off posted`.

### 11.2 What the production functions do (facts)

- Unique index is `(damage_report_id, damage_posting_kind)` — **one row per kind**, so `quarantine_transfer` and `ordinary_writeoff` can both exist.
- `transfer_verified_damage_to_quarantine` posts `CRATE_TRANSFER` from active `on_hand_deduction` holds and sets holds to `transferred`.
- `post_ordinary_damage_writeoff` → `consume_damage_holds` consumes holds in `('active', 'transferred')` and posts `ordinary_writeoff`.
- M5.4D document section 9: write-off quantity is the remaining **active/transferred** hold total. Transfer-then-write-off is an intended pipeline (relocate to quarantine, then write off quarantine stock), not two alternative debits of the same saleable crate.

Serialized outcomes:

1. **Write-off first:** original crate ADJUSTMENT; holds `written_off`; transfer finds no active holds → `23514`. Kinds = `ordinary_writeoff` only.
2. **Transfer first:** CRATE_TRANSFER to quarantine; holds `transferred`; write-off then consumes transferred holds → both kinds. Net: original crate −qty, quarantine +qty then −qty.

That is **not** a double debit of saleable stock.

### 11.3 Classification

| Hypothesis | Verdict |
|---|---|
| Fixture collision | Unlikely. Unique `PREFIX`; kinds filtered by `report_wt`. |
| Stale flags / session | Unlikely. Suite `finally` restores flags. |
| Harness assertion defect | **Primary.** XOR (`both posted` is failure) is too strict for transfer-first serialization, which is allowed by `consume_damage_holds`. |
| Genuine conservation bug | **Not demonstrated.** Transfer-then-write-off is documented remaining-hold consumption. |
| Product mutual-exclusion gap | Optional follow-up: if operations want write-off **or** transfer as alternatives, production should refuse write-off on `transferred` holds. That is an M5 design change, not invoice work. |

**Release blocker for M7.5 invoices?** **No.** Unrelated financial module; no silent dual saleable debit proven.

**Release blocker for damage cutover?** **Not proven.** Remaining M5 test debt: either accept transfer-then-write-off in the harness, or (owner/M5 decision) make the two RPCs mutually exclusive. Do **not** mark resolved.

---

## 12. Proposed M7.5B implementation stages

Do not start until D3 and I1/I7 (and I2–I5 if D3=(b)) are answered.

| Stage | Scope | Not in stage |
|---|---|---|
| **B0** | Owner decision log in this file. | Code. |
| **B1** | Invoice note + invoice tables, GUC, FORCE RLS, qty snapshot from DISPATCH, GM prepare/submit, Accounts finalize **quantity-only**, print payload reuse of `read_company_print_identity`, handover, zero stock tests. | Prices, GST calc, PDF binary, credits, Tally. |
| **B2** | If D3=(b): product (and optional shop) price masters, effective dates, snapshot on finalize. | Schemes/free goods unless I4. |
| **B3** | If D3=(b) and accountant pack: HSN, GSTIN, place of supply, tax components, rounding **as specified**. | Hardcoded rates. |
| **B4** | If I5: credit notes linked to posted returns / close-missing. Still no stock writes. | Auto-cancel invoice; auto-call `post_delivery_return`. |
| **B5** | Playwright DN → note → invoice → driver visibility; SQL RLS; concurrency finalize-once; lint/typecheck. | Flag activation; cloud. |

If D3=(c), **skip B1–B5** and record ORD-07/08 as owner-accepted external.

Suggested first migration tip after `20261028000000`, local Docker only, when approved.

---

## 13. Dependencies and acceptance criteria

### Dependencies

- M7.4B return writer exists and must stay independent.
- M7.3B short-ship qty path must be readable even while `SHORT_SHIPMENT_OPERATIONAL=false`.
- DN print identity keys already exist; extend rather than invent a second company table.
- Production picking/dispatch still needs lot cutover flags (remain false). Invoice RPCs must work in tests with replica-enabled dual-write the same way dispatch tests do, then restore flags.
- Accountant/tax adviser for D3=(b) and I3/I7/I11.
- Clean migration replay still needs a **second** Supabase instance (`auth.users` from `20261014150000`). Not required in this design milestone. Do not `db reset` the owner database.

### Acceptance for a later M7.5B (when approved)

- Unique invoice note per dispatch; qty fingerprint matches DISPATCH grains.
- Accounts cannot prepare; GM cannot finalize.
- Finalize is exactly-once; number unique and immutable.
- Invoice RPCs insert zero `stock_transactions`.
- Returns do not mutate finalized invoices.
- Driver can see handover; unauthorized roles 42501.
- Flags remain false after tests.
- Playwright covers prepare → finalize → print/handover; unauthorized GM cannot issue.

### Out of M7.5 unless separately approved

- Payments, credit ledgers, outstanding balances.
- TallyPrime.
- Lot cutover activation.
- Damage write-off vs transfer mutual-exclusion change.

---

## 14. Clean migration replay (documentation only)

**Fact:** `20261014000000` is comment-only. `20261014150000` creates `profiles` referencing `auth.users`. Later tests use `extensions.crypt`.

**Not feasible** on a bare extra Postgres. Requires a disposable `npx supabase start` on unused ports. Owner development database must not be reset. No replay was executed in this milestone.
