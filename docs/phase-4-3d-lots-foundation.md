# Phase 4.3D — Lot/expiry schema foundation

**LOCAL IMPLEMENTATION.** Not authorized for development cloud `db push` until a later gate.

Migrations:

- `supabase/migrations/20261020120000_stock_lots_foundation.sql` (4.3D)
- `supabase/migrations/20261022120000_stock_lots_foundation_hardening.sql` (4.3D.1)

## Delivered (4.3D)

- `products.expiry_policy` (`NULL` | `expiry_controlled` | `non_expiring`); existing products stay `NULL`
- `public.set_product_expiry_policy(uuid, text)` — SECURITY DEFINER, audit, blocks policy change when lots exist
- `app_configuration.stock.near_expiry_warning_days` = `90`
- Empty `stock_lots` and `stock_lot_balances`
- Nullable `stock_ledger.lot_id` (no backfill)
- FORCE RLS; authenticated SELECT only; no client mutations

## Hardening (4.3D.1)

- Dedicated permission `products.expiry_policy.manage` granted **only to Admin**
- `set_product_expiry_policy` asserts that permission (not `products.manage`)
- Godown Manager retains `products.manage` for catalog create/update/deactivate and **cannot** classify expiry policy
- `stock_lots.branch_id` (`NOT NULL`, FK to `branches`) scopes SELECT via `can_work_at_branch`
- Lots with no balance rows are **not** globally readable; legitimate zero-quantity balance lots remain visible to authorized branch users
- SQL comments corrected so Admin-only classification is not confused with Godown Manager `products.manage`

## Explicitly not in 4.3D / 4.3D.1

- Legacy stock seeding
- Lot-aware posting cutover / dual-write
- Aggregate = Σ lots invariant trigger (would fail while balances exist and lots are empty)
- Picking, FEFO/FIFO, PICK transaction type
- Classification UI
- Cloud deployment

## Future lot-creating RPCs — concurrency requirement (not implemented)

`set_product_expiry_policy` locks the product `FOR UPDATE` and refuses a policy change when any `stock_lots` rows exist for that product.

Any later lot-creating SECURITY DEFINER RPC **must**:

1. Lock the same product row `FOR UPDATE` before inserting a lot
2. Re-read `products.expiry_policy` under that lock
3. Reject lot creation for unclassified products (and enforce expiry_date rules for classified ones)

Without the product lock, a concurrent classify/create race can leave lots that no longer match the policy the creator observed. Do not rely on the lots-exist check alone in the classification RPC.

## Unresolved: `source_receipt_line_id` uniqueness (not implemented)

`stock_lots.source_receipt_line_id` is nullable and indexed, but **not** unique.

Open product decision for a later phase:

- One internal lot per receipt line, or
- Multiple lots allowed per receipt line (e.g. split manufacturer codes)

Do **not** invent a unique constraint until that rule is approved. Document the choice in the posting/receiving design that introduces lot creation.

## Future invariant (dormant)

For each `(crate_id, product_id)`:

`stock_balances.quantity = sum(stock_lot_balances.quantity)` over lots of that product in that crate.

Activate only after lot-aware posting and legacy representation are authorized and applied.
