# M3 — Dispatch confirmation, atomic stock consumption, and delivery tracking

Local implementation. **Not deployed** to development cloud `ypkfondrkhkydkgovwup`. Does not seed, attribute, classify, or flip cutover flags on development.

## Architecture

Orders stay on the Phase 4.1 machine: `draft → submitted → held → verified → cancelled`. M3 does **not** add dispatch statuses to `orders`.

Warehouse work stays on the M2 picking sidecar until `ready_for_dispatch`. Physical dispatch lives on `stock_dispatch_requests`, one active document per picking handoff.

Invariant: **one physical dispatch = one authorized stock consumption**. Delivery-note paperwork never substitutes for a picking handoff.

```
Verified order
  → FEFO/FIFO picking (M2)
  → ready_for_dispatch
  → prepare_dispatch (preparing, no ledger)
  → confirm_dispatch (atomic reservation consume + DISPATCH ledger)
  → assign_dispatch_delivery
  → start_dispatch_delivery / acknowledge_dispatch_delivery
  → or report_dispatch_delivery_exception (no restock)
```

## Existing-system integration

| System | Role after M3 |
|---|---|
| `orders.status` | Unchanged. Dispatch does not mark the order delivered. |
| `stock_picking_requests` | Handoff remains `ready_for_dispatch`. Reservations move `active → consumed`. |
| Phase 4.2 `delivery_notes` | Paperwork only (`draft → generated → sent → acknowledged`, void pre-ack). Optional FK from dispatch. Create, acknowledge, and void never debit or restore stock. Godown `delivery_notes.acknowledge` is document receipt, not customer POD. |
| Vehicles | No vehicle master exists. Vehicle assignment is deferred. |

`app_private.assert_picking_handoff_for_dispatch(order_id)` is called from `confirm_dispatch` and `prepare_dispatch`. EXECUTE remains revoked from `public`, `anon`, `authenticated`, and `service_role`.

## Dispatch lifecycle

`preparing → dispatched → in_transit → delivered`

Also: `preparing → cancelled` (before consumption only). `dispatched|in_transit → exception`.

A dispatched document cannot revert to `preparing` or `cancelled`. Historical rows cannot be deleted.

## Delivery lifecycle

User-facing delivery state is the dispatch sidecar, not delivery-note status:

| Dispatch status | Meaning |
|---|---|
| `dispatched` | Stock consumed. Optional assignment pending. |
| `in_transit` | Assigned personnel started the run. |
| `delivered` | Customer proof of delivery (recipient name + timestamp). |
| `exception` | Failed delivery. `physical_return_status = pending_verification`. Stock stays deducted. |

## Database schema

Migration `20261022240000_dispatch_delivery.sql` (local only):

- `stock_dispatch_requests`
- `stock_dispatch_assignments`
- `stock_dispatch_events`
- `stock_reservations.status` adds `consumed`
- `stock_transactions.transaction_type` adds `DISPATCH` with `dispatch_request_id`
- Unique successful consumption per picking request (`stock_consumed`)
- Unique `stock_transactions.dispatch_request_id`

## RPC contracts

Public, `SECURITY DEFINER`, `search_path = ''`, EXECUTE granted to `authenticated` only:

| RPC | Effect |
|---|---|
| `preview_dispatch` | Advisory blockers. DN presence is informational. |
| `prepare_dispatch` | Creates `preparing`. No ledger. |
| `confirm_dispatch` | Exactly-once stock consumption. |
| `cancel_dispatch` | Preparing only. |
| `assign_dispatch_delivery` | Branch-scoped `delivery_person`. |
| `start_dispatch_delivery` | `dispatched → in_transit`. |
| `acknowledge_dispatch_delivery` | Customer POD. |
| `report_dispatch_delivery_exception` | Failed delivery, no restock. |
| `get_dispatch_request` / `list_dispatch_queue` / `list_assigned_deliveries` / `list_dispatch_assignees` | Reads. |

## Reservation consumption algorithm

`confirm_dispatch` is one PostgreSQL function, therefore one transaction. Any exception (including an injected ledger failure) rolls back reservation consume, `DISPATCH` insert, ledger, balances, dispatch status, and events.

Lock order (must match `cancel_order` and M1 `apply_lot_aware_stock_deltas`):

1. Shared cutover advisory `(88104301, 1)`.
2. Resolve dispatch keys, then lock **order → picking → dispatch** `FOR UPDATE`.
3. Replay if `stock_consumed` (same or different confirm key). Lost HTTP after commit is safe even with a stale version.
4. Status must be `preparing`. Stale version is `PT409`.
5. `assert_dispatch_handoff_ready` / `assert_picking_handoff_for_dispatch`. Delivery notes never authorize this step.
6. Fingerprint of current active reservations must match prepare. Mismatch is `23514`, not a unique-violation replay.
7. Lock reservations (`crate_id, lot_id, id`).
8. Lock products (`id`), then `prepare_stock_locations` (zones, crates), then lots (`id`).
9. Lock `stock_lot_balances` (`crate_id, lot_id`) then `stock_balances` (`crate_id, product_id`).
10. Recheck handoff and physical availability. Never `legacy_unattributed`.
11. Set reservations to `consumed` **in this transaction** so reservation guards see zero active holds.
12. Insert `DISPATCH` transaction (`idempotency_key` `dispatch:<id>`), negative lot ledger rows, `apply_lot_aware_stock_deltas`.
13. Mark `stock_consumed`, append dispatch event, audit.

Never disable reservation guards. Never release in one committed transaction and debit in another. Never call `apply_stock_delta` (aggregate-only is closed under dual-write).

## Exactly-once guarantees

- Unique prepare idempotency key. Same key + different order fails (`23514`/`23505`).
- Unique `confirm_idempotency_key` where present.
- Unique consumed row per `picking_request_id`.
- Unique `DISPATCH` transaction per dispatch id; ledger key `dispatch:<dispatch_id>`.
- Duplicate confirm after commit returns the original payload, including when the HTTP response was lost and `expected_version` is stale.
- Concurrent confirms serialize on order/picking/dispatch row locks. One ledger posting.
- Same confirm fingerprint with a mutated reservation set fails closed (`23514`) before consume.

## Delivery-note compatibility

Creating a delivery note does not consume stock. Acknowledging or voiding a delivery note does not consume or restore stock. Dispatch may link the latest non-voided note. Voiding paperwork after dispatch leaves the FK for audit and does not reverse inventory.

## Security model

FORCE RLS. Authenticated table grants are SELECT only. Mutations require GUC `app.dispatch_write` (reservation consume also accepts `app.picking_write`). UI gates are advisory.

| Permission | Roles |
|---|---|
| `dispatch.view` / `dispatch.confirm` / `dispatch.exception` / `dispatch.history` | Admin, Godown Manager |
| `deliveries.assign` | Godown Manager (existing) |
| `deliveries.execute` | Delivery Person (existing; assigned work only) |

Store Keepers cannot confirm dispatch. Delivery personnel cannot view unassigned documents.

## Failure handling and return-to-godown boundary

Failed delivery, customer refusal, and delivery-note voiding do **not** increment inventory. Exception records `physical_return_status = pending_verification`. A later return-receiving workflow must require physical receipt, an authorized operator, valid lot identity, and exactly-once positive posting. That workflow is not implemented here.

## Test coverage

Local Docker / Vite `--mode m1s2` only. Development cloud was not migrated, seeded, or flag-flipped.

| Suite | Result |
|---|---|
| `phase_m3_dispatch_delivery.sql` | Passed (rollback). Handoff, fail-closed dual-write, DN-without-picking, keeper/cross-branch/anon denial, prepare without ledger, confirm consume, idempotent replay, conservation, reservation `consumed`, POD vs DN paperwork, failed delivery without restock, injected ledger `P0001` rolls back consume/txn/consumed flag, cancel-before-consume, DML denial, private helper revoke. |
| `phase_m3_concurrency.mjs` | Passed. Three-way confirm/confirm/transfer: one `DISPATCH`, remaining qty 2 of 6, reserved grain not oversubscribed. Replay after success. Versus order cancel, picking cancel, and cutover exclusive lock. Replica cleanup restored flags. |
| `phase_m3_http_integration.mjs` | Passed (9). Store Keeper denied; queue/preview/prepare; PostgREST `confirm_dispatch` consumes once; idempotent replay; assign / in-transit / POD. Opening seeded over `psql` because PostgREST loads `safeupdate`. |
| Playwright (`auth` + `dispatch` + `lot-reconciliation` + `picking`) | Passed (21). Dispatch confirm, assignment, failed delivery without restock, driver POD, cutover-disabled alert. |
| `npm run typecheck` / `lint` / `test` / `build` | Passed (85 unit tests). Lint warnings only in unrelated inventory/product pages. |
| M1 SQL | `phase_m1_lot_aware_operational_posting`, `phase_4_3e2b1`, `phase_4_3e2b2`, `phase_4_3e1a`, `phase_m1_s1_cutover_flag_safety`, `phase_m1_s2_physical_reconciliation`, `phase_m1_s3_legacy_attribution` passed. |
| M1 concurrency | `phase_m1_s1`, `phase_m1_s2`, `phase_m1_s3`, `phase_4_3e2b2` passed. `phase_m1_concurrency.mjs` remains documented as unsafe on the working local database (M1-S1 dual-write enable guards); transfer lock-order is covered by M3 vs `post_crate_transfer` and `phase_4_3e2b2`. |
| M2 SQL / concurrency | `phase_m2_fefo_fifo_picking.sql` and `phase_m2_concurrency.mjs` passed. |
| Phase 4.1 / 4.2 | `4_1a`, `4_1b`, `4_1c`, `4_1d`, `4_2a`, `4_2b`, `4_2c`, `4_2f` SQL passed. 4.1/4.2 concurrency passed. 4.1c/4.1d no longer assert that `stock_reservations` is absent; they assert order RPCs do not create holds and clients cannot DML the table. |

PostgREST `safeupdate` requires `DELETE ... WHERE`. M3 patches `apply_lot_aware_stock_deltas` and `lot_aware_delta_fingerprint` temp-table cleanup to `WHERE true` without disabling the extension.

Rollback SQL suites and dual-write HTTP/Playwright fixtures must not share a dirty local database: leftover aggregate-only grains from M1-S2 concurrency block cutover-flag enable.

## Deployment prerequisites

Do not `db push` until a later owner authorization that names the development project, backup, and freeze. Cutover flags stay `false`. Pending local migration: `20261022240000_dispatch_delivery.sql`.

## Known limitations

- Vehicle assignment is deferred (no vehicle master).
- Proof of delivery is recipient name, timestamp, and notes. No signature capture and no evidence-attachment bucket in this milestone.
- Picking remains `ready_for_dispatch` after consumption, so order cancel stays blocked for those orders (stock already left the godown).
- Development inventory is still unclassified and not dual-write enabled, so cloud dispatch cannot run until operational cutover.
