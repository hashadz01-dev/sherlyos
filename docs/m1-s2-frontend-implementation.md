# M1-S2.3 — Physical lot reconciliation frontend

Local UI against the M1-S2.2 RPCs. Attribution is not implemented.

## Routes

| Path | Gate |
|---|---|
| `/stock-lot-reconciliation` | `stock.lots.physical_reconcile` OR `stock.lots.legacy.reconcile` OR `operations.monitor` |
| `/stock-lot-reconciliation/new` | `stock.lots.legacy.reconcile` |
| `/stock-lot-reconciliation/:sessionId` | same as list |

Nav item **Lot reconciliation** sits after daily verification. Store Keeper `stock.count_assist` is not granted.

## RPC wrappers

`src/lib/lot-reconciliation/api.ts` calls the public functions with the SQL argument names (`target_godown`, `expected_version`, `reject_reason`, and so on). Errors keep PostgREST `code` so `PT409` can refetch without replaying the stale edit.

## List display

`list_lot_reconciliations()` is the authorization boundary. Godown names, crate counts, `created_by`, and `updated_at` are filled from RLS `SELECT` on already-returned session ids. Those fields are not on the list RPC payload.

## Out of scope here

- Photo evidence (no M1-S2.2 photo RPC)
- `apply_legacy_lot_attribution`
- Cloud migrations or the development project `ypkfondrkhkydkgovwup`

## M1-S2.4 local integration

Browser tests use Vite `--mode m1s2`, which loads gitignored `.env.m1s2.local` (`http://127.0.0.1:54321` + local anon key). `.env` and `.env.local` stay on the development cloud and were not overwritten.

`npx playwright test tests/e2e/lot-reconciliation.spec.ts` passed 5/5 against that local API:

- Store Keeper is denied the page and nav item.
- Tablet-width create form remains usable.
- Stale-version save shows the PT409 banner and does not replay the edit.
- Draft refresh confirmation clears counts; unexpected stock can be submitted and blocks approval; reject/reopen/cancel stay on the session.
- Admin creates a selected-crate session, GM records known and unknown lot evidence, Admin 2 approves a fully matched session, and audit history shows created → submitted → approved.

Sign-in requests were asserted to `127.0.0.1:54321` before mutations. No product P0/P1 defects were found. Locator mismatches in the first e2e draft (`Matched` vs `Unmatched`, unscoped Save count) were test-only.
