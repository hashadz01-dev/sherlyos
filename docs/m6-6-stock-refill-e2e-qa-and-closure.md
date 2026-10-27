# M6.6 — Stock refill end-to-end QA and module closure

Local-only QA of PDF Branch 05 REF-01 through REF-07 (M6.1–M6.5). This phase does **not** add business features, a second stock writer, over-delivery acceptance, automatic request closure, automatic supplier messaging, cloud migration, Netlify deploy, Git commit, or feature-flag activation.

**Development completion is not production readiness.**

Starting HEAD: `59fb2799ffe60928a07976ecd07987aa1d1d3250`  
`feat(m6.5): complete refill UI and reporting workflows` on `main`. Working tree was clean except this phase’s QA files. Parent is M6.4 `8667e3bac947bd7cd281a1318f6f557681718452`.

## 1. BPM traceability matrix

Source compared: `reference/Sherlys_Distribution_Agents_BPM.pdf` Branch 05, M6.1 extraction, and live local RPCs/UI/tests.

Classifications:

- **IMPLEMENTED AND VERIFIED** — code exists, tests passed in this session, and the step is available under current flags.
- **IMPLEMENTED (MANUAL / ATTESTED)** — the PDF step is covered by a manual recording, not an automated external action.
- **OWNER DECISION / REMAINING** — blueprint is silent or an extra policy was deliberately not invented.

### REF-01 — Identify replenishment demand

| Attribute | Evidence |
| --- | --- |
| Blueprint | System/Accounts detect low stock or extra demand. No reorder field in the PDF. |
| UI | Accounts opens `/refill/new`. Queue `/refill`. Inventory reports remain available under `stock.read`. |
| RPC | None dedicated. Demand is expressed by `create_stock_refill_request`. |
| Permission | `refill.request` (Accounts). `operations.monitor` is **not** a refill grant. |
| State | Creates `draft`. |
| Audit | `created` |
| Tests | M6.2 SQL/HTTP/e2e; M6.6 SQL Scenario A create. |
| Stock | Zero. |
| Classification | **IMPLEMENTED AND VERIFIED** as **manual identification**. Automated reorder-level detection is **OWNER DECISION / REMAINING** (`products` has no reorder field). |

### REF-02 — Prepare supplier-specific products and case quantities

| Attribute | Evidence |
| --- | --- |
| UI | `/refill/new` and `/refill/:id/edit` (`RefillForm`). Brand = existing `supplier_id`. Destination godown is mandatory. |
| RPC | `create_stock_refill_request`, `update_stock_refill_request`, `list_stock_refill_options` |
| Permission | `refill.request`; creator only; assigned **active** godown. |
| State | `draft` or `held` lines. Unique active SKUs of the selected supplier. Whole cases 1–1_000_000. |
| Audit | `created`; edit does not duplicate create. |
| Tests | M6.2 SQL supplier/SKU consistency; M6.6 SQL hold-revise path. |
| Stock | Zero. |
| Classification | **IMPLEMENTED AND VERIFIED** |

### REF-03 — Submit to Admin

| Attribute | Evidence |
| --- | --- |
| UI | Detail `/refill/:id` Submit. |
| RPC | `submit_stock_refill_request` |
| Permission | `refill.request`; creator; active destination. |
| State | `draft`/`held` → `submitted`. Held resubmit writes `resubmitted`. |
| Audit | `submitted` / `resubmitted`. Actor `auth.uid()`. |
| Tests | M6.2 SQL/HTTP/e2e; M6.6 Scenario C. |
| Stock | Zero. |
| Classification | **IMPLEMENTED AND VERIFIED** |

### REF-04 — Admin approves, holds, or rejects

| Attribute | Evidence |
| --- | --- |
| UI | `/refill/:id` Admin actions. Queue filters by status. |
| RPC | `approve_stock_refill_request`, `hold_stock_refill_request`, `reject_stock_refill_request` |
| Permission | `refill.approve`. Approve requires active godown. Hold/reject require a reason. Accounts cannot approve. GM/Keeper cannot approve. |
| State | `submitted` → `approved` (immutable) / `held` / `rejected` (terminal). |
| Audit | `approved` / `held` / `rejected`. |
| Tests | M6.2 full matrix; M6.6 C/D; Playwright admin approve. |
| Stock | Zero. Approval is not a receipt. |
| Classification | **IMPLEMENTED AND VERIFIED** |

### REF-05 — Record external supplier communication

| Attribute | Evidence |
| --- | --- |
| UI | `/refill/:id` `RefillSupplierPanel`. Copy states this is a manual record, not a sent message. |
| RPC | `record_stock_refill_supplier_communication` |
| Permission | `refill.request`; assigned **active** godown. Admin cannot send. |
| State | Communication `not_sent` → `sent`. Acknowledgement starts `pending`. Approval status stays `approved`. |
| Audit | `sent_to_supplier`. `recorded_at` is `clock_timestamp()`. Send row is immutable. |
| Tests | M6.3 SQL/HTTP/e2e; M6.6 A + Admin-send denial. |
| Stock | Zero. |
| Classification | **IMPLEMENTED (MANUAL / ATTESTED)**. SherlysOS does not send WhatsApp/email/SMS. Channel/date correction of the original send is **OWNER DECISION / REMAINING**. |

### REF-06 — Supplier acknowledgement and dispatch information

| Attribute | Evidence |
| --- | --- |
| UI | Same supplier panel. Decline copy: Admin approval remains; dispatch blocked until an audited acknowledgement correction. |
| RPC | `record_stock_refill_supplier_acknowledgement`, `record_stock_refill_supplier_dispatch` |
| Permission | `refill.request`; assigned active godown. |
| State | Ack `pending` / `acknowledged` / `declined`. Dispatch `not_recorded` / `recorded`. Decline blocks dispatch. Approval stays `approved`. |
| Audit | `supplier_acknowledged`, `supplier_declined`, `supplier_acknowledgement_corrected`, `supplier_dispatch_recorded`, `supplier_dispatch_corrected`. |
| Tests | M6.3 SQL decline + correction; M6.6 Scenario E. |
| Stock | Zero. No in-transit balance. |
| Classification | **IMPLEMENTED (MANUAL / ATTESTED)**. Physical carrier tracking is not a Sherlys inventory movement. |

### REF-07 — Physical deliveries through Branch 03 receiving

| Attribute | Evidence |
| --- | --- |
| UI | Keeper `/receiving/new` optional refill link; `/receiving/:id` count/submit; GM verify. Refill detail `RefillReceivingPanel`. Accounts see receipt numbers without `/receiving/:id` links. |
| RPC | Existing `create_stock_receipt` (optional `target_refill_request`), `update_stock_receipt`, `submit_stock_receipt`, `hold_stock_receipt`, `cancel_stock_receipt`, `verify_stock_receipt`. Read `get_stock_refill_receiving_reconciliation`. |
| Permission | Create/submit: `receiving.execute`. Verify: `receiving.verify`. Refill approve does not grant receiving. Receiving does not grant refill queues. |
| State | Receipt `draft` → `submitted`/`held` → `posted`/`cancelled`. Request stays `approved`. Multiple receipts per request. |
| Audit | Receipt `write_audit` plus refill events from earlier steps. Duplicate verify does not add a second ledger posting. |
| Tests | M6.4 SQL/HTTP/concurrency/e2e; M6.6 A/B/F/G/I. |
| Stock | **Only** `verify_stock_receipt` posts accepted cases. Damaged cases excluded. Drafts reserve request capacity, not inventory. |
| Classification | **IMPLEMENTED AND VERIFIED**. Linked receiving does **not** require REF-05/REF-06 first (**OWNER DECISION / REMAINING**). |

## 2. End-to-end scenario results

Disposable prefixes: `m66%` (this phase), plus existing `m62%`–`m65%`. All SQL scenarios roll back.

| ID | Scenario | Result | Evidence |
| --- | --- | --- | --- |
| A | Standard replenishment through verify | **PASS** | M6.6 SQL + HTTP. Six refill events through dispatch. Stock unchanged until GM verify. Accepted posted once. |
| B | Multiple partial deliveries | **PASS** | M6.4 SQL/HTTP/e2e; M6.6 two posted receipts, independent identities, `fully_received` at 18 accepted of 18 requested. |
| C | Hold → revise → resubmit → approve | **PASS** | M6.2 + M6.6 SQL. |
| D | Rejected is terminal | **PASS** | Send and linked create raise `42501`. |
| E | Supplier decline blocks dispatch until audited correction | **PASS** | M6.3 + M6.6 SQL. Approval remains `approved`. |
| F | Damaged cases excluded | **PASS** | Counted 6 / damaged 1 → accepted 5. Snapshot `damaged_cases = 1`. |
| G | Draft reserves; cancel releases | **PASS** | Draft reserved 8 blocks over-limit create; cancel returns reserved to 0; zero stock. |
| H | Historical inactive godown | **PASS** | Get remains; new send and linked create `42501`; then branch reactivated for later statements. |
| I | Unlinked Branch 03 receiving | **PASS** | Unlinked posted receipt does not change refill accepted. M6.4 HTTP + M6.6 SQL. |
| J | Failure recovery | **PASS** | Duplicate verify exact-once; second submit of submitted receipt `42501`; stale versions `PT409` (M6.2); assignment removal denies get and send replay; Admin/Accounts/GM/sales/delivery/monitor denials. |

No scenario failed after the test-only first-pass key-length fix in M6.6 SQL.

## 3. Permission matrix

Live FORCE RLS is on `stock_refill_requests`, lines, events, supplier communications, and dispatches. Authenticated EXECUTE only on trusted RPCs. Authenticated INSERT on refill and stock writer tables is denied.

| Actor | Refill queue/detail/report | Create/submit/send/ack/dispatch | Approve/hold/reject | Linked receiving | Verify receipt |
| --- | --- | --- | --- | --- | --- |
| Accounts `refill.request` | Assigned godown, including inactive | Yes, creator / assigned active | No | No | No |
| Admin `refill.approve` | `branches.access_all` or assignment | No (cannot impersonate send) | Yes | No | No |
| Godown Manager | No | No | No | No create (no `receiving.execute`) | Yes, assigned |
| Store Keeper | No | No | No | Yes, assigned active | No |
| Salesperson | No | No | No | No | No |
| Delivery Person | No | No | No | No | No |
| Monitor-only `operations.monitor` | No | No | No | No | No |

Additional proofs this session:

- Cross-godown get denied.
- Removed assignment denies get and completed-send replay.
- Inactive godown writes denied; historical get remains.
- Direct table mutation denied (M6.2/M6.3 grants).
- Idempotency replay re-checks current authorization.

## 4. Inventory invariants

Compared before refill mutations and after each non-verify step: `stock_balances`, `stock_transactions`, `stock_ledger`, `stock_lots`, `stock_reservations`, `damage_stock_holds`.

| Step | Stock effect |
| --- | --- |
| Create / edit / submit / hold / resubmit / approve / reject | Zero |
| Supplier send / ack / decline / ack correction / dispatch / dispatch correction | Zero |
| Receipt linkage, draft, submit, hold | Zero. Drafts **reserve request capacity** only. |
| `verify_stock_receipt` | Posts **accepted** cases once (`RECEIPT`). Damaged excluded. |
| Duplicate verify | Recovers; no second transaction. |
| Cancelled / unverified receipts | Do not add accepted. |
| Two verified partials | Sum to requested; outstanding 0. |
| Unlinked receiving | Posts its own accepted cases; refill totals unchanged. |

`verify_stock_receipt` still does not mention `stock_refill`. Linked create still locks the refill header `FOR UPDATE` before location grains. Flags remained false after every suite:

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`

No existing stock writer was modified in M6.6.

## 5. Concurrency results

Re-run this session, first pass, all PASS. No deadlocks reported. No duplicate postings.

| Suite | Count |
| --- | --- |
| M6.2 concurrency | 16/16 |
| M6.3 concurrency | 12/12 |
| M6.4 concurrency | 12/12 including concurrent over-limit creates, in-limit partials, verify replay, cancel vs verify, mismatch/status races, linked vs unlinked on the same crate |

Cumulative reservation still includes **every non-cancelled linked receipt**, including drafts. Abandoned drafts therefore occupy requested quantity until an authorized Keeper cancels them. That is an operational consequence, not a defect relative to the approved M6.4 contract. No over-delivery acceptance policy and no automatic draft expiry were added.

## 6. Audit and idempotency findings

Server-authoritative actors and timestamps:

- Refill events: `auth.uid()`, `clock_timestamp()` via `record_refill_event`.
- Send `recorded_at` / ack `acknowledged_recorded_at` / dispatch `recorded_at` are server clocks. Client supplies the attested communication/response/dispatch calendar values only.
- Receipt submit/verify use existing `write_audit`.

Successful same-key replays return the original payload and do **not** insert a second event. Conflicting payloads on a used key raise `23505`. Foreign-actor key reuse is `42501` without disclosure. After assignment or permission removal, completed-send replay is `42501`.

Coverage: create, edit, submit, hold, resubmit, approve, reject, send, ack, decline, ack correction, dispatch, dispatch correction, linked receiving, verification.

## 7. Reporting consistency

Authoritative totals come from `app_private.stock_refill_progress_totals` (used by queue, detail snapshot, reconciliation, report, and export):

| Field | Meaning |
| --- | --- |
| requested | Request lines |
| reserved | Accepted cases on every non-cancelled linked receipt |
| draft_reserved | Accepted cases on draft linked receipts |
| pending | Counted cases on submitted/held receipts |
| accepted | Posted receipts only |
| damaged | Posted damaged cases (never inventory) |
| outstanding | `greatest(requested − accepted, 0)` |
| excess | Historical posted excess only; linked create/update/submit still refuse over-request |

M6.6 SQL/HTTP compared queue item, recon summary, report row, and CSV for the same request number. Values matched. Filters run in SQL after `can_view_refill_at_godown`. Pagination caps remain 25 (queue) and 50 (report). Inactive godowns remain in authorized historical lists. Keepers/GM/sales/delivery cannot export refill rows.

The UI does not invent ledger math. `formatRefillReceivingLabel` only displays server fields.

## 8. Migration replay results

Chronological M6.2–M6.5 files (already applied locally; M6.6 added **no** migration):

| Version | File | Local `schema_migrations.name` |
| --- | --- | --- |
| 20261027120000 | `stock_refill_request_lifecycle.sql` | `stock_refill_request_lifecycle` |
| 20261027133000 | `stock_refill_create_idempotency.sql` | `stock_refill_create_idempotency` |
| 20261027150000 | `stock_refill_supplier_communication.sql` | **empty** |
| 20261027170000 | `stock_refill_receiving_integration.sql` | `stock_refill_receiving_integration` |
| 20261027180000 | `stock_refill_receiving_cumulative_limit.sql` | `stock_refill_receiving_cumulative_limit` |
| 20261027190000 | `stock_refill_ui_reporting.sql` | `stock_refill_ui_reporting` |

Live function checks vs files: FORCE RLS present; `verify_stock_receipt` has no refill mention; linked header lock is `FOR UPDATE`; EXECUTE granted to `authenticated` only.

**Isolated empty-database migration replay was not run.** Resetting shared Docker `supabase_db_sherlyos` is forbidden. No throwaway empty Postgres with the full Supabase `auth`/extensions catalog was available in this session.

That is an **explicit cloud-migration blocker**. This document does **not** claim migration-chain validation passed. Applied migrations were not rewritten. The empty 150000 name is bookkeeping only.

## 9. Test counts

First-pass vs final:

| Suite | First pass | Final |
| --- | --- | --- |
| M6.6 SQL `phase_m6_6_module_closure.sql` | FAIL — verify key `m66-v1` shorter than 8 characters (test-only) | PASS after key rename; rolled back |
| M6.2 SQL | PASS | PASS |
| M6.3 SQL | PASS | PASS |
| M6.4 SQL | PASS | PASS |
| M6.5 SQL | PASS | PASS |
| Branch 03 `phase_3_1_stock_receiving.sql` | PASS | PASS |
| M5.3 `phase_m5_3_damage_stock_isolation.sql` | PASS | PASS |
| M6.2 HTTP | 16/16 | 16/16 |
| M6.3 HTTP | 12/12 | 12/12 |
| M6.4 HTTP | 10/10 | 10/10 |
| M6.5 HTTP | 8/8 | 8/8 |
| M6.6 HTTP | 9/9 | 9/9 |
| M6.2 concurrency | 16/16 | 16/16 |
| M6.3 concurrency | 12/12 | 12/12 |
| M6.4 concurrency | 12/12 | 12/12 |
| Vitest | **212/212** (34 files) | same |
| Playwright | **88/88** | same |
| `npm run typecheck` | PASS | PASS |
| `npm run lint` (oxlint) | exit 0; 4 pre-existing warnings outside M6 | same |
| `npm run build` | PASS | PASS |

Skipped tests were not counted as passing. Shared-database suites ran sequentially.

Playwright used existing `playwright.config.ts`: Vite `webServer` on `http://127.0.0.1:4173`, `--mode m1s2`, Chromium `devices["Desktop Chrome"]`, `workers: 1`.

## 10. Remaining limitations

1. REF-01 has no automated reorder-level detector.
2. REF-05/REF-06 are manual attestations. SherlysOS does not message suppliers.
3. Original send channel/time/reference cannot be corrected (send row is immutable).
4. Linked receiving does not require send or dispatch first.
5. Approved requests are never auto-closed after full receipt.
6. Abandoned drafts reserve remaining requested quantity until cancelled. There is no expiry job.
7. Over-delivery on a linked receipt is refused. There is no exception/acceptance workflow.
8. Accounts cannot open receipt detail (number only).
9. No in-transit supplier stock, financial settlement, or supplier credit note.
10. `schema_migrations` row `20261027150000` has an empty `name` (local bookkeeping).

## 11. Explicit production blockers

These keep the module **DEVELOPMENT COMPLETE** and **not PRODUCTION READY**:

1. Isolated empty-database replay of M6.2–M6.5 (and prior) migrations has **not** been proven. Do not treat local Docker history as cloud-migration validation.
2. No cloud Supabase migration.
3. No Netlify / production deploy.
4. Cutover flags must stay false until a later approved phase: `damage.stock_hold_ready`, `stock.lots.dual_write_enabled`, `stock.lots.aggregate_only_blocked`.
5. Local tests on disposable fixtures are not a production cutover.
6. Owner Git checkpoint is still required; this phase did not commit.

## 12. M7 handoff

M6 Stock Refill (Branch 05) is closed for **development** under the approved contract.

Suggested M7 / later owner questions — do not implement from this document:

- Whether send and dispatch should be required before linked receiving.
- Whether abandoned draft reservations should expire, and who may cancel them.
- When an authorized person may mark a request complete.
- Whether Accounts should get read-only receipt detail.
- Automated reorder levels (REF-01).
- Send-field correction policy.
- Over-delivery exception / excess review workflow.
- Supplier messaging, credits, and financial settlement.
- Isolated migration replay on an empty catalog before any cloud apply.
- Lot dual-write and damage isolation activation remain **out of refill scope**.

M7 must not invent a second stock writer. Accepted inventory remains `verify_stock_receipt` only.

---

**Verdict for owner review:** M6 DEVELOPMENT CLOSURE RECOMMENDED.  
**Not** production ready.
