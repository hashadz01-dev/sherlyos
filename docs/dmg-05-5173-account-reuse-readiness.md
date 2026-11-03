# DMG-05 — 5173 / development-cloud fixture readiness

**Status: READY FOR MANUAL DMG-05 TEST (5173 accounts)**

Owner approval: `APPROVED — DMG-05 DEVELOPMENT-CLOUD TEST FIXTURE ONLY`.  
Fixture created via trusted RPCs. **No damage report** created/submitted. Commercial and DMG-04 baselines unchanged. No flag/permission/migration/commit/push.

---

## Environment

| Item | Value |
|------|--------|
| App | `http://127.0.0.1:5173` |
| Backend | `https://ypkfondrkhkydkgovwup.supabase.co` |
| Script | `scripts/dmg05/prepare-transit-fixture-cloud.mjs` |

---

## Fixture IDs

| Field | Value |
|-------|--------|
| Product | `TEST-DMG05-ONLY` (`2490a6c8-d5bf-4365-a3de-7bd3bace70ef`) |
| Lot | `TEST-LOT-DMG05` (`75614bb2-c5bd-4f8f-91a4-f743764504fe`) |
| Opening | `OS-20261103-000056` — **3** cases @ Godown-1 / `uat_c1` |
| Sales order | **`SO-20261103-000027`** |
| Packing | **`PK-20261103-000003`** |
| Dispatch | **`DS-20261103-000002`** — `dispatched`, `stock_consumed=true` |
| Assigned Delivery Person | `testdeliveryperson@gmail.com` |
| Vehicle | `KL-43-F-948` |
| Dispatched | **2** |
| Final physical `TEST-DMG05-ONLY` | **1** |
| Transit eligibility | Source picker returns `DS-20261103-000002` with 2 reserved TEST cases |

### Untouched baselines (verified after write)

| SKU | Qty |
|-----|-----|
| AVT-CATER-BLEND-1KG | 17 |
| GOODLIFE-MILK-500ML | 18 |
| TEST-DMG04-ONLY | 3 |
| Packing `PK-20261103-000002` | unchanged (not used) |

---

## Manual browser UAT (do not run until you start testing)

### Test Deliveryperson — create/submit

1. Open `http://127.0.0.1:5173` → login `testdeliveryperson@gmail.com` / `12345678`
2. Damage → **New report**
3. Godown: **Godown-1**
4. Scenario: **Transit**
5. Source: **`DS-20261103-000002`**
6. Line: `TEST-DMG05-ONLY` / `uat_c1` / `TEST-LOT-DMG05` / reserved **2**
7. Qty **1**; reason; draft → finalize evidence → **Submit**
8. Expect: `submitted`; physical still **1**; no new `DISPATCH`; no default hold

### Test Godownmanager — verify

9. Login `testgodownmanager@gmail.com` / `12345678`
10. Open the submitted report → **Verify**
11. Expect: `verified`

**Stopped before any damage create.** Waiting for owner manual UAT.
