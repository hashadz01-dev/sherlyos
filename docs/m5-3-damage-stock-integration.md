# M5.3 — Damage holds, quarantine, and stock integration

Local implementation only. **Do not apply** `20261026160000_damage_stock_isolation_and_disposition.sql` to development cloud `ypkfondrkhkydkgovwup`. Lot cutover flags stay false. `damage.stock_hold_ready` stays false in the committed database; local tests may enable it and must restore it.

M5.4 will replace the empty `/damage` placeholder. This phase is backend isolation and disposition only.

## Schema

| Object                                                        | Purpose                                                                    |
| ------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `zones.location_role` / `crates.location_role`                | `storage` (default) or `quarantine`. One quarantine zone/crate per godown. |
| `damage_stock_holds`                                          | Isolation rows. No parallel balance table.                                 |
| `damage_exceptional_requests`                                 | Admin approval for supplier return / destroy.                              |
| `stock_transactions.damage_report_id` + `damage_posting_kind` | Exact-once linkage. Types remain `ADJUSTMENT` / `CRATE_TRANSFER`.          |
| `damage_reports.physical_custody_confirmed_*`                 | Shop-return goods must be confirmed in godown custody before submit.       |

Hold kinds: `on_hand_deduction`, `reservation_conversion`, `quarantine_intake`.

Hold statuses: `active`, `released`, `transferred`, `written_off`, `returned_supplier`.

FORCE RLS, SELECT-only, trusted writer GUC `app.damage_write`. Stock posts also set a pid-scoped token via `app_private.enable_trusted_guc('app.damage_stock_write')` so `prepare_stock_locations` may touch quarantine crates. Client `set_config('app.damage_stock_write','on')` cannot spoof that token.

## RPC contracts

Submit still always calls `app_private.apply_damage_stock_isolation`. The hold-ready flag may **block** that function; it cannot skip isolation once ready.

| RPC                                                                                | Actor                                | Effect                                                                           |
| ---------------------------------------------------------------------------------- | ------------------------------------ | -------------------------------------------------------------------------------- |
| `confirm_shop_return_custody`                                                      | `damage.record` at the godown        | Records physical custody. Required before shop-return submit.                    |
| `submit_damage_report`                                                             | reporter                             | Calls isolation in the same transaction.                                         |
| `verify_damage_report`                                                             | GM `damage.verify`, not the reporter | Evidence required. Hold qty must match lines for hold scenarios.                 |
| `return_damage_report`                                                             | GM                                   | Releases on-hand / loading holds. **Denied** for submitted shop-return.          |
| `reject_damage_report`                                                             | GM, not the reporter                 | Releases on-hand / loading holds. Shop-return stays quarantined.                 |
| `post_ordinary_damage_writeoff`                                                    | GM `damage.verify`                   | Tagged `ADJUSTMENT`. Admin cannot post.                                          |
| `request_exceptional_damage_disposition`                                           | GM                                   | `return_supplier` or `destroy`. No stock.                                        |
| `approve_exceptional_damage_disposition` / `reject_exceptional_damage_disposition` | Admin `damage.dispose`               | Approval only.                                                                   |
| `post_exceptional_damage_disposition`                                              | GM after approval                    | Tagged `ADJUSTMENT`.                                                             |
| `transfer_verified_damage_to_quarantine`                                           | GM                                   | `CRATE_TRANSFER` of verified storage holds. Hold stays effective in the same TX. |

## Hold lifecycle

1. Submit (flag true) → active hold.
2. Return / reject of storage or loading → `released` (loading restores a reservation only if picking/dispatch still eligible).
3. Verified storage may physically move → `transferred` on the quarantine crate.
4. Ordinary write-off → `written_off` then ledger debit.
5. Exceptional supplier return → `returned_supplier` then ledger debit.

## Quarantine location model

`ensure_godown_quarantine_crate` creates zone `QRN` / crate `QRN-01` with `location_role = quarantine`.

- `picking_available_cases` returns 0 for quarantine crates.
- `picking_line_plan` excludes those locations.
- Ordinary `prepare_stock_locations` callers (opening, receiving, crate transfer, adjustment, dispatch) raise if a quarantine crate is included unless `app.damage_stock_write` is on.

A crate may still hold multiple SKUs. Quarantine is a location role, not a single-product assumption.

## Reservation interactions

`picking_available_cases = on_hand - active reservations - active on-hand/conversion holds`.

Loading conversion reduces or releases the overlapping reservation, then inserts `reservation_conversion` holds. `assert_dispatch_handoff_ready` counts remaining active reservations **plus** converted holds against the verified order. `confirm_dispatch` consumes only remaining active reservations and rewrites the dispatch fingerprint after conversion.

## Trusted ledger posting

No `DAMAGE_*` transaction types. Intake and write-off use `ADJUSTMENT` with `damage_report_id` and `damage_posting_kind`. Physical move uses `CRATE_TRANSFER`. Unique `(damage_report_id, damage_posting_kind)` plus idempotency keys prevent duplicate posts.

When dual-write is on, posts go through `apply_lot_aware_stock_deltas`. Quarantined lots may be mutated only with `app.damage_stock_write`. When dual-write is off, aggregate `apply_stock_delta` is used and `lot_id` stays null.

`assert_stock_transaction_complete` treats tagged damage `ADJUSTMENT` rows (no `adjustment_request_id`) as complete when intake ledger sums to `+quantity` and write-off ledger sums to `-quantity`. Ordinary stock adjustments are unchanged. This check is deferred to commit, so SQL rollback suites cannot prove it; concurrency and HTTP commits can.

`apply_lot_aware_stock_deltas` must clear its scratch tables with `DELETE ... WHERE true`. PostgREST sessions load `safeupdate`, which rejects unqualified `DELETE`. M3 already patched this; M5.3 preserves it.

## Shop-return custody

A shop-return report is not proof of receipt. `confirm_shop_return_custody` is the authorized custody step. Isolation posts unavailable quarantine inventory atomically with submit. Reject does **not** move that stock into saleable locations.

## Verification and exceptional approval

D1: `reporter_user_id` must not equal `auth.uid()` on verify (and reject). No Admin verify bypass.

D2: ordinary write-off is GM after verified (+ finalized photo + active isolation).

D3: supplier return and destroy require Admin approval; Admin does not post stock. No quantity/money threshold.

## Inactive godown

Non-transit isolation and posting call `assert_operational_active_branch`. Admin `access_all` cannot skip `is_active`.

## Lot cutover

Nullable `lot_id` when dual-write is off. Dual-write storage/loading isolation requires lot grains. Flags are not written by the migration. Legacy unattributed lots stay ineligible for picking.

## Lock order

1. Cutover shared `(88104301, 1)`
2. Damage report
3. Source documents (order / picking / dispatch / reservations as needed)
4. Products
5. `prepare_stock_locations` (zones → crates → branch; inactive godown fails here)
6. Lots
7. Lot balances
8. Aggregate balances
9. Hold rows
10. Transactions / ledger

`assert_damage_create_auth` must not `FOR UPDATE` the branch for loading/storage/shop-return. That inverted `confirm_dispatch` (documents → products → locations) and deadlocked M5.3 race C. Inbound still locks the branch because it does not take picking/dispatch/product locks.

Reservation conversion also takes `app.picking_write` / `app.dispatch_write`.

## Test evidence

Recorded in the M5.3 implementation report after local SQL / HTTP / concurrency / regression runs.

## M5.3A fixture hygiene

The four leftover `m1s2qa` aggregate grains (`m1s2qa-oil`×4 on `m1s2qa_ca1`, `m1s2qa-soap`×6/3/2 on `m1s2qa_ca1`/`ca2`/`cb`) are disposable Playwright/HTTP QA fixtures. They persist because e2e `ensureQaFixtures` posts opening stock and does not always tear down lots/balances. `assert_lot_inventory_grains_reconciled` scans every committed grain, so unmatched leftovers block dual-write enablement in M1-S1/M2/M3/M4.1.

Scoped cleanup (replica, SKU `m1s2qa-%` only) nulls ledger `lot_id`, then deletes attributions, baselines, legacy seeds, lot balances, lots, and aggregate balances. Opening headers remain. Playwright `beforeAll` and M1-S2 HTTP restock those grains when quantity is short, because idempotent `post_opening_stock` replay does not recreate balances. Playwright `afterAll` repeats the SKU-scoped lot/balance wipe. Operational dual-write enables in M2/M3/M4.1 SQL and HTTP now use `session_replication_role = replica` because those suites are not proving the unmatched-grain trigger. M1-S1 and M1 posting still exercise the real enable path.

## Known limitations

1. `/damage` remains an empty placeholder.
2. Transit goods that later physically return need a new shop-return-style custody report; M5.3 does not auto-restock consumed dispatch.
3. Rejected shop-return inventory stays in quarantine until a later authorized write-off or exceptional post.
4. `damage.stock_hold_ready` is not enabled on development cloud.
5. Postgres still cannot hash Storage object bytes; M5.2 finalize rules remain.

## Future M5.4 frontend

- Custody confirmation control on shop-return submit.
- Hold and quarantine visibility on the report.
- Ordinary write-off vs exceptional request/approval/post screens.
- Disable self-verify in the UI (database already enforces it).
