# M7.4A — Vehicle master and delivery operations

Local-only implementation after M7.3B. This phase reuses the M3 dispatch/delivery engine. It adds a vehicle master, assignment of an active vehicle plus authorized driver, proof-of-delivery metadata, and non-posting failed/partial delivery exceptions.

It does **not** add a second delivery subsystem, return-to-stock posting, tax invoices, payments, TallyPrime, cloud migration, Netlify deploy, Git commit, or feature-flag activation.

**Development completion is not operational activation.** Lot cutover flags stay false. `SHORT_SHIPMENT_OPERATIONAL` stays `false`. Delivery-status updates never write the stock ledger.

Starting HEAD: `0a5e70c6adf113dcd20fb23ec9ae34a4f523ef20`  
`feat(m7.3b): implement controlled short-shipment and backorder integrity` on `main`.

Working tree was clean at start. M7.3B checkpoint was committed.

Migration applied locally (Docker): `20261027230000_vehicle_master_and_delivery_operations.sql`.

Flags at start and end (operational values):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`

Owner decisions honoured: D2 (vehicle master), D5 (failed-delivery returns are a later workflow), D7 (TallyPrime/payments out of M7). Physical restock is M7.4B.

---

## 1. Existing delivery contracts reused

M7.4A extends the M3 dispatch document. It does not create a parallel delivery table or a second stock writer.

| Capability | Pre-M7.4A source | Reused? |
|---|---|---|
| Dispatch lifecycle `preparing → dispatched → in_transit → delivered` / `exception` | `stock_dispatch_requests` + M3 RPCs | Yes |
| Stock consume | `confirm_dispatch` only | Unchanged |
| Driver assignment | `assign_dispatch_delivery`, `stock_dispatch_assignments`, `profiles` + `delivery_person` | Extended with vehicle |
| Start delivery | `start_dispatch_delivery` | Hardened: requires vehicle + assignee |
| POD | `acknowledge_dispatch_delivery` (`recipient_name`, notes, actor, timestamps) | Extended with optional `proof_reference` and outcome lines |
| Failed delivery | `report_dispatch_delivery_exception` + `physical_return_status=pending_verification` | Extended with `delivery_outcome=failed`, `return_required`, attempt history, outcome lines |
| Assignment history | append-only `stock_dispatch_assignments` | Vehicle column added; history cannot be rewritten |
| Employee master | `profiles`, `user_roles`, `user_branch_assignments` | Reused. No duplicate driver master |
| Godown scope | `can_work_at_branch` / `can_complete_consumed_delivery_at_branch` | Reused |
| M7.3B shipment / backorder | `order_shipments`, `create_linked_backorder` | Read for dispatched qty; never rewritten |
| Delivery notes | M7.2 DN handshake | Unchanged |
| Audit | `app_private.write_audit` + `stock_dispatch_events` | Extended event `partial_recorded` |

`confirm_dispatch` posting semantics and `verify_stock_receipt` were not modified.

---

## 2. Vehicle master

Table `public.vehicles`, branch-scoped, FORCE RLS, select-only for `authenticated`. Writes go through SECURITY DEFINER RPCs.

| Field | Rule |
|---|---|
| `id` | UUID |
| `registration_number` | Display plate, trimmed, 4–32 chars |
| `registration_normalized` | Lowercase alphanumeric only, 4–20 chars |
| `vehicle_type` | `truck` / `van` / `two_wheeler` / `other` |
| `display_name` | Required label |
| `capacity_cases` | Optional integer ≥ 1. **Informational only.** No load enforcement |
| `notes` | Optional operational notes, ≤ 500 |
| `is_active` | Inactive rows stay readable |
| `created_by` / `created_at` / `updated_by` / `updated_at` / `deactivated_*` | Server-generated |

Uniqueness: partial unique index `vehicles_active_registration_uidx` on `registration_normalized` where `is_active`. Inactive plates may be reused; reactivation races fail closed.

Hard delete is refused by `app_private.guard_vehicle_mutation`. Vehicles with operational history stay.

Permissions:

- `vehicles.view` — admin, godown manager
- `vehicles.manage` — admin, godown manager

Drivers, store keepers, accounts, sales, and monitor-only roles cannot create or edit vehicles. Direct `INSERT`/`UPDATE`/`DELETE` on `vehicles` is revoked.

RPCs: `create_vehicle`, `update_vehicle`, `set_vehicle_active`. Deactivation is refused while the vehicle is assigned to a `dispatched` or `in_transit` run.

---

## 3. Assignment rules

`assign_dispatch_delivery(target_dispatch, assignee, expected_version, idempotency_key, target_vehicle default null)` replaces the four-argument M3 signature. Positional four-argument SQL still works because `target_vehicle` defaults to null (existing vehicle kept).

Rules:

- Requires posted dispatch (`stock_consumed` and `status='dispatched'`).
- Reassignment is allowed only before transit starts.
- Assignee must be an active `delivery_person` assigned to the dispatch godown (or `branches.access_all`).
- Vehicle, when supplied, must be active, belong to the same godown, and not already sit on another `dispatched`/`in_transit` document.
- `assigned_by` / `assigned_at` are `auth.uid()` / `clock_timestamp()`.
- Prior assignment rows are closed (`unassigned_at`/`unassigned_by`/`reason='reassigned'`); a new assignment row is inserted. History is not rewritten.
- Stale `expected_version` raises `PT409`.
- Conflicting active vehicle assignment raises `vehicle is already assigned to an active delivery` (unique index + lock).

Fail-closed vehicle-in-use rule: a vehicle is treated as in use when `stock_dispatch_requests.vehicle_id` is set and `status in ('dispatched','in_transit')`. There is **no** calendar, route plan, or outside-system occupancy signal. Occupancy outside this dispatch table is not knowable here and is not invented.

Start (`start_dispatch_delivery`) requires both an assigned driver and an assigned vehicle. Lock order: dispatch row `FOR UPDATE`, then vehicle `FOR UPDATE`.

---

## 4. Delivery lifecycle

Existing M3 statuses are preserved.

| Status | Meaning after M7.4A |
|---|---|
| `preparing` | Ready for `confirm_dispatch`. No vehicle required yet |
| `dispatched` | Stock consumed. Assignment and reassignment window |
| `in_transit` | Run started. Reassignment refused |
| `delivered` | POD recorded. `delivery_outcome='delivered'` |
| `exception` | Failed or partial. `delivery_outcome` is `failed` or `partial`. `return_required=true` |
| `cancelled` | Pre-consume cancel only |

`delivery_outcome` is null until a terminal delivery result. Status updates do not insert `stock_transactions` or change `posted_transaction_id`. Drivers cannot change ordered, approved-shipment, or invoice amounts (no invoice exists in M7).

Idempotency remains event-key replay on `stock_dispatch_events`. Actor and timestamps are server-generated.

---

## 5. Proof of delivery

`acknowledge_dispatch_delivery` still requires the **assigned** driver (`app_private.assert_dispatch_executor`). No existing supervisory role is permitted to mark another driver's POD as complete. Godown managers may still record `dispatch.exception` (failed/partial) under the existing M3 exception permission.

Captured:

- Outcome `delivered`
- `delivered_at` / `acknowledged_at` / `acknowledged_by`
- Recipient name (required)
- Optional notes
- Optional `proof_reference` (opaque metadata, 1–200 chars, charset `A-Za-z0-9._:/\- `, rejects `javascript:` / `data:`)
- Dispatch/shipment reference via the existing payload

**Storage prerequisite:** there is no trusted private object store for signatures or photos in this phase. Only a sanitized reference string is stored. Do not treat `proof_reference` as a verified URL. Public unsigned uploads were not added.

POD writes full delivered outcome lines (`delivered_cases = dispatched_cases`) and does not alter stock. Duplicate POD with a new key is refused once outcome lines exist; same-key replay returns the existing payload.

---

## 6. Failed and partial delivery

Both remain on the M3 `exception` status. They do not restock.

### Failed

`report_dispatch_delivery_exception`:

- Records reason, actor, `attempted_at`
- Sets `delivery_outcome='failed'`, `return_required=true`, `physical_return_status='pending_verification'`
- Writes outcome lines with `delivered_cases=0`
- Preserves original `posted_transaction_id` and DISPATCH ledger
- Appends `stock_dispatch_delivery_attempts`

### Partial

`record_partial_dispatch_delivery`:

- Line grain is `order_line_id` on the dispatch
- Dispatched quantity is shipment `approved_cases` when an M7.3B shipment exists, otherwise `sum(reserved_cases)` on consumed/active reservations
- `0 ≤ delivered_cases ≤ dispatched_cases`
- Partial requires some but not all cases
- `undelivered_cases = dispatched_cases - delivered_cases`
- Unique `(dispatch_id, order_line_id)` prevents double-count
- Does not credit finance, does not rewrite the backorder, does not call `confirm_dispatch`

Schema can represent line-level partial delivery against **dispatched** quantities. Lot-level physical return (damaged vs eligible vs missing) is M7.4B.

---

## 7. M7.3B compatibility

Documents remain distinct:

| Document | Authority |
|---|---|
| Original order | Ordered qty and events. Fulfilment may stay `partially_fulfilled` |
| Linked backorder | Remainder after approved short-shipment |
| Acknowledged DN | Paperwork; not rewritten |
| Approved operational shipment | Approved lots / cases |
| Posted dispatch | Sole stock debit |
| Delivery outcome | Physical result of **that** dispatch |

SQL proof: short-ship 2 ordered / 1 approved / 1 dispatched, then POD. Original `fulfilment_status` stays `partially_fulfilled`. Linked backorder remains. `posted_transaction_id` unchanged. Original order status is not rewritten.

---

## 8. Security and RLS

FORCE RLS remains on `vehicles`, `stock_dispatch_requests`, `stock_dispatch_assignments`, `stock_dispatch_outcome_lines`, `stock_dispatch_delivery_attempts`.

Table grants: `SELECT` only for `authenticated`. Mutations require `app.dispatch_write='on'` inside trusted RPCs. Outcome lines and attempts are insert-only history.

Monitor-only permissions were not expanded. `vehicles.*` is admin/GM only.

Tested denials:

- Store keeper cannot create vehicles
- Direct vehicle insert denied
- Unauthorized HTTP vehicle create
- Cross-godown vehicle assignment
- Inactive vehicle / inactive driver
- Other driver cannot start or POD
- Forged POD
- Stale assignment version
- Delivered qty above dispatched
- Duplicate outcome
- Delivery start without posted dispatch
- Vehicle deactivation while assigned

---

## 9. Concurrency

Lock order: dispatch header `FOR UPDATE`, then vehicle `FOR UPDATE`. Unique active-vehicle index is the second line of defence.

| Race | Result |
|---|---|
| Two assignments for one delivery | One current assignee |
| Vehicle reassignment vs in-transit | One winner; the other is `PT409` or assignment-window refusal |
| Duplicate POD | One outcome; no second outcome lines |
| Delivered vs failed | One terminal outcome |
| Vehicle deactivation during assignment | Fail closed |

Partial quantity races are covered by the dispatch row lock plus unique outcome-line constraint. Role revocation during retry remains 42501 on the next RPC (existing M3/M7 pattern).

---

## 10. UI

Existing Masters / Dispatch / Delivery runs navigation. No parallel app.

- `/masters/vehicles` — list, create, edit, deactivate (`vehicles.view` / `vehicles.manage`)
- Dispatch detail — vehicle + driver selects while `status='dispatched'`; start gated on both; POD proof reference; fail reason; partial line quantities; attempts and delivery lines
- Delivery runs reuse the same dispatch detail

Capacity is shown as an optional master field and is not used as a load check.

---

## 11. Test results

| Suite | Result |
|---|---|
| SQL `phase_m7_4a_delivery.sql` | PASS, rolled back |
| HTTP `phase_m7_4a_http_integration.mjs` | 9/9 PASS |
| Concurrency `phase_m7_4a_concurrency.mjs` | 5/5 PASS |
| Vitest | 222 passed / 36 files / 0 failed / 0 skipped |
| Playwright | **97 passed / 97 run / 0 failed / 0 skipped** |
| Typecheck | PASS |
| Lint | PASS (pre-existing warnings only) |
| Production build | PASS (`VehiclesPage`, `DispatchDetailPage` chunks emitted) |

M7.4A SQL covers: unauthorized vehicle create, duplicate active registration, delivery without posted dispatch, cross-godown vehicle, start without vehicle, other-driver start/POD, POD metadata without replacing the DISPATCH transaction, duplicate POD, failed delivery `return_required` without restock, delivered qty above dispatched, partial undelivered without restock, duplicate partial, inactive vehicle, inactive driver, stale assignment, short-ship POD stays `partially_fulfilled`, direct vehicle insert denied.

M7.4A HTTP covers: unauthorized vehicle creation, GM create, vehicle+driver assign, other driver cannot start, in-transit, forged POD, POD metadata without stock write, invalid delivered quantity, partial undelivered without restock.

M7.4A concurrency covers: concurrent assignments, reassignment vs in-transit, delivered vs failed, duplicate POD, deactivation during assignment.

Regressions re-run locally:

- M2 SQL / HTTP 5/5 PASS (after replica-null of 8 leftover lot-attributed ledger rows from earlier HTTP fixtures; flags restored false)
- M3 SQL / HTTP 9/9 PASS
- M4.1 SQL PASS
- M5.2 SQL / HTTP 8/8 PASS
- M5.3 SQL PASS
- M6.2–M6.6 SQL PASS; HTTP 16+12+10+8+9 PASS
- M7.2 SQL / HTTP 7/7 / concurrency 3/3 PASS
- M7.3A SQL / HTTP 7/7 / concurrency 5/5 PASS
- M7.3B SQL / HTTP 5/5 / concurrency 6/6 PASS

Disposable SKU prefix `m74a%` was added to `tests/e2e/disposable-stock.ts` so leftover HTTP/concurrency grains (`m74a-`, `m74ac_`) cannot block later picking flag enable. E2E dispatch fixtures also create `KL07{RUN}` vehicles.

---

## 12. Remaining limitations

- Vehicle capacity is informational. No owner-approved load or regulatory check exists.
- Vehicle occupancy is knowable only from open `dispatched`/`in_transit` rows in this database. External scheduling is out of scope.
- Signature/photo bytes are not stored. `proof_reference` is unsanctioned-URL-safe metadata only.
- Assigned driver is the only POD executor. There is no supervisory “complete another driver's run” permission.
- Partial delivery is per order line against dispatched cases, not per lot/crate condition.
- Failed/partial goods remain deducted until M7.4B.
- Short-shipment remains implemented but not live-operational (`SHORT_SHIPMENT_OPERATIONAL=false`).
- Clean-database migration replay was not independently tested in this phase.

---

## 13. M7.4B return-workflow prerequisites

M7.4A records that a physical return **may be required**. It does not accept goods.

A later return workflow needs owner-approved answers for:

1. Failed vs partial delivery already recorded (`delivery_outcome`, outcome lines, `return_required`).
2. Physical goods handed back by the assigned driver (who, when, to which receiving godown).
3. Returned cases per **line and lot/crate**, not only order-line totals.
4. Damaged / missing / saleable split, with verification by authorized warehouse staff (not the driver alone).
5. Quarantine vs eligible stock destinations. Do not reuse unverified damage holds.
6. Audited return acceptance that **then** posts a stock writer distinct from `verify_stock_receipt` and `confirm_dispatch`.
7. What happens to the linked backorder: leave it, adjust it, or create a different remainder document. M7.4A does not auto-modify it.
8. Whether `physical_return_status` stays `pending_verification` until that acceptance, and which roles may complete it.

Do not increase inventory from delivery RPCs. Do not add a stock writer in this phase.

---

## 14. Cutover blockers

Operational flags remain false. Do not flip `damage.stock_hold_ready`, `stock.lots.dual_write_enabled`, or `stock.lots.aggregate_only_blocked` outside disposable replica DML that restores them. Do not activate `SHORT_SHIPMENT_OPERATIONAL`.

Local leftover lot-attributed `stock_ledger` rows from earlier HTTP fixtures were replica-nulled so M2's flag-restore trigger could run. That cleanup did not enable dual-write and did not post stock.
