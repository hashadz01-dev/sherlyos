# Phase 4.3E.2B.1 — Ledger / lot integrity hardening

Local-only hardening on top of 4.3E.2B. Does **not** enable dual-write or wire posting RPCs.

## Migration

`20261022170000_lot_aware_ledger_integrity.sql`

## Helper contract

```text
app_private.apply_lot_aware_stock_deltas(transaction_id uuid, lot_deltas jsonb)
```

- Requires existing `stock_transactions` row and matching `stock_ledger` rows with **non-null** `lot_id`.
- Fingerprint match on `(lot_id, crate_id, product_id, quantity)`.
- Rejects duplicate `(lot_id, crate_id)` deltas (`23514`).
- Applies **once** per transaction (`stock_lot_aware_applications`).
- Lot status: `available`; `legacy_unattributed` needs `stock.lots.legacy.reconcile`; `quarantined` / `expired_blocked` rejected.

## Integrity layers

1. **Helper fail-fast** — ledger must match deltas before balance writes.
2. **Write gate** — `stock_lot_balances` only via `app.lot_balance_write` = `helper` | `seed` (plus local table-owner fixtures).
3. **Deferred constraint** — any transaction with non-null `lot_id` ledger must have a matching application marker + fingerprint at commit. Aggregate-only / NULL-lot history unchanged. Seed sets `app.lot_balance_write=seed` and skips deferred lot-aware requirements.

## Attribution

Immutability trigger locks parent receipt `FOR UPDATE`. Invalid numerics → `23514`. Receiving permissions unchanged.
