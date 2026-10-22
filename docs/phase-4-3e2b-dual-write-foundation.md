# Phase 4.3E.2B — Private dual-write foundation

Local-only foundation for lot-aware stock deltas and durable pre-verify receipt lot attributions. Does **not** enable dual-write, seed lots, or rewrite posting RPCs.

## Delivered

| Item | Detail |
|------|--------|
| Migration | `20261022160000_lot_aware_dual_write_foundation.sql` |
| Private helper | `app_private.apply_lot_aware_stock_deltas(jsonb)` — no client grants |
| Receipt attributions | `stock_receipt_line_lot_attributions` + `set_stock_receipt_line_lot_attributions` |
| D1 | `stock.lots.legacy.reconcile` → Admin only (reserved; unused by posting) |
| D4 | Adjustment stale version → `PT409` (`lock_adjustment_request`, `post_stock_adjustment`) |
| Fingerprint | `receipt_posting_fingerprint` includes attribution fields |

## Private helper contract

Input array elements:

```json
{ "product_id": "uuid", "lot_id": "uuid", "crate_id": "uuid", "quantity": 1 }
```

`carton_delta` is accepted as an alias for `quantity`. Signed integers; zero rejected; same lot×crate rows are summed.

Behavior:

1. Always updates **lot balances and aggregate balances** together (no aggregate-only fallback).
2. Validates lot↔product, lot.branch ↔ crate→zone→branch, active products/locations via `prepare_stock_locations`.
3. Rejects negative lot or aggregate balances.
4. Does **not** write ledger/transactions. Callers must insert matching `stock_ledger` rows **before** the helper updates `stock_balances` (ledger/balance trigger).
5. Not wired into opening, transfer, receive verify, or adjustment posting.

## Lock order (helper)

Intended sequence for `apply_lot_aware_stock_deltas`:

1. Shared cutover advisory `(88104301, 1)` via `acquire_stock_cutover_shared_lock`
2. Products `FOR UPDATE` (id order)
3. `prepare_stock_locations` → shared advisory again → zones → crates (id order); inactive/unauthorized rejected
4. Lots `FOR UPDATE` (id order)
5. Lot balances then aggregate balances in `(crate_id, product_id, lot_id)` / `(crate_id, product_id)` order

Compatible with:

| Workflow | Notes |
|----------|--------|
| Legacy seed | Exclusive cutover first; helper waits on shared |
| Opening / transfer | Shared via prepare before balances — same advisory class |
| Receipt verify | Still locks receipt/supplier/products **before** prepare (existing). Helper alone products→prepare. See residual below |
| Adjustment | Same product-before-prepare pattern as verify |

### Residual ordering differences (defer to later increments)

- **Receive verify / adjustment post** lock **products before** shared cutover today. Safe vs seeder (seeder does not lock products). When those RPCs adopt the helper, prefer moving shared+prepare before or immediately after document locks, then products, **or** keep products-before-prepare but never lock lots before shared.
- Helper intentionally does **not** take document/request locks (caller owns those).
- Aggregate-only `apply_stock_delta` still used by existing posting; freeze (`aggregate_only_blocked`) and future dual-write assert close that path when flags flip (4.3E.2F).

## Receipt attributions

- Multiple rows per receipt line (no uniqueness on `source_receipt_line_id`).
- Positive integer `carton_quantity`; sum must equal `accepted_cases` (empty only when accepted is 0).
- Expiry policy: `expiry_controlled` requires `expiry_date`; `non_expiring` forbids it.
- Writable in `draft` / `submitted` / `held` via `receiving.execute` or `receiving.verify` + branch access.
- Immutable after `posted` / `cancelled` (RPC gate + trigger).
- Table: SELECT for authorized viewers; no client INSERT/UPDATE/DELETE.

## Flags (unchanged)

- `stock.lots.aggregate_only_blocked = false`
- `stock.lots.dual_write_enabled = false` (still trigger-blocked from client/true enable)

## Out of scope

Dual-write activation, posting RPC cutover, FEFO/FIFO, picking, availability, cross-godown lot moves, legacy seed on working DB, cloud migrate, Git publish.
