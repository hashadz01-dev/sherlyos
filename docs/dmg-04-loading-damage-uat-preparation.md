# DMG-04 — Loading Damage UAT preparation

**Verdict: READY FOR MANUAL DMG-04 TEST**

No commit/push/deploy. No dispatch posted. No loading damage submitted. Commercial AVT/GOODLIFE unchanged. `PK-20261102-000001` left as historical (consumed).

---

## Why the UI had no usable packing sources

Loading Damage sources come from `list_damage_report_sources` (`scenario=loading`) and require packing status in:

`allocated` | `picking` | `picked` | `ready_for_dispatch`

with **active** reservations for line hydration.

| Existing record | Reality |
|-----------------|---------|
| `PK-20261102-000001` / `SO-20261030-000025` | Status still `ready_for_dispatch`, but linked dispatch is **delivered** / `stock_consumed=true` |
| Reservations | Only **consumed** (no `active` rows) |
| Lines in picker | Empty → not usable for loading isolation |

No feature flag blocked allocation. `damage.stock_hold_ready` is already **true**. The gap was **missing undispatched packing with active reservations**.

Isolation behavior (do not submit yet): `isolate_loading_damage` converts reservation qty into `reservation_conversion` holds — **physical on-hand does not decrease** on submit; avail floor stays consistent (reserved↓ and hold↑ cancel in the availability equation).

---

## Disposable fixture created (trusted RPCs)

| Field | Value |
|-------|--------|
| SKU | `TEST-DMG04-ONLY` |
| Lot | `TEST-LOT-DMG04` (`ae79d6ad-af05-45ed-a0f4-730b963bcb8c`) |
| Crate | `uat_c1` (Godown-1) |
| Opening | `OS-20261103-000055` — **3** cases |
| Shop | SHOPPE FRESH |
| Sales order | **`SO-20261103-000026`** (`1c7483bc-6315-41d0-ad0f-d171a44907f4`) |
| Packing | **`PK-20261103-000002`** (`11cc17cc-bcd9-44fc-862d-bdd3758ea997`) |
| Packing status | `ready_for_dispatch` |
| Dispatch | **none** |
| Active reserved | **2** |
| Active picked | **2** |
| Physical / reserved / avail | **3 / 2 / 1** |
| Aggregate↔lot mismatched | **0** |
| Source picker | Returns `PK-20261103-000002` with 2 reserved cases on TEST lot |

Script: `scripts/dmg04/prepare-loading-fixture.mjs` (already run). Eligibility check: `scripts/dmg04/verify-loading-eligibility.mjs`.

---

## Manual browser steps (5173)

### Store Keeper (`teststorekeeper@gmail.com` / `12345678`)

1. Open `http://127.0.0.1:5173` → Damage → New report.
2. Confirm isolation readiness banner is on.
3. Godown: **Godown-1**.
4. Scenario: **Loading**.
5. Source: select **`PK-20261103-000002`** (search if needed).
6. Line should hydrate: `TEST-DMG04-ONLY` / `uat_c1` / lot `TEST-LOT-DMG04` / reserved 2.
7. Set quantity **1** case; enter a damage reason.
8. Save draft → upload/finalize evidence → **Review and Submit** → submit.
9. Expect: status Submitted; **1** `reservation_conversion` hold; physical still **3**; reserved **1**; available still **1** (no double physical deduct).

### Godown Manager (`testgodownmanager@gmail.com` / `12345678`)

10. Open the submitted report → Verify (Store Keeper must not self-verify).
11. Optionally quarantine / disposition on TEST stock only.

**Do not** prepare/confirm dispatch on `PK-20261103-000002` until after the loading damage UAT you intend.

---

## Safety notes

- Do not use `PK-20261102-000001` / GOODLIFE for this test.
- Do not flip unrelated flags; none were required.
- Flag rollback reminder: setting `damage.stock_hold_ready=false` does not undo holds.
