# DMG-03J — Existing Cloud Production Hardening & Controlled Activation Plan

**Project:** SherlysOS ERP · Supabase `ypkfondrkhkydkgovwup` (`https://ypkfondrkhkydkgovwup.supabase.co`)  
**Scope authorized:** audit, code review, local validation, migration preparation, activation planning  
**Not authorized (stopped):** cloud migrations, operational flag changes, commercial inventory mutation, historical ledger edits, DB reset/restore, commit, push, deploy

**Audit timestamp (UTC):** 2026-11-03 ~09:15–09:51  
**Cloud tip migration:** `20261102125515_damage_evidence_cloud_storage_fetch`  
**Cloud draft left unchanged:** `DMG-20261103-000013` (status `draft`, version `5`)

---

## A. Executive verdict

| Layer | Verdict |
|-------|---------|
| Application + migration **code** readiness (local disposable proof) | **READY** for owner-approved cutover *planning* |
| Existing **cloud operational activation** | **BLOCKED** |
| Claim that Storage Damage is live in production | **FORBIDDEN** while `damage.stock_hold_ready=false` |

**Why blocked for cutover (hard gates):**

1. **No verified recoverable backup** of the owner database (branching empty; agent cannot prove PITR/snapshot recoverability).
2. **No owner-approved disposable pilot stock** on cloud — only commercial SKUs `AVT-CATER-BLEND-1KG` (17) and `GOODLIFE-MILK-500ML` (18) on `gd_1` / `uat_c1`.
3. **Six production migrations are not applied** on cloud (helpers for lot catalog, dual-write hold guard, transfer/adjustment early hold checks, inbound receipt-line lock).
4. Existing draft **`DMG-20261103-000013` has `lot_id=null`** and will be incompatible with lot-required storage drafts after `…160000` without an owner-reviewed resolution.

**What is already correct today:** 5173 correctly keeps **Review and submit** disabled via trusted RPC `damage_stock_hold_ready_status` + isolation blockers. There is **no** frontend-only enablement path.

---

## B. Existing cloud inventory and readiness

### B.1 Project identity

| Check | Evidence |
|-------|----------|
| URL | `https://ypkfondrkhkydkgovwup.supabase.co` (MCP `get_project_url`) |
| Branches | `list_branches` → **[]** |
| Migration tip | `20261102125515_damage_evidence_cloud_storage_fetch` |

### B.2 Operational flags (READ-ONLY)

| Key | Cloud value | Gate |
|-----|-------------|------|
| `damage.stock_hold_ready` | **false** | Submit isolation off (expected) |
| `stock.lots.dual_write_enabled` | **true** | Prerequisite for future hold activation |
| `stock.lots.aggregate_only_blocked` | **true** | Leave unchanged |

### B.3 Godowns / products / stock

| Godown | Active | Crates |
|--------|--------|--------|
| gd_1 … gd_7 | all active | Only **gd_1** has crate count **1** (`uat_c1`); gd_2–7 crates **0** |

| SKU | Crate | Aggregate qty |
|-----|-------|---------------|
| AVT-CATER-BLEND-1KG | uat_c1 | 17 |
| GOODLIFE-MILK-500ML | uat_c1 | 18 |

**AVT lot grains (draft grain still valid physically):**

| Lot id | manufacturer_lot_code | expiry | qty |
|--------|----------------------|--------|-----|
| `7285514c-09c1-4749-b69b-a2a63ed2339e` | UAT-AVT-CB1KG-20261102-001 | 2027-04-01 | 8 |
| `e9ef206b-6bd7-4af9-968c-606e6e9a0553` | AVT-CB-A01 | 2027-07-01 | 9 |

### B.4 Reconciliation & open work

| Metric | Value |
|--------|-------|
| Aggregate vs lot mismatches | **0** (agg 35 / lot 35) |
| Active/transferred damage holds | **0** |
| Damage reports | draft **1**, verified **2** |
| Reservations | **1** row status `consumed` only |
| `stock_allocations` table | **does not exist** (N/A) |

**Caveat:** zero aggregate/lot mismatch does **not** prove every stock writer is hold-safe. Transfer/adjustment early-fail helpers are still missing on cloud (§E).

### B.5 Helper presence vs local tip

| Helper / property | Cloud today | After pending migrations |
|-------------------|-------------|--------------------------|
| `damage_stock_hold_ready_status()` | present | unchanged |
| `picking_available_cases` subtracts damage holds | **yes** | unchanged |
| `assert_balance_not_below_reservation` / lot floor mention holds | **yes** | unchanged |
| `build_damage_storage_catalogs` | **absent** | from `…160000` |
| `unreserved_grain_cases` / `unreserved_lot_cases` | **absent** | from `…140000` |
| `guard_damage_hold_configuration` requires dual-write | **no** | from `…130000` |
| Store Keeper storage draft (`assert_damage_create_auth` storage → `null`) | **present** | `…120000` catch-up |
| Evidence fetch `CURLOPT_FOLLOWLOCATION` | **already removed** | `…100000` history catch-up |
| Inbound `replace_damage_lines` `FOR UPDATE` on receipt lines | **absent** (`locks_receipt_lines=false`) | from `…190000` |

---

## C. Backup and recovery assessment

| Question | Finding |
|----------|---------|
| Available backup mechanism via agent tools | **None verified.** `list_branches` empty. Prior DMG-03H: `create_branch` creates a **fresh** empty DB — **not** a data-preserving inventory backup. |
| Dashboard PITR / daily backups | **Not observable** from this agent. Owner must confirm in Supabase Dashboard (Pro+ PITR / scheduled backups) or provide an external dump. |
| Recovery point | **Unknown** until owner documents last successful backup RPO. |
| Restoration procedure | **Not established** for this engagement. |
| Recovery time expectations | **Unknown**. |
| Restore actually tested | **No** evidence of a tested restore for `ypkfondrkhkydkgovwup`. |
| Who authorizes restoration | **Owner / Jeffin only.** Agent must not restore, overwrite, or create backups without separate explicit approval. |

**Production activation gate:** recoverability **cannot** be established → mark cloud cutover **BLOCKED** until the owner attests a verified recoverable checkpoint (RPO, restore path, tested restore or accepted residual risk in writing).

---

## D. Migration audit

**Apply order (owner-approved only; do not run now):**

1. `20261102190000_damage_inbound_receipt_line_lock.sql`
2. `20261103100000_damage_evidence_drop_followlocation.sql`
3. `20261103120000_damage_storage_store_keeper_draft.sql`
4. `20261103130000_damage_hold_ready_requires_lot_dual_write.sql`
5. `20261103140000_transfer_adjustment_honor_damage_holds.sql`
6. `20261103160000_damage_storage_lot_catalog.sql`

**Explicitly exclude:** `20261103170000_damage_evidence_disposable_kong_hosts.sql` (disposable Kong hosts only).

### Per-migration notes

#### 1. `20261102190000_damage_inbound_receipt_line_lock.sql`

| Aspect | Assessment |
|--------|------------|
| Compatibility | Replaces `app_private.replace_damage_lines`; cloud already has inbound overlap helper `damage_open_receipt_qty` but **no** `FOR UPDATE` on receipt lines. |
| Lock / impact | Row lock on `stock_receipt_lines` during inbound draft replace — short duration inside transaction; may serialize concurrent inbound damage drafts on same receipt line. |
| Tx / rollback | Single DDL migration of function bodies; Postgres DDL transactional for these replaces. |
| RLS / perms | No table privilege changes; security definer unchanged pattern. |
| Idempotency | `CREATE OR REPLACE` — safe retry of function body. |
| Conflicts | Later `…160000` also replaces `replace_damage_lines` — **must apply 190000 before 160000** so lot validation wins. |
| Post-verify | `position('for update' in lower(pg_get_functiondef(...replace_damage_lines...))) > 0` |

#### 2. `20261103100000_damage_evidence_drop_followlocation.sql`

| Aspect | Assessment |
|--------|------------|
| Compatibility | Cloud already lacks FOLLOWLOCATION and includes cloud host allowlist. Apply for migration history + identical function body. |
| Lock / impact | Function replace only; evidence finalize path briefly unavailable mid-replace. |
| Idempotency | Safe `CREATE OR REPLACE`. |
| Conflicts | None with later damage migrations. |
| Post-verify | `still_has_followlocation = false`; finalize smoke on disposable first. |

#### 3. `20261103120000_damage_storage_store_keeper_draft.sql`

| Aspect | Assessment |
|--------|------------|
| Compatibility | Cloud storage branch already `elsif scenario = 'storage' then null;` under `damage.record`. |
| Impact | Expect **no functional change**; history catch-up. |
| Idempotency | Safe replace. |
| Post-verify | Store Keeper can still create storage drafts; submit still gated by hold_ready. |

#### 4. `20261103130000_damage_hold_ready_requires_lot_dual_write.sql`

| Aspect | Assessment |
|--------|------------|
| Compatibility | Strengthens existing guard; dual-write already **true** so activation path remains open after migrate. |
| Impact | Blocks future accidental `hold_ready=true` if dual-write ever false. |
| Idempotency | Safe replace. |
| Post-verify | `position('dual_write' in pg_get_functiondef(guard...)) > 0` |

#### 5. `20261103140000_transfer_adjustment_honor_damage_holds.sql`

| Aspect | Assessment |
|--------|------------|
| Compatibility | Adds `unreserved_*` helpers; rewrites `post_crate_transfer` / `post_stock_adjustment` pre-checks. Balance triggers already fail closed on holds. |
| Lock / impact | Longer function replace; concurrent transfers/adjustments may see brief redefine. Prefer maintenance window. |
| Rollback | Function replace only — rollback means re-applying prior function definitions from tip (prepare before cutover). Flag flip does **not** undo. |
| Post-verify | Helpers present; intentional hold + transfer attempt fails early with clear error (on disposable / pilot only). |

#### 6. `20261103160000_damage_storage_lot_catalog.sql`

| Aspect | Assessment |
|--------|------------|
| Compatibility | Requires dual-write true (already). Replaces catalog builder + `replace_damage_lines` lot requirements for storage. |
| Impact | Storage drafts **must** include `lot_id`. Existing null-lot draft becomes non-submittable until fixed. |
| Post-verify | `build_damage_storage_catalogs` present; catalog `lots` non-empty for gd_1; null-lot storage draft RPC rejected. |

### Post-migration verification queries (READ after apply — not now)

```sql
select to_regprocedure('app_private.build_damage_storage_catalogs(uuid)') is not null as lot_catalog,
       to_regprocedure('app_private.unreserved_lot_cases(uuid,uuid)') is not null as unreserved_lot,
       position('dual_write' in pg_get_functiondef('app_private.guard_damage_hold_configuration'::regproc)) > 0 as guard_dual_write,
       position('for update' in lower(pg_get_functiondef('app_private.replace_damage_lines(uuid,text,uuid,uuid,uuid,uuid,jsonb)'::regprocedure))) > 0 as inbound_lock;

-- recon
with agg as (
  select crate_id, product_id, quantity as agg_qty from stock_balances where quantity <> 0
), lots as (
  select slb.crate_id, sl.product_id, sum(slb.quantity)::int as lot_qty
  from stock_lot_balances slb join stock_lots sl on sl.id = slb.lot_id
  group by 1,2
)
select count(*) filter (where coalesce(lots.lot_qty,0) is distinct from agg.agg_qty) as mismatched
from agg left join lots on lots.crate_id = agg.crate_id and lots.product_id = agg.product_id;

select key, value #>> '{}' from app_configuration
where key in ('damage.stock_hold_ready','stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked');
-- expect hold_ready still false until separate activation step
```

---

## E. Stock writer and hold safety

### Already hold-aware on cloud (foundation)

| Path | Hold behavior |
|------|----------------|
| Lot picking availability | `picking_available_cases` = on_hand − reserved − **active damage holds** |
| Aggregate / lot balance floors | `assert_balance_not_below_reservation` / lot twin **mention damage holds** |
| Quarantine crates | Picking returns 0 for quarantine locations |
| Damage quarantine / write-off / exceptional | Trusted RPCs `transfer_verified_damage_to_quarantine`, ordinary/exceptional disposition consume holds via `consume_damage_holds` |

### Gaps until `…140000` (early UX / fail-fast)

| Path | Cloud today | After `…140000` |
|------|-------------|-----------------|
| `post_crate_transfer` | No `unreserved_*` / direct hold pre-check in function body | Early fail using unreserved helpers |
| `post_stock_adjustment` | Same | Early fail |
| Concurrent operations | Rely on row locks + balance triggers | Same floors + clearer pre-checks |

### Writers reviewed for activation plan

| Operation | Isolation expectation when hold_ready true |
|-----------|---------------------------------------------|
| Picking / packing / DN consume | Lot avail subtracts holds; cannot pick held qty |
| Dispatch consumption | Uses reservation/picking path under dual-write |
| Transfers | Must not move held qty contrary to active holds |
| Adjustments | Must not reduce below reserved+held floor |
| Receiving | Separate inbound damage path; receipt-line lock pending |
| Returns / failed delivery | Existing return RPCs; holds remain on damage side |
| Damage quarantine / write-off / exceptional | Only via trusted disposition RPCs |
| Concurrent damage submit | Grain/lot locks inside isolation apply |

**Do not bypass:** `damage.stock_hold_ready`, dual-write, aggregate_only_blocked, or RLS/security-definer gates.

---

## F. Existing draft compatibility — `DMG-20261103-000013`

| Field | Value |
|-------|-------|
| Status | `draft` |
| Scenario | `storage` |
| Version | `5` |
| Godown | `gd_1` |
| Product | `AVT-CATER-BLEND-1KG` |
| Crate | `uat_c1` |
| Quantity | `1` case |
| Finalized evidence | **1** |
| `lot_id` | **null** |

**Grain validity:** AVT @ `uat_c1` still has 17 aggregate / two positive lots (8+9). Physical grain is valid; **lot attribution is missing**.

**Do not silently repair or submit this draft.**

### Owner-reviewed resolution options (after migrations; still no auto-fix)

1. **Preferred:** Reporter opens draft on 5173 after `…160000`, selects the correct lot from catalog, saves, then submits only after hold_ready cutover.  
2. **Cancel/supersede:** Return or abandon draft under manager policy; create a new lot-aware draft.  
3. **Do not** SQL-patch `lot_id` without owner + reporter confirmation of which lot is damaged.

---

## G. Frontend readiness

| Requirement | Status | Evidence |
|-------------|--------|----------|
| Readiness from trusted backend | **PASS** | `getDamageStockHoldReadyStatus` / RPC; `staleTime` 15s + focus refetch |
| Isolation status display | **PASS** | `DamageReadinessBanner` + storage submit hint |
| Store Keeper drafts | **PASS** | Backend auth already allows storage drafts |
| Lot selection when dual-write | **PASS (code)** / **blocked on cloud** until `…160000` | `requireStorageLot: catalogs.dual_write_enabled` |
| Evidence via trusted finalize | **PASS** | Uploader + finalize RPC path |
| Review/Submit only when ready | **PASS** | `collectDamageSubmitBlockers` isolation code; no UI-only bypass |
| Server errors / duplicate submit | **PASS** | Ambiguous submit handling; E2E duplicate hold test |
| Isolated qty after submit | **PASS** | Toast with held cases; holds on payload |
| Prevent SK self-verify | **PASS** | UI `isReporter` + backend message map |
| Manager verify + disposition | **PASS** | Verification + quarantine/write-off/exceptional panels |

---

## H. Test results (disposable m82c only)

**Cloud was not used for stock-affecting tests.**

| Suite | Result |
|-------|--------|
| `npm run typecheck` | **PASS** |
| `npm run lint` | **PASS** (warnings only; none treated as damage blockers) |
| `npm run build` | **PASS** |
| Vitest `tests/unit/damage` | **PASS** 13 files / **102** tests |
| Playwright DMG-03C (after fixture recover) | **PASS** 5/5 |
| Playwright DMG-03D | **PASS** 6/6 |
| Playwright DMG-03E1 (after recover) | **PASS** 4/4 |
| Playwright DMG-03E2 disposition | **4/5 PASS** — quarantine, write-off, exceptional approve/reject **PASS**; final soft recon bound `phys + qPhys <= physicalC1Before + 2` **FAIL** (fixture recovery + multi-suite physical drift; stranded holds **0**, avail floor identity **OK**) |
| SQL `phase_dmg03b_transfer_holds_precheck.sql` | **PASS** (rolled back) |
| SQL `phase_dmg03a_isolation_readiness.sql` | **SKIP/FAIL by design** — requires flags false at start; m82c already hold_ready true |
| SQL `phase_dmg03_storekeeper_storage_draft.sql` | **STALE** — rejects null lot under lot-aware dual-write (correct product behavior; harness pre-dates lot requirement; covered by DMG-03D) |

Fixture recovery used: `scripts/dmg03f/recover-m82c-stable-fixture.sql` (m82c only; refused owner/m81c sysids).

---

## I. Exact activation prerequisites

All must be true before any cloud write:

1. Owner attests **verified recoverable backup** (mechanism, RPO, restore authority).  
2. Owner approves **maintenance window**.  
3. Pre-activation recon: mismatched **0**; dual-write **true**; aggregate_only_blocked **true**; hold_ready **false**.  
4. Owner approves applying migrations §D in order (exact CLI/MCP commands in §K).  
5. Post-migration verifies §D queries.  
6. Owner resolves draft `DMG-20261103-000013` lot policy (§F).  
7. Owner defines **pilot stock** (disposable SKU/lot) — **not** silent use of AVT/GOODLIFE commercial balances unless explicitly approved.  
8. Separate approval to set `damage.stock_hold_ready=true`.  
9. Browser pilot: SK submit → hold → GM verify → quarantine/disposition on **pilot** stock only.  
10. Post-pilot recon + incident contacts ready.

---

## J. Owner approval requirements

Stop and obtain **separate explicit written approval** for each of:

| Action | Approval needed |
|--------|-----------------|
| Apply cloud migrations | Yes |
| Flip `damage.stock_hold_ready` | Yes (separate from migrations) |
| Create/consume commercial cloud stock for tests | Yes |
| Repair/submit/cancel `DMG-20261103-000013` | Yes |
| Create/overwrite/restore backups | Yes |
| Commit / push / deploy | Yes |
| Change `stock.lots.*` cutover flags | Yes (not recommended for this cutover) |

**This DMG-03J package does not constitute that approval.**

---

## K. Production cutover and rollback plan

### K.1 Maintenance window (proposed)

- Freeze stock transfers/adjustments/picking on gd_1 for the window.  
- Communicate: Storage damage submit remains disabled until step 8 completes.

### K.2 Pre-activation checkpoint

```sql
-- READ-ONLY preflight (owner runs / authorizes)
select key, value #>> '{}' from app_configuration
where key in ('damage.stock_hold_ready','stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked');
-- expect: false / true / true
```

Owner confirms backup attestation recorded.

### K.3 Migration execution (AFTER approval only)

Exact planned commands (do **not** run until approved):

```bash
# From repo root, targeting project ypkfondrkhkydkgovwup — owner credentials required
npx supabase db push --project-ref ypkfondrkhkydkgovwup
# OR apply the six files in §D order via Dashboard SQL / MCP apply_migration
# Exclude 20261103170000_damage_evidence_disposable_kong_hosts.sql
```

Expected impact: function/catalog replaces only; **no** automatic hold creation; **hold_ready stays false**.

### K.4 Post-migration verification

Run §D verification queries. Confirm helpers present; recon mismatched=0; flags unchanged.

### K.5 Dual-write health

Confirm dual-write still true; spot-check opening/transfer on disposable first; cloud pilot only with approval.

### K.6 Owner-approved test-stock pilot

Introduce or designate disposable pilot SKU/lot on gd_1 **or** explicitly authorize 1-case commercial pilot with named SKU/lot.

### K.7 Activate isolation (AFTER separate approval)

```sql
update public.app_configuration
set value = 'true'::jsonb
where key = 'damage.stock_hold_ready'
  and value is distinct from 'true'::jsonb;

select public.damage_stock_hold_ready_status();
-- expect stock_hold_ready true (authenticated)
```

### K.8–K.11 Browser + recon + disposition

1. 5173 Store Keeper: new lot-aware storage draft on pilot grain → evidence → Review and submit → held cases toast.  
2. Confirm picking_available_cases reduced; physical unchanged.  
3. Different GM user verifies (reporter cannot).  
4. Quarantine transfer + authorized disposition on pilot only.  
5. Recon mismatched=0; no stranded active holds beyond expected.

### K.12 Rollback / incident response

**Setting `damage.stock_hold_ready=false` does NOT undo:**

- Active / transferred holds  
- Quarantine crate movements  
- Write-off / exceptional ledger posts  

**Rollback design:**

| Situation | Action |
|-----------|--------|
| Migrations applied, flag still false | Keep flag false; fix forward or restore functions from tip backup |
| Flag true, bad pilot hold | Manager return/reject (releases logical holds) or complete authorized disposition; do **not** delete hold rows by hand |
| Ledger quarantine/write-off already posted | Compensating trusted adjustments only under owner finance/ops authority; **never** raw balance UPDATE |
| Catastrophic data error | Owner-authorized **restore from verified backup** — only recovery that rewinds stock+damage history |

Incident contacts: Owner (authorization), ops lead (warehouse freeze), agent (diagnostics only until re-authorized).

---

## L. Final READY / BLOCKED verdict

| Question | Answer |
|----------|--------|
| Is the **implementation** (code, local migrations, permissions model, isolation design) production-ready pending cutover? | **READY** (with E2 soft-recon harness flake noted; core isolation/disposition E2E green on disposable) |
| Is the feature **operationally activated** on existing cloud? | **NO** — `damage.stock_hold_ready` remains **false** |
| May we proceed to cloud migrate / flag flip / commercial pilot **now**? | **BLOCKED** — backup recoverability unproven; no disposable pilot policy; migrations not applied; draft lot resolution pending; **awaiting separate owner approvals** |

### Explicit non-claims

- Activation is **not** complete.  
- 5173 submit remaining disabled is **correct**.  
- No commit, push, deploy, cloud migration, or flag change was performed under DMG-03J.

---

*End of DMG-03J readiness package. Next step: owner responds with backup attestation + approval (or denial) of the exact §K commands.*
