# M1 — Lot-aware posting cutover runbook (owner approval required)

This runbook is **not** executed as part of local M1 implementation. Working database flags must stay:

- `stock.lots.dual_write_enabled = false`
- `stock.lots.aggregate_only_blocked = false`

Do not run seed or flip flags without a separate owner authorization that names the target environment.

## Preconditions

1. Local migration tip includes `20261022190000_lot_aware_operational_posting`.
2. Cloud (or target) migrations applied through the same tip after explicit deploy approval.
3. All products that will receive lot-aware posts are classified via `set_product_expiry_policy` (Admin only).
4. Aggregate stock balances reconcile to the ledger.
5. Disposable fixture SQL `supabase/tests/phase_m1_lot_aware_operational_posting.sql` has passed (rolled back).

## Recommended order (disposable or approved environment only)

1. **Freeze window** — stop operational posting (opening, transfer, receive verify, adjustment post).
2. **Seed legacy lots** (only if positive aggregate balances lack lots):

   ```sql
   select public.seed_legacy_stock_lots();
   ```

   This sets `aggregate_only_blocked=true` on success. Aggregate-only posts then fail until dual-write is enabled.

3. **Enable dual-write** (Admin / configuration owner path used by the project):

   ```sql
   update public.app_configuration
   set value = 'true'::jsonb
   where key = 'stock.lots.dual_write_enabled';
   ```

4. **Smoke** — opening with lot metadata, multi-lot receive, explicit lot transfer, lot adjustment; confirm aggregate delta = sum(lot deltas) and ledger `lot_id` populated.

5. **Unfreeze** operational posting.

## Rollback (approved environment only)

1. Re-enable freeze.
2. Set `stock.lots.dual_write_enabled = false` only if inventory conservation and business rules still allow aggregate-only resume (post-seed this usually requires clearing or completing dual-write; treat as a deliberate recovery plan, not a casual toggle).
3. Do not delete ledger or lot history.

## Explicitly out of scope for this cutover

- FEFO picking / order availability cutover
- Cross-godown transfers
- Cloud deploy without separate authorization
