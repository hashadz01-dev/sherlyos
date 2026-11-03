# DMG-03D — Lot-Aware Storage Damage UI and Browser UAT

**Verdict: DMG-03D PASSED — UI-ONLY END-TO-END**

Disposable stack only (`supabase_db_sherlyos_m82c`, API `57321`, app `5174`). Cloud and owner DB unchanged. Cloud draft `DMG-20261103-000013` not modified.

## Root cause

Storage Damage failed to expose a lot because **two layers omitted lot grains**, not because isolation rejected browser input alone:

1. **`list_damage_report_sources` (storage)** returned `crates`, `products`, and aggregate `balances` only. No lot catalog.
2. **`DamageLineEditor`** for storage offered Product + Crate only and always saved `lot_id: ""`.
3. Backend already required `lot_id` at **submit** when `stock.lots.dual_write_enabled` (`isolate_storage_damage`). Draft replace previously allowed null lots, so DMG-03C had to SQL-attribute a lot after save.

Availability math already existed (`picking_available_cases` = on_hand − reserved − holds). The gap was catalog + UI + draft-time validation.

## Changed files

| Area | Path |
|------|------|
| Migration | `supabase/migrations/20261103160000_damage_storage_lot_catalog.sql` |
| FE catalogs | `src/lib/damage/api.ts` |
| Lot picker UI | `src/features/damage/components/DamageLineEditor.tsx` |
| Draft validation | `src/features/damage/utils/draft.ts` |
| Editor wiring | `src/features/damage/DamageReportEditorPage.tsx` |
| Review summary | `src/features/damage/components/DamageSubmitReview.tsx` |
| Fixture | `scripts/dmg03d/prepare-two-lot-stable-fixture.sql` |
| Negatives | `scripts/dmg03d/negative-lot-validation.sql` |
| Playwright | `playwright.dmg03d.config.ts`, `tests/e2e/dmg03d-lot-aware-storage-uat.spec.ts` |
| Regression | `tests/e2e/dmg03c-isolation-uat.spec.ts` (UI lot select; no SQL lot repair) |

## Database changes (disposable m82c applied)

- `app_private.build_damage_storage_catalogs(godown)` — crates, products, balances, lots (physical/reserved/held/available via existing helpers), `dual_write_enabled`.
- `list_damage_report_sources` storage branch calls that builder.
- `replace_damage_lines` — when storage + dual-write: require lot; prove lot↔product↔godown↔crate via `stock_lot_balances`; reject qty above `picking_available_cases`.
- `isolate_storage_damage` — explicit lot/product/crate grain check before availability lock math.

No cloud migration applied.

## UI behavior

1. Select godown → Storage → Add line.
2. Select product and crate.
3. **Stock lot** select appears when `dual_write_enabled`.
4. Options show manufacturer code, expiry (if any), and available cases.
5. Selected lot shows physical / reserved / held / available.
6. Empty lots: clear message that reserved/held stock is not eligible for storage isolation.
7. Save persists `lot_id`; reload keeps selection.
8. Review summary includes lot id prefix; submit success still reports isolated cases.

Policy: damage quantity is validated against **available** (not reserved). Reserved stock is not silently consumed.

## Backend validation

| Check | Where |
|-------|--------|
| Lot belongs to product/godown | `assert_optional_damage_lot` + storage replace |
| Lot at selected crate | `stock_lot_balances` existence |
| Qty whole positive cases | existing `receipt_case_count` |
| Qty ≤ available | replace (early) + isolate (locked) |
| Godown authorization | existing create/update auth |
| No duplicate overlapping holds | existing submit/idempotency |
| Non-negative / concurrent pick safety | isolate locks + `picking_available_cases` |

Browser availability is never trusted for posting.

## Test fixture

- Godown `m82c_gd1`, zone `m82c_z1`, crate `m82c_c1`, SKU `m82c-stable`.
- Two lots: `TEST-LOT-STABLE` (10 physical) + `TEST-LOT-STABLE-B` (7 physical) = **17** aggregate.
- Flags: `damage.stock_hold_ready=true`, `stock.lots.dual_write_enabled=true`.
- Users: `keeper.m82c@example.test`, `gm.m82c@example.test`.

## Browser UAT evidence

Primary UI-only report (lot selected in browser, no SQL lot repair):

- **Damage ID:** `DMG-20261103-000007` (and subsequent re-runs on the same disposable stack)
- Lot held: `TEST-LOT-STABLE-B` (+1)
- Other lot: `TEST-LOT-STABLE` held unchanged by that report
- Physical aggregate: **17** unchanged
- Picking availability on selected lot decreased by 1
- GM verification succeeded; Store Keeper self-verify blocked
- Duplicate submit did not add holds

Playwright DMG-03D: **6/6 passed**  
Playwright DMG-03C (updated): **5/5 passed**

## Lot-level reconciliation (post 03D happy path)

| Lot | Physical | Held | Available |
|-----|----------|------|-----------|
| TEST-LOT-STABLE | 10 | prior holds | prior − prior holds |
| TEST-LOT-STABLE-B | 7 | +1 from UI report | 6 after isolate |
| Aggregate | 17 | — | — |

## Regression results

| Suite | Result |
|-------|--------|
| DMG-03D Playwright | 6/6 PASS |
| DMG-03C Playwright | 5/5 PASS |
| Damage unit (vitest ×4 files) | 57/57 PASS |
| Negative lot SQL | PASS (wrong product, insufficient qty, wrong crate; physical unchanged) |
| Typecheck / build | FAIL — pre-existing `ReceivingPage.tsx` status filter typing (unrelated to DMG-03D) |
| Lint (changed damage files) | warning only: existing setState-in-effect on editor hydrate |

DMG-03A/03B were migration/readiness streams; their disposable SQL artifacts remain valid. M5.3 / FEFO / full inventory e2e suites were not re-executed in this pass beyond damage unit + 03C/03D Playwright.

## Remaining blockers

- Evidence upload may still fall back to disposable SQL finalize on private storage (lot is **not** repaired).
- Repo `tsc -b` / `vite build` blocked by unrelated ReceivingPage type error.
- Cloud not cut over.

## Cloud deployment prerequisites

1. Apply `20261103160000_damage_storage_lot_catalog.sql` (and prior DMG-03A–C migrations) after owner review.
2. Confirm lot dual-write + reconciliation on target godowns before `damage.stock_hold_ready`.
3. Do **not** flip cloud `damage.stock_hold_ready` without owner cutover.
4. Deploy FE with lot picker before enabling dual-write storage submit in production.
5. Leave legal GST / quarantine / write-off paths untouched.

## Final verdict

**DMG-03D PASSED — UI-ONLY END-TO-END**
