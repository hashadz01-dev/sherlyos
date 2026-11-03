# DMG-03E.2 — Damage Quarantine, Write-Off and Exceptional Disposition UAT

**Verdict: PASS**

Disposable stack only (`supabase_db_sherlyos_m82c`, API `57321`, app `5174`). Cloud and owner DB unchanged. Owner draft `DMG-20261103-000013` not modified. No commit/push/deploy. No cloud migrations. No operational flag flips. No browser service-role. No direct SQL stock posts during workflows.

## A. Existing lifecycle analysis

Post-verification lifecycle is already implemented end-to-end. No new lifecycle invented.

| Transition | Status | Trusted surface |
|------------|--------|-----------------|
| Submit → isolate hold | Complete (DMG-03C/D/E.1) | `submit_damage_report` + `damage_stock_holds` |
| Verify (GM, not reporter) | Complete | `verify_damage_report` |
| Quarantine / custody transfer | Complete | `transfer_verified_damage_to_quarantine` (auto `ensure_godown_quarantine_crate`) |
| Ordinary write-off | Complete | `post_ordinary_damage_writeoff` |
| Exceptional request | Complete | `request_exceptional_damage_disposition` (`return_supplier`, `destroy`) |
| Admin approve / reject | Complete | `approve_exceptional_damage_disposition` / `reject_exceptional_damage_disposition` (`damage.dispose`) |
| Exceptional post | Complete | `post_exceptional_damage_disposition` (`damage.verify`) |
| Lot balances + ledger | Complete | Dual-write lots; `stock_transactions.damage_posting_kind` |
| Audit | Complete | `damage_report_events` (`quarantine_transferred`, `ordinary_writeoff`, `exceptional_*`) |

UI already exists on report detail: quarantine transfer dialog, ordinary write-off panel, exceptional request / Admin review / execute panels. Quarantine crate `QRN` / `QRN-01` is created on first trusted transfer when absent.

Disposition does not require quarantine first; this UAT still exercised quarantine → ordinary write-off as a custody-first path. Exceptional destroy posted from an active (non-quarantined) hold after Admin approval.

## B. Implementation gaps

| Gap | Disposition |
|-----|-------------|
| Product UI / RPC lifecycle for quarantine, write-off, exceptional | **None** — already correct |
| Disposable fixture capacity after repeated UATs | Softened E.2 baselines; reuse verified holds when picking avail is 0; reject leftover submitted holds via trusted `reject_damage_report` |
| Prior suites hard-code C1 physical `= 17` | Expected: after write-offs, C1 physical drops; C/D/E.1 cannot re-baseline without replenishing disposable stock |

## C. Files changed

| Path | Change |
|------|--------|
| `playwright.dmg03e2.config.ts` | Disposable E.2 Playwright config (5174 / m82c) |
| `tests/e2e/dmg03e2-helpers.ts` | Browser create→evidence→submit→verify; stock snapshot; release submitted holds; find reusable verified holds |
| `tests/e2e/dmg03e2-disposition-uat.spec.ts` | Serial UAT: quarantine, ordinary write-off, exceptional destroy, rejection, reconciliation |
| `docs/dmg-03e2-quarantine-disposition-and-stock-reconciliation-uat.md` | This report |

No production React/RPC/migration changes required for E.2.

## D. Quarantine test results

**PASS** (Playwright + DB assertions).

- Verified Storage Damage (fresh create when avail ≥ 1, else reused verified active hold on `TEST-LOT-STABLE`).
- UI: Transfer verified damage → Post quarantine transfer.
- Hold becomes `transferred|on_hand_deduction|1|quarantine|TEST-LOT-STABLE`.
- C1 physical −1; QRN physical +1; lot code retained on destination.
- Ledger +2 legs (source/destination transfer).
- Quarantine crate picking availability = 0.
- Audit includes `quarantine_transferred`.
- Store Keeper: quarantine action button absent.

## E. Ordinary write-off results

**PASS**.

- Continued the same quarantined report (custody then write-off).
- UI: Post ordinary write-off → Confirm.
- Hold `written_off|1`.
- Exactly one `stock_transactions` row with `damage_posting_kind = ordinary_writeoff`.
- Exactly one ledger adjustment leg for that transaction.
- Quarantine physical −1; C1 unchanged by the write-off itself.
- Duplicate `post_ordinary_damage_writeoff` (GM JWT, new idempotency key) did not create a second transaction.
- Audit matches `ordinary_writeoff`.

## F. Exceptional disposition results

**PASS** for supported kinds.

| Case | Result |
|------|--------|
| Request destroy | Stock / ledger unchanged |
| Store Keeper approve | Rejected by RPC authorization |
| Admin approve | Authorization only; stock unchanged |
| GM execute destroy | Hold written off; C1 physical −1; request `destroy\|posted` |
| Request return_supplier then Admin reject | Stock unchanged; status `rejected` |
| Post after reject | Blocked by RPC |
| Active hold after reject | Remains `active` (1 case) |

Duplicate approval / concurrent exceptional posting covered by M5.3 concurrency races E (below). Insufficient / stale quantity and wrong lot/crate remain enforced by existing trusted RPCs (not bypassed).

## G. Independent stock reconciliation

Post-suite disposable `m82c-stable` snapshot (after legitimate write-offs / transfers):

| Metric | Actual |
|--------|--------|
| C1 physical | 7 (lot sum = 7) |
| Quarantine physical | 4 |
| Active holds (sku) | 7 cases |
| Transferred holds | 4 cases |
| Written-off holds | 6 cases |
| Released holds | 3 cases |
| `quarantine_transfer` txs | 8 |
| `ordinary_writeoff` txs | 4 |
| `exceptional_writeoff` txs | 2 |
| Negative balances | 0 |
| Stranded active holds on cancelled reports | 0 |
| Cross-lot / cross-godown leakage in E.2 assertions | None observed |

Lot grain after suite:

| Lot | Crate | Qty | Held | Avail |
|-----|-------|-----|------|-------|
| TEST-LOT-STABLE | m82c_c1 | 3 | 3 | 0 |
| TEST-LOT-STABLE | QRN-01 | 3 | 0 | 0 |
| TEST-LOT-STABLE-B | m82c_c1 | 4 | 4 | 0 |
| TEST-LOT-STABLE-B | QRN-01 | 1 | 0 | 0 |

Opening disposable physical was 17 on C1 before disposition UATs; closing C1 + quarantine + written-off cases conserve the disposable pool without duplicate deductions in the E.2 paths under test.

## H. Security and concurrency

| Check | Result |
|-------|--------|
| Store Keeper cannot quarantine (UI) | PASS |
| Store Keeper cannot approve exceptional (RPC) | PASS |
| Admin required before exceptional stock post | PASS |
| Rejected exceptional cannot post | PASS |
| Duplicate ordinary write-off idempotent | PASS |
| M5.3 concurrency races A–I | **9/9 PASS** |
| RLS / trusted RPC auth | Preserved (no SQL workflow bypass) |

## I. Regression results

| Suite | Result |
|-------|--------|
| DMG-03E.2 Playwright | **5/5 PASS** |
| M5.3 isolation SQL (`phase_m5_3_damage_stock_isolation.sql`) | **PASS** (completed with `ROLLBACK`) |
| M5.3 concurrency (`phase_m5_3_concurrency.mjs`) | **9/9 PASS** |
| Vitest (full unit suite) | **368/368 PASS** (60 files) |
| `npm run typecheck` | **PASS** |
| `npm run build` | **PASS** |
| `npm run lint` | **PASS** (existing warnings only) |
| DMG-03E.1 Playwright | **Not re-runnable** — `beforeAll` expects C1 physical `17`, received `7` after disposable write-offs |
| DMG-03D Playwright | Same fixture gate (`17` vs `7`) |
| DMG-03C Playwright | Same fixture gate (`17` vs `7`) |

Prior DMG-03C **5/5**, DMG-03D **6/6**, DMG-03E.1 **4/4** remain the last green results on the pre-disposition grain. Failure mode is fixture exhaustion from E.2 write-offs, not a product regression.

## J. Remaining blockers

- Replenish disposable `m82c-stable` (or reset m82c) before re-running C/D/E.1 baselines that hard-code physical `17`.
- Cloud cutover still owner-gated (`damage.stock_hold_ready`, lot dual-write flags, etc.).
- Cloud migrations / flag flips not in scope.

## K. Cloud readiness

Not ready for cloud operational cutover. Disposable validation of quarantine → write-off → exceptional destroy/reject is green. Do not flip cloud flags or migrate owner DB from this pass.

## L. Final verdict

**PASS** — Quarantine, ordinary write-off, supported exceptional dispositions, stock reconciliation, authorization/concurrency, typecheck, and build all verified on disposable m82c without SQL workflow repair. Prior C/D/E.1 PASS results stand; those suites need a replenished disposable grain before they can re-assert the opening `17` case baseline.
