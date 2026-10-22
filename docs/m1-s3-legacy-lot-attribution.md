# M1-S3 — Legacy lot attribution (Approach B)

Local implementation contract. Does **not** deploy, seed, attribute, or flip flags on development cloud `ypkfondrkhkydkgovwup`.

Source of truth is the shipped M1-S1/M1-S2 schema plus this additive migration `20261022220000_legacy_lot_attribution.sql`. Seed RPC behaviour is unchanged.

## Architecture findings used

- Aggregate grain remains `stock_balances(crate_id, product_id)`. Historical `stock_ledger` rows stay NULL-lot and are never rewritten.
- `seed_legacy_stock_lots()` is the only writer that creates the first `legacy_unattributed` blob and seed marker and that sets `stock.lots.aggregate_only_blocked`.
- Trusted lot-balance writes require `app_private.begin_lot_balance_write`. Clients have SELECT only on `stock_lots` / `stock_lot_balances`.
- Cutover lock class is `(88104301, 1)`: exclusive for seed/flags/attribution; shared for posting and M1-S2 submit/approve/refresh.
- M1-S2 approval is evidence only. Status set is extended additively with `applied`.
- Permission `stock.lots.legacy.reconcile` is Admin-only (D9). Attribution does not use `stock.lots.seed`.

## Locked decisions (no new owner guesses)

| Topic | Decision | Origin |
|---|---|---|
| Approach | Keep seed; attribute in a separate RPC | Approach B / D13 |
| Authorization | Authenticated Admin `stock.lots.legacy.reconcile` + `can_work_at_branch` | D9, existing admin helper |
| Eligible session | `approved`, matched, classified, no found-product lines, not already applied | M1-S2 approve rules + invariant 12 |
| Multiple sessions | Crate hold until `cancelled` or `applied`; apply is per session | D14 |
| Product classification | Re-check `expiry_controlled` / `non_expiring` at apply | M1-S1 / M1-S2 |
| Known lots | Operator-entered manufacturer code; never fabricated | D8 |
| Unknown identity | Stays on the original `legacy_unattributed` lot | D8 |
| Expiry-controlled + expiry_unknown | Stays `legacy_unattributed` (not `available`) | Contract §4 |
| Non-expiring identified | `available` / `quarantined`, `expiry_date` null | Contract §4 |
| Condition map | available→`available`; quarantined→`quarantined`; expired→`expired_blocked` | Contract §4 |
| Partial grain | Known qty splits off; unknown remainder stays on the seed lot | Contract §4 |
| Stale evidence | Live aggregate must still equal approved expected and counted | M1-S2 baseline |
| Session version | `PT409` unless the session is already `applied` | Existing recon pattern |
| Concurrency | Exclusive lock first, then session, crates, balances, lots | Seed lock order |
| Duplicate apply | `applied` status + attribution PK; same idempotency key replays | Contract §8 |
| Failure | Function subtransaction rolls back; session stays `approved` | Contract §8 |
| Aggregate/ledger | No `stock_balances` / `stock_ledger` writes | Invariants 7–8 |
| Flags | Apply does not flip flags. Requires `aggregate_only_blocked=true` and `dual_write_enabled=false` | Cutover window |
| Seed after split | Existing seed RPC fail-closes if marker qty no longer equals aggregate. Do not re-seed after attribution | Keep seed unchanged |

## Eligibility

`get_lot_attribution_readiness` / `apply_legacy_lot_attribution` require all of:

1. Authenticated Admin with `stock.lots.legacy.reconcile` and branch access.
2. Session status `approved` (or `applied` for idempotent replay).
3. `stock.lots.aggregate_only_blocked = true` (seed completed).
4. `stock.lots.dual_write_enabled = false` (still in the post-seed cutover window).
5. No found-product lines.
6. Every expected line matched, classified, with lot quantities equal to counted.
7. Seed marker present; exactly one live `legacy_unattributed` lot on the grain; marker qty = lot qty = live aggregate = approved counted/expected.
8. No unexpected extra lot balances on the grain before the split.

## Apply behaviour

For each expected grain, under exclusive lock:

- Known identified lots become new (or reused) `stock_lots` with origin `legacy_reconciliation`.
- Same `(product, branch, manufacturer_lot_code, expiry_date, status)` is reused so manufacturer identities are not duplicated.
- Unknown remainder stays on the original unattributed lot.
- Seed marker quantity is reduced to the remaining unattributed qty (may be `0`; the marker row is kept).
- Attribution rows and lot-balance baselines are written for conservation.
- Session becomes `applied`; crate `holds_scope` is released.
- Idempotent retry returns the existing payload.

## Conservation after split

- Aggregate: unchanged `stock_balances` / `stock_ledger`.
- Grain: sum of lot balances for `(crate, product)` still equals aggregate.
- Marker lots: balances = updated seed baseline + lot-id ledger (ledger stays 0 here).
- Newly attributed lots: balances = `stock_lot_attribution_baselines` + lot-id ledger (prepares M2 dual-write picks).

## Out of scope

- Development-cloud seed, attribution, or flag activation
- FEFO/FIFO picking (M2)
- Changing `seed_legacy_stock_lots`
- Rewriting deployed migrations
