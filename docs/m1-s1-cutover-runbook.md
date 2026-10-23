# M1-S1 — Lot cutover runbook (documentation only)

Do **not** execute against development or production without a separate owner authorization that names the environment, backup, and maintenance window.

This file documents the operational sequence. It is not a script. Database triggers enforce the unsafe transitions; they do not replace freeze, backup, or physical count.

## Preconditions

1. Migration tip includes `20261022220000_legacy_lot_attribution` (M1-S3 apply RPC), `20261022210000` (physical recon), `20261022200000_lot_cutover_flag_safety` (flag guards), and `20261022190000` (operational posting).
2. Both flags are `false` / `false` before any cutover work.
3. A fresh logical backup exists and inventory totals are recorded (balance rows, carton sum, ledger rows, ledger net).
4. Disposable SQL `supabase/tests/phase_m1_s1_cutover_flag_safety.sql` has passed locally (rolled back).

### Development schema status (ypkfondrkhkydkgovwup)

M1-S3 schema was applied **2026-10-22 18:27 +05:30** from `c89734aa57ba31ffc6833a42310eaccdcfadd066` via `npx --yes supabase@2.121.0 db push --linked --skip-vault` (exit 0). Cloud tip is `20261022220000`. Pre-apply backup: `C:\Users\Hash\Desktop\Hashdev\sherlyos-backups\dev-ypkfondrkhkydkgovwup\20261022T124850Z`. Inventory remained 11/73 balances and 23/73 ledger. Flags remain `false` / `false`.

**Operational cutover is still pending.** Development inventory is not eligible for seed, attribution, or dual-write: all 10 products are unclassified, there are 0 reconciliation sessions, and there are 0 lots. Schema deployment authorization is not seed/attribution/flag authorization.

## Required product classifications

Dual-write activation is **rejected** unless every product with **positive** `stock_balances.quantity` already has:

- `expiry_controlled`, or
- `non_expiring`

`NULL` (unclassified) is not a valid cutover state for in-stock products. Admin classifies through `set_product_expiry_policy` only (`products.expiry_policy.manage`). Do **not**:

- invent expiry dates
- auto-classify during seed or flag enable
- change policy after `stock_lots` exist for that product (database rejects)

Products with zero stock may remain unclassified; lot-aware posting of those SKUs still requires classification at post time.

Zero-grain inventory (no positive `stock_balances` rows) is already reconciled: there is no unclassified in-stock product and no lot/aggregate mismatch, so the validator allows greenfield `dual_write_enabled` + `aggregate_only_blocked`. Development is not on that path. Its 11 positive grains are unclassified, so dual-write remains rejected until classification, seed, and attribution complete. The empty-database SQL assertion was corrected to match this; validators were not weakened.

Verify before freeze ends:

```sql
select p.id, p.sku, p.expiry_policy, sum(sb.quantity) as qty
from public.stock_balances sb
join public.products p on p.id = sb.product_id
where sb.quantity > 0
  and p.expiry_policy is distinct from 'expiry_controlled'
  and p.expiry_policy is distinct from 'non_expiring'
group by 1, 2, 3;
-- must return zero rows before dual-write enable
```

## Phase 0 — Inventory freeze

Pause until explicitly cleared:

- `post_opening_stock`
- `post_crate_transfer`
- `verify_stock_receipt`
- `post_stock_adjustment`

Confirm no `idle in transaction` inventory sessions.

Configuration changes take an **exclusive** advisory lock `(88104301, 1)`. Posting takes the **shared** lock on the same key (including the dual-write flag read). Seed takes exclusive. Flag transitions and posting cannot interleave on that key.

## Phase 1 — Backup checkpoint

Record:

```sql
select count(*) as balance_rows, coalesce(sum(quantity), 0) as balance_qty
from public.stock_balances;
select count(*) as ledger_rows, coalesce(sum(quantity), 0) as ledger_net
from public.stock_ledger;
select count(*) as lot_rows from public.stock_lots;
select max(version) from supabase_migrations.schema_migrations;
```

Abort if backup is missing or stale. Restoring later is a separate authorized procedure.

## Phase 2 — Physical reconciliation

Use the M1-S2 session workflow (Admin `create_lot_reconciliation` for selected crates, Godown Manager count/lot entry/submit, Admin approve). Approval does **not** change `stock_balances` or seed lots.

Resolve every scoped grain so counted carton cases equal frozen expected quantity, with lot entries summing to the count. Unexpected physical stock is found-product evidence only — post it later through the existing adjustment path, then start a new session. Do not invent manufacturer codes or expiry dates; unknown identity stays explicit. Classify every in-scope product before approve. Do not apply attribution until seed has completed (Phase 3–3b).

## Phase 3 — Legacy lot seed (Admin)

```sql
select public.seed_legacy_stock_lots();
```

Expect `aggregate_only_blocked = true`, `dual_write_enabled = false`, one `legacy_unattributed` lot per positive aggregate grain, **no** ledger rewrite.

Policy cannot be changed after this step for seeded products. Classify first (see above).

Do **not** re-run seed after attribution. The unchanged seed RPC fail-closes when marker quantity no longer equals aggregate.

## Phase 3b — Apply approved attribution (Admin, M1-S3)

Requires:

- Authenticated Admin with `stock.lots.legacy.reconcile`
- Eligible `approved` session (matched, classified, no found-product lines)
- Seed completed (`aggregate_only_blocked = true`)
- Dual-write still off
- Live aggregate still equal to the approved counted/expected qty
- Exclusive advisory lock `(88104301, 1)` first, then session, crates, balances, lots

```sql
select public.get_lot_attribution_readiness('<session_id>');
-- eligible true, blockers empty

select public.apply_legacy_lot_attribution(
  '<session_id>',
  <expected_version>,
  '<idempotency_key>'
);
```

Behaviour:

- Known physical lots become `legacy_reconciliation` stock lots (`available` / `quarantined` / `expired_blocked`).
- Unknown identity and expiry-controlled unknown expiry stay on the original `legacy_unattributed` lot.
- Aggregate `stock_balances` and historical `stock_ledger` are **not** rewritten.
- Seed marker quantity is reduced to the remaining unattributed qty (may be 0; the marker row is kept).
- Session becomes `applied` and crate holds are released.
- Same idempotency key, or a second call on an already-applied session, is a no-op.
- Failed apply rolls back; session stays `approved`.

UI: Lot reconciliation detail, Admin only. Apply stays disabled until readiness is eligible. Godown Manager and Store Keeper never see the control.

Do **not** enable dual-write until every intended approved session has been applied (or explicitly left unattributed).

## Phase 4 — Aggregate / lot grain validation

```sql
select sb.crate_id, sb.product_id, sb.quantity as aggregate_qty,
       coalesce(sum(slb.quantity), 0) as lot_qty
from public.stock_balances sb
left join public.stock_lot_balances slb on slb.crate_id = sb.crate_id
left join public.stock_lots sl on sl.id = slb.lot_id and sl.product_id = sb.product_id
where sb.quantity > 0
group by 1, 2, 3
having coalesce(sum(slb.quantity), 0) is distinct from sb.quantity;
-- must return zero rows
```

Orphan non-zero lot grains (lot qty with no matching positive aggregate) must also be zero.

## Phase 5 — Flag transition order

Preferred sequential order after seed **and attribution**:

1. Confirm `aggregate_only_blocked = true` (seed already set this).
2. Confirm intended sessions are `applied` and grain conservation still holds.
3. Enable dual-write:

```sql
update public.app_configuration
set value = 'true'::jsonb
where key = 'stock.lots.dual_write_enabled';
```

A single statement that sets **both** flags to `true` is judged on the **final pair** (AFTER STATEMENT). It still fails closed if grains, classification, or Rule A/B/C do not hold. Sequential enable (blocked, then dual-write) remains the documented operator path.

Database enforces (M1-S1.1):

- `aggregate_only_blocked` must be `true` whenever `dual_write_enabled` is `true`.
- Every positive aggregate grain must equal lot balances for that `(crate_id, product_id)`.
- No orphan / mismatched lot grains.
- No negative lot quantities.
- Every positive-stock product has `expiry_controlled` or `non_expiring`.
- Privileged SQL `UPDATE` of these keys still hits the same triggers (bypass requires superuser replica role or `DISABLE TRIGGER`).

If this `UPDATE` fails with SQLSTATE `55000`, **do not** bypass triggers. Fix classification or reconciliation under freeze. The failed statement leaves both flags unchanged.

## Phase 6 — Post-activation checks

With `dual_write_enabled = true` (still frozen or tightly controlled):

- Opening with lot metadata on a **new** grain (or controlled test branch).
- Multi-lot receipt attributions summing to accepted quantity.
- Explicit lot transfer (`lot_moves`).
- Adjustment lot allocations summing to line quantity.

Confirm ledger `lot_id` populated and aggregate delta equals sum of lot deltas per transaction.

```sql
select public.get_stock_lot_cutover_state();
-- dual_write_enabled true, aggregate_only_blocked true
```

## Phase 7 — Unfreeze

Resume normal posting only after smoke checks and owner sign-off.

## Failure handling

| Failure | Action |
|---|---|
| Seed fails mid-transaction | Transaction rolls back; flags unchanged; investigate balances |
| Attribution fails mid-transaction | Function rolls back; session stays `approved`; lots unsplit; retry after fixing blockers |
| Attribution before seed | Rejected; run Phase 3 first |
| Re-seed after attribution | Rejected by existing seed reconciliation check; do not bypass |
| Dual-write enable rejected (`55000`) | Fix grain mismatch or unclassified positive-stock products; do not toggle flags into unsafe combinations |
| Migration apply fails on cloud | Forward-fix migration; do not `db reset` production/development without owner plan |
| Post-cutover inventory drift | Standard adjustment workflow; do not disable dual-write while lot-attributed ledger rows exist |

## Recovery restrictions (M1-S1.1)

- **Do not** set both flags to `false` while lot rows or lot-attributed ledger history exists (database rejects).
- **Do not** set `dual_write_enabled = false` while any `stock_ledger.lot_id` is non-null.
- **Do not** set `aggregate_only_blocked = false` while lot inventory exists.
- **Do not** delete lot or ledger history to “fix” flag state.
- **Do not** use `session_replication_role = replica` or `DISABLE TRIGGER` to force flags.
- Restoring from backup is a separate authorized procedure; partial logical restore is insufficient for full Auth parity.

## M2 prerequisites

- Dual-write enabled only after attribution of intended crates
- Attributed lots carry conservation baselines (`stock_lot_attribution_baselines`) so later lot-id ledger can pick without rewriting historical aggregate ledger
- Remaining `legacy_unattributed` qty is explicit unknown stock; FEFO/FIFO must not treat it as dated available
- `received_on` is still null on legacy lots; FIFO chronology is a later posting concern
- M2 picking is implemented locally (`docs/m2-fefo-fifo-picking.md`). It fails closed until dual-write is on and does not debit the ledger. Development-cloud picking is not authorized in this file.

## Out of scope

- FEFO / order availability cutover
- Cross-godown lot moves
- Automatic cloud deploy
- Development-cloud seed, attribution, or flag activation (M1-S3 schema is on development; operational cutover still needs separate authorization)
