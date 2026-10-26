# M5.5 — Damage Management module closure

Local-only QA of Phase M5. This work does **not** flip `damage.stock_hold_ready`, lot cutover flags, or post stock from React. No Git commit, push, cloud migration, Netlify deploy, stock isolation activation, or M6 implementation.

M5.4F HEAD is unchanged. Development completion is **not** production readiness.

## 1. Executive summary

SherlysOS Damage Management (M5.2–M5.4F) was revalidated against `reference/Sherlys_Distribution_Agents_BPM.pdf` Branch 02 (DMG-01–DMG-06), the companion BPM module, the implemented trusted RPC surface, and the twelve inventory-accounting invariants.

**Verdict for owner review:** M5.5 QA PASSED — M5 DEVELOPMENT CLOSURE RECOMMENDED.

Under the currently approved configuration (`damage.stock_hold_ready=false`):

- Inbound (DMG-01/02) and transit (DMG-05) create → evidence → submit → GM verify are operationally available and tested.
- Storage (DMG-03), loading (DMG-04), and shop-return (DMG-06) **submit** remain fail-closed. Drafts, evidence, custody UI, verification UI, and exceptional RPCs exist; isolation-required submit is blocked in both UI and backend.
- Ordinary/exceptional posting, dashboard posted totals, quarantine identity, RLS, evidence byte-verify, and concurrency/idempotency contracts pass on isolated local fixtures.
- Companion-BPM extras that are **not** in the PDF six-situation register (Repacking, Inspection, Other, cost-based damage value, a distinct Closed header status) are classified as owner decisions, not silent implementations.

No stock-integrity blocker, privilege-escalation blocker, duplicate-ledger defect, or first-pass regression failure was found in this session.

## 2. Verified baseline HEAD

| Item | Value |
| --- | --- |
| Branch | `main` |
| Tracking | `origin/main` (read-only inspect: `0 ahead / 0 behind` at start) |
| M5.5 baseline HEAD | `c3f224ac8c8d37787d81ca5116fb0ba43ca9b983` |
| Commit message | `feat(m5.4f): integrate damage workflows and harden regression coverage` |
| Parent | `7fd7d2138144551ea7ae2b40c523c298aed55624` |
| Working tree at start | clean |
| Latest damage migration | `20261026181000_damage_dashboard_posted_totals.sql` (local Docker) |
| Flags after all tests | `damage.stock_hold_ready=false`, `stock.lots.dual_write_enabled=false`, `stock.lots.aggregate_only_blocked=false` |
| Local target | Docker `supabase_db_sherlyos`, API `http://127.0.0.1:54321`, Playwright `http://127.0.0.1:4173` (`--mode m1s2`) |
| Cloud / production | not migrated, not deployed |

HEAD remained `c3f224a` throughout. No fetch, push, rebase, reset, or commit.

## 3. Blueprint traceability matrix

### 3.1 Sources compared

1. **Authoritative PDF register:** `reference/Sherlys_Distribution_Agents_BPM.pdf` Branch 02 — six detection situations (DMG-01–DMG-06) and handling actions (inspect/isolate, separate, quarantine, return for inspection, receive shop returns). Rule: “Damaged or returned goods remain unavailable for sale until verified disposition.”
2. **Companion structured BPM** (`bpm-sherlys-distribution-agents` module `damage-management`): receiving / warehouse / transit paths plus verification and action stages. Extra prototype items: action list Supplier Return / Hold / Write-off / **Repacking / Inspection / Other**, damage value = cases × cost, statuses Open / Verified / **Closed**.
3. **Implemented SherlysOS mapping:** scenarios `refill_supply`, `unloading`, `storage`, `loading`, `transit`, `shop_return` over trusted SECURITY DEFINER RPCs.

Classifications used below:

- **IMPLEMENTED AND VERIFIED** — code exists, tests passed in this session, and the step is available under current flags.
- **IMPLEMENTED BUT ACTIVATION-GATED** — code and tests exist; live submit/isolation is blocked while `damage.stock_hold_ready=false`.
- **PARTIALLY IMPLEMENTED** — intent covered by a different status/event model or UX policy.
- **NOT IMPLEMENTED** — no workflow.
- **REQUIRES OWNER DECISION** — companion/PDF gap that must not be silently built.

### 3.2 DMG-01 Stock refill damage

| Attribute | Finding | Classification |
| --- | --- | --- |
| Business scenario | Identify and separate goods damaged in manufacturer supply/refill. | IMPLEMENTED AND VERIFIED |
| Initiating actor | Godown Manager / Store Keeper (`damage.record` + receiving/verify extras). Admin cannot create. | IMPLEMENTED AND VERIFIED |
| Required permissions | Create: `damage.record` and (`receiving.execute` or `damage.verify`). Verify: `damage.verify`, not the reporter. | IMPLEMENTED AND VERIFIED |
| Required previous state | Posted receipt line; qty ≤ remaining `damaged_cases` (shared with DMG-02). | IMPLEMENTED AND VERIFIED |
| UI entry | `/damage/new` scenario Refill supply; detail `/damage/:id`. | IMPLEMENTED AND VERIFIED |
| Backend RPC | `create_damage_report`, `update_damage_report`, `submit_damage_report`, `verify_damage_report` / `return_damage_report` / `reject_damage_report`. | IMPLEMENTED AND VERIFIED |
| Evidence | ≥1 finalized photo before verify (backend). Create UI also requires a photo before Submit. | IMPLEMENTED AND VERIFIED |
| Custody | Not required (never accepted stock). | IMPLEMENTED AND VERIFIED |
| Isolation/hold | None. Receipt damaged cases were never posted as RECEIPT. | IMPLEMENTED AND VERIFIED |
| Verification | GM; self-verify denied. | IMPLEMENTED AND VERIFIED |
| Approval | Ordinary inbound has no Admin approval; exceptional not applicable without holds. | IMPLEMENTED AND VERIFIED |
| Stock impact | None on accepted inventory. | IMPLEMENTED AND VERIFIED |
| Ledger impact | No damage write-off ledger for inbound remaining damaged cases. | IMPLEMENTED AND VERIFIED |
| Final state | `verified` (or `rejected` / `cancelled`). | IMPLEMENTED AND VERIFIED |
| Audit event | created, submitted, verified (plus return/reject). | IMPLEMENTED AND VERIFIED |
| Automated test | M5.2 SQL+HTTP, M5.4B HTTP, `damage-reporting.spec.ts` inbound submit. | IMPLEMENTED AND VERIFIED |
| Operational availability | Yes, under current flags. | IMPLEMENTED AND VERIFIED |
| Remaining | No supplier credit note / shipment. | REQUIRES OWNER DECISION |

### 3.3 DMG-02 Unloading damage

Same inbound contract as DMG-01. Reporter chooses `unloading` vs `refill_supply`; remaining receipt `damaged_cases` is a shared pool. Handling in the PDF is “separate products damaged during unloading.”

| Attribute | Finding | Classification |
| --- | --- | --- |
| Scenario / RPCs / UI / evidence / verify | Same inbound path as DMG-01. | IMPLEMENTED AND VERIFIED |
| Stock / ledger | None (never accepted). | IMPLEMENTED AND VERIFIED |
| Operational availability | Yes. | IMPLEMENTED AND VERIFIED |
| Remaining | Shared remaining-qty pool with DMG-01 is a reporter-chosen label, not two independent quantity ledgers. | PARTIALLY IMPLEMENTED |

### 3.4 DMG-03 Godown storage damage

PDF handling: “Quarantine damage detected in godown.”

| Attribute | Finding | Classification |
| --- | --- | --- |
| Create / product+crate selection / evidence | GM/Store Keeper on authorized active godown crate. | IMPLEMENTED AND VERIFIED (drafts) |
| Submit + on-hand hold | `submit_damage_report` → `apply_damage_stock_isolation`. Fail-closed while readiness=false. | IMPLEMENTED BUT ACTIVATION-GATED |
| Physical quarantine transfer | `transfer_verified_damage_to_quarantine` after verify, remaining on-hand holds. | IMPLEMENTED BUT ACTIVATION-GATED (needs a submitted/isolated report) |
| GM verification | `verify_damage_report`; evidence required; hold qty must match when isolated. | IMPLEMENTED BUT ACTIVATION-GATED for live isolated reports; UI/RPC tested on fixtures that enable the flag inside tests only |
| Ordinary write-off | `post_ordinary_damage_writeoff` (`damage.verify`). Tagged `ADJUSTMENT` `ordinary_writeoff`. | IMPLEMENTED BUT ACTIVATION-GATED |
| Exceptional | Request (`damage.verify`) → Admin approve/reject (`damage.dispose`) → GM post. | IMPLEMENTED BUT ACTIVATION-GATED |
| Stock / ledger | Hold then write-off; posted history excluded from current unavailable. | IMPLEMENTED AND VERIFIED on fixtures; not live operational |
| Audit | isolate, verified, ordinary_writeoff or exceptional_*. | IMPLEMENTED AND VERIFIED |
| Tests | M5.3/4D/4E/4F SQL+HTTP+concurrency; Playwright reporting fail-closed submit; verification/exceptional e2e on fixtures. | IMPLEMENTED AND VERIFIED |
| Operational availability | **No** for submit/isolation while readiness=false. | IMPLEMENTED BUT ACTIVATION-GATED |

### 3.5 DMG-04 Vehicle loading damage

PDF handling: “Separate products damaged while loading.”

| Attribute | Finding | Classification |
| --- | --- | --- |
| Eligible context | Picking `allocated`/`picking`/`picked`/`ready_for_dispatch` and/or preparing unconsumed dispatch. Consumed dispatch rejected. | IMPLEMENTED AND VERIFIED (create validation) |
| Submit / reservation conversion | Isolation converts overlapping reservation; no duplicate consume with `confirm_dispatch`. | IMPLEMENTED BUT ACTIVATION-GATED |
| Evidence / GM verify / disposition | Same as storage once isolated. | IMPLEMENTED BUT ACTIVATION-GATED |
| Concurrent dispatch safety | M5.3 race C; M5.4C/4D/4E post vs confirm_dispatch. | IMPLEMENTED AND VERIFIED (fixtures) |
| Operational availability | **No** for submit while readiness=false. | IMPLEMENTED BUT ACTIVATION-GATED |

### 3.6 DMG-05 Transit damage

PDF handling: “Return transit-damaged goods for inspection.”

| Attribute | Finding | Classification |
| --- | --- | --- |
| Initiating actor | Assigned Delivery Person (`deliveries.execute` + `assigned_to`) or GM in consumed-delivery scope. | IMPLEMENTED AND VERIFIED |
| Required state | Consumed dispatch `dispatched`/`in_transit`/`delivered`/`exception`; qty ≤ reserved cases. | IMPLEMENTED AND VERIFIED |
| Unauthorized driver | Unassigned / cross-dispatch / cross-branch denied before duplicate detection. | IMPLEMENTED AND VERIFIED |
| Submit | Allowed (no new DISPATCH, no available-stock hold). | IMPLEMENTED AND VERIFIED |
| Evidence / GM verify | Same evidence/verify contract. Driver cannot verify, reject, dispose, or post. | IMPLEMENTED AND VERIFIED |
| Stock impact | No new dispatch transaction. Isolation/disposition only if a hold path applied (not the default transit path). | IMPLEMENTED AND VERIFIED |
| Audit | created, submitted, verified. | IMPLEMENTED AND VERIFIED |
| Tests | M5.2 HTTP driver path; `damage.spec.ts`; `damage-reporting.spec.ts`; 4D HTTP driver denied verify. | IMPLEMENTED AND VERIFIED |
| Operational availability | Yes for report/submit/verify. | IMPLEMENTED AND VERIFIED |
| Remaining | PDF “return for inspection” is GM verify/return-for-correction, not a separate reverse-logistics shipment. | PARTIALLY IMPLEMENTED |

### 3.7 DMG-06 In-shop / expired products

PDF handling: “Receive damaged or expired shop returns.”

| Attribute | Finding | Classification |
| --- | --- | --- |
| Create | Active shop; optional order matching shop+godown. | IMPLEMENTED AND VERIFIED (drafts) |
| Physical custody | `confirm_shop_return_custody` required before submit. Store keeper cannot confirm. | IMPLEMENTED AND VERIFIED (UI); submit gated |
| Quarantine intake | Isolation posts unavailable quarantine inventory atomically with submit. | IMPLEMENTED BUT ACTIVATION-GATED |
| Evidence / submit / GM verify or reject | Rejected report remains quarantined; no saleable restore. | IMPLEMENTED BUT ACTIVATION-GATED for live submit; reject-keeps-quarantine verified on fixtures |
| Exceptional destroy of rejected intake | Admin approve + GM post. | IMPLEMENTED BUT ACTIVATION-GATED |
| Operational availability | Custody UI yes; submit **No** while readiness=false. | IMPLEMENTED BUT ACTIVATION-GATED |

### 3.8 Shared verification, disposition, and companion extras

| Blueprint item | SherlysOS mapping | Classification |
| --- | --- | --- |
| Unavailable until verified disposition (PDF) | Holds + quarantine crates excluded from picking; write-off/supplier-return never restore saleable stock. | IMPLEMENTED AND VERIFIED (fixtures) / ACTIVATION-GATED (live isolation) |
| Manager verification of evidence (companion DMG-VER-*) | `verify` / `return` / `reject`; Open case cannot deduct. | IMPLEMENTED AND VERIFIED |
| Deduction only after Verified/Closed (DMG-R1) | Write-off RPCs require verified + remaining holds. Verify itself posts no ledger. | IMPLEMENTED AND VERIFIED |
| Status Open / Verified / Closed (DMG-R2) | Header: draft/submitted/returned/verified/cancelled/rejected. Closure is event `ordinary_writeoff` / `exceptional_posted`, not a Closed header. | PARTIALLY IMPLEMENTED / REQUIRES OWNER DECISION |
| Action list Hold / Write-off / Supplier Return (DMG-R3 subset) | Holds; ordinary write-off; exceptional `destroy` / `return_supplier`. | IMPLEMENTED AND VERIFIED (gated where isolation required) |
| Repacking / Inspection / Other (DMG-R3 extras) | No workflows. | NOT IMPLEMENTED / REQUIRES OWNER DECISION |
| Damage value = cases × cost (DMG-RCV-05) | Not calculated or stored. | NOT IMPLEMENTED / REQUIRES OWNER DECISION |
| Distinct Closed status (DMG-ACT-05) | Event/ledger completion labels (“Posted — ledger complete”). | PARTIALLY IMPLEMENTED / REQUIRES OWNER DECISION |
| Physical destruction / supplier handover certificate | Explicitly not claimed. UI copy states ledger posting only. | NOT IMPLEMENTED / REQUIRES OWNER DECISION |
| Crate 50-case prototype flag (DMG-R5) | Not a SherlysOS operational rule. | NOT IMPLEMENTED / REQUIRES OWNER DECISION |
| PD-02 verifying manager vs stock supervisor | GM verifies and posts ordinary/exceptional; Admin approves exceptional only. | IMPLEMENTED AND VERIFIED as the chosen split; owner may still confirm |

Do not treat a gated workflow as operationally available.

## 4. Workflow scenario results

| Scenario | Result under current flags | Evidence |
| --- | --- | --- |
| A Refill / unloading | Eligible reporter, receipt reference, create, evidence, submit, GM verify, no accepted-stock mutation. Disposition N/A (never accepted). Fail-closed isolation not invoked. | M5.2 HTTP inbound; 4B HTTP; reporting e2e inbound submit |
| B Storage | Draft + evidence + fail-closed submit while readiness=false. Isolation/hold/ordinary/exceptional posting proven on isolated fixtures that temporarily enable the flag inside tests and restore it. Operational UI does not bypass the gate. | 4F HTTP fail-closed; reporting e2e; M5.3/4D/4E fixtures |
| C Loading | Create eligibility + consumed-dispatch rejection. Reservation conversion and no duplicate consume proven in concurrency C and post-vs-dispatch races. Submit gated live. | M5.3 race C; 4C/4D/4E dispatch races |
| D Transit | Assigned driver create/submit; unassigned/cross-branch denied; GM verify; driver denied verify/dispose/quarantine/exceptional. No new DISPATCH. | M5.2 HTTP; damage.spec; 4D/4E HTTP denials |
| E Shop-return | Custody UI; keeper cannot confirm; driver denied quarantine; reject remains quarantined; exceptional destroy of rejected intake on fixtures. Submit gated live. | 4C e2e + HTTP; 4E HTTP rejected shop-return |
| F Exceptional | Requested → Approved — pending execution (zero ledger) → Posted — ledger complete. Admin rejection blocks execution. Exact-once post. Destroy vs supplier-return hold statuses distinguished. | 4E HTTP+concurrency; 4F dashboard identity; exceptional e2e; M5.5 SQL approval-no-ledger |

Physical destruction and supplier handover are **not** independently verified outside the system. Posted means ledger complete.

## 5. Inventory accounting reconciliation

M5.5 SQL replica fixtures (`m55-sql-ord` 3 ordinary written-off, `m55-sql-des` 2 exceptional destroy, `m55-sql-sup` 4 returned-supplier, `m55-sql-act` 5 active holds) plus established M5.3–M5.4E posting tests.

| # | Invariant | Result | Proof |
| --- | --- | --- | --- |
| 1 | No negative inventory | Pass | M5.5: `stock_balances.quantity >= 0`; posting RPCs fail closed on over-consume |
| 2 | No double consumption of holds | Pass | Unique active grain; write-off vs write-off / post vs post races |
| 3 | No duplicate ledger posting | Pass | Unique `(damage_report_id, damage_posting_kind)` + completed identification |
| 4 | No saleable restoration of rejected shop returns | Pass | Reject keeps `quarantine_intake`; 4C e2e; 4E HTTP destroy of rejected intake |
| 5 | No posting after unauthorized branch deactivation | Pass | M5.3 race I; 4D/4E deactivation races; inactive replay denied without re-post |
| 6 | No stock change from approval alone | Pass | M5.5: approved request `stock_transactions` count = 0; 4E HTTP “approval is authorization only” |
| 7 | No stock change from report verification alone | Pass | Verify does not insert `ADJUSTMENT`; write-off is a separate RPC |
| 8 | No historical write-off counted as current unavailable | Pass | M5.5 dashboard `active_hold_cases=5` vs posted 3+2+4; quarantine current unavailable = 5 |
| 9 | No ordinary/exceptional double count | Pass | M5.5 ordinary=3, exceptional destroy=2, supplier=4; 4F HTTP |
| 10 | No cross-godown inventory disclosure | Pass | M5.5 other-godown GM dashboard zeros; sales denied dashboard |
| 11 | No reservation conversion inconsistency | Pass | Loading conversion vs confirm_dispatch; remaining reservations + converted holds |
| 12 | No lot/aggregate reconciliation drift | Pass | Dual-write remains false; aggregate `apply_stock_delta` path; lot_id unused operationally |

All assertions used database values (SQL/HTTP/concurrency), not mocked frontend state. No invariant failed. None classified as BLOCKER.

## 6. Security assessment

| Control | Result |
| --- | --- |
| FORCE RLS on six damage tables | Pass (M5.5) |
| Authenticated INSERT/UPDATE revoked on stock_balances, stock_ledger, stock_transactions, damage_stock_holds | Pass (M5.5 privilege check + DML denial) |
| Authenticated UPDATE on damage_reports denied | Pass (M5.5) |
| `app_private.apply_damage_stock_isolation` not executable by authenticated | Pass (M5.5) |
| SECURITY DEFINER RPCs with `search_path=''`, EXECUTE granted to `authenticated` only | Pass (foundation migrations; not widened in M5.5) |
| Private helpers revoked from public/anon/authenticated/service_role except storage-policy helpers | Pass (M5.2/M5.3) |
| JWT session authorization; no invented sessions | Pass (HTTP suites use Auth users) |
| Frontend mutates only via `callRpc` + private Storage upload | Pass (`src/lib/damage/api.ts`; no privileged stock table writes) |
| Admin cannot create ordinary reports, cannot verify, cannot request/execute exceptional | Pass (M5.2/4E HTTP) |
| GM cannot approve/reject exceptional | Pass (4E HTTP) |
| Store keeper denied verify, write-off, custody confirm, exceptional queue | Pass (4D/4E HTTP + e2e) |
| Delivery Person denied verify, quarantine, exceptional, storage create | Pass (HTTP + e2e) |
| Accounts / Sales denied damage screens and dashboard RPC | Pass (damage.spec accounts; M5.5/4F sales dashboard) |
| Cross-godown GM zeros; inactive godown historical read vs operational write fail-closed | Pass |
| Revoked permission / removed assignment / inactive godown completed-post replay denied without re-post | Pass (4E HTTP) |
| Reporter cannot self-verify | Pass (4D HTTP + e2e) |

No confirmed privilege escalation. None classified as BLOCKER.

## 7. Evidence and storage assessment

| Control | Result |
| --- | --- |
| Private bucket `stock-damage-evidence` (10 MB, jpeg/png/webp) | Pass |
| Path `{report_id}/{evidence_id}`; no public read; no update/delete storage policies | Pass |
| Upload then trusted finalize; browser upload is not finalization | Pass (api.ts + 4B HTTP) |
| Actual uploaded-byte verification (in-cluster GET, byte equality, magic bytes) | Pass (4B HTTP matching / mismatch / missing object) |
| Checksum/eTag/size/MIME from client never prove content | Pass |
| Cross-uploader / replay finalize fail-closed | Pass |
| Cross-godown / unauthorized photo URL | `get_damage_photo_url` requires view of that report + finalized |
| Missing evidence blocks verify (backend) and Submit (UX) | Pass |
| Evidence persists through lifecycle | Catalog rows remain; terminal reports lock quantity/evidence changes |

**In-cluster vs cloud:** Finalize allowlists `http://kong:8000` and `http://supabase_kong_sherlyos:8000` only. Cloud/project Storage hosts are **not** allowlisted. Remote finalize stays fail-closed until an owner-approved allowlisted base URL is added and tested. This session did not weaken that list.

## 8. Concurrency and idempotency results

All suites used independent database sessions. No skipped race was counted as pass. First-pass, sequential, no retry.

| Suite | Result |
| --- | --- |
| M5.2 concurrent verify | 1/1 — one verified report |
| M5.3 A–I | 9/9 |
| M5.4C | 7/7 (transfer exact-once, replay, vs picking/write-off/deactivation/dispatch) |
| M5.4D | 9/9 (verify vs verify/return/reject; write-off vs write-off/transfer/picking/deactivation/dispatch; return vs dispatch) |
| M5.4E | 12/12 (request vs request; approve vs reject; approve vs post; post vs post; exceptional vs ordinary/transfer/picking/deactivation/dispatch/hold consume; post-then-deactivate replay read-only) |

Lock order remains request → report → products → locations. No deadlock observed. Version conflicts raise `PT409`. Completed-operation identification returns the posted row instead of double-posting. Lost-response UI: no silent automatic mutation retry; dialogs instruct refresh first. Current authorization is re-checked on completed-post replay (4E HTTP).

## 9. Dashboard and reporting reconciliation

`get_damage_dashboard` (81000) vs hold rows in M5.5:

| Total | Fixture identity | Mixed into current unavailable? |
| --- | --- | --- |
| `ordinary_writeoff_cases` | 3 | no |
| `exceptional_writeoff_cases` | 2 | no |
| `returned_supplier_cases` | 4 | no |
| `active_hold_cases` | 5 | yes |
| quarantine `current_unavailable_cases` | 5 | yes |

Posted write-offs do not inflate current unavailable. Filter-wide totals are server-side. Pagination and godown filters remain list RPCs (`list_damage_reports`, `list_damage_quarantine_inventory`, `list_exceptional_damage_requests`). Inactive godown historical reporting allowed; new operational writes fail closed. 4F HTTP: salesperson cannot execute dashboard; storage submit fail-closed.

## 10. Test fixture isolation

`tests/e2e/disposable-stock.ts` remains prefix-scoped. M5.5 added `m55%` so leftover `m55_sql_*` grains (if a future SQL abort skipped rollback) cannot collide with operational SKUs or unmatched-seed checks. M5.5 SQL itself begins/rolls back and takes `pg_advisory_lock(hashtext('sherlyos.m5.stock_flag_tests'))`.

- Disposable prefixes only; QA `m1s2*` openings excluded from lot-recon leftover wipe.
- Ledger deletes for disposable SKUs only under `session_replication_role = replica`.
- Flag restore to false is part of cleanup.
- Playwright `workers: 1`, `fullyParallel: false`.
- SQL/HTTP/concurrency run sequentially in this session.

Playwright first-pass included dispatch, picking, lot-reconciliation, and reports without manual leftover cleanup.

## 11. UI / accessibility assessment

Automated Chromium Playwright (72 tests) plus unit page tests. **Human UAT was not performed.**

Inspected surfaces: dashboard, reports, editor, detail, evidence, custody, quarantine, verification, ordinary write-off, exceptional request/approvals/execution.

| Check | Result |
| --- | --- |
| Navigation / role-specific actions | Permission-gated routes; hidden buttons are not the control |
| Loading / empty / error | Shared LoadingState / EmptyState / Access Denied |
| Status accuracy | Event-based ordinary vs exceptional; `formatExceptionalStatus` Requested / Approved — pending execution / Posted — ledger complete |
| Irreversible warnings | Write-off and exceptional execute dialogs warn ledger posting, no saleable restore, refresh-after-ambiguous-failure |
| Quantity formatting | `formatCases` (“N case(s)”) |
| Dialogs | `AppModal` with confirm `aria-label`s; filters labelled |
| Readiness banner | `role="status"`; isolation not ready copy; no misleading “stock complete” claim |
| Dead-ends | Isolation submit shows backend fail-closed; exceptional rejected returns ordinary path when holds remain |
| Responsive | Login phone-width, reports tablet-width, lot-recon tablet-width covered in e2e; damage dialogs use the shared modal |

Known lint warning (pre-existing): `DamageReportEditorPage.tsx` react-compiler `set-state-in-effect` on hydrate. Not treated as a functional defect.

## 12. Automated test evidence

All first-pass unless noted. Sequential SQL → HTTP → concurrency. No suite was retried.

### SQL (rollback)

| Suite | Exit |
| --- | --- |
| `phase_m5_2_damage_foundation.sql` | 0 |
| `phase_m5_3_damage_stock_isolation.sql` | 0 |
| `phase_m5_4a_damage_frontend_reads.sql` | 0 |
| `phase_m5_4b_damage_reporting.sql` | 0 |
| `phase_m5_4c_custody_quarantine.sql` | 0 |
| `phase_m5_4d_verification_writeoff.sql` | 0 |
| `phase_m5_4e_exceptional_disposition.sql` | 0 |
| `phase_m5_4f_damage_integration.sql` | 0 |
| `phase_m5_5_module_closure.sql` | 0 |

M5.5 SQL was also executed once before the sequential pack (exit 0). Sequential pack is the recorded first-pass of the full M5.2–M5.5 SQL set.

### HTTP

| Suite | Checks |
| --- | --- |
| M5.2 | 8 passed |
| M5.3 | 4 passed |
| M5.4B | 14 passed |
| M5.4C | 5 passed |
| M5.4D | 13 passed |
| M5.4E | 20 passed |
| M5.4F | 4 passed |

Node printed `DEP0190` child_process/shell deprecation on `npx supabase status`. Not a test failure.

### Concurrency

38/38 races passed (1+9+7+9+12).

### Frontend / engineering

| Check | Result |
| --- | --- |
| Vitest | **185 passed / 30 files**, first-pass |
| Playwright first-pass | **72 passed**, 0 failed, 0 skipped, 4.3m, 1 worker |
| Playwright final | same as first-pass (no retry) |
| Typecheck | passed |
| Lint | passed; warnings: TransfersPage / OpeningStockPage / ProductsPage `incompatible-library`; DamageReportEditorPage `set-state-in-effect` |
| Production build | passed; existing >500 kB chunk advisory |

No Playwright first-pass failure occurred in M5.5 (unlike M5.4F’s locator strict-mode miss, which was already fixed before this baseline).

## 13. Known limitations

1. Isolation-required submit is fail-closed while `damage.stock_hold_ready=false`.
2. Lot dual-write and aggregate-only cutover remain false. No lot-attributed damage posting in operations.
3. Posted ≠ independently verified physical destruction or supplier handover.
4. `return_supplier` does not create a shipment or Accounts credit note.
5. No partial-quantity exceptional posting; quantity is remaining holds.
6. Inbound DMG-01 vs DMG-02 share remaining receipt damaged cases.
7. No Repacking / Inspection / Other actions.
8. No cost-based damage value.
9. No distinct Closed header status.
10. Evidence finalize is in-cluster Storage only; cloud hosts are not allowlisted.
11. Damage migrations through 81000 are **local Docker only**.
12. Admin cannot execute exceptional posting; GM cannot approve (by design).
13. Inactive godown: historical reporting allowed; new non-transit operational writes fail closed.

## 14. Activation prerequisites

Do not enable any of these as part of M5.5.

**Currently operational (flags false):**

- DMG-01 / DMG-02 create, evidence, submit, GM verify/return/reject.
- DMG-05 assigned-driver/GM transit create, evidence, submit, GM verify.
- Reads: dashboard, reports, quarantine list, verification queue, exceptional queue.
- Shop-return custody confirmation UI (submit still gated).
- Draft storage/loading/shop-return create and evidence.

**Blocked by `damage.stock_hold_ready=false`:**

- Storage / loading / shop-return submit, hold creation, quarantine intake, ordinary write-off of isolated stock, exceptional post of isolated stock, physical quarantine transfer.

**Before enabling isolation (owner + operations):**

1. Explicit owner approval to set `damage.stock_hold_ready=true` on a named environment.
2. Confirm M5.3 isolation functions are installed (`damage_stock_isolation_installed()`).
3. Decide whether lot dual-write must be on first. Current recommendation: **do not** enable `stock.lots.dual_write_enabled` or `stock.lots.aggregate_only_blocked` as part of damage activation.
4. Apply damage migrations through 81000 to that environment (development cloud and production have **not** received them).
5. Confirm Storage finalize allowlist includes that environment’s in-cluster Kong URL; do not silently allowlist a cloud host.
6. Deploy the matching frontend (Netlify not done here).
7. Rollback plan: set `damage.stock_hold_ready=false` (trigger still prevents `true` only until isolation is installed; disabling remains the live kill-switch). Do not reverse posted ledgers ad hoc.
8. Post-activation monitoring: dashboard current unavailable vs hold rows; ordinary vs exceptional vs supplier-return identity; picking availability on quarantine crates; no negative balances; evidence finalize success rate.
9. Re-run storage/loading/shop-return submit → verify → ordinary and exceptional posting against live holds after enablement — as a **separate** activation test, not by bypassing safeguards now.

## 15. Open owner decisions

1. Enable `damage.stock_hold_ready` on which environment, and when.
2. Whether lot dual-write must precede isolation enablement (recommended: no).
3. Whether to implement companion actions Repacking, Inspection, Other.
4. Whether to add cost-based damage value.
5. Whether to add a distinct Closed header status vs keeping event/ledger completion.
6. Supplier shipment / credit-note integration for `return_supplier`.
7. Physical-completion evidence (destruction certificate / handover).
8. Partial-quantity exceptional posting.
9. Cloud Storage host allowlist for evidence byte-verify.
10. PD-02 confirmation that GM verify + Admin exceptional approve is the intended split.
11. When to migrate development cloud / production and deploy Netlify.

## 16. M5 closure recommendation

All twelve development-closure criteria are met:

1. DMG-01–06 mapped against the PDF.
2. Implemented workflows have passing tests.
3. Gated workflows are explicitly identified.
4. No unresolved critical stock-integrity defect.
5. No unresolved privilege-escalation defect.
6. No duplicate ledger posting found.
7. Dashboard and hold balances reconcile on fixtures.
8. Evidence controls remain intact.
9. Full first-pass run was repeatable without manual cleanup.
10. Activation requirements documented.
11. All three flags remain false.
12. No prohibited deployment or cutover occurred.

**Recommendation:** M5 DEVELOPMENT CLOSURE — for owner review. Not production-ready. Not an instruction to commit, migrate, or enable flags.

## 17. M6 Stock Refill handoff

BPM Branch 05 (REF-01–REF-07) is **not** started.

Handoff notes:

- Do not enable damage isolation or lot cutover as a side effect of M6.
- Receiving already excludes receipt `damaged_cases` from accepted stock; inbound damage reporting (DMG-01/02) remains the damage entry for refill arrivals.
- Accounts/Admin refill approval is a new module; do not overload `damage.dispose`.
- Keep FORCE RLS, trusted RPCs, and disposable-prefix test isolation.
- Local Docker vs cloud migration remains an owner decision.

---

This document is a QA recommendation. It does not declare production readiness and does not create a Git checkpoint.
