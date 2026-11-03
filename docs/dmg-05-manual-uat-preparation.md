# DMG-05 — Manual UAT preparation (Transit Damage)

**Verdict: READY FOR MANUAL DMG-05 TEST**

Disposable **m82c** fixture prepared under owner approval (`APPROVED — DMG-05 TRANSIT DAMAGE UAT FIXTURE ONLY`).  
`confirm_dispatch` ran **once** for 2 TEST cases. **No damage report** created/submitted/verified. No cloud writes, flag changes, migrations, commits, or pushes. Commercial AVT/GOODLIFE and DMG-04 packing are absent from this stack and were not touched.

---

## 1. Authoritative specification

| Source | What it states |
|--------|----------------|
| `docs/m5-2-damage-foundation.md` | DMG-05 = scenario `transit`. Consumed dispatch in `dispatched`/`in_transit`/`delivered`/`exception`. Assigned driver or GM in consumed-delivery scope. Qty ≤ reserved cases on that picking. **No new `DISPATCH` transaction** on damage submit. |
| `docs/m5-4f-damage-integration-and-regression.md` | Create: assigned Delivery Person or GM. Path C: create → GM verify. Submit allowed (no new stock). |
| `docs/m5-5-damage-management-module-closure.md` §3.6 | No available-stock hold by default; driver cannot verify/dispose. |
| `src/features/damage/utils/labels.ts` | “DMG-05. Damage on an assigned consumed dispatch…” |
| `src/lib/damage/rules.ts` | `scenarioMaySubmitWithoutHold('transit')` = true |

**Business purpose:** Report goods damaged after dispatch stock was already consumed, without posting another `DISPATCH` ledger consume or (by default) an on-hand isolation hold.

---

## 2. Implementation readiness

**READY** on m82c (GM and assigned Delivery Person create paths).

| Area | Evidence |
|------|----------|
| Frontend | `/damage/new` → scenario Transit; consumed-dispatch picker |
| Backend | Transit auth + `list_damage_report_sources`; submit without hold |
| Stock | Default transit path: no reservation conversion / on-hand hold |
| Isolation gate | `damage.stock_hold_ready=true` on m82c (not required for transit submit) |

---

## 3. Fixture (isolated m82c only)

**Script:** `scripts/dmg05/prepare-transit-fixture.mjs` (guards: sysid, API port 57321, refuses owner/m81c/commercial SKUs).

| Field | Value |
|-------|--------|
| Environment | `supabase_db_sherlyos_m82c` / Kong `http://127.0.0.1:57321` / sysid `7702447407569928229` |
| App URL for UAT | **`http://127.0.0.1:5174`** (Vite `--mode dmg03c`) — **not** 5173 cloud |
| SKU | `TEST-DMG05-ONLY` |
| Lot | `TEST-LOT-DMG05` (`f31aa6c2-f605-4ad6-a0ec-c93835c6d6e3`) |
| Godown | `m82c_gd1` (TEST ONLY Godown-1) |
| Crate | `m82c_c1` |
| Shop | TEST ONLY Shop Alpha |
| Opening | `OS-20261103-000053` — **3** cases |
| Sales order | **`SO-20261103-000006`** |
| Packing | **`PK-20261103-000006`** |
| Dispatch | **`DS-20261103-000006`** — status `dispatched`, `stock_consumed=true` |
| Assigned Delivery Person | `driver.m82c@example.test` / password `local-only-m82c` |
| Vehicle | `TEST-UAT-0001` |
| Dispatched cases | **2** |
| Remaining physical / lot | **1 / 1** |
| Active reservations on packing | **0** (consumed by dispatch) |
| Transit source picker | Returns `DS-20261103-000006` with 2 reserved cases on TEST SKU/lot |
| Ledger (TEST SKU only) | `OPENING_STOCK` +3 → `DISPATCH` −2 |

**Safety checks after prep**

- Commercial SKUs AVT/GOODLIFE on m82c: **0**
- Packing `PK-20261103-000002` (cloud DMG-04): **0** on m82c
- Damage report for this dispatch: **not created**

---

## 4. Expected stock behavior when damage is submitted (do not submit yet)

| Event | Physical on-hand | New `DISPATCH` | Hold / quarantine |
|-------|------------------|----------------|-------------------|
| Already done: `confirm_dispatch` | 3 → **1** | Yes (once) | n/a |
| Transit damage **submit** | **unchanged (1)** | **No** | Default **none** |
| GM **verify** | unchanged | No | Disposition N/A unless a hold path was used |

Qty on the report should be ≤ 2 (picking reserved cases shown on the source).

---

## 5. Manual browser steps (`5174` / m82c)

Start the disposable app if needed:

```bash
npm run dev -- --mode dmg03c --host 127.0.0.1 --port 5174 --strictPort
```

**Do not use `http://127.0.0.1:5173`** for this fixture (that env is cloud).

### Option A — Godown Manager reporter (recommended)

1. Login: `gm.m82c@example.test` / `local-only-m82c`
2. Damage → **New report**
3. Godown: **TEST ONLY Godown-1** (`m82c_gd1`)
4. Scenario: **Transit**
5. Source: **`DS-20261103-000006`**
6. Confirm line: `TEST-DMG05-ONLY` / `m82c_c1` / `TEST-LOT-DMG05` / reserved **2**
7. Quantity **1**; damage reason; save draft
8. Upload + finalize ≥1 photo → **Review and Submit**
9. Sign out; login a **different** user with verify rights (or Accounts path if configured) — GM reporter must not self-verify if policy denies it
10. Verify the submitted report

### Option B — Assigned Delivery Person reporter

1. Login: `driver.m82c@example.test` / `local-only-m82c`
2. Same create/submit steps against `DS-20261103-000006` only
3. Driver cannot verify — GM verifies

**Stop before step 7–8 until you are ready to execute the manual test.** Fixture preparation already stopped before any damage create.

---

## 6. Pass/fail acceptance checklist

- [ ] App is **5174 → m82c**, not 5173 cloud
- [ ] Source is **`DS-20261103-000006`** / `TEST-DMG05-ONLY` only
- [ ] Unassigned driver (if tried) cannot create against this dispatch
- [ ] Submit succeeds without isolation blocker
- [ ] Physical stock stays **1** after submit (no second deduction)
- [ ] No new `DISPATCH` row for the damage submit
- [ ] No quarantine / hold created on default transit path
- [ ] Reporter cannot self-verify
- [ ] GM verify succeeds
- [ ] No AVT/GOODLIFE / cloud DMG-04 records involved

---

## 7. Safety constraints observed

- Stock write limited to TEST-DMG05-ONLY opening + one `confirm_dispatch`
- No damage hold, write-off, supplier return, or extra dispatch
- No operational flag changes
- No cloud migrate/deploy/commit/push
- No ledger history deletes
- Waiting for owner manual browser testing before any damage report submit
