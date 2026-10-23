# M2 — FEFO/FIFO allocation, reservation, and warehouse picking

Local implementation. **Not deployed** to development cloud `ypkfondrkhkydkgovwup`. Does not seed, attribute, classify, or flip cutover flags on development.

## Architecture

Orders stay on the Phase 4.1 machine: `draft → submitted → held → verified → cancelled`. M2 does **not** add picking statuses to `orders`. Warehouse work lives on `stock_picking_requests`, one active document per verified order.

Availability for picking is lot-aware:

`available = on-hand lot×crate quantity − sum(active reserved_cases)`

The preview RPC is advisory. `reserve_order_allocation` recomputes availability after locking grains.

## Allocation algorithm

1. Shared cutover lock `(88104301, 1)` via `acquire_stock_cutover_shared_lock`.
2. Lock the order `FOR UPDATE`.
3. Fail closed unless `stock.lots.dual_write_enabled = true`. Aggregate-only picking is not a workaround.
4. Require every line product to be classified (`expiry_controlled` or `non_expiring`).
5. Lock candidate `stock_lot_balances` in `crate_id, lot_id` order.
6. Recompute the plan. Full-line fill is required. Shortfall is a blocker, not a silent partial reserve.
7. Insert `stock_picking_requests` (`allocated`) and `stock_reservations` (`active`). Replay by idempotency key.

### FEFO / FIFO eligibility

**FEFO** (`expiry_controlled`): `available` lots with a non-null `expiry_date >= current_date`, ordered by `expiry_date`, `received_on` nulls last, `lot_id`, `crate_id`.

**FIFO** (`non_expiring`): `available` lots with `expiry_date` null and non-null `received_on`, ordered by `received_on`, `lot_id`, `crate_id`. NULL `received_on` is never treated as oldest.

Excluded from automatic allocation:

- `legacy_unattributed`
- quarantined / expired_blocked
- expiry-controlled lots with missing or past expiry
- unclassified products
- other godowns

## Reservation lifecycle

| Event | Reservation | Stock |
|---|---|---|
| Reserve | `active.reserved_cases` | Hold only. No ledger. |
| Confirm pick | `picked_cases` increases | Hold remains. |
| Shortage / cancel picking | `released` | Hold returns to available. |
| Order cancel from `allocated` | `released` | Hold returns to available. |
| `ready_for_dispatch` | still `active` | Held until M3. |
| M3 dispatch (not implemented) | consume once | Ledger debit in the same transaction. |

Idempotent reserve replay returns the existing payload. Duplicate allocate after an active request is refused.

## Trusted posting protections

BEFORE UPDATE OR DELETE on `stock_lot_balances` and `stock_balances` refuse any reduction below active reservations (`insufficient unreserved stock`).

Covered stock-reducing trusted paths that update those tables:

- crate transfers
- stock adjustments
- lot-aware operational posting / aggregate balance maintenance

Receipt reversal is not a supported RPC. M2 does not add one.

Picking RPCs never write `stock_ledger`. Client DML on inventory tables remains denied.

## Picking state transitions

`allocated → picking → picked → ready_for_dispatch`

Cancel is allowed from `allocated`, `picking`, `picked`, or `blocked`. `ready_for_dispatch` is the M3 handoff and is not cancelled from M2. Order cancel auto-releases only `allocated` holds; in-progress picking must be cancelled first.

Store Keepers execute assigned tasks only (`picking.execute` plus `assigned_to = auth.uid()`). Admin and Godown Manager allocate (`picking.allocate`) and manage (`picking.manage`). Branch scope is `can_work_at_branch` in every RPC. UI permission gates are advisory; RPCs enforce authorization.

## Stock deduction boundary

| Stage | Stock effect |
|---|---|
| Reservation | Holds `reserved_cases` on the lot×crate grain. No ledger row. |
| Pick confirmation | Updates `picked_cases` only. Hold remains `reserved_cases`. |
| Picking complete / handoff | Status `picked` then `ready_for_dispatch`. Still no ledger debit. |
| M3 dispatch (not implemented) | Must consume held reservations and write `stock_ledger`. |
| Delivery notes (Phase 4.2) | Paperwork only. See below. |

Do not debit the same cartons at pick and again at dispatch.

## Delivery-note integration

Phase 4.2 `create_delivery_note` still requires a **verified order**. It does **not** require a picking handoff. It does **not** write `stock_ledger`, create reservations, or release holds.

That is an operational paperwork path, not an inventory consumption path. M2 leaves it unchanged so existing accounts workflows keep working.

Unsafe alternative dispatch would exist only if a later stock-reducing RPC treated a delivery note as permission to debit inventory. M2 adds `app_private.assert_picking_handoff_for_dispatch(order_id)` as the M3 gate: it returns the `ready_for_dispatch` request id, or raises `23514`. EXECUTE is revoked from `public`, `anon`, `authenticated`, and `service_role`. Delivery-note create does not call it.

## M3 handoff

`get_picking_handoff(request_id)` when status is `ready_for_dispatch` returns:

- order and picking identifiers
- per-line requested / reserved / picked / shortage
- crate, lot, manufacturer code, expiry, quantities
- `stock_consumed: false`
- `reservation_state: held_until_dispatch`

M3 must:

1. Call `assert_picking_handoff_for_dispatch` before any stock-reducing dispatch posting.
2. Consume those holds **exactly once** in the same transaction as the dispatch ledger write.
3. Refuse dispatch when no `ready_for_dispatch` handoff exists, even if a delivery note already exists.

## Cutover prerequisites

Lot-aware picking **fails closed** unless `stock.lots.dual_write_enabled = true`.

When `aggregate_only_blocked = true` and dual-write is still false, picking stays blocked.

Development cloud is not eligible until operational cutover: products classified, physical sessions approved, legacy seed, attribution, then dual-write. See `docs/m1-s1-cutover-runbook.md` and `docs/m1-s3-legacy-lot-attribution.md`.

### M1-S1 empty-database enable

`phase_m1_s1_cutover_flag_safety.sql` previously expected same-statement `false/false → true/true` to fail on an empty local database. That assertion was inaccurate.

Zero-grain inventory is reconciled: there is no unclassified positive stock and no lot/aggregate mismatch. Greenfield dual-write+blocked is therefore allowed. Fail-closed cases remain unclassified in-stock products and grain mismatch. Validators were not weakened; only the empty-DB expectation was corrected. After asserting success the test restores `false/false`.

## Schema

Migration `20261022230000_fefo_fifo_picking.sql` (local only):

- `stock_picking_requests`
- `stock_reservations`
- `stock_picking_exceptions`
- `stock_picking_events`
- reservation guards on `stock_lot_balances` and `stock_balances`
- `cancel_order` releases `allocated` picking holds
- `app_private.assert_picking_handoff_for_dispatch`

Tables are FORCE RLS. Authenticated grants are SELECT only. Nested child SELECT inherits header RLS (branch + allocate/manage/monitor, or assigned execute). Mutations go through SECURITY DEFINER RPCs with `search_path = ''`. Public RPCs grant EXECUTE to `authenticated` only. Helper/trigger functions revoke EXECUTE from `public`, `anon`, `authenticated`, and `service_role`. GUC `app.picking_write` gates table writes.

## Tests (local Docker / Vite `--mode m1s2` only)

| Suite | Result |
|---|---|
| `phase_m2_fefo_fifo_picking.sql` | Passed (rollback). FEFO, FIFO, fail-closed, seed-only window, expired exclusion, shortage release, unclassified blocker, DML denial, transfer vs reserved stock, idempotent reserve, handoff `stock_consumed=false`, delivery-note paperwork without ledger/hold mutation, M3 helper reject/accept. |
| `phase_m2_concurrency.mjs` | Passed. Two verified orders, one reserve winner; transfer cannot consume the held grain. Cleanup restores flags and removes disposable lots. |
| `phase_m2_http_integration.mjs` | Passed. Store Keeper and Accounts denied; Godown Manager preview/reserve/replay. Opening is seeded over `psql` because PostgREST loads `safeupdate`. |
| Playwright full suite (`auth` + `lot-reconciliation` + `picking`) | Passed (15). One worker, `fullyParallel: false`. M1-S2 login now seeds m1s2qa fixtures in `beforeAll` and fails on a visible alert instead of a silent timeout. Picking `beforeAll` seeds leftover disposable unmatched grains through `seed_legacy_stock_lots`, then enables dual-write as postgres so the cutover trigger still validates. |
| `npm run typecheck` / `lint` / `test` / `build` | Passed (83 unit tests). Lint warnings only in unrelated inventory/product pages. |
| M1 SQL | `phase_m1_lot_aware_operational_posting`, `phase_4_3e2b1`, `phase_4_3e2b2`, `phase_4_3e1a`, `phase_m1_s1_cutover_flag_safety`, `phase_m1_s2_physical_reconciliation`, `phase_m1_s3_legacy_attribution` passed. Phase 4.2 delivery-note SQL (`4_2a` / `4_2b` / `4_2c`) passed. S3 first lots save now targets crate_a1 soap explicitly because `m1s3_line(session, sku)` is ambiguous when two crates share a SKU. |

## Known limitations

- Development inventory is still unclassified and not dual-write enabled, so cloud picking cannot run until operational cutover.
- Phase 4.2 can still create a delivery note from a verified order without a picking handoff. That is paperwork. M3 must require `ready_for_dispatch` before consuming stock.
- Assignee is a profile id in this milestone (no picker directory UI).
- `received_on` is the persisted FIFO clock; it is not invented for legacy lots.

## Deployment prerequisites

Do not `db push` until a later owner authorization that names the development project, backup, and freeze. M1-S3 schema is already on development; M2 is not. Pending local migration: `20261022230000_fefo_fifo_picking.sql`.
