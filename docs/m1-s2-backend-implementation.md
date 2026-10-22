# M1-S2.2 — Physical lot reconciliation backend

Local implementation of the approved M1-S2 contract. Attribution (`apply_legacy_lot_attribution`) is **not** implemented; that is M1-S3.

## Tables

| Table | Purpose |
|---|---|
| `stock_lot_reconciliations` | Session header. Status `draft` / `submitted` / `approved` / `rejected` / `cancelled`. Optimistic `version`. Unique `session_number` (`LR-YYYYMMDD-######`). Unique `idempotency_key`. |
| `stock_lot_reconciliation_scope_crates` | Selected crates. Partial unique `(crate_id) where holds_scope` blocks overlapping active/approved sessions. Cancel sets `holds_scope = false`. |
| `stock_lot_reconciliation_lines` | Frozen expected carton cases + physical count. Unique grain `(session_id, crate_id, product_id)`. Found products have `expected_quantity = 0`. |
| `stock_lot_reconciliation_lot_entries` | Physical lot breakdown. Unknown identity is explicit. Unique identity per line uses `NULLS NOT DISTINCT`. |
| `stock_lot_reconciliation_events` | Append-only history. Unique idempotency key where present. |

No changes to `stock_balances`, `stock_ledger`, `stock_lots`, `stock_lot_balances`, seed markers, or cutover flags.

## RPC signatures

All `SECURITY DEFINER`, `search_path = ''`, `GRANT EXECUTE` to `authenticated` only. Writes require transaction GUC `app.lot_reconciliation_write`.

| Function | Actor |
|---|---|
| `create_lot_reconciliation(target_godown, crate_ids, idempotency_key, session_notes)` | Admin `stock.lots.legacy.reconcile` |
| `list_lot_reconciliations()` | GM / Admin / monitor (branch-scoped) |
| `get_lot_reconciliation(target_session)` | same |
| `save_lot_reconciliation_count(target_session, expected_version, target_crate, target_product, counted_quantity)` | GM `stock.lots.physical_reconcile`, draft |
| `save_lot_reconciliation_lots(target_session, expected_version, target_line, lots jsonb)` | GM, draft |
| `add_lot_reconciliation_found_product(target_session, expected_version, target_crate, target_product)` | GM, draft |
| `refresh_lot_reconciliation_expected(target_session, expected_version)` | GM, draft; deletes counts and lots and resnapshots |
| `submit_lot_reconciliation(target_session, expected_version, idempotency_key default null)` | GM, draft |
| `approve_lot_reconciliation(target_session, expected_version, review_notes, idempotency_key default null)` | Admin; not the submitter |
| `reject_lot_reconciliation(target_session, expected_version, reject_reason, idempotency_key default null)` | Admin |
| `reopen_lot_reconciliation(target_session, expected_version, idempotency_key default null)` | GM, rejected → draft |
| `cancel_lot_reconciliation(target_session, expected_version, cancel_reason, idempotency_key default null)` | Admin, draft or rejected |

Stale `version` raises `PT409`. Approve does not post stock, seed lots, or flip flags.

## State machine

```
create → draft
draft → submitted (GM)
submitted → approved (Admin, matched + classified + live baseline)
submitted → rejected (Admin)
rejected → draft (GM reopen)
draft | rejected → cancelled (Admin; releases crate scope)
```

`approved` stays locked until M1-S3 attribution. There is no `applied` transition in this stage.

## Permissions

- `stock.lots.physical_reconcile` — Godown Manager and Admin. Record, submit, reopen.
- `stock.lots.legacy.reconcile` — Admin. Create, approve, reject, cancel.
- Store Keeper is not granted either key.

Branch isolation uses `app_private.can_work_at_branch`. Clients have `SELECT` only; RLS uses `can_view_lot_reconciliation`.

## Locking

Submit, approve, and refresh take **shared** advisory `(88104301, 1)` first, then crates, then `stock_balances` ordered `(crate_id, product_id)`. They never take the exclusive seed/flag lock. Draft count saves lock only the session row.

## Idempotency

Create is unique on `idempotency_key`. Submit / approve / reject / reopen / cancel replay a matching event key without a second transition.

## Test commands (local Docker only)

```text
Get-Content supabase/tests/phase_m1_s2_physical_reconciliation.sql | docker exec -i supabase_db_sherlyos psql -U postgres -d postgres -v ON_ERROR_STOP=1
node supabase/tests/phase_m1_s2_concurrency.mjs
node supabase/tests/phase_m1_s2_http_integration.mjs
```

Do not run these against development cloud.

## M1-S2.4 verification (local Docker only)

Re-run on `supabase_db_sherlyos` / `http://127.0.0.1:54321`. Development cloud `ypkfondrkhkydkgovwup` was not written. Cloud migration tip remains `20261022200000`. Local tip is `20261022210000`.

- SQL regression: `NOTICE: M1-S2.2 SQL checks passed`, `ROLLBACK`
- Concurrency: T20 overlap, non-overlap, T21 PT409, T22 approve versus posting — PASS
- HTTP (password JWT + supabase-js, same argument names as the frontend): 21/21 PASS, including cross-branch denial, Store Keeper denial, direct DML denial, self-approval denial, unexpected-stock approval block, cancel releases scope, attribution RPC absent
- Inventory after recon HTTP: aggregate quantity, lot rows, seed rows, and cutover flags unchanged versus the post-fixture baseline. `apply_legacy_lot_attribution` does not exist.

Pending migration `20261022210000_lot_physical_reconciliation.sql` is additive: new tables, RPCs, SELECT-only grants, RLS. No `DROP`/`TRUNCATE` of live stock, no seed, no flag flip, no stock mutation. Applying it does not require an inventory posting pause. After deploy, submit/approve/refresh share advisory `(88104301, 1)` with posting.

## Known limitations

- Photo evidence is not part of this workflow.
- Refresh is draft-only and wipes counts and lot entries.
- Approved sessions cannot be cancelled here; crate scope stays held.
- `apply_legacy_lot_attribution` does not exist. Do not add a stub.
- Local GoTrue cannot scan NULL varchar tokens on `auth.users`; disposable QA users need non-null tokens. This is a local Auth compatibility issue, not an M1-S2 RPC defect.
