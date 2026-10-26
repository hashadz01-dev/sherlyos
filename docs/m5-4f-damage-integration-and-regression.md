# M5.4F — Full Damage Management Integration & Regression Hardening

Local-only integration of M5.2–M5.4E into one coherent, auditable workflow. This work does **not** flip `damage.stock_hold_ready`, lot cutover flags, or post stock from React. No Git commit, push, cloud migration, or Netlify deploy.

HEAD remains `7fd7d2138144551ea7ae2b40c523c298aed55624` (`feat(m5.4e): add exceptional damage approvals and dispositions`).

## 1. DMG-01–DMG-06 coverage matrix

Authoritative process: `docs/m5-2-damage-foundation.md`. Isolation-required submit stays fail-closed while `damage.stock_hold_ready=false`. A component existing is not treated as the step being operational.

| Code | Scenario | Role (create) | UI | Trusted RPC | Required state | Transition | Stock effect (when ready) | Evidence | Audit event | Tests | Remaining limitation |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| DMG-01 | `refill_supply` | GM / Store Keeper | `/damage/new`, `/damage/:id` | `create_damage_report`, `submit_damage_report` | Posted receipt line; qty ≤ remaining `damaged_cases` | draft → submitted → verified | None. Receipt damaged cases were never accepted stock. | ≥1 finalized photo before verify | created, submitted, verified | M5.2/4B SQL+HTTP, reporting e2e | No supplier credit note. |
| DMG-02 | `unloading` | GM / Store Keeper | same | same inbound RPCs | Same remaining receipt qty (shared with DMG-01) | draft → submitted → verified | None | ≥1 finalized photo | created, submitted, verified | M5.2/4B | Same inbound remaining-qty pool as DMG-01. |
| DMG-03 | `storage` | GM / Store Keeper | `/damage/new`, dashboard, verification, detail | create/submit/verify; `post_ordinary_damage_writeoff` or exceptional chain | Crate in authorized active godown | draft → submitted → verified → ordinary/exceptional post | On-hand hold then `ordinary_writeoff` or `exceptional_writeoff` | ≥1 finalized photo | isolate, verified, ordinary_writeoff or exceptional_* | M5.3/4D/4E/4F | **Submit fail-closed** until readiness is enabled. |
| DMG-04 | `loading` | GM / Store Keeper | `/damage/new` | create/submit; isolation converts reservation | Eligible picking / preparing unconsumed dispatch | draft → submitted → verified → disposition | Reservation conversion hold; no saleable restore | ≥1 finalized photo | isolate, verified, disposition | M5.3 concurrency C | **Submit fail-closed** until readiness. Consumed dispatch rejected. |
| DMG-05 | `transit` | Assigned Delivery Person or GM in consumed-delivery scope | `/damage/new` transit | create/submit (`deliveries.execute` + assigned dispatch) | Consumed dispatch; qty ≤ reserved cases | draft → submitted → verified → disposition | No new `DISPATCH`. Hold/disposition only if isolation applied | ≥1 finalized photo | created, submitted, verified | M5.2 HTTP driver path, damage.spec | Driver cannot verify/dispose. Unassigned driver denied. |
| DMG-06 | `shop_return` | GM / Store Keeper | `/damage/new`, custody panel, quarantine | create; `confirm_shop_return_custody`; submit; verify/reject; exceptional post | Active shop; custody before submit | draft → custody → submitted → verified/rejected → exceptional | Quarantine intake; rejection does not restock; exceptional consume | ≥1 finalized photo | custody_confirmed, isolate, verified/rejected, exceptional_* | M5.4C/4E e2e | **Submit fail-closed** until readiness. No physical-completion certificate. |

### End-to-end paths (A–E)

| Path | Navigation | Backend eligibility | State refresh | Permissions | Inventory | Audit | Readiness |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A Storage | dashboard → new → detail → verification → write-off/exceptional | GM verify + remaining holds | Payload after mutation; no optimistic stock | GM ordinary; Admin approve; GM execute | Exact-once tagged ADJUSTMENT | ordinary_writeoff or exceptional_* | Submit blocked while false |
| B Loading | new with picking source → verification → disposition | Reservation grain; unconsumed dispatch | Same | Same as storage | Converts reservation; no silent release | isolate + disposition | Submit blocked while false |
| C Transit | driver new → GM verify → disposition | Assigned consumed dispatch | Same | Driver create/submit only | No new dispatch txn | created/submitted/verified | Transit submit allowed (no new stock) |
| D Shop-return | new → custody → quarantine → verify/reject → exceptional | Custody required; reject keeps intake | Same | GM custody/verify; Admin exceptional | Intake then consume; never restock | custody_confirmed, rejected, exceptional_posted | Submit blocked while false |
| E Exceptional | detail request → `/damage/exceptional` → execute | Unique open request; post needs `approved` | Completed identification before stale version | GM request/execute; Admin approve/reject | `exceptional_writeoff`; holds `written_off` or `returned_supplier` | requested/approved/rejected/posted | Exceptional RPCs do not consult readiness; posting fail-closes if no holds |

## 2. Role / workflow mapping

| Role | Open `/damage` | Create | Verify / ordinary write-off | Exceptional queue | Approve/reject | Execute exceptional | Quarantine | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Admin | Yes (monitor) | No | No | Yes | Yes | No | Yes (monitor) | Historical read; cannot skip inactive operational writes |
| Godown Manager | Yes | Assigned godowns | Assigned godowns | List RPC via `damage.verify`; UI queue is Admin/monitor | No | Assigned after approval | Yes | Cannot self-verify as reporter |
| Store Keeper | Yes | Assigned (not transit) | No | No | No | No | Yes | Draft/edit only |
| Delivery Person | Transit-scoped | Assigned consumed dispatch | No | No | No | No | No | Deep-link to storage denied |
| Accounts / Sales | No | No | No | No | No | No | No | Direct RPC denied |
| Authorized monitor | Yes | No | No | Yes | No | No | Yes | Read-only |

Frontend eligibility is never broader than backend predicates. Hidden buttons are not the control.

## 3. Routes and navigation

Static routes remain ordered before `:reportId`:

`/damage` → `/damage/reports` → `/damage/quarantine` → `/damage/verification` → `/damage/exceptional` → `/damage/new` → `/damage/:reportId/edit` → `/damage/:reportId`

Guards: `damageNavPermissions`, `damageQuarantinePermissions`, `damageVerificationPermissions`, `damageExceptionalQueuePermissions`, `damageCreatePermissions`. Unauthorized deep-links render Access Denied.

M5.4F navigation: dashboard “Awaiting disposition” links to `/damage/reports`; report list links Exceptional when allowed; detail links Quarantine; queue badges use `formatExceptionalStatus` (Approved — pending execution / Posted — ledger complete). Loading, empty, error, and forbidden states were already present and kept.

## 4. Lifecycle integration

Frontend stages now follow persisted events and `exceptional_requests.status`, not raw `written_off` holds.

- Ordinary write-off is complete only when event `ordinary_writeoff` exists.
- Exceptional destroy (`written_off` + `exceptional_posted`) is **not** labeled ordinary.
- After exceptional rejection, ordinary write-off becomes applicable again if isolation remains.
- `reportHasCompletedOrdinaryWriteoff` requires the ordinary event so lost-response recovery cannot treat exceptional destroy as an ordinary post.
- Activity and verification history show persisted events only, with posted labeled **ledger complete**. Physical destruction / supplier handover is not claimed.

Backend remains authoritative. No optimistic stock mutations.

## 5. Stock and ledger reconciliation

No new stock writers. Established lock order unchanged: request → report → products → locations.

| Kind | Hold status | `damage_posting_kind` | Current unavailable | Saleable restore |
| --- | --- | --- | --- | --- |
| Ordinary write-off | `written_off` | `ordinary_writeoff` | excluded | no |
| Exceptional destroy | `written_off` | `exceptional_writeoff` | excluded | no |
| Return to supplier | `returned_supplier` | `exceptional_writeoff` | excluded | no |
| Active / transferred hold | `active` / `transferred` | none or quarantine intake | included | n/a |

Exact-once posting, nonnegative stock, and dual ordinary/exceptional exclusion remain M5.3–M5.4E RPC contracts. 4F did not change them.

## 6. Reporting changes

Narrow read-only replacement of `get_damage_dashboard` in `20261026181000_damage_dashboard_posted_totals.sql` (local Docker only):

| Total | Source | Mixed into current unavailable? |
| --- | --- | --- |
| `active_hold_cases` | holds `active`/`transferred` | is current unavailable |
| `quarantined_cases` | those holds on quarantine crate/intake | is current unavailable |
| `ordinary_writeoff_cases` | `written_off` holds with `ordinary_writeoff` event | no |
| `exceptional_writeoff_cases` | `written_off` holds with `exceptional_posted` event | no |
| `returned_supplier_cases` | holds `returned_supplier` | no |
| `pending_exceptional` | requests `requested`/`approved` | no (count of requests, not cartons) |

Quarantine UI now shows `returned_supplier_cases` from the existing list RPC. Filter-wide totals remain server-side (not page sums). Godown filter still uses `can_view_damage_report`. Inactive godown historical reporting is unchanged.

React still calls only permission-scoped RPCs.

## 7. Security checks

- Salesperson cannot execute `get_damage_dashboard` (SQL + HTTP).
- Cross-godown GM posted totals are zero.
- Storage submit fail-closed while readiness is false (SQL + HTTP + reporting e2e).
- Driver denied quarantine and exceptional queue (existing e2e).
- Store Keeper denied verify/write-off/exceptional queue (existing e2e).
- Admin cannot request or execute exceptional (existing 4E HTTP).
- Permission/assignment revocation still denied on completed exceptional replay (4E HTTP, not weakened).
- FORCE RLS and security-definer RPCs unchanged. No privileged table queries from React.

## 8. Test isolation approach

M5.4E Playwright leftovers were unmatched `m4e2e_%` stock and inactive-branch balances that blocked `seed_legacy_stock_lots` (`location is inactive`) and dispatch/picking unmatched-SKU checks.

Shared helper `tests/e2e/disposable-stock.ts`:

- Explicit disposable SKU prefixes only (`m1s2*`, `m2e2e`, `m3e2e`, `m4e2e`, `m41*`, `m52*`, `m53*`, `m54*`, `m14e2e`). Not operational stock.
- Before dispatch/picking: leftover unmatched disposable grains and disposable stock on inactive locations are removed; unmatched allowlists include the same prefixes.
- Before lot-recon `seed_legacy_stock_lots`: same leftover cleanup **excluding** `m1s2*` so QA openings remain.
- Reports e2e: leftover cleanup before seed; **full** `m4e2e_%` family stock wipe after (ledger, lots, balances, transactions). Products/branches kept when FKs require it.
- Flag restore to false is part of cleanup. Suites still run sequentially (`workers: 1`).
- SQL/HTTP/concurrency keep `pg_advisory_lock(hashtext('sherlyos.m5.stock_flag_tests'))`.
- Immutable ledger rows for disposable SKUs are deleted only under `session_replication_role = replica` in those owned prefixes. Operational history is not deleted.

## 9. SQL / HTTP / concurrency results

All first-pass. Sequential. No retry.

| Suite | Result |
| --- | --- |
| `phase_m5_2_damage_foundation.sql` | passed (rollback) |
| `phase_m5_3_damage_stock_isolation.sql` | passed (rollback) |
| `phase_m5_4a_damage_frontend_reads.sql` | passed (rollback) |
| `phase_m5_4b_damage_reporting.sql` | passed (rollback) |
| `phase_m5_4c_custody_quarantine.sql` | passed (rollback) |
| `phase_m5_4d_verification_writeoff.sql` | passed (rollback) |
| `phase_m5_4e_exceptional_disposition.sql` | passed (rollback) |
| `phase_m5_4f_damage_integration.sql` | passed (rollback) |
| M5.2 HTTP | passed (8) |
| M5.3 HTTP | passed (4) |
| M5.4B HTTP | passed (14) |
| M5.4C HTTP | passed (5) |
| M5.4D HTTP | passed (13) |
| M5.4E HTTP | passed (20) |
| M5.4F HTTP | passed (4) |
| M5.2 concurrency | passed (1) |
| M5.3 concurrency | passed (9/9) |
| M5.4C concurrency | passed (7/7) |
| M5.4D concurrency | passed (9/9) |
| M5.4E concurrency | passed (12/12) |

4F adds no new stock-writer races. 4E concurrency remains the latest posting lock-order suite.

## 10. Vitest and Playwright results

Vitest: **185 passed / 30 files**, first-pass.

Playwright first pass: **68 passed, 1 failed, 3 did not run** (serial file stopped after the failure). Failure: `damage-verification` ordinary write-off assertion used `getByText('Ordinary write-off posted')` after event labels were applied to lifecycle, activity, and verification history (strict-mode 3 matches). Dispatch, picking, lot-reconciliation, and reports all passed on that first pass (isolation fix held without manual leftover cleanup).

Locator corrected to `.first()`. Full suite retry: **72 passed**, 0 failed, 0 skipped.

## 11. Remaining business limitations

- `damage.stock_hold_ready` remains false. Storage, loading, and shop-return **submit** stay fail-closed. Drafts, inbound/transit submit, reads, verification UI, and exceptional RPCs (which fail if no holds exist) are unchanged.
- Lot dual-write and aggregate-only cutover remain false. No stock cutover.
- Posted ≠ independently verified physical destruction or supplier handover. Backend does not record that certificate.
- `return_supplier` does not create a shipment or credit note.
- Partial quantity exceptional posting is not offered; quantity is remaining holds.
- Admin cannot execute exceptional posting; GM cannot approve.
- Inactive godown: historical reporting allowed; new operational damage writes fail closed.
- Damage migrations including 81000 are **local Docker only**. Development cloud `ypkfondrkhkydkgovwup` was not migrated.

## 12. M5.5 QA handoff

M5.5 should treat this module as feature-complete under the fail-closed readiness gate, not as a new workflow.

Suggested QA focus:

1. Repeat A–E on local Docker with the three flags false; confirm isolation-required submit errors are visible and not bypassed.
2. When operations later enables `damage.stock_hold_ready` (owner decision, not this phase), re-run storage/loading/shop-return submit → verify → ordinary and exceptional posting against live holds.
3. Confirm dashboard posted totals never inflate current unavailable after ordinary vs exceptional vs supplier-return.
4. Confirm quarantine `returned_supplier` is historical-only.
5. Permission matrix: Admin / GM / Store Keeper / Driver / Accounts / Sales, including deep-links.
6. Playwright isolation: a clean `npx playwright test` with workers=1 should not need manual `m4e2e_%` cleanup.
7. Do not enable lot dual-write or aggregate-only as part of damage QA.

Owner decisions still required before M5.5/M6: enable isolation, physical-completion evidence, supplier shipment/credit, partial dispositions.

Local Docker `supabase_db_sherlyos`, API `http://127.0.0.1:54321`. Cloud was not written. Cutover flags restored to false / false. `damage.stock_hold_ready` remains false.
