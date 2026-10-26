# M5.4D — Godown Manager Verification & Ordinary Damage Write-Offs

Local-only operational frontend over the trusted M5.2/M5.3 damage RPCs, plus a read-only list/payload extension and lock-order alignment on verify/return/reject. This work does **not** flip `damage.stock_hold_ready`, lot cutover flags, or post stock from React.

## 1. Feature overview

Godown Managers inspect submitted damage reports, record verification, return reports for correction, reject reports, and post ordinary write-offs of remaining isolated quantity through `post_ordinary_damage_writeoff`. Verification is a status decision. Ordinary write-off is a separate trusted ledger posting.

## 2. Routes and components

| Path                   | Screen                                      | Guard                                   |
| ---------------------- | ------------------------------------------- | --------------------------------------- |
| `/damage`              | Dashboard + awaiting-verification link      | `damageNavPermissions`                  |
| `/damage/reports`      | Report list                                 | `damageNavPermissions`                  |
| `/damage/verification` | GM verification queue                       | `damage.verify` or `operations.monitor` |
| `/damage/:reportId`    | Inspection, verify/return/reject, write-off | `damageNavPermissions`                  |

`/damage/verification` is registered before `/damage/:reportId`.

Components:

- `DamageVerificationPage`
- `DamageVerificationPanel` / `DamageVerificationDialog` / `DamageVerificationEligibility`
- `DamageDecisionReasonDialog`
- `DamageOrdinaryWriteoffPanel` / `DamageOrdinaryWriteoffDialog`
- `DamageVerificationHistory`
- Extended `DamageReportDetailPage`, `DamageHoldsPanel`, `DamageLifecycleTimeline`

## 3. Exact RPC signatures

Audited in repository (local `20261026180700` replaces verify/return/reject bodies only for unlocked godown snapshot + payload/list facts):

| RPC                                      | Arguments                                                                | Auth                     | Notes                                                                                     |
| ---------------------------------------- | ------------------------------------------------------------------------ | ------------------------ | ----------------------------------------------------------------------------------------- |
| `verify_damage_report`                   | `target_report uuid`, `expected_version integer`                         | `damage.verify`          | Submitted only. No idempotency key. Does not post stock.                                  |
| `return_damage_report`                   | `target_report uuid`, `expected_version integer`, `reason text`          | `damage.verify`          | Submitted only. Shop-return forbidden (`23514`). Releases logical holds. Reason 1–500.    |
| `reject_damage_report`                   | `target_report uuid`, `expected_version integer`, `reason text`          | `damage.verify`          | Submitted only. Reporter cannot reject own report. Quarantine intake stays. Reason 1–500. |
| `post_ordinary_damage_writeoff`          | `target_report uuid`, `expected_version integer`, `idempotency_key text` | `damage.verify`          | Exact-once by `damage_posting_kind = ordinary_writeoff`. Does not consult readiness.      |
| `get_damage_report`                      | `target_report uuid`                                                     | `can_view_damage_report` | Payload now includes verifier/return/reject actor fields.                                 |
| `list_damage_reports`                    | page, page_size, target_godown, status/scenario/search/dates             | `can_view_damage_report` | Adds evidence, hold, reporter id, godown_active facts for the queue. Page size cap 100.   |
| `get_damage_dashboard`                   | none                                                                     | existing                 | Unchanged. Awaiting-verification queue remains.                                           |
| `get_damage_photo_url`                   | existing                                                                 | existing signed preview  | Unfinalized evidence is never shown as verified.                                          |
| `transfer_verified_damage_to_quarantine` | existing                                                                 | `damage.verify`          | Storage verified only. Unchanged.                                                         |

Private helpers used, not invented: `assert_damage_create_auth`, `lock_damage_stock_grains`, `consume_damage_holds`, `post_damage_adjustment`, `assert_operational_active_branch` (write-off snapshots activity without locking the branch), `can_view_damage_report`, new `assert_damage_godown_active_unlocked` for verify/return/reject.

## 4. Verification eligibility

Backend is authoritative. UX blockers match:

- Permission `damage.verify` at the godown.
- Status `submitted`.
- Caller is not the reporter.
- At least one `damage_evidence.verified_at` row (finalized bytes).
- Isolation scenarios (`storage`, `loading`, `shop_return`) require matching active/transferred holds.
- Isolation quantities must equal reported line quantities.
- Godown `is_active`.

Inbound (`refill_supply` / `unloading`) and transit may verify without holds. Isolation scenarios cannot be submitted while `damage.stock_hold_ready=false`, so they do not reach this gate in the live environment.

## 5. Self-verification restrictions

`verify_damage_report` and `reject_damage_report` raise `42501` `the reporter cannot verify this damage report` when `reporter_user_id = auth.uid()`. Frontend disables Verify/Reject and explains why. Direct RPC tests cover this; hiding the button is not the control.

## 6. Evidence requirements

Unfinalized photo metadata is insufficient. Catalog rows without `verified_at` never count. Signed previews use `get_damage_photo_url` only for finalized rows. Private Storage paths are not shown.

## 7. Return / reject state transitions

| Action | Allowed from                   | Effect on status | Holds                                                                                             | Reporter editability    |
| ------ | ------------------------------ | ---------------- | ------------------------------------------------------------------------------------------------- | ----------------------- |
| Return | `submitted`, not `shop_return` | `returned`       | Logical `on_hand_deduction` / reservation holds released. Quarantine intake is not a return path. | Reporter can edit again |
| Reject | `submitted`, not own report    | `rejected`       | Logical holds released. `quarantine_intake` remains active.                                       | Locked                  |

Shop-return cannot return to draft. Rejected shop-return stock stays unavailable until authorized disposition (M5.4E). There is no rejection-to-saleable-stock pathway.

## 8. Ordinary write-off eligibility

`assert_damage_disposition_ready`:

- Scenario is not inbound/transit (`refill_supply`, `unloading`, `transit` have no on-hand stock to post).
- Status `verified`, or shop-return `rejected` still holding quarantine stock.
- Finalized evidence.
- Remaining active/transferred holds.
- No open exceptional request.
- Active assigned godown.
- `damage.verify` (admin monitor-only cannot post).

Readiness is **not** consulted. If holds do not exist because isolation never ran, the RPC fails closed with `no isolated damage quantity remains`.

## 9. Stock-impact semantics

Preview is informational. Backend recalculates at posting time.

- Verification: no ledger, no hold consumption.
- Return: releases logical holds; no ledger.
- Reject: releases logical holds; quarantine intake stays; no ledger.
- Ordinary write-off: `consume_damage_holds(..., 'written_off', 'ordinary_writeoff')` posts `ADJUSTMENT` / `ordinary_writeoff` and marks holds written off. Quantity is the remaining active/transferred hold total.

## 10. Idempotency behavior

- Verify/return/reject: no idempotency key. Stale `expected_version` → `PT409` `changed by someone else`. UI reloads; it does not silently retry.
- Ordinary write-off: if an `ordinary_writeoff` stock transaction already exists for the report, the RPC returns the current payload **before** asserting `expected_version`. Lost HTTP, original-key replay with a stale version, and a different key all identify the completed posting without another ledger row. A **new** posting still requires the current version. Network failures tell the user to refresh before retrying; the dialog keeps one key until success and identifies completion from `get_damage_report`.

## 11. Lock ordering

M5.4B/C products → locations. Verify/return/reject previously called `assert_operational_active_branch` (branch `FOR UPDATE`) before any stock work. Return/reject `release_damage_holds` can lock dispatch after that branch lock, inverting `confirm_dispatch`.

M5.4D `assert_damage_godown_active_unlocked` snapshots `branches.is_active` without locking. Write-off already snapshots, then `consume_damage_holds` → `lock_damage_stock_grains` (products then locations).

## 12. Permission matrix

| Role            | Queue / inspect | Verify / return / reject  | Ordinary write-off | Notes                           |
| --------------- | --------------- | ------------------------- | ------------------ | ------------------------------- |
| Admin           | Yes (monitor)   | No unless `damage.verify` | No                 | Oversight only                  |
| Godown Manager  | Yes             | Assigned godowns          | Assigned godowns   | Cannot verify/reject own report |
| Store Keeper    | No queue        | No                        | No                 | Report/view in scope            |
| Delivery Person | No queue        | No                        | No                 | Assigned transit only           |
| Accounts/Sales  | No              | No                        | No                 | Unauthorized                    |

## 13. Test evidence

| Suite       | Path                                                   |
| ----------- | ------------------------------------------------------ |
| SQL         | `supabase/tests/phase_m5_4d_verification_writeoff.sql` |
| HTTP        | `supabase/tests/phase_m5_4d_http_integration.mjs`      |
| Concurrency | `supabase/tests/phase_m5_4d_concurrency.mjs`           |
| Unit        | `tests/unit/damage-verification.test.ts` (+ pages)     |
| Playwright  | `tests/e2e/damage-verification.spec.ts`                |

## 14. Readiness restrictions

Current flags remain false:

- `damage.stock_hold_ready=false`
- `stock.lots.dual_write_enabled=false`
- `stock.lots.aggregate_only_blocked=false`

Isolation-required scenarios cannot be submitted. Inbound/transit verification is the live path. Ordinary write-off UI is visible on verified storage fixtures; the trusted RPC still requires real remaining holds. Tests that enable lot dual-write for dispatch races restore the flags.

## 15. Known limitations

- Verify is not idempotent; a successful verify cannot be replayed.
- Exceptional return-to-supplier / destroy remains M5.4E.
- Isolation-required live reports stay blocked until operations enables readiness.

## 16. M5.4E handoff

M5.4E should add exceptional approval/disposition UI on top of `request_exceptional_damage_disposition`, `approve_exceptional_damage_disposition`, `reject_exceptional_damage_disposition`, and `post_exceptional_damage_disposition`. Do not treat ordinary write-off as covering destroy or supplier-return. Rejected shop-return quarantine intake is the primary exceptional stock that still needs authorized resolution.
