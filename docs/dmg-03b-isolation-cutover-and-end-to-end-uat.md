# DMG-03B — Isolation cutover preparation and end-to-end UAT

## 1. Root cause (Review and submit disabled)

Storage submit is gated by backend `damage.stock_hold_ready`. While false,
`apply_damage_stock_isolation` raises and the editor’s
`collectSubmitBlockers` disables Review and submit. This is intentional.

Frontend readiness comes from RPC `damage_stock_hold_ready_status` (not a
hardcoded enable). Short `staleTime` + `refetchOnWindowFocus` were added so a
future cutover appears without a hard reload.

## 2. Current database connection

| Client | Target |
|--------|--------|
| Vite `http://127.0.0.1:5173` | **Cloud** `https://ypkfondrkhkydkgovwup.supabase.co` (`.env` `VITE_SUPABASE_URL`) |
| Local Docker `supabase_db_sherlyos` | Disposable SQL/concurrency fixtures only |

**localhost:5173 does not mean a local database.** Enabling flags only on Docker
does not enable the UAT button on 5173.

## 3. Lot dual-write readiness

### Cloud (UAT backend)

| Check | Result |
|-------|--------|
| `stock.lots.dual_write_enabled` | **true** (already from prior UAT) |
| `stock.lots.aggregate_only_blocked` | **true** |
| `damage.stock_hold_ready` | **false** |
| Negative balances | 0 |
| Aggregate vs lot mismatch | **0** (35 cases both sides) |
| `legacy_unattributed` lots | 0 |
| Active damage holds | 0 |

Cloud dual-write data looks reconciled for current nonzero stock. Historical
delivery-return lot gaps were not fabricated; this milestone did not rewrite
returns.

### Local Docker (disposable)

Flags remain **false** after all suites. Cutover rehearsals flip flags inside
rolled-back SQL or concurrency `finally` restore only.

### Guard

Local migration `20261103130000_damage_hold_ready_requires_lot_dual_write.sql`
refuses `damage.stock_hold_ready=true` unless dual-write is already true.
**Not applied to cloud** in this milestone (owner gate).

## 4. Inventory reconciliation

Cloud: mismatched_grains=0, total_agg_cases=35 = total_lot_cases.

Local disposable fixture (DMG-03A readiness): physical 17, hold 1, avail 16,
ledger unchanged — proven under temporary dual-write + hold-ready inside
ROLLBACK.

## 5. P0 / P1 / P2 findings

| ID | Severity | Status |
|----|----------|--------|
| Enable hold-ready without dual-write | P0 cutover | Mitigated locally by guard; cloud already dual-write true |
| Transfer/adjustment pre-check ignored holds | P1 | **Fixed** in `20261103140000_…` (local apply) |
| Gross on-hand display vs ATP | P2 | Unchanged; picking formula authoritative |
| 5173 button vs Docker-only cutover | P0 ops confusion | Documented; do not confuse environments |

## 6. Changes implemented

| Path | Change |
|------|--------|
| `supabase/migrations/20261103140000_transfer_adjustment_honor_damage_holds.sql` | `unreserved_*` helpers; transfer/adjustment pre-checks |
| `supabase/tests/phase_dmg03b_transfer_holds_precheck.sql` | Transfer of held qty fails; unreserved transfer OK |
| `src/features/damage/DamageReportEditorPage.tsx` | Readiness refetch; submit toast shows isolated cases |
| `docs/dmg-03b-isolation-cutover-and-end-to-end-uat.md` | This document |

Prior: `20261103130000` dual-write guard; DMG-03A readiness SQL; SK draft auth.

**Not done:** enable flags on cloud or persistent local; submit
`DMG-20261103-000013`; cloud migrations; browser e2e against a cut-over cloud.

## 7. Migration list (this stream)

1. `20261103120000_damage_storage_store_keeper_draft.sql` — SK storage drafts  
2. `20261103130000_damage_hold_ready_requires_lot_dual_write.sql` — cutover guard  
3. `20261103140000_transfer_adjustment_honor_damage_holds.sql` — hold-aware pre-checks  

Local Docker: 1300 + 1400 applied for validation. Cloud: create-auth hotfix only
from earlier work; **1300/1400 not applied to cloud**.

## 8. Test results

| Suite | Result |
|-------|--------|
| `phase_dmg03b_transfer_holds_precheck.sql` | **PASS** (rollback) |
| `phase_dmg03a_isolation_readiness.sql` | **PASS** |
| `phase_dmg03_storekeeper_storage_draft.sql` | **PASS** |
| `phase_m5_3_damage_stock_isolation.sql` | **PASS** |
| `phase_m5_3_concurrency.mjs` | **PASS 9/9**; flags restored false |
| Vitest damage editor/pages/rules/verification | **57 passed** |
| oxlint editor page | Warning `set-state-in-effect` (pre-existing hydrate effect) |
| Playwright browser cutover UAT | **NOT RUN** (would require Vite→local or owner cloud cutover) |
| Full tsc / production build | **NOT RUN** (known pre-existing `ReceivingPage.tsx` TS issue) |
| Lot foundation / FEFO full suites | **NOT RUN** this pass; M5.3 concurrency covers pick vs hold |

Local flags after all runs:

```text
damage.stock_hold_ready=false
stock.lots.dual_write_enabled=false
stock.lots.aggregate_only_blocked=false
```

## 9. Disposable cutover rehearsal

**Environment:** local Docker `supabase_db_sherlyos` only.  
**Method:** transaction-scoped flag flip + ROLLBACK (`phase_dmg03a`,
`phase_dmg03b`) and concurrency suite with `finally` restore.

**Not** an activation of owner persistent data or cloud.

Rehearsal proved:

- Isolation creates hold; physical unchanged; avail decreases  
- Transfer cannot move held cases (`insufficient unreserved`)  
- Unreserved remainder can transfer  
- Operational path still blocked when hold-ready restored false  

## 10. Button readiness behavior

- Enabled only when `getDamageStockHoldReadyStatus().stock_hold_ready === true`
- Blockers still list isolation reason while false  
- No frontend-only bypass  
- Double submit guarded by busy flag + backend idempotency  
- After successful submit (when ready): toast reports isolated case count;
  detail page Stock isolation section shows holds  

On **current 5173 → cloud**, button remains **disabled** because cloud
`damage.stock_hold_ready=false`.

## 11. End-to-end UAT (browser)

**Not executed** against a cut-over backend in this milestone (safety gate).

Existing UAT draft `DMG-20261103-000013` was **not modified**.

## 12. Rollback / recovery

- Local migration 1400: reinstall prior `post_crate_transfer` /
  `post_stock_adjustment` from `20261022240000_…`; drop `unreserved_*` helpers.  
- If hold-ready flipped by mistake: set to `false` immediately. Do not delete
  active holds without authorized release/disposition.  
- Concurrency interrupt: set three config keys to `false` under
  `session_replication_role = replica`.

## 13. Remaining blockers

1. **Owner approval** required before setting `damage.stock_hold_ready=true` on
   any persistent DB (local durable or cloud).  
2. Apply local migrations `20261103130000` + `20261103140000` to cloud only with
   owner approval (or equivalent hotfixes).  
3. Browser E2E after cutover still outstanding.  
4. Optional: lot-level unreserved check on dual-write adjustment allocations
   (grain check + triggers already protect).

## 14. Owner approvals required

### Option A — Local disposable cutover for Playwright (recommended next)

1. Approve pointing a **separate** Vite env (not the owner’s daily `.env`) at
   local Supabase API `http://127.0.0.1:54321`.  
2. Confirm Docker DB is acceptable as disposable UAT.  
3. Approve temporary enable of dual-write + aggregate-only + hold-ready on Docker
   with documented restore.  
4. Run new DMG-03 draft → submit → verify (not `DMG-20261103-000013`).  
5. Restore all three flags to false.

### Option B — Cloud UAT cutover (higher risk)

1. Confirm dual-write remains true and reconcilation re-checked.  
2. Approve apply of guard + transfer pre-check migrations/hotfixes.  
3. Approve **only** `damage.stock_hold_ready=true` on cloud.  
4. New disposable SKU/godown pilot — **do not** submit historical drafts without
   review.  
5. Rollback plan signed.

**This document does not approve either option.**

## 15. Exact next steps for the owner

1. Decide Option A (local API) vs Option B (cloud).  
2. Do **not** expect 5173 (cloud) submit to enable until Option B is approved.  
3. Keep `DMG-20261103-000013` as draft until a cutover environment is ready.  
4. After approval, re-run `phase_dmg03a` + `phase_dmg03b` + M5.3 concurrency on
   the chosen DB, then one new storage report E2E.
