# M7.4B — Failed/partial delivery return contract (design only)

Design and audit checkpoint after M7.4A. **No stock writer was implemented.** This document is the implementation contract for a later authorized phase.

Local-only. No commit, push, cloud migration, Netlify deploy, flag activation, invoice work, or ledger posting in this checkpoint.

Starting HEAD: `de317a377403e48be07a36fa0431fe7b6761e8b9`  
`feat(m7.4a): implement vehicle master and delivery operations` on `main`.

Working tree was clean at start. M7.4A is committed. Local migration tip: `20261027230000`.

Flags (read-only, remain false):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`

BPM source: `reference/Sherlys_Distribution_Agents_BPM.pdf` is **not present in this workspace** (same limit recorded in earlier phase docs). BPM statements below reuse the M7.1 extraction of Branch 01 ORD-09 and Branch 02 DMG-05/DMG-06, plus live M3/M5/M7.3B/M7.4A schema.

Owner decision D5 already chose a dedicated return-receipt path, not silent restock inside `report_dispatch_delivery_exception`, and not an implicit shortcut through supplier receiving.

---

## 1. Actual schema findings

### 1.1 What already exists (reuse)

| Object | Finding |
|---|---|
| `confirm_dispatch` | Sole order-fulfilment debit. One `DISPATCH` `stock_transactions` row per dispatch (`stock_transactions_dispatch_once`). Ledger grains are `(product_id, crate_id, lot_id)` with **negative** quantity. Dual-path: full consume uses consumed `stock_reservations`; short-ship uses `order_shipment_lots.shipped_cases`. |
| `verify_stock_receipt` | Supplier inbound. Requires `receiving.verify`, a submitted `stock_receipts` header, supplier, destination crate, and **creates new lots** (`stock_lots.origin` in `receipt` / `opening` / `legacy_reconciliation` / `adjustment`). Not a delivery-return writer. |
| `stock_transactions` | Types: `OPENING_STOCK`, `CRATE_TRANSFER`, `RECEIPT`, `ADJUSTMENT`, `DISPATCH`. Header `quantity >= 1`. Unique `idempotency_key` and `reference_number`. Append-only. |
| `stock_ledger` | Signed crate lines. `lot_id` nullable in the column, required by lot-aware apply. Append-only. No client writes. |
| `stock_lots` | Identity + expiry + `status` (`available`, `quarantined`, `expired_blocked`, `legacy_unattributed`). `apply_lot_aware_stock_deltas` refuses `legacy_unattributed` except legacy reconcile, and refuses `quarantined` / `expired_blocked` for ordinary apply. |
| `stock_reservations` | `(picking_request_id, order_line_id, crate_id, lot_id)` with `reserved_cases` / `picked_cases`. Status `active` / `released` / `consumed`. Consumed rows remain after dispatch. |
| `order_shipment_lots` | Short-ship grain: `reservation_id`, `lot_id`, `crate_id`, `order_line_id`, `shipped_cases`. |
| `stock_dispatch_outcome_lines` | **Order-line** grain only: `dispatched_cases`, `delivered_cases`, `undelivered_cases`. No `lot_id`, no `crate_id`. Unique `(dispatch_id, order_line_id)`. |
| `stock_dispatch_delivery_attempts` | Attempt history. No quantities. |
| `physical_return_status` | Allowed value is **only** `pending_verification`. Exception shape **requires** that exact value while `status='exception'`. Closure of a return cannot be recorded on the dispatch header without a constraint change. |
| `return_required` | Boolean on the dispatch. Set true for failed/partial. Not a stock posting gate. |
| Damage | Scenarios include `transit` (assigned driver, DMG-05) and `shop_return` (DMG-06, custody then quarantine intake). Quarantine crate `QRN-01` per godown. `prepare_stock_locations` refuses quarantine crates unless `app.damage_stock_write` is the trusted token. `damage.stock_hold_ready` is still false. |
| Cross-godown | `stock.transfer.post` is same-godown crate transfer. There is **no** approved inter-godown transfer writer. |
| Permissions | Store Keeper: `receiving.execute`, `damage.record`, `damage.read`. **No** `dispatch.view`. Driver: `deliveries.execute` only. GM: `dispatch.exception`, `receiving.verify`, `damage.verify`. Admin: dispatch view/confirm/exception; **no** `damage.record` / `receiving.execute`. |

### 1.2 How a dispatched case traces to lot and godown today

Do **not** infer lots from order totals. The recoverable debit grain is:

```
dispatch.branch_id                         → originating godown
dispatch.posted_transaction_id             → DISPATCH header
stock_ledger where transaction_id = that
  and quantity < 0                         → (product, crate, lot, dispatched_cases = -quantity)
stock_reservations consumed
  (full path)                              → (order_line, product, crate, lot, reserved_cases)
order_shipment_lots.shipped_cases
  (short-ship path)                        → (order_line, product, crate, lot, shipped_cases)
crates.zone_id → zones.branch_id           → receiving godown of the original crate
```

That grain is sufficient to know **what left the warehouse**. It is **not** sufficient to know **which of those lots came back** after a partial delivery.

### 1.3 Partial-delivery lot attribution — insufficient

`stock_dispatch_outcome_lines` stores undelivered cases per `order_line_id`. One order line may have been dispatched from several lots/crates. Example: line ordered 10, shipped lot A×6 + lot B×4, undelivered 3. The current row cannot say whether those 3 belong to A, B, or a mix.

Failed delivery (`delivered_cases=0` on every line) can snapshot **all** dispatched lots as the expected physical return set. Partial delivery cannot.

**Required new records (not optional):** a lot×crate×order-line allocation of undelivered cases, verified against the dispatched grain, before any restock.

### 1.4 Why existing writers cannot be reused

| Writer | Why it is the wrong tool |
|---|---|
| `verify_stock_receipt` | Supplier document, new lots, `RECEIPT` type, unique `receipt_line_id`. Would mint a second identity for goods that already exist as dispatched lots. |
| `confirm_dispatch` | Debit-only. Unique one `DISPATCH` per dispatch. Must not be inverted. |
| `post_stock_adjustment` | Reason-coded correction, not a delivery document. Would hide failed-delivery restock inside adjustments. |
| `post_crate_transfer` | Same-godown move of **on-hand** stock. Returned goods are not on-hand until posted. |
| Damage `ADJUSTMENT` / quarantine intake | Holds unavailable stock for damage reports. Transit damage is a **separate** BPM path (DMG-05). Failed delivery of saleable cartons is not automatically damage. |
| Opening stock | Once per product×crate. Irrelevant. |

`stock_transactions_dispatch_once` unique on `dispatch_request_id` means a return **cannot** reuse `DISPATCH` or the same FK. A new type and a new FK are required.

### 1.5 Constraint that blocks closure today

`stock_dispatch_requests_exception_shape` forces `physical_return_status = 'pending_verification'` for every exception row. `stock_dispatch_requests_return_check` allows only that value. Implementation must widen these checks; it must not try to close returns by overloading `status` back to `delivered` (delivered shape requires POD fields and `delivery_outcome='delivered'`).

---

## 2. Proposed return lifecycle

Separate operational document: `stock_delivery_returns`. Do not invent a second dispatch engine. One **open** return per dispatch with `return_required=true`.

```
Posted dispatch (DISPATCH debit exists)
  → failed or partial delivery (M7.4A exception, return_required)
  → driver handback declaration
  → Store Keeper physical count (lot, crate, condition)
  → GM review / approval
  → post_delivery_return (dedicated writer) or close-all-missing
  → audited closure
```

### 2.1 Condition classes

| Class | Physical meaning | Stock effect |
|---|---|---|
| **Saleable** | Counted, intact, eligible for later pick | Credit original lot onto an authorized **storage** crate in the originating godown |
| **Damaged** | Counted, not saleable | Credit original lot onto the godown **quarantine** crate only. Not pickable. |
| **Uncertain** | Counted, condition not decided | Same as damaged until a later M5 verification. Not pickable. |
| **Missing** | Declared or counted as not present | **No stock increase.** Ledger already reflects the DISPATCH debit. |

Delivered cases (from M7.4A outcome lines) stay out of the return document. They are not restocked.

### 2.2 Return document statuses

| Status | Meaning | Who |
|---|---|---|
| `awaiting_handback` | Created when exception sets `return_required` (or first driver/GM open). No stock. | system / GM |
| `handed_back` | Driver declared physical return of some or all undelivered cases. | assigned driver |
| `counted` | Keeper entered lot/crate/condition counts. | Store Keeper |
| `approved` | GM accepted the count. Still no stock. | GM |
| `posted` | Dedicated writer committed. Terminal. | GM (post RPC) |
| `closed_missing` | All remaining undelivered classified missing. Terminal, no credit. | GM |
| `cancelled` | Abandoned before post. Terminal. Only if nothing posted. | GM |

Dispatch `status` stays `exception`. Dispatch `physical_return_status` tracks the return document (see §5).

### 2.3 Allowed transitions

```
awaiting_handback → handed_back          driver (assigned) or GM dispatch.exception
handed_back       → counted              store keeper
counted           → approved             GM
counted           → handed_back          GM return-to-count (versioned)
approved          → posted               GM post RPC (atomic stock)
approved          → counted              GM stale/reject count (versioned, before post)
approved          → closed_missing       GM, only if saleable+damaged+uncertain = 0
awaiting_handback → closed_missing       GM, explicit all-missing, no physical goods
*                 → cancelled            GM, before post only
```

Forbidden:

- Driver count or post.
- Keeper approve or post.
- Post from `handed_back` without a keeper count.
- Post after `cancelled` / `posted` / `closed_missing`.
- Post against `delivered`, `cancelled`, or unconsumed dispatch.
- Re-open after post.

Idempotent replay of the **same** post key after success returns the posted payload.

---

## 3. Quantity reconciliation

Per dispatched lot grain `g = (dispatch_id, order_line_id, product_id, lot_id, source_crate_id)`:

```
dispatched_g     = shipped/consumed cases on that grain (integer ≥ 1)
delivered_g      = allocated delivered cases (see partial rule)
saleable_g
damaged_g
uncertain_g
missing_g
unresolved_g     = dispatched_g - delivered_g - saleable_g - damaged_g - uncertain_g - missing_g

0 ≤ each term
delivered_g + saleable_g + damaged_g + uncertain_g + missing_g + unresolved_g = dispatched_g
saleable_g + damaged_g + uncertain_g + missing_g ≤ undelivered_line
```

Document-level:

```
sum(saleable + damaged + uncertain + missing) ≤ sum(undelivered_cases on outcome lines)
sum(delivered from M7.4A) + sum(return classes) = sum(dispatched)
```

Posting gate: `unresolved_g = 0` for every grain. Partial posting of “the bits we counted” is refused unless the owner later approves multi-wave returns (default: **one close**).

Missing cases never produce a positive ledger row. Damaged/uncertain never produce a storage-crate credit.

### 3.1 Failed delivery

`delivered_g = 0` for every grain. The expected physical set **is** the dispatched lot snapshot. Driver/keeper still classify condition; they must not invent extra lots.

### 3.2 Partial delivery — required allocation gate

Before `counted` can be saved:

1. Load dispatched grains from reservations or `order_shipment_lots` (not from order totals).
2. Require `sum(delivered_g)` per `order_line_id` = `stock_dispatch_outcome_lines.delivered_cases`.
3. Require `sum(undelivered allocated to lots)` = `undelivered_cases`.
4. `delivered_g + undelivered_g = dispatched_g` per grain.

Who performs step 2–4 is owner decision **R3**. Default recommendation: Store Keeper, because the driver does not have trustworthy lot identity in the current UI.

Until that allocation exists, **stop** — do not restock from order-line undelivered totals.

### 3.3 Duplicate posting protection

- Unique open return per `dispatch_id`.
- Unique `stock_transactions.delivery_return_id`.
- Unique idempotency key `delivery-return:<return_id>`.
- Outcome lines already unique; do not rewrite them at post.
- DISPATCH `posted_transaction_id` remains immutable (existing dispatch write guard).

---

## 4. Role and approval design

New permissions (do not overload `receiving.*`):

| Code | Roles | Use |
|---|---|---|
| `deliveries.return_view` | Admin, GM, Store Keeper, assigned driver | Read the return document for authorized godowns |
| `deliveries.return_handback` | Delivery Person | Declare handback on **assigned** dispatch only |
| `deliveries.return_count` | Store Keeper | Physical lot/condition count at the originating godown |
| `deliveries.return_approve` | Godown Manager | Accept count |
| `deliveries.return_post` | Godown Manager | Call the dedicated writer |

GM already has `dispatch.exception` (create/fail). That must **not** grant post. Admin monitor/history only — same pattern as damage: Admin does not post ordinary stock.

Store Keeper still has no `dispatch.confirm`. Count is not consume and not credit.

Driver cannot classify saleable into a crate. Handback is a declaration (`handed_back_at`, actor, optional notes, optional declared case totals). The keeper count is the posting quantity.

**Segregation:** GM must not skip keeper count (default). Owner decision **R6** if a small godown needs GM-as-keeper.

Cross-godown: `receiving_branch_id` must equal `stock_dispatch_requests.branch_id`. A different godown is refused. After posting at origin, a later same-godown crate transfer may move saleable stock; inter-godown movement still requires a future transfer contract.

Inactive godown: historical read allowed; new count/post refused (`assert_operational_active_branch`), matching other operational writers.

---

## 5. Dedicated `DELIVERY_RETURN` stock writer (design, not implemented)

Name: `public.post_delivery_return(target_return uuid, expected_version integer, idempotency_key text)`  
`SECURITY DEFINER`, `search_path = ''`, EXECUTE `authenticated` only. Private apply helpers revoked from clients.

### 5.1 Authorized caller

`deliveries.return_post` + `can_work_at_branch(dispatch.branch_id)` + return `status='approved'` + dual-write enabled. Store Keeper and driver denied. Admin denied unless the owner later grants post (not recommended).

Approver is a prior `deliveries.return_approve` actor, stored on the document. Poster may be the same GM; that is owner decision **R6**. The post RPC re-checks current permission (revoke during retry → 42501).

### 5.2 Preconditions

1. Dispatch `stock_consumed`, `status='exception'`, `return_required`, `delivery_outcome in ('failed','partial')`.
2. `posted_transaction_id` present and still the DISPATCH row.
3. Dual-write on; fail closed if off (same as `confirm_dispatch`).
4. Every grain resolved (`unresolved=0`).
5. Destination storage crates: `location_role='storage'`, active, same branch.
6. Destination for damaged/uncertain: `ensure_godown_quarantine_crate(branch)` only.
7. Each credited `(lot_id, product_id)` matches a dispatched grain. Wrong lot → `23514`.
8. Saleable destination must not be quarantine. Damaged/uncertain must not be storage.
9. Lot `status='available'` for saleable credits. Expired/quarantined/legacy lots cannot become saleable via this writer.
10. Fingerprint of approved lines matches post fingerprint (stale count → `PT409`).

### 5.3 Required lot attribution

Posting input is the approved return-lot table, not outcome-line totals. Ledger credits:

- Saleable: `+saleable_g` on chosen storage crate, **same `lot_id`**.
- Damaged + uncertain: `+(damaged_g+uncertain_g)` on quarantine crate, **same `lot_id`**.
- Missing: omitted.

No new `stock_lots` rows. Origin stays the original receipt/opening lot.

### 5.4 Ledger event identity

| Field | Value |
|---|---|
| `transaction_type` | `DELIVERY_RETURN` (new; extend type + shape checks) |
| `delivery_return_id` | new FK, unique where not null |
| `dispatch_request_id` | **null** (must not collide with `stock_transactions_dispatch_once`) |
| `receipt_id` / `adjustment_request_id` / `damage_report_id` | null |
| `idempotency_key` | `delivery-return:<return_id>` |
| `reference_number` | return document number, e.g. `DR-YYYYMMDD-######` |
| Header `quantity` | sum of credited cases (saleable + quarantine). If that sum is 0, do not insert a transaction; use `closed_missing` instead. |
| `source_crate_id` | null |
| `destination_crate_id` | set only if every credit lands on one crate; else null (same pattern as multi-crate DISPATCH `source_crate_id`) |
| Ledger lines | positive quantities only |

### 5.5 Atomicity and idempotency

One PostgreSQL function, one transaction. Injected ledger failure rolls back balances, lots, return status, and dispatch `physical_return_status`. Replay after commit: if return already `posted` and key+fingerprint match, return payload even if `expected_version` is stale (same M3 lost-HTTP pattern). Different fingerprint → `23505`/`23514`.

### 5.6 Lock order

Must match trusted writers (M3/M5):

1. Cutover shared advisory `(88104301, 1)`
2. Order → picking → dispatch `FOR UPDATE`
3. Return document `FOR UPDATE`
4. Products by id
5. `prepare_stock_locations` (zones → crates → branch). Quarantine crate allowed only with trusted `app.damage_stock_write` token when damaged/uncertain > 0
6. Lots by id
7. `stock_lot_balances` `(crate_id, lot_id)`
8. `stock_balances` `(crate_id, product_id)`
9. Insert transaction + ledger + `apply_lot_aware_stock_deltas`
10. Stamp return `posted`, dispatch `physical_return_status`, events, audit

Never lock branch before documents (M5.3 deadlock lesson). Never take transfer lock order.

### 5.7 Concurrent return protection

Row lock on dispatch then return. Unique open return index. Unique posted transaction. Two GM posts: one winner, one `PT409` or unique violation mapped to “already posted”.

### 5.8 Quarantine handling

Damaged/uncertain credits use the godown quarantine crate so `picking_available_cases` stays 0. Saleable must not set `app.damage_stock_write` for storage crates.

Do **not** auto-create an M5 `damage_reports` row from this writer. Transit damage (DMG-05) remains a separate driver-created report against the dispatch. If both exist, quantities must not double-credit: owner decision **R4**. Default: a posted delivery-return quarantine credit is the physical restock of those cases; an overlapping open transit damage report on the same dispatch/lot must be refused or must exclude those cases.

`damage.stock_hold_ready` stays false until a later owner cutover. Implementation of quarantine **credits** still requires the trusted location token; it must not flip the hold-ready flag.

### 5.9 Audit trail

Append-only `stock_delivery_return_events`: `opened`, `handed_back`, `counted`, `approved`, `posted`, `closed_missing`, `cancelled`, `returned_to_count`. `app_private.write_audit` on post. Dispatch event type `return_posted` (extend `stock_dispatch_events_type_check`).

### 5.10 Reversal / correction

No unpost. No reversing `DELIVERY_RETURN`. After post, quantity mistakes follow existing `post_stock_adjustment` (authorized, reason-coded). Do not add a reverse-return RPC in the first implementation.

### 5.11 FEFO / FIFO / expiry

Credits restore the **original lot**. FEFO/FIFO picking will see saleable restored quantity on storage crates in lot expiry/receipt order. Do not mint a new lot with a new `received_on` — that would jump the queue. Expired lots cannot be saleable; they may only go to quarantine (or missing) per **R5**.

### 5.12 Interaction with M7.3B backorders

Posting a return does **not** rewrite the original order, the acknowledged DN, the approved shipment, or the linked backorder. Undelivered returned stock is warehouse stock again; commercial remainder stays on the backorder until operations capture a new order/shipment. Owner decision **R8** if they later want auto-cancel of a backorder — default **leave it**.

---

## 6. Security model

FORCE RLS on new tables. Authenticated grants: `SELECT` only. Mutations via GUC `app.delivery_return_write` inside trusted RPCs (and `app.damage_stock_write` token only when touching quarantine locations).

| Abuse | Defence |
|---|---|
| Forged return | Permission + assigned-driver/handback + branch + version |
| Cross-godown return | `receiving_branch_id = dispatch.branch_id`; crate.zone.branch must match |
| Excess quantity | Grain checks vs dispatched and vs undelivered line |
| Wrong lot | Lot must appear on dispatched grain for that dispatch |
| Duplicate verification | Unique post + outcome uniqueness already in place |
| Driver posts saleable | No `return_post`; count RPC refuses `deliveries.execute` |
| Keeper posts | No `return_post` |
| GM skips count | Status must be `approved` from `counted` |
| Quarantine bypass | Saleable crate `location_role` must be `storage`; damaged cannot target storage |
| Damaged-as-saleable | Condition enum + check constraint on posted buckets; GM cannot change class inside the post RPC (must return-to-count) |
| Missing restocked | Missing bucket omitted from `lot_deltas` |
| Return on cancelled/unconsumed dispatch | Preconditions |
| Direct ledger insert | Existing FORCE RLS + append-only + write GUCs |

Monitor-only (`operations.monitor`) is read, not post.

---

## 7. Concurrency design

| Race | Outcome |
|---|---|
| Two handbacks | One current declaration; stale version `PT409` |
| Handback vs keeper count | Count requires `handed_back`; lock return row |
| Two keeper counts | One `counted` version |
| Approve vs count edit | `PT409` |
| Two posts | One `DELIVERY_RETURN` transaction |
| Post vs role revoke | Next call 42501; completed post stays |
| Post vs vehicle/dispatch exception rewrite | Dispatch already terminal `exception`; write guard forbids status change |
| Return post vs `confirm_dispatch` | Dispatch already consumed; confirm replays |
| Return post vs crate transfer of empty source | Credits target destination crate, not “put back into a crate that was later transferred empty”; owner **R2** chooses original crate vs keeper-selected crate. If original crate inactive, fail closed unless **R2** allows substitute storage crate in-godown |
| Return vs damage isolation on same lot | Fail closed if an active hold would double-count; see **R4** |

---

## 8. Required migration plan (later implementation phase)

Forward-only. Do **not** change `confirm_dispatch` or `verify_stock_receipt` posting bodies.

1. Permissions in §4 and role grants.
2. Widen `physical_return_status` to `pending_verification | handed_back | counted | approved | posted | closed_missing | cancelled` and relax exception_shape so exception rows may progress without leaving `pending_verification`.
3. Tables: `stock_delivery_returns`, `stock_delivery_return_lots` (dispatched snapshot + condition buckets + destination crate), `stock_delivery_return_events`. FORCE RLS, select-only, write GUC, no delete.
4. Snapshot dispatched grains from reservations / shipment lots / DISPATCH ledger at return open. Store `dispatched_cases` immutably.
5. Partial allocation columns: `delivered_cases` per grain, constrained to outcome lines.
6. `stock_transactions`: add `DELIVERY_RETURN`, `delivery_return_id`, shape check, unique index.
7. RPCs: `open_delivery_return` (idempotent), `declare_delivery_return_handback`, `count_delivery_return`, `approve_delivery_return`, `post_delivery_return`, `close_delivery_return_missing`, `cancel_delivery_return`, reads.
8. Extend `dispatch_payload` with return summary (split jsonb if needed; M7.4A already hit the 100-arg cap).
9. UI on existing dispatch / delivery-runs screens: handback, count, approve, post. No parallel navigation tree.
10. Do not enable flags.

Clean-database replay of this migration is an implementation-phase test, not this design checkpoint.

---

## 9. Test design (implementation phase)

### SQL

Unauthorized open/count/post; cross-godown crate; excess vs dispatched; wrong lot; duplicate post; missing does not credit; damaged onto storage refused; saleable onto quarantine refused; expired lot as saleable refused; unconsumed/cancelled/delivered dispatch refused; partial without lot allocation refused; short-ship dispatched grain (approved lots only, not original ordered 2); fingerprint stale; injected ledger failure rolls back; DISPATCH `posted_transaction_id` unchanged; no `RECEIPT` row; dual-write off fail-closed; overlapping transit damage per **R4**.

### HTTP

PostgREST: driver handback allowed, driver post 42501; keeper count allowed, keeper post 42501; GM post after approve; Accounts/salesperson denied; revoke GM between approve and post.

### Concurrency

Two posts; count vs approve; handback vs count; post vs cancel; damaged-as-saleable race (one approved fingerprint).

### Vitest

Status transition helpers; quantity invariant helpers; permission-aware button rules.

### Playwright

Failed-delivery return: keeper count saleable, GM approve/post, ledger increases by counted saleable only, DISPATCH row unchanged. Keeper cannot open post. Unauthenticated denied. Cutover-off still blocks operational post (same as dispatch).

Regress M2/M3/M5/M6/M7.2–M7.4A. Restore flags false. Disposable SKU prefix `m74b%`.

---

## 10. Owner decisions required

Implementation must not guess these.

| # | Question | Default if approved as-is | Blocks coding? |
|---|---|---|---|
| **R1** | Receiving godown is always the originating dispatch godown? | **Yes.** Cross-godown needs a later transfer contract. | Yes if owner wants another godown now. |
| **R2** | Saleable destination crate: original source crate, or keeper-selected storage crate in that godown? | Keeper-selected, defaulting to original crate if still active storage. | Yes — crate is a posting key. |
| **R3** | Who allocates partial undelivered cases onto lots? | Store Keeper during count. Driver handback is case totals only. | Yes for partial. Failed-only could ship without this, but the writer should still snapshot grains. |
| **R4** | Relationship to DMG-05 transit damage on the same dispatch? | Refuse post while an open transit damage report covers the same lot/qty; do not auto-convert damage reports into returns. | Yes if both workflows can run together. |
| **R5** | Expired dispatched lots returned physically? | Quarantine or missing only. Never saleable. | Recommended fail-closed; confirm. |
| **R6** | May GM count and approve (no keeper)? | **No.** Keeper count required. | Yes for single-person godowns. |
| **R7** | Multi-wave returns (post some now, missing later)? | **No.** One close. Unresolved grains block post. | Yes if operations need split waves. |
| **R8** | Linked backorder when goods return saleable? | **Leave it.** No auto-cancel, no auto-reserve. | Yes if sales wants the remainder closed. |
| **R9** | New `DELIVERY_RETURN` type vs tagged `ADJUSTMENT`? | **New type.** Adjustments stay corrections. D5 was a dedicated writer. | Yes — shape constraints change. |
| **R10** | Should damaged/uncertain create an M5 damage report, or only a quarantine crate credit? | Quarantine credit only in M7.4B. Optional later link into M5 verify/write-off. | Yes if owner wants full DMG evidence in the same posting. |

D3 invoices and D7 Tally/payments stay out of this phase.

---

## 11. Implementation boundaries

When coding is later approved:

- Do not modify `verify_stock_receipt` posting semantics.
- Do not modify `confirm_dispatch` posting semantics.
- Do not rewrite M7.3B backorder quantities.
- Do not use client DML on ledger/balances.
- Do not flip `damage.stock_hold_ready`, `stock.lots.dual_write_enabled`, or `stock.lots.aggregate_only_blocked`.
- Do not activate `SHORT_SHIPMENT_OPERATIONAL`.
- Do not restock from order-line undelivered totals.
- Do not treat POD `delivered` as a return source.

This design checkpoint implemented **nothing**. Flags remain false.

---

## 12. Verdict rationale

The debit-side lot contract **is** sufficient: dispatched cases are recoverable from consumed reservations, `order_shipment_lots`, and negative `DISPATCH` ledger lines. The M7.4A outcome table is **not** sufficient for partial lot reconciliation, but that is a missing **return document**, not a broken stock writer. Existing writers must not be reused. A dedicated `DELIVERY_RETURN` writer is designable without inverting DISPATCH uniqueness if it uses a new FK.

Coding is blocked only on the owner answers in §10, not on an untraceable stock identity.
