# DMG-03M — Existing cloud Damage Management activation

**Project:** `ypkfondrkhkydkgovwup` (`https://ypkfondrkhkydkgovwup.supabase.co`)  
**Frontend:** `http://127.0.0.1:5173`  
**Verdict: PASS**

No commit, push, or deploy. Commercial SKUs and `DMG-20261103-000013` were not modified. Kong disposable migration `…170000` was not applied.

---

## A. Cloud migrations applied

Controlled apply (not unrestricted `db push`):

| Order | Source file | Cloud history name / version |
|-------|-------------|------------------------------|
| 1 | `20261102190000_damage_inbound_receipt_line_lock.sql` | `damage_inbound_receipt_line_lock` `20261103100451` |
| 2 | `20261103100000_damage_evidence_drop_followlocation.sql` | `damage_evidence_drop_followlocation` `20261103100513` |
| 3 | `20261103120000_damage_storage_store_keeper_draft.sql` | `damage_storage_store_keeper_draft` `20261103100523` |
| 4 | `20261103130000_damage_hold_ready_requires_lot_dual_write.sql` | `damage_hold_ready_requires_lot_dual_write` `20261103100529` |
| 5 | `20261103140000_transfer_adjustment_honor_damage_holds.sql` | body via `db query --remote`; history `transfer_adjustment_honor_damage_holds` `20261103100718` |
| 6 | `20261103160000_damage_storage_lot_catalog.sql` | body via `db query --remote`; history `damage_storage_lot_catalog` `20261103100706` |

Post-apply helpers confirmed: lot catalog, `unreserved_lot_cases`, dual-write guard, inbound `FOR UPDATE`, isolation installed.

---

## B. Operational flags before and after

| Key | Before | After |
|-----|--------|-------|
| `damage.stock_hold_ready` | false | **true** |
| `stock.lots.dual_write_enabled` | true | true (unchanged) |
| `stock.lots.aggregate_only_blocked` | true | true (unchanged) |

SHORT_SHIPMENT / GST flags were not touched.

---

## C. Test inventory created

| Item | Value |
|------|-------|
| Product | `TEST-DMG03M-ONLY` (`8d442f1e-8790-4f30-b87e-2d63248e1ec3`), non_expiring |
| Lot | `TEST-LOT-DMG03M` |
| Opening | `OS-20261103-000052` — **3** cases via trusted `post_opening_stock` |
| Location | Godown-1 / `uat_c1` |
| Commercial | AVT 17 / GOODLIFE 18 **unchanged** |

Test Auth passwords for `teststorekeeper@gmail.com` and `testgodownmanager@gmail.com` were set to a known development password for browser/RPC UAT (`dmg03m-dev-only`). Owner should rotate if desired.

---

## D. Review and Submit button status

On `5173` after activation:

- Readiness banner: isolation **enabled** (trusted RPC `damage_stock_hold_ready_status`).
- Playwright: **Review and submit** enabled after draft + finalized evidence on TEST grain.
- No frontend-only bypass; isolation check remains in `collectDamageSubmitBlockers`.

---

## E. Store Keeper submission result

| Check | Result |
|-------|--------|
| Browser save draft + reload + evidence finalize | **PASS** |
| Review and Submit → Submit report | **PASS** |
| Report | **`DMG-20261103-000014`** (not 000013) |
| Status after submit | `submitted` |
| Active hold | **1** case on `TEST-LOT-DMG03M` |
| Physical at submit | **3** unchanged |
| Available at submit | **2** (3 − 1 hold) |

---

## F. Godown Manager verification result

| Check | Result |
|-------|--------|
| Store Keeper `verify_damage_report` | **rejected** (`not authorized`) |
| Godown Manager verify | **PASS** → status `verified` |
| Browser GM verify UI | **PASS** after session-clear fix (Sign out is a dropdown item). Also proven via RPC (`not authorized` for SK; GM verify succeeded). |

---

## G. Stock hold and available quantity reconciliation

| Moment | Physical `uat_c1` | Available | Hold |
|--------|-------------------|-----------|------|
| After submit | 3 | 2 | 1 active |
| After quarantine | 2 storage + 1 `QRN-01` | — | hold `transferred` |
| After ordinary write-off | 2 on `uat_c1` | — | hold `written_off` |
| Aggregate/lot mismatched | **0** | | |

Ledger: `DMG-QRN-20261103-000053` (quarantine transfer), `DMG-ordinary_writeoff-20261103-000054` (adjustment).

---

## H. Quarantine / disposition result

Events on `DMG-20261103-000014`:

`created` → `evidence_attached` → `submitted` → `verified` → `quarantine_transferred` → `ordinary_writeoff`

---

## I. Test results

| Suite | Result |
|-------|--------|
| Playwright `playwright.dmg03m.config.ts` readiness + submit | **PASS** |
| Playwright GM verify UI | **PASS** (re-run after session-clear fix) |
| Vitest `tests/unit/damage` | **102 PASS** |
| Typecheck | **PASS** |
| Lint | **PASS** (existing warnings only) |
| Production build | **PASS** |
| Disposable Docker C/D/E suites | Not re-run (no code change requiring them; cloud activation was the target) |

---

## J. Remaining issues

1. Cloud migration history versions use MCP timestamps, not the local `20261102*` / `20261103*` filenames — bodies match; `migration list` may still show local-only siblings.
2. `DMG-20261103-000013` still draft with null `lot_id` — intentionally unused; owner may abandon or lot-select later.
3. Rotate test account passwords if the temporary `dmg03m-dev-only` credential should not remain.

---

## K. Final PASS / FAIL verdict

**PASS**

Review and Submit works on port **5173** against the existing cloud database. A Store Keeper submitted lot-aware Storage Damage on TEST-ONLY stock; stock isolation held 1 case atomically; Godown Manager verified; quarantine and ordinary write-off completed; commercial inventory and draft `000013` untouched; `damage.stock_hold_ready=true`.
