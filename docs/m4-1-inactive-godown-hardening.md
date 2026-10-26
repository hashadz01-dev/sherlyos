# M4.1 — Inactive godown operational hardening

Local implementation only. **Do not apply** this migration to development cloud `ypkfondrkhkydkgovwup` until a separate owner authorization. This work does not seed, attribute, classify, flip cutover flags, or post operational stock on development.

## Final inactive-godown policy

1. Inactive godowns remain included in **authorized historical reporting**.
2. **New operational activity** targeting an inactive godown is rejected.
3. Existing stock, ledger rows, and historical documents are **not rewritten**, auto-cancelled, or deleted by deactivation.
4. For **already-consumed** dispatches, authorized actors may finish delivery or record an exception. That path does not create reservations, picking, dispatch preparation, confirmation against inactive locations, new deductions, or new adjustments, and it does not bypass branch or role permissions.

`app_private.can_work_at_branch` is unchanged. Admin `access_all` still sees inactive stock in reports. Admin `access_all` cannot skip `branches.is_active` on guarded writes.

## Post-consume delivery behavior

Inspected against the M3 state machine in `20261022240000_dispatch_delivery.sql`. Delivery statuses were not invented.

| RPC | Existing M3 gate (unchanged) | M4.1 authorization |
|---|---|---|
| `assign_dispatch_delivery` | `stock_consumed` and status `dispatched` or `in_transit` | `deliveries.assign` plus assignment or `access_all`. Does **not** require `is_active`. |
| `start_dispatch_delivery` | `stock_consumed` and status `dispatched` (idempotent if already `in_transit`) | Assigned driver with `deliveries.execute`, plus assignment or `access_all`. |
| `acknowledge_dispatch_delivery` | `stock_consumed` and status `dispatched` or `in_transit` (idempotent if already `delivered`) | Same executor rule. |
| `report_dispatch_delivery_exception` | `stock_consumed` and status `dispatched` or `in_transit` (idempotent if already `exception`) | `dispatch.exception` or assigned `deliveries.execute`, plus assignment or `access_all`. |

These four RPCs do not call `assert_operational_active_branch`. They do not mutate `stock_balances` or `stock_ledger`, do not insert `DISPATCH` transactions, do not reactivate the godown, and cannot confirm a new dispatch.

A **preparing** (unconsumed) dispatch cannot enter delivery: assign still raises `23514` `delivery can be assigned only after stock consumption`. `confirm_dispatch` against inactive locations still fails at `prepare_stock_locations` (`location is inactive`).

Assigned drivers lose `can_work_at_branch` after deactivation because that helper requires `is_active`. `can_complete_consumed_delivery_at_branch` is assignment or `access_all` **without** `is_active`, and is used only for consumed-dispatch view/assign/start/POD/exception.

## Operational-active guard

`app_private.assert_operational_active_branch(uuid)` (VOLATILE, SECURITY DEFINER, `search_path = ''`):

1. Null / missing branch → `42501` `not authorized`
2. `SELECT … FROM branches WHERE id = $1 FOR UPDATE`
3. `can_work_at_branch` false → `42501` `not authorized`
4. `is_active` false → `23514` `godown is inactive`

Revoked from `public`, `anon`, `authenticated`, and `service_role`. Direct PostgREST calls cannot invoke it. Unauthorized callers never receive the inactive message. Admin `access_all` does not bypass the active check.

Lock order is unchanged: cutover shared advisory `(88104301, 1)` → order → picking → dispatch → products → `prepare_stock_locations` (zones → crates → **branches by id**) → lots → lot balances → stock balances.

The guard runs **after** the document row lock. `prepare_stock_locations` now locks owning branch rows after crate locks and re-checks crate, zone, and branch `is_active`. Error text stays `location is inactive`.

## RPC authorization matrix

### New operational activity (blocked at inactive godowns)

| RPC | How |
|---|---|
| `create_order` / `update_order` | `assert_order_branch` calls the guard; both failures map to existing `42501` `godown is not authorized` |
| `preview_order_allocation` / `reserve_order_allocation` | `assert_picking_allocator` |
| `assign_picking_request` | manager auth, then guard |
| `start_picking`, `confirm_picking_quantity`, `report_picking_shortage`, `complete_picking` | `assert_picking_executor` |
| `confirm_picking_handoff` | manager auth, then guard |
| `prepare_dispatch` | confirmer auth, then guard (after idempotent replay) |
| `create_stock_adjustment` | after closed-verification check |
| opening / transfer / receiving / verification start / lot recon crate lock | existing `prepare_stock_locations` plus branch `FOR UPDATE` |

### Stock posting (blocked at location lock)

| RPC | How |
|---|---|
| `confirm_dispatch` | confirmer stays auth-only so consumed replay still works; first consume hits `prepare_stock_locations` |
| `post_stock_adjustment` | same location lock |

Do **not** put the active check in `assert_dispatch_confirmer`. Blocking there would prevent replay of an already-consumed dispatch at an inactive site.

### Cancellation / safe release (auth only)

| RPC | Notes |
|---|---|
| `cancel_picking_request` | `assert_picking_manager` only. Assigned non-admins lose `can_work_at_branch` after deactivation, so **Admin** performs the release. |
| `cancel_dispatch` | confirmer auth; preparing only. Does not consume or restore stock. |
| `cancel_order` | existing rules unchanged |
| adjustment `return` / `reject` | unwind paths; no stock post |

### Post-consume delivery (allowed; assignment without `is_active`)

See table above. `dispatch_can_view` allows consumed rows at an inactive godown for assigned delivery actors so POD/exception payloads remain readable.

### Read-only historical access (unchanged)

Dashboard and report RPCs still use `can_work_at_branch` / `report_assert_branch`. Inactive stock remains in authorized totals. Frontend reporting totals are not changed by this migration.

### Caller matrix

| Caller | Inactive operational write | Inactive historical report | Post-consume delivery |
|---|---|---|---|
| Admin (`access_all`) | `23514` `godown is inactive` (or `location is inactive` on stock post) | Allowed | Allowed if role has the delivery permission |
| Assigned Godown Manager | `42501` on guarded writes (`can_work_at_branch` already false) | Assigned reporting already excluded | Allowed for assign / exception when the role has the permission |
| Assigned Store Keeper | `42501` | Excluded | `42501` (no `deliveries.assign` / `deliveries.execute`) |
| Assigned Delivery Person | N/A | Denied on inventory reports | Allowed for start / POD / exception when assigned to that dispatch |
| Unassigned / other branch | `42501` | `42501` on UUID filter | `42501` |
| Anon / guessed private RPC | `42501` | `42501` | `42501` |

Frontend `toUserRpcMessage` already surfaces short `23514` text.

## Security findings

- Guard and `can_complete_consumed_delivery_at_branch` are not granted to `authenticated`. Bypass through PostgREST is closed.
- Admin `access_all` cannot skip `is_active` on guarded writes.
- Trusted stock writers (`app.picking_write`, `app.dispatch_write`, `app.adjustment_write`) and FORCE RLS are unchanged.
- Direct DML on reservations / ledger remains denied.
- Existing EXECUTE grants on public delivery RPCs are preserved by `CREATE OR REPLACE`. No new public EXECUTE grants were added.
- No dynamic SQL. No lock-order inversion. No hidden stock mutation. Cutover flags are not touched.
- No destructive data migration. No edits to previously applied migration files.

## Fixture isolation corrections

### M4 SQL

`phase_m4_operational_intelligence.sql` previously asserted global dashboard / movement totals (`opening_cartons = 14`). Leftover committed `OPENING_STOCK` from HTTP/e2e inflated those totals.

Correction: unique `m4qi_` branch codes and every dashboard, inventory, movement, export, order, and dispatch assertion scoped to the fixture `filter_branch`. Business quantities (14 opening cartons on the fixture godown) are unchanged.

### M4.1 SQL

Unique `m41sql@` emails and `m41sql_` branch codes so HTTP `m41ig@` users do not collide. Delivery cases A–F use a second consumed dispatch for exception. Dashboard inactive-stock assertion is scoped to the inactive fixture UUID (remaining on-hand ≥ 1 after two fixture consumes), not a global carton total.

### Lot-reconciliation Playwright

`ensureQaFixtures` in `tests/e2e/lot-reconciliation.spec.ts` now:

1. Runs only against local Docker `supabase_db_sherlyos`.
2. Restocks each m1s2qa crate independently.
3. Posts a new opening **only** when no `OPENING_STOCK` header exists for that product+crate (unique idempotency keys).
4. If an opening header remains after HTTP replica cleanup stripped ledger/balance rows, restores those disposable ledger and balance rows instead of posting a second opening.
5. Does not skip or weaken the PT409 conflict assertion.
6. Restores cutover flags to false in `wipeLocalLotsIfSafe`.
7. Last attribution test still wipes lots when dual-write is off and no lot-attributed ledger remains.

If a full Playwright run leaves leftover `m1s2qa` unattributed seed lots because wipe refused while attribution was in flight, delete only those local disposable lots after confirming `stock_ledger.lot_id` is null. Do not run a remote reset.

### Test orchestration

Run against disposable local Supabase only. Do not `db reset --linked`.

Recommended order (fixture-safe):

1. SQL: M1-S1 (needs empty lots) → M1 posting → M1-S2 → M1-S3 → M2 → M3 → M4 → M4.1 → 4.1D / 4.2A–C.
2. HTTP: M2 → M3 → M4 → M4.1 (each restores flags in cleanup).
3. Concurrency: M2 → M3 → M4.1.
4. Unit / typecheck / lint / build (no database).
5. Full Playwright last (`workers: 1`, `--mode m1s2` on `127.0.0.1:4173`).

M1-S1 and lot-attribution e2e conflict if lots remain. Keep M1-S1 before Playwright, or wipe leftover local lots after Playwright as above. M4 SQL and M4.1 SQL no longer require an empty global ledger.

## Local evidence (2026-10-26, this preflight)

Environment: local Docker `supabase_db_sherlyos`, API `http://127.0.0.1:54321`. Cutover flags restored to `false` / `false` after each mutating suite. Historical results from the previous partial pass are not reused.

| Suite | Setup | Exit | Result | Cleanup |
|---|---|---|---|---|
| M1-S1 SQL | flags false, lots 0 | 0 | passed (rollback) | flags false |
| M1 posting SQL | local Docker | 0 | passed | rollback |
| M1-S2 SQL | local Docker | 0 | passed | rollback |
| M1-S3 SQL | local Docker | 0 | passed | rollback |
| M2 SQL | local Docker | 0 | passed | rollback |
| M3 SQL | local Docker | 0 | passed | rollback |
| M4 SQL | unique `m4qi_` branch + branch-scoped totals | 0 | passed | rollback |
| M4.1 SQL | unique `m41sql@` fixtures + delivery A–F | 0 | passed | rollback |
| 4.1D security SQL | local Docker | 0 | passed | as scripted |
| 4.2A / 4.2B / 4.2C SQL | local Docker | 0 | passed | as scripted |
| M2 HTTP | PostgREST 127.0.0.1:54321 | 0 | 5 checks passed | replica cleanup, flags false |
| M3 HTTP | same | 0 | 9 checks passed | replica cleanup, flags false |
| M4 HTTP | same | 0 | 13 checks passed | replica cleanup, flags false |
| M4.1 HTTP | same | 0 | 6 checks passed | replica cleanup, flags false, no ledger mutation on deny |
| M2 concurrency | two-session local psql | 0 | reserve vs reserve / transfer conserved | flags false |
| M3 concurrency | two-session local psql | 0 | confirm once; transfer/cancel/cutover races | flags false |
| M4.1 concurrency | deactivate vs Admin reserve | 0 | serialized; no bypass (this run: deactivate first, reserve denied) | flags false |
| Playwright | `--mode m1s2`, Chromium, 1 worker | 0 | **30 passed** (PT409 included) | flags false; leftover m1s2qa unattributed seed lots wiped locally afterwards |
| Vitest | jsdom | 0 | 103 passed / 20 files | n/a |
| typecheck | `tsc -b` | 0 | passed | n/a |
| lint | oxlint | 0 | passed (existing react-compiler warnings on Transfers / Opening / Products) | n/a |
| build | `tsc -b && vite build` | 0 | passed | `dist/` not part of the checkpoint |

### Delivery security tests (M4.1 SQL, isolated)

| Case | Result |
|---|---|
| A. Consumed dispatch, deactivate, authorized assign → start → POD | `delivered` |
| B. Second consumed dispatch, deactivate, authorized exception | `exception` |
| C. Preparing dispatch cannot `assign_dispatch_delivery` | `23514` |
| D. Cross-branch manager cannot assign; Store Keeper cannot start | `42501` |
| E. Repeated POD with the same idempotency key | existing replay, still `delivered` |
| F. Delivery progression creates no new `DISPATCH` stock transaction | txn count unchanged |

Admin / Godown Manager / Store Keeper / unauthorized inactive-write denies, active-godown success, historical Admin reporting, safe Admin cancel of in-flight allocation, and deactivation-vs-reserve serialization remain covered by the M4.1 SQL / HTTP / concurrency files.

## Development-cloud identity (read-only)

| Item | Value |
|---|---|
| Linked project ref | `ypkfondrkhkydkgovwup` (`supabase/.temp/project-ref` and MCP API URL) |
| API | `https://ypkfondrkhkydkgovwup.supabase.co` |
| Applied migrations | **29** |
| Tip | `20261023200000` `operational_intelligence` |
| M4.1 on cloud | **not applied** |
| Cutover flags | `dual_write_enabled=false`, `aggregate_only_blocked=false` |
| Lots | 0 |
| Negative balances | 0 |
| On-hand cartons | 73 |
| Ledger vs balances | no mismatched crate/product rows |
| Stock transactions | 20 (10 `OPENING_STOCK`, 4 `RECEIPT`, 3 `CRATE_TRANSFER`, 3 `ADJUSTMENT`) |
| Dispatch rows | 0 |

`npx supabase db push --dry-run --linked` (did **not** apply):

```
Would push these migrations:
 • 20261026120000_inactive_godown_operational_hardening.sql
```

That is the only pending migration. Cloud flags, migration count, and inventory were unchanged after the dry-run.

## Backup directories (exist; new dump not taken)

| Path | Notes |
|---|---|
| `C:\Users\Hash\Desktop\Hashdev\sherlyos-backups\dev-ypkfondrkhkydkgovwup\` | Latest verified dump `20261023T083843Z` (M4 apply). Evidence folders for M2/M3/M4 sit beside it. |
| `C:\Users\Hash\Desktop\Hashdev\sherlyos-recovery\` | Older phase dumps (4.2, 4.1, 3.x). |

The 23 October dump is **not** a substitute for an immediate pre-apply backup. Take a new verified dump after owner authorization and write freeze, immediately before apply.

## Deployment plan (do not execute)

1. **Final owner authorization** naming project `ypkfondrkhkydkgovwup` and this migration file only.
2. **Development project identity verification** (`npx supabase migration list --linked`, API host, 29 applied, tip `20261023200000`).
3. **Operational write freeze** on development (no openings, receipts, transfers, adjustments, picking, dispatch, or cutover flag changes).
4. **Immediate verified backup** under `sherlyos-backups\dev-ypkfondrkhkydkgovwup\<timestamp>\` (schema, data, roles, SHA-256, manifest).
5. **Final migration dry-run** (`db push --dry-run --linked`) confirming the only pending file is `20261026120000_inactive_godown_operational_hardening.sql`.
6. **Single M4.1 migration apply** via the approved CLI/MCP path. No other migrations. No frontend deploy.
7. **Post-apply security checks**: guard exists, revoked from `authenticated`; `can_work_at_branch` unchanged; Admin inactive write denied; unauthorized fail closed.
8. **Stock conservation checks**: on-hand still 73 (or freeze baseline), no negatives, ledger matches balances, 0 lots, 0 unexpected dispatches.
9. **Cutover flag verification**: still `false` / `false`.
10. **Safe freeze release** only after those checks.
11. **Incident procedure**: PostgreSQL cannot roll back replaced functions in-place. Restore previous bodies from `20261022150000`, `20261022230000`, `20261022240000`, `20261016200000`, and `20261017120000` in a **new forward** migration, or restore the pre-apply backup. Do not edit already-applied files.

## Remaining blockers

- Owner has **not** authorized development-cloud apply.
- Immediate pre-apply backup has **not** been taken (existing dump is M4-era 2026-10-23).
- Do not enable lot cutover. Do not deploy frontend as part of this migration.
- Local disposable leftover lots after Playwright attribution must be wiped before the next M1-S1 run if wipe was skipped; this preflight wiped them locally after the suite (`lots = 0`).

No test or security gate remaining for local M4.1.

## Git checkpoint proposal (do not commit in this task)

Include:

- `supabase/migrations/20261026120000_inactive_godown_operational_hardening.sql`
- `supabase/tests/phase_m4_1_inactive_godown_hardening.sql`
- `supabase/tests/phase_m4_1_http_integration.mjs`
- `supabase/tests/phase_m4_1_concurrency.mjs`
- `supabase/tests/phase_m4_operational_intelligence.sql`
- `tests/e2e/lot-reconciliation.spec.ts`
- `tests/e2e/reports.spec.ts`
- `docs/m4-1-inactive-godown-hardening.md`

Exclude: `.env`, `.env*.local`, secrets, `dist/`, `supabase/.temp/`, unrelated dirty files.

Suggested message:

```
Harden inactive godown write RPCs and allow post-consume delivery completion.

Keep can_work_at_branch unchanged so Admin historical reporting still includes inactive stock.
```
