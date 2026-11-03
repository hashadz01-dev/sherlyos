# DMG-03 Store Keeper permission and safety UAT

## 1. Original UAT issue

On `/damage/new`, Test Storekeeper saw DMG-03 Storage disabled with
“Not permitted for this account.” Shop Return was also disabled (unchanged by
design). Stock isolation readiness banner correctly reported isolation not ready.

## 2. Root cause

| Layer | Restriction | Evidence |
|-------|-------------|----------|
| Frontend | `scenariosAvailableForPermissions` required `damage.record` **and** `damage.verify` for `storage` | `src/lib/damage/rules.ts` |
| Backend | `app_private.assert_damage_create_auth` required `damage.verify` for `storage` and `shop_return` | `app_private.assert_damage_create_auth` |
| Role grants | Store Keeper has `damage.record`, `receiving.execute`, `loading.assist` — **not** `damage.verify` | role permissions |
| Submit gate | Storage requires stock hold; with `damage.stock_hold_ready=false`, submit fail-closes | `submit_damage_report` → `apply_damage_stock_isolation` |

Disabled UI was therefore both frontend and backend policy, not a display-only bug.

## 3. Permission matrix

### Before

| Scenario | Store Keeper | Godown Manager |
|----------|--------------|----------------|
| DMG-01 / DMG-02 | Yes | Yes |
| DMG-03 Storage | No | Yes |
| DMG-04 Loading | Yes | Yes |
| DMG-05 Transit | Yes | Yes |
| DMG-06 Shop return | No | Yes |

### After

| Scenario | Store Keeper | Godown Manager |
|----------|--------------|----------------|
| DMG-01 / DMG-02 | Yes | Yes |
| DMG-03 Storage **draft** | Yes (authorized godown) | Yes |
| DMG-03 Storage **submit** | Blocked while isolation off | Blocked while isolation off |
| DMG-04 Loading | Yes (submit still isolation-gated) | Yes |
| DMG-05 Transit | Yes | Yes |
| DMG-06 Shop return | No | Yes |

Store Keeper still cannot verify own reports (`damage.verify` required; self-verify blocked).

Godown scope uses `app_private.can_work_at_branch`. Store Keepers with
`store_keeper.godowns.all` may draft at any **active** godown; crates must still
belong to the selected godown.

## 4. Files changed

- `src/lib/damage/rules.ts` — enable Storage when `damage.record`
- `src/features/damage/utils/submit.ts` — storage draft/submit copy
- `supabase/migrations/20261103120000_damage_storage_store_keeper_draft.sql` — auth for storage drafts
- `supabase/tests/phase_m5_2_damage_foundation.sql` — SK storage draft + gated submit
- `supabase/tests/phase_m5_4b_damage_reporting.sql` — SK may list storage sources
- `supabase/tests/phase_dmg03_storekeeper_storage_draft.sql` — dedicated SK storage draft SQL
- `tests/unit/damage-editor.test.ts` — scenario + isolation submit gates
- `docs/dmg-03-storekeeper-permission-and-safety-uat.md` — this document

## 5. Database migrations

Additive local migration only:

`20261103120000_damage_storage_store_keeper_draft.sql`

Applied locally and hotfixed on cloud via `CREATE OR REPLACE` (not
`apply_migration`). Re-apply from repo if cloud is reset:

```powershell
Get-Content supabase/migrations/20261103120000_damage_storage_store_keeper_draft.sql |
  docker exec -i supabase_db_sherlyos psql -U postgres -d postgres -v ON_ERROR_STOP=1
```

## 6. Why draft creation is safe

- `create_damage_report` / `update_damage_report` write document rows only.
- Storage lines validate crate-in-godown; they do not deduct balances on draft.
- No `damage_holds` rows are created on draft.
- Godown scope uses `can_work_at_branch` (assigned / company-wide SK access).
- `damage.record` is still required; shop-return still needs `damage.verify`.

## 7. Behavior while stock isolation is disabled

- Draft save: allowed for authorized Store Keeper / GM.
- Photo evidence attach: allowed on draft (existing private evidence flow).
- Submit / Review and submit: blocked in UI (`collectSubmitBlockers` isolation) and RPC (`stock isolation is not ready`).
- No stock hold, ledger posting, quarantine, or balance change from draft.

Suggested UI copy (implemented for storage):

> Storage damage reports can be saved as drafts. Submission and stock isolation are unavailable until the warehouse damage safety controls are enabled.

## 8. Test results (executed)

| Suite | Result |
|-------|--------|
| `tests/unit/damage-editor.test.ts` (+ related damage unit files) | **57 passed** / 4 files |
| `oxlint` on changed damage files | **pass** |
| `phase_dmg03_storekeeper_storage_draft.sql` on local `supabase_db_sherlyos` | **pass** (rolled back) |
| `tsc` filtered | **pre-existing** `ReceivingPage.tsx` status setter only; no damage regressions |
| Cloud migration apply | **not run** (owner gate) |
| Full `phase_m5_2` / Playwright | not re-run this pass; dedicated DMG-03 SQL covers SK draft + gates |

## 9. Manual UAT instructions

1. Ensure local migration `20261103120000_...` is applied (not cloud).
2. Sign in as Test Storekeeper on local `5173` (or matching local API).
3. Operations → Damage → New damage report.
4. Select **DMG-03 Storage** (should be enabled).
5. Choose assigned Godown-1.
6. Choose zone/crate/product with on-hand stock.
7. Enter 1 case, reason, optional notes.
8. Save draft → confirm Damage ID and status **Draft**.
9. Confirm Review and submit remains blocked while isolation banner shows not ready.
10. Confirm inventory / stock ledger unchanged.
11. Confirm Shop Return remains disabled for Store Keeper.
12. Confirm Store Keeper cannot verify the draft.

## 10. Remaining operational blockers

- Full DMG-03 operational processing (submit → isolate → verify → quarantine/write-off) remains blocked until owner-approved `damage.stock_hold_ready` cutover with isolation installed.
- Cloud `assert_damage_create_auth` was hotfixed via SQL replace (same body as
  the local migration) so UAT on `5173` can list storage sources; formal
  migration history may still need owner apply later.

## 11. Operational flags

Confirmed target policy (must remain false unless a separate owner cutover):

- `damage.stock_hold_ready=false`
- `stock.lots.dual_write_enabled=false` (local disposable tests; cloud UAT may differ for lots — this change does not flip flags)
- `stock.lots.aggregate_only_blocked=false`
- `SHORT_SHIPMENT_OPERATIONAL=false`
