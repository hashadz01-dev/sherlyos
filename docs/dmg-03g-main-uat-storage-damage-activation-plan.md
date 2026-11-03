# DMG-03G — Main UAT Storage Damage Activation Plan

**Final verdict: READY FOR OWNER APPROVAL**

No cloud migrations applied. No cloud flags flipped. No commit/push/deploy. No changes to `DMG-20261103-000013`. No GST legal issuance. No browser service-role. No direct SQL stock balance edits on cloud.

---

## A. Root cause confirmed

### What port 5173 talks to

| Item | Evidence |
|------|----------|
| App | `http://127.0.0.1:5173` (listening; default `npm run dev`) |
| Vite env | `.env.local` / `.env` → `VITE_SUPABASE_URL=https://ypkfondrkhkydkgovwup.supabase.co` |
| Cloud project | `ypkfondrkhkydkgovwup` (MCP `get_project_url`) |
| Contrast | Disposable UAT is **5174** → `http://127.0.0.1:57321` (`.env.dmg03c.local` / `.env.m82c.local`) |

### Why “Review and submit” stays disabled

1. Editor calls RPC `damage_stock_hold_ready_status` (`DamageReportEditorPage` → `getDamageStockHoldReadyStatus`).
2. `stockHoldReady` is true **only** when the RPC returns `stock_hold_ready === true`.
3. For Storage (and other hold scenarios), `collectDamageSubmitBlockers` adds an **isolation** blocker when `!stockHoldReady` (`src/features/damage/utils/submit.ts`).
4. The submit button is `disabled={… \|\| blockers.length > 0}`.
5. Exact user-facing copy:

> Storage submit is blocked because submit isolates on-hand stock. Until isolation is enabled, save a draft only…

Backend truth on cloud:

| Flag | Value |
|------|-------|
| `damage.stock_hold_ready` | **false** |
| `stock.lots.dual_write_enabled` | **true** |
| `stock.lots.aggregate_only_blocked` | **true** |

This is intentional fail-closed behavior: Storage submit creates on-hand holds so damaged cases stop being pickable. Enabling the button without isolation would leave submitted damage still allocatable — unsafe. There is **no** UI-only bypass.

Disposable 5174 works because m82c has `damage.stock_hold_ready=true` after local cutover rehearsal.

---

## B. Current cloud readiness

| Check | Result |
|-------|--------|
| Project | `https://ypkfondrkhkydkgovwup.supabase.co` |
| Migration tip | `20261102125515_damage_evidence_cloud_storage_fetch` |
| Aggregate vs lot mismatch | **0** (agg 35 / lot 35) |
| Dual-write | **true** |
| Hold ready | **false** (blocker) |
| `damage_stock_hold_ready_status` | Present |
| Hold-ready guard trigger | `app_configuration_damage_hold_guard` present |
| Guard body | Blocks hold_ready unless isolation installed; **does not yet require dual-write** (local `…130000` strengthens this) |
| SK storage draft auth | Present (`assert_damage_create_auth` includes `damage.record` + storage) |
| Lot storage catalog builder | **Missing** (`build_damage_storage_catalogs`) |
| Transfer/adjustment unreserved helpers | **Missing** (`unreserved_lot_cases` / `unreserved_grain_cases`) |
| Damage reports | 1 draft, 2 verified |
| Damage holds | **none** |
| Reservations | 1 consumed row (2 cases); no open active reservation pressure observed |
| Owner draft | `DMG-20261103-000013` = draft / storage / version 5 — **do not modify without separate approval** |
| Godown with stock | `gd_1` only (`uat_c1`: AVT-CATER-BLEND-1KG 17, GOODLIFE-MILK-500ML 18) |

---

## C. Missing migrations

### Required before flag activation (cloud)

Apply in version order after owner approval:

| Migration | Purpose | Cloud today |
|-----------|---------|-------------|
| `20261102190000_damage_inbound_receipt_line_lock.sql` | Inbound receipt-line claim serialization | Missing |
| `20261103100000_damage_evidence_drop_followlocation.sql` | Evidence byte fetch without unsupported curl FOLLOWLOCATION | Missing (cloud tip may predate; confirm after apply) |
| `20261103120000_damage_storage_store_keeper_draft.sql` | SK storage draft auth | **Behavior already present** — re-apply only if migration history must catch up; verify no-op |
| `20261103130000_damage_hold_ready_requires_lot_dual_write.sql` | Guard: refuse hold_ready unless dual-write true | **Required** — cloud guard lacks dual-write clause |
| `20261103140000_transfer_adjustment_honor_damage_holds.sql` | Early fail for transfer/adjustment vs holds/reservations | **Required** |
| `20261103160000_damage_storage_lot_catalog.sql` | Lot-aware storage catalogs + draft lot validation | **Required** for lot select on 5173 |

### Disposable-only / do not apply to cloud as-is

| Migration | Reason |
|-----------|--------|
| `20261103170000_damage_evidence_disposable_kong_hosts.sql` | Adds disposable Kong hostnames (`m82c`/`m81c`). Cloud URL is already allowlisted in evidence fetch. **Skip** unless owner explicitly wants the same function body after review. |

### Already on cloud (do not re-invent)

Damage foundation through `20261026181000`, evidence cloud fetch tip `20261102125515`, dual-write + aggregate_only_blocked, isolation RPCs, quarantine/write-off/exceptional paths.

---

## D. Isolation safety results

| Surface | Status on disposable (activated) | Cloud readiness |
|---------|----------------------------------|-----------------|
| Submit creates hold; physical unchanged | Proven C/D/E.1 | Needs hold_ready + lot catalog |
| Pickable decreases by held qty | Proven (picking_available_cases) | Hold subtract already in lot readers; needs activation |
| Duplicate submit idempotent | Proven | Installed |
| Self-verify blocked | Proven | Installed |
| Concurrent pick vs hold | M5.3 race A/H PASS | Installed |
| Quarantine / write-off / exceptional | E.2 PASS | Installed |
| Transfer/adjustment honor holds | Local `…140000` + M5.3 | **Apply `…140000` first** |
| Fail-closed without dual-write | Local guard `…130000` | **Apply `…130000` before flag** |
| Dual-write cannot be turned off once lot ledger exists | Confirmed on m82c (cutover validator) | Same — rollback path is **hold_ready=false**, not dual-write=false |

---

## E. Disposable cutover rehearsal

Environment: `supabase_db_sherlyos_m82c` (sysid `7702447407569928229`), app **5174**, API **57321**.

| Rehearsal item | Result |
|----------------|--------|
| Identity not owner / not m81c | Confirmed |
| Activated flags | `damage.stock_hold_ready=true`, dual-write=true |
| Hold_ready false → true in transaction + ROLLBACK | **PASS** (flags restored true/true) |
| Attempt to set dual-write false | **Blocked** by lot cutover validator (expected; do not use as rollback) |
| DMG-03F full C/D/E.1/E.2 | **5/5 · 6/6 · 4/4 · 5/5 PASS** |
| DMG-03G smoke E.1 | **4/4 PASS** |
| DMG-03G smoke E.2 quarantine | **1/1 PASS** |
| M5.3 concurrency (prior) | **9/9 PASS** |

Scripts:

- `scripts/dmg03f/recover-m82c-stable-fixture.sql` — trusted capacity recovery  
- `scripts/dmg03g/rehearse-hold-ready-guard.sql` — guard rehearsal (dual-write flip blocked by design)

---

## F. Regression results (supporting activation)

| Suite | Result |
|-------|--------|
| DMG-03C/D/E.1/E.2 (DMG-03F) | All PASS on m82c |
| DMG-03G E.1 smoke | 4/4 PASS |
| DMG-03G E.2 quarantine smoke | 1/1 PASS |
| Typecheck / build / Vitest (DMG-03F) | PASS / PASS / 368/368 |

No product bypass was introduced to make 5173 clickable.

---

## G. Exact proposed activation steps

**Owner-approved window only. Do not run until signed off.**

### G0 — Pre-cutover (read-only gate)

1. Confirm cloud project `ypkfondrkhkydkgovwup`.  
2. Re-run aggregate/lot reconciliation → must be `mismatched = 0`.  
3. Confirm `stock.lots.dual_write_enabled=true`.  
4. Confirm no unexpected active `damage_stock_holds`.  
5. Snapshot / Supabase branch backup.  
6. Agree pilot: godown `gd_1`, crate `uat_c1`, **prefer a disposable UAT SKU** — do **not** write off commercial SKUs (`AVT-*`, `GOODLIFE-*`) without explicit owner OK.  
7. Leave `DMG-20261103-000013` as draft unless separately approved for submit after cutover.

### G1 — Deploy lot-aware frontend

1. Ensure 5173 build includes Storage lot select + readiness RPC wiring (already in repo).  
2. Hard refresh clients after deploy so readiness refetch sees post-cutover flag.

### G2 — Apply migrations (order)

1. `20261102190000_damage_inbound_receipt_line_lock.sql`  
2. `20261103100000_damage_evidence_drop_followlocation.sql`  
3. `20261103120000_damage_storage_store_keeper_draft.sql` (verify no-op if already equivalent)  
4. `20261103130000_damage_hold_ready_requires_lot_dual_write.sql`  
5. `20261103140000_transfer_adjustment_honor_damage_holds.sql`  
6. `20261103160000_damage_storage_lot_catalog.sql`  
7. **Skip** `20261103170000_…kong_hosts.sql` for cloud.

### G3 — Pre-flag function checks

- `build_damage_storage_catalogs` exists  
- `unreserved_lot_cases` / `unreserved_grain_cases` exist  
- `guard_damage_hold_configuration` text includes dual-write requirement  
- Recon still `mismatched = 0`

### G4 — Flag activation

```sql
-- ONLY after G2–G3 pass
update public.app_configuration
set value = 'true'::jsonb
where key = 'damage.stock_hold_ready';
```

Expect: succeeds because dual-write is true and isolation is installed.  
If dual-write were false, post-`…130000` guard must raise.

### G5 — Post-activation validation (pilot)

1. SK @ 5173: Storage draft → godown/product/crate/**lot** → finalize photo → **Review and submit enabled**.  
2. Submit → exactly one `active` hold; physical unchanged; pickable − held.  
3. SK cannot verify self.  
4. GM verifies.  
5. Optional: quarantine → ordinary write-off on **pilot disposable qty only**.  
6. Duplicate submit does not double-hold.  
7. Picking/transfer/adjustment cannot consume held cases.

### G6 — Stop conditions (P0)

STOP and do not flip flag if:

- Aggregate/lot mismatch > 0  
- Dual-write not true  
- Required migrations missing  
- Evidence finalize broken on cloud Storage  
- Unexpected active holds / open high-risk reservations unexplained  

---

## H. Rollback procedure

1. **Immediate:** set `damage.stock_hold_ready=false` (submit of hold scenarios fail-closed again; drafts remain).  
2. Do **not** set `stock.lots.dual_write_enabled=false` if lot-attributed ledger rows exist (validator blocks; unsafe).  
3. Do **not** delete or rewrite stock ledger / hold history.  
4. If a migration is defective: restore DB branch/snapshot; keep hold_ready false.  
5. Communicate: 5173 returns to “save draft only” for Storage until re-approved.  
6. Existing holds created during a bad window: settle via trusted quarantine/write-off/exceptional paths — never SQL balance edits.

---

## I. Owner approval requirements

Approve explicitly before:

| Item | Detail |
|------|--------|
| Cloud project | `ypkfondrkhkydkgovwup` |
| Migrations | List in §G2 (skip `…170000`) |
| Flag change | `damage.stock_hold_ready`: false → **true** |
| Pilot godown/SKU | `gd_1` / disposable SKU preferred; commercial SKUs need separate OK |
| Draft `DMG-20261103-000013` | Leave untouched unless separately approved |
| Impact | Storage/loading/shop-return submits will isolate stock; picking availability drops by holds; quarantine/write-off become operational |
| Risk | Medium — reversible via hold_ready=false; irreversible if commercial stock is written off during pilot |
| Rollback | §H |

---

## J. Final verdict

**READY FOR OWNER APPROVAL**

Root cause is confirmed: 5173 uses cloud with `damage.stock_hold_ready=false`, so Storage submit is correctly disabled. Disposable activation path is proven. Cloud inventory reconciliation is clean and dual-write is on. Remaining work is **owner-gated**: apply the required migrations (§C/§G2), then flip hold_ready — not a UI bypass.

Until that approval and cutover complete, port 5173 will continue to show the draft-only Storage message by design.
