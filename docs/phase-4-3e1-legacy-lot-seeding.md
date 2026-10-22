# Phase 4.3E.1 / 4.3E.1A — Legacy inventory lot seeding

**LOCAL IMPLEMENTATION.** Not authorized for cloud `db push` until a later gate.

Migrations:

- `20261022140000_legacy_stock_lot_seeding.sql` (4.3E.1)
- `20261022150000_legacy_seed_lock_order_hardening.sql` (4.3E.1A)

## Delivered

- Permission `stock.lots.seed` (Admin only; explicit RPC call — **not** run by migration apply)
- Marker table `stock_legacy_lot_seeds` (PK `crate_id, product_id`)
- RPC `public.seed_legacy_stock_lots()`
- Config:
  - `stock.lots.dual_write_enabled` = false (cannot be set `true` until dual-write exists)
  - `stock.lots.aggregate_only_blocked` = true after successful seed
- Cutover advisory lock `(88104301, 1)`

## Lock order (4.3E.1A)

| Actor | Order |
|-------|--------|
| **Seeder** | Exclusive advisory → `prepare_stock_locations` (shared + zones/crates) → balance `FOR UPDATE` → insert lots/markers → set `aggregate_only_blocked` |
| **Opening / transfer / receiving / adjustment / verification** | `prepare_stock_locations` acquires **shared** advisory **before** zone/crate locks → later balance locks / `apply_stock_delta` (re-asserts freeze) |

`apply_stock_delta` alone is not sufficient for lock ordering because callers held location locks first; shared lock now lives in `prepare_stock_locations`.

## Seed rules (owner-approved)

- One `legacy_unattributed` / `legacy_reconciliation` lot per positive aggregate grain
- `branch_id` from crate → zone → branch
- Metadata / source refs NULL
- Aggregate quantities and historical ledger unchanged
- Zero-quantity aggregate rows skipped
- Idempotent via marker; quantity mismatch → hard error
- **Unexpected existing lot balances** (any qty, including 0) without a marker → hard error (no extra legacy lot)

## Operational downtime after seed (intentional)

After a **successful** `seed_legacy_stock_lots()` commit:

- All aggregate-only stock posts fail with SQLSTATE `55000` until Phase 4.3E.2 implements dual-write.
- Affected: opening, crate transfer, receipt verify/post, stock adjustment post.
- There is **no** client unfreeze RPC. Do not flip config flags manually.
- `stock.lots.dual_write_enabled=true` is **rejected** by trigger until dual-write ships.
- Run seed only in an explicit Admin maintenance window.

## Single-transaction seed limits

- Seed runs in **one** database transaction (markers + freeze commit together).
- Holds exclusive cutover lock and row locks on all positive-balance crates/zones for the duration.
- **Local inventory** (tens of grains / low hundreds of cases): acceptable under a short maintenance window.
- Risks if inventory grows large: long lock duration, client wait timeouts, statement_timeout on the seed session.
- **Future batching** only if measured timeouts appear; batching must preserve exclusive cutover serialization and per-grain markers. Not required for current local size.

## Explicitly not in 4.3E.1 / 4.3E.1A

- Dual-write posting
- FEFO / FIFO / picking
- Order availability cutover
- Cross-godown lot transfers
- Cloud deployment
- Automatic seed on migration apply
