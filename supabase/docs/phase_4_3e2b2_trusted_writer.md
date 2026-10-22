# Phase 4.3E.2B.2 — Trusted writer security model (verified)

## PostgreSQL facts (local Supabase PG 17.11)

1. **`SET LOCAL ROLE` / `SET ROLE` cannot run inside `SECURITY DEFINER` functions.**
   Verified error: `cannot set parameter "role" within security-definer function`.
   Therefore a NOLOGIN writer role switched via `SET LOCAL ROLE` from the lot helper or seeder is **not** a viable authorization path without changing the DEFINER architecture.

2. **Custom GUCs (`app.lot_balance_write`) are spoofable** by `authenticated` via `set_config` / `SET LOCAL`. They must not authorize writes.

3. **`current_user` inside a `SECURITY DEFINER` trigger is the function owner**, not the client. It is not a substitute for application identity (`auth.uid()`).

4. **Table owners retain DML** even when clients are SELECT-only. A write gate is required so owner sessions (and DEFINER bodies) cannot write unless an explicit, non-client-forgeable permit exists.

## Chosen mechanism: transaction-scoped private permits

- Table `app_private.lot_balance_write_permits` keyed by `pg_current_xact_id()`, mode `helper` | `seed`.
- **No grants** to `anon`, `authenticated`, or `service_role` (schema USAGE alone does not grant table DML).
- `app_private.begin_lot_balance_write(mode)` / `end_lot_balance_write()` are `SECURITY DEFINER`, `search_path = ''`, **EXECUTE revoked** from clients.
- Only approved DEFINER paths (`apply_lot_aware_stock_deltas`, `seed_legacy_stock_lots`) open permits. Local SQL fixtures may call begin/end as the table owner (`postgres`); that is not production client access.
- BEFORE trigger `assert_lot_balance_write_allowed` allows writes **only** when a permit row exists for the current transaction ID. GUC values are ignored. There is no `postgres` bypass.

Nested DEFINER calls cannot inherit a user-forged authorization mode: clients cannot insert permits, and GUC spoofing has no effect.

## Cumulative conservation

Deferred checks reconcile lot balances with **lot_id ledger totals only** (never NULL-lot ledger):

- **Seed-marker lots:** `sum(balances) = sum(marker.quantity) + sum(ledger where lot_id = L)`.
- **Lots with lot-ledger history and no marker:** `sum(balances) = sum(ledger where lot_id = L)`.
- **Neither marker nor lot-ledger:** check skipped (fixture / pre-attribution balances). Seed mode permits skip conservation while the baseline is written.
