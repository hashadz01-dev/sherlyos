# Phase 3.3 stock discrepancy and adjustment approval

Status: IMPLEMENTED LOCALLY — COMMITTED — DEVELOPMENT DEPLOYMENT PENDING.

Decisions A through K below are owner-approved. The exceptional threshold is 10 whole carton cases per line. Absolute quantity greater than 10 makes the entire request exceptional. 10 is ordinary. The placeholder 50 is not used.

Phase 3.3 supports ordinary and exceptional stock adjustments. Reversal functionality is not available. `compensates_request_id` is kept for a later phase and must stay null. A non-null value is rejected on create, update, submit, approve, and post. Existing posted ledger entries stay immutable. A reversal workflow needs a separate approved design and implementation.

This commit follows `962de31fe577f397a7784db5d35f3615b028c17a`. Development Supabase `ypkfondrkhkydkgovwup` still ends at `20261015200000`. Phase 3.2 migration `20261015220000_daily_stock_verification.sql` is committed and is not applied there. Cloud verification has not passed.

`reference/Sherlys_Distribution_Agents_BPM.pdf` is not in this repository. BPM comparisons below use the mappings already written in the phase plans. Where the PDF could not be re-read, that limit is stated.

## Executive overview

Phase 3.1 posts accepted receipt cases into the append-only ledger. Phase 3.2 freezes a crate snapshot, records a physical count, requires a recount and Godown Manager review for a variance, and can close with `variance_recorded` or `correction_requested`. Closure does not change `stock_ledger` or `stock_balances`. `correction_request_status = 'requested'` is only a flag on the closed verification.

Phase 3.3 is the later, separate workflow that may turn a documented discrepancy into an authorized ledger posting. It must not run inside `close_stock_verification`.

The permission catalog already exists and was not widened by later migrations:

| Permission | Granted to |
| --- | --- |
| `stock.discrepancy.report` | Godown Manager |
| `stock.adjustment.request` | Godown Manager |
| `stock.adjustment.post` | Godown Manager |
| `stock.adjustment.approve_exceptional` | Admin |

`app_configuration` stores `stock.adjustment.exceptional_absolute_units` as `50` and `stock.adjustment.exceptional_requires_admin` as `true`. The migration comment says `50` is a provisional placeholder, not an approved rule. `docs/access-control.md` says the same.

## Existing system dependencies

| Step | What exists now |
| --- | --- |
| Opening stock | `post_opening_stock`. Admin, `stock.opening.post`. One opening per product and crate. Positive ledger entry. |
| Stock receiving | Draft, submit, verify, post. Posted rows are `RECEIPT`. Damaged cases stay off the ledger. Posted receipts are immutable. |
| Inventory ledger | `stock_transactions`, `stock_ledger`, `stock_balances`. Types are only `OPENING_STOCK`, `CRATE_TRANSFER`, and `RECEIPT`. Update and delete are rejected. Balances are a same-transaction projection and cannot go below zero. |
| Crate transfer | Same godown only. Two ledger rows that net to zero. |
| Daily verification | Local and committed. Not on the development database. Snapshot ledger-id set, recount, review, private photo, close without a stock change. |
| Discrepancy identification | On a verification line: `final_variance_cases`, `discrepancy_status` of `uncounted`, `counted`, `recount_required`, or `reviewed`, and a reason. This does not create an adjustment request. |
| Recount and Godown Manager review | Required before a variance can close. |
| Adjustment request, approval, and posting | Not implemented. No adjustment table. No `ADJUSTMENT` transaction type. |

`docs/access-control.md` still says the access-control migration has not been applied and that the app does not read roles. Both statements are stale. The migration is on the development project, and the app gates routes with permissions. The permission matrix and the provisional `50` in that document still match the SQL.

`docs/phase-2c-master-data-plan.md` sketched `stock_adjustment_requests` against an earlier `stock_movements` idea. The live ledger is `stock_transactions` plus `stock_ledger`. Phase 3.3 should follow the live ledger, not that sketch.

## Proposed workflow

This sequence is a proposal. Steps that depend on an open decision stay blocked until that decision is approved.

1. A closed verification already holds the physical count, recount, review, photo, and variance. Phase 3.3 reads that record. It does not rewrite it.
2. A Godown Manager creates a draft adjustment request for one assigned godown, referencing that closed verification.
3. Each request line references one verification line whose reviewed variance is not zero. The requested carton quantity is copied from the database, not typed as a new expected balance.
4. Submit freezes the requested quantities and computes whether the request is exceptional. The client does not set that flag.
5. Ordinary and exceptional approval follow the decision table. Approval does not post stock.
6. A separate post step, in one database transaction, writes one new `stock_transactions` row and one signed `stock_ledger` row per line, then updates `stock_balances` from the ledger sum.
7. Rejection and return append history. They do not update or delete a posted ledger row. A reversal is not part of this phase.

`variance_recorded` and `correction_requested` both remain non-posting closure results. Only an approved and posted adjustment changes stock.

## Business decision table

| Decision | What is already in the database or docs | Proposal for this phase | Status |
| --- | --- | --- | --- |
| A. Who may request | `stock.adjustment.request` is Godown Manager only. Store Keeper can count and assist photos, not request. | Only an assigned Godown Manager may draft and submit. No other role drafts or submits. | **Requires approval.** The grant exists; this phase has not been authorized to use it. |
| B. Ordinary approval | Docs say a Godown Manager posts a routine adjustment through the workflow. They do not name a second approver. The same role holds request and post. | Do not treat self-approval as authorized. Prefer a posted-by user different from the requester when a second assigned Godown Manager exists. A single-manager godown needs an explicit owner choice: allow that manager to approve their own routine request, or require Admin for every adjustment. | **Requires approval.** |
| C. Exceptional threshold | Seed value `50`. Config key is absolute units. Admin flag defaults to true. INR is deferred until valuation exists. | Measure each line's absolute requested cases. If any line is above the approved number, the whole request is exceptional. Do not use the net of positives and negatives. Do not use value in this phase. Do not implement `50` as the rule. | **Requires approval** of both the number and the per-line rule. |
| D. Admin authority | Admin has `stock.adjustment.approve_exceptional`, `operations.monitor`, `stock.read`, and `branches.access_all`. Admin does not have `stock.adjustment.request` or `stock.adjustment.post`. | Admin may approve or reject an exceptional request and may return it for correction. Admin does not post and does not override an ordinary request by posting it. Posting stays `stock.adjustment.post`. | **Requires approval.** Matches current grants; not yet a Phase 3.3 build authorization. |
| E. Verification prerequisite | Phase 3.2 can close with a variance and no stock change. Damage posting is not built. | Every Phase 3.3 line references one closed verification line that was recounted, reviewed, and has a non-zero final variance. Damage, breakage, data-entry errors, and emergency corrections outside a verification are out of this phase. | **Requires approval.** |
| F. Movement after the snapshot | Verification already records post-snapshot ledger ids and blocks close until they are acknowledged. Later receipts and transfers remain allowed. | Submit stores the verification variance. Post locks the current balance and compares ledger rows after close. If the posted quantity would go negative, or the gap no longer equals the approved quantity, the request becomes stale and cannot post until it is reviewed again. One verification line can be posted once. | **Requires approval.** |
| G. Rejection and resubmission | No request table exists. Verification history is immutable after close. | A draft can be edited. A submitted request cannot. Return for correction unlocks the draft and appends an event. Reject is terminal. A replacement is a new request. Posted rows are never edited. | **Requires approval.** |
| H. Partial approval | Not specified. | The approver accepts or returns the whole request. Approving fewer cases than the reviewed variance is out of this phase. | **Requires approval.** |
| I. Evidence | Closure already requires one finalized photo in `stock-verification-evidence`. | The request must cite that closed verification. Reason and a note are required. An extra photo, a separate document, and a coded reason list are not required unless the owner adds them. Admin writes an approval note when acting. | **Requires approval.** |
| J. Reversal | Ledger triggers reject update and delete. | A wrong posting is corrected by a new adjustment request that references the original transaction and posts the opposite signed quantity, under the same approval rules. | **Requires approval.** |
| K. Posting timing | The access-control contract describes one posting function, not an automatic post. | Approval does not post. An assigned Godown Manager with `stock.adjustment.post` posts in a second action. No expiry window is proposed until the owner sets one. A stale balance check is mandatory at post. | **Requires approval.** |

Self-approval risk, if Decision B allows the requester to approve and post: one person can confirm their own count and change stock, including a shortage that hides a loss. Separation is stronger when a second Godown Manager approves a routine request and Admin approves an exceptional one. The existing grants do not by themselves create that second person.

## Proposed schema

No migration is created here. Names can change before implementation. Reuse `stock_verifications`, `stock_verification_lines`, `stock_verification_evidence`, `stock_transactions`, `stock_ledger`, `stock_balances`, `audit_logs`, and `app_configuration`.

Do not add a second balance table. Do not add `stock_adjustment_approvals` as a mutable current-state table. Approval is an append-only event. Do not add `stock_adjustment_evidence` unless Decision I requires a new file. The verification photo remains the evidence.

### `stock_adjustment_requests`

Purpose: one godown's request to post reviewed variances from one closed verification.

| Column | Type | Rule |
| --- | --- | --- |
| `id` | uuid | Primary key. |
| `request_number` | text | Unique. Server-issued. |
| `godown_id` | uuid | Foreign key to `branches`. |
| `verification_id` | uuid | Foreign key to `stock_verifications`. Must be `closed`. |
| `status` | text | `draft`, `submitted`, `returned`, `approved`, `rejected`, `posted`, `stale`. |
| `exceptional` | boolean | Set by the server at submit. |
| `requested_by` | uuid | Profile. |
| `submitted_at` | timestamptz | Null until submit. |
| `version` | integer | Incremented on each accepted change. Stale calls fail. |
| `idempotency_key` | text | Unique. |
| `created_at`, `updated_at` | timestamptz | Server clocks. |

Checks: a rejected or posted request cannot return to draft. `exceptional` cannot be supplied by the client. Indexes: `(godown_id, created_at desc)`, unique `(verification_id)` where `status` not in (`rejected`, `posted`) so one open request per verification. **The one-open-request rule requires approval** if the owner wants several requests per verification.

RLS: enable and force. `authenticated` select only when the caller can view that godown. No client insert, update, or delete policy.

Immutability: posted and rejected rows do not change except a status transition that the posting function performs from `approved` to `posted` or to `stale`. Line quantities do not change after submit except through return-to-draft.

### `stock_adjustment_lines`

Purpose: one crate and product, tied to one verification line.

| Column | Type | Rule |
| --- | --- | --- |
| `id` | uuid | Primary key. |
| `request_id` | uuid | Foreign key. |
| `verification_line_id` | uuid | Foreign key. Unique among non-rejected requests. |
| `crate_id`, `product_id` | uuid | Copied from the verification line and checked equal. |
| `variance_cases` | integer | Copied from `final_variance_cases` at submit. Not zero. |
| `requested_cases` | integer | Same sign as the variance. Whole cases. Not zero. |
| `posted_transaction_id` | uuid | Null until post. Unique when set. |

`requested_cases` is the ledger delta: positive adds cases, negative removes them. A partial quantity different from the variance is not allowed under Decision H.

Unique `(request_id, verification_line_id)`. Unique `verification_line_id` where the parent is not rejected, so the same discrepancy cannot be posted twice.

### `stock_adjustment_events`

Purpose: append-only history of submit, return, approve, reject, stale, and post.

Columns: `id`, `request_id`, `event_type`, `actor_id`, `from_status`, `to_status`, `note`, `request_version`, `created_at`. No update or delete trigger, same pattern as the ledger. A note is required for return, reject, and exceptional approval.

RLS: select with the request. Inserts only from the security-definer functions.

## Ledger integration

Posting stays inside one function. It does not update an old ledger row, delete history, or set `stock_balances` by hand.

Proposed transaction type, **not approved yet**: `ADJUSTMENT`.

If that type is approved, the next migration, and only that migration, would:

- Extend `stock_transactions_type_check` and `stock_transactions_shape_check` with `ADJUSTMENT`: no receipt, one crate in `destination_crate_id`, `source_crate_id` null, and a new nullable `adjustment_line_id`.
- Allow `stock_transactions.quantity` to stay a positive absolute count, with the sign stored only on `stock_ledger.quantity`.
- Extend `assert_stock_transaction_complete` so an adjustment has exactly one ledger row whose signed quantity equals the approved line and is not zero.
- Add a unique index on `adjustment_line_id`.
- Leave `OPENING_STOCK`, `CRATE_TRANSFER`, and `RECEIPT` checks unchanged.

The posting function locks the request row, then zones by id, then crates by id, then the balance row. That matches receiving and transfers. It does not lock products before zones. It inserts the transaction and the signed ledger row, lets the existing balance trigger check the ledger sum, and refuses a negative result. The same idempotency key posts once.

A positive variance posts a positive quantity. A negative variance posts a negative quantity. Concurrent receipts and transfers either commit before the lock and are visible to the stale check, or wait and commit after the adjustment.

`close_stock_verification` stays free of ledger writes. `correction_request_status` is not an approval.

## Permission matrix

Inactive profiles already fail `has_permission`. Frontend checks are not the boundary. Godown scope uses `can_work_at_branch`, which is true for an active assignment or for `branches.access_all`.

| Action | Admin | Godown Manager | Store Keeper | Accounts | Salesperson | Delivery Person |
| --- | --- | --- | --- | --- | --- | --- |
| View requests for a visible godown | yes, `operations.monitor` or `stock.read` with access | yes, assigned godown | yes, assigned godown, read only | yes, assigned godown, read only | no | no |
| Create or edit a draft | no | yes, `stock.adjustment.request` | no | no | no | no |
| Submit | no | yes, `stock.adjustment.request` | no | no | no | no |
| Report a discrepancy on a verification | no | yes, already `stock.discrepancy.report` | no | no | no | no |
| Approve ordinary | no, unless Decision B assigns it | only if Decision B allows `stock.adjustment.post` | no | no | no | no |
| Approve exceptional | yes, `stock.adjustment.approve_exceptional` | no | no | no | no | no |
| Reject or return | exceptional: Admin; ordinary: only the role Decision B names | same | no | no | no | no |
| Post | no | yes, `stock.adjustment.post`, after approval | no | no | no | no |
| View audit and verification evidence | yes | yes, assigned | read-only if they can already view the verification | read-only stock only, not the photo unless already allowed | no | no |

Do not grant Admin `stock.adjustment.post` in this phase. Do not grant Store Keeper request or post.

## API design

All functions are `security definer` with `search_path` empty. Execute is revoked from `public`, `anon`, and `service_role`, and granted to `authenticated`. Each call checks the permission and `can_work_at_branch`. Clients do not insert into the ledger.

| RPC | Who | Transaction | Failure |
| --- | --- | --- | --- |
| `list_stock_adjustments` | View matrix | Read only | Other godowns are omitted, not errored, except a direct id. |
| `get_stock_adjustment` | View matrix | Read only | Missing or out of scope is `not authorized`. |
| `create_stock_adjustment` | `stock.adjustment.request` | Inserts a draft for one closed verification | Open verification, zero variance, wrong godown. |
| `set_stock_adjustment_lines` | Requester, draft or returned | Replaces draft lines inside the transaction | Line outside the verification, zero or mismatched variance. |
| `submit_stock_adjustment` | Requester | Locks the request, freezes lines, sets exceptional from configuration | Empty lines, stale version. |
| `return_stock_adjustment` | Approver for that class | Appends an event, status `returned` | Posted, rejected, or wrong role. |
| `reject_stock_adjustment` | Approver for that class | Terminal event | Same. |
| `approve_stock_adjustment` | Ordinary or exceptional approver, not both in one shortcut | Locks the request. Does not post. Idempotent for the same version | Exceptional request without Admin. Stale version. |
| `post_stock_adjustment` | `stock.adjustment.post` | One transaction, idempotency key, lock order above | Not approved, stale balance, negative result, duplicate line, inactive caller. |
| `list_stock_adjustment_events` | Same view rule as the request | Read only | Out of scope. |

Idempotency: create and post take a client key stored uniquely. A repeat with the same key and same fingerprint returns the first result. A repeat with a different fingerprint fails.

## UI architecture

Follow the verification screens: page header, status badge, empty and error states, and a card list below the `md` breakpoint so a 390px width does not clip a wide table.

| Screen | Route | Contents |
| --- | --- | --- |
| Discrepancy queue | `/stock-adjustments` | Closed verifications with a non-zero variance and no posted adjustment. Cards at 390px. |
| Request list | same page, second section | Status, godown, verification number, exceptional badge, requester. |
| New request | `/stock-adjustments/new` | Godown Manager only. Selects one closed verification. Lines come from the server. |
| Detail | `/stock-adjustments/:requestId` | Lines, variance, evidence link, event history, role actions. |
| Approval | on the detail page | Approve, reject, and return each open a dialog that requires a note. |
| Post confirmation | on the detail page | States that stock will change by the approved quantities and names the godown. |
| History | on the detail page | Append-only events. Posted requests are read-only. |
| Exceptional queue | filter on the list, not a second module | Visible to Admin. Ordinary managers do not see an approve action on an exceptional request. |

Validation stays in the database. The form disables actions the role cannot call. Empty state: no closed variances. Error state: authorization and stale-version messages from the RPC.

## Security and concurrency

| Risk | Control |
| --- | --- |
| Two managers post one request | Lock the request row. Unique idempotency key. Status must be `approved`. |
| Approve and reject together | Same row lock. Version check. One event wins. |
| Receipt or transfer during post | Zone, then crate, then balance locks, shared with Phase 3.1 and Phase 3.2 close. |
| Movement after approval | Post recomputes the balance. A changed gap marks the request `stale` and does not post. |
| Product, crate, or zone deactivation | Post refuses an inactive crate, zone, or product. Deactivation still locks open verifications first; a posted adjustment is not an open verification. |
| Permission removed mid-request | Every RPC checks the active profile and permission again. |
| Cross-godown | `can_work_at_branch` on the verification godown. Crate must belong to that godown. |
| One discrepancy, two requests | Unique verification line among requests that are not rejected. |
| Stale approval after an edit | `version` on the request. Approval stores the version it saw. |
| Negative adjustment larger than stock | Balance check constraint and the ledger-sum trigger. |
| Direct table writes | No insert, update, or delete grants or policies for `authenticated`. |
| Storage policy lock | Phase 3.3 does not create a storage policy unless Decision I adds a new bucket. That avoids the Phase 3.2 `storage.objects` exclusive lock during this migration. |

Phase 3.2 deactivation locks open verification rows before zone locks. Adjustment posting must not take those verification locks before zones, or it can deadlock with deactivation. A closed verification row can be read without `FOR UPDATE` because close already made it immutable.

## Test strategy

Local first, after Phase 3.2 is present on the local database.

- SQL: role denial, inactive user, cross-godown, closed-verification requirement, recount and review required, zero variance rejected, duplicate line rejected, exceptional flag not client-set, partial quantity rejected if Decision H stays closed.
- Positive and negative post, negative post that would pass below zero, duplicate post, idempotent retry.
- Receipt and transfer on both sides of the adjustment lock. Append-only triggers still reject an update or delete.
- Direct inserts into the new tables and into `stock_ledger` denied for `authenticated`.
- Stale post after a receipt changes the crate.
- JWT sessions for Admin, Godown Manager, Store Keeper, Accounts, Salesperson, Delivery Person, an inactive user, and a second godown.
- UI: list, create, detail, denied routes, and a 390px card layout.
- Development-cloud checks only after a separate deploy approval, and only after Phase 3.2 is on that database.

## Deployment dependencies

Phase 3.2 must be applied and verified on development before a Phase 3.3 migration can be applied there. The verification tables and the closed-verification rule do not exist on `ypkfondrkhkydkgovwup` yet. The Phase 3.2 blocker remains an `AccessShareLock` on `storage.objects` that conflicts with `CREATE POLICY`.

Safe order:

1. Approve or reject the decision table in this document.
2. Clear the Phase 3.2 lock and deploy `20261015220000` to development after a separate approval.
3. Finish Phase 3.2 cloud JWT, storage, and browser checks.
4. Implement Phase 3.3 locally. Do not point a migration at the development project.
5. Run local SQL, concurrency, permission, and UI tests.
6. Review deployment readiness.
7. Deploy Phase 3.3 to development only with a new approval.
8. Verify ledger totals, then stop before Git and production until that work is accepted.

Local planning and, after the decisions are approved, local implementation may proceed while the development database is still on Phase 3.1.

## Implementation milestones

1. Owner decision on A through K.
2. Phase 3.2 development deployment and verification.
3. Local migration and posting function. No new transaction type until Decision K's ledger shape is approved.
4. RLS, grants, and RPC tests.
5. Screens and route gates.
6. Concurrency tests against receiving, transfer, and verification deactivation.
7. Separate development deploy.

## Owner decisions

A–K are approved. The requester cannot approve. The requester may post after another eligible person approves. The threshold is 10 whole cases per line. A line above 10 makes the whole request exceptional. Every line needs a closed, recounted, reviewed, non-zero verification line and the finalized photo. Approvers cannot change quantities. Returned requests can be revised. Rejected requests stay closed. Approval does not post and does not expire. The deployed access-control migration still seeds 50. The local Phase 3.3 migration sets 10.

## Local verification (2026-10-16)

Admin fallback SQL passed and rolled back. One eligible manager submitted an ordinary request. Self-approval, an inactive manager, and a wrong-godown manager were denied. Admin approved and could not post. The manager posted, and the soap balance became 4. After a second eligible manager was assigned, Admin was denied with `not authorized`. The database checks the post permission before the longer fallback message, so that longer message is not what Admin sees.

Concurrency passed in independent sessions: two posts, same-key retry, different-key denial, approval versus rejection, approval versus return, posting versus return, posting versus rejection, receiving, transfer, product deactivation, crate deactivation, zone deactivation, duplicate verification-line claims, and an oversized transfer. No negative balances and no extra adjustment transactions remained. Cleanup exit code was 0.

Posting locks the request, then the line products, then zones and crates, then balance rows. The product lock is first so a receipt, which locks products before locations, does not deadlock with the post. A transfer waits on the location locks the post already holds.

Any later ledger row for the same crate and product, including a legitimate receipt or transfer and including a movement that nets back to the old quantity, makes the request stale. The approved quantity is not changed. A new verification is required. A movement of a different product does not affect the line.

Compensation references are closed. A null reference follows the ordinary adjustment flow. A non-null `compensates_request_id` is rejected by the request check, the write guard, and create, line revision, submit, approve, return, reject, and post. The value is not cleared and turned into an ordinary adjustment. Direct inserts and updates cannot set it. The column remains only so a future migration can use it after a separate reversal design is approved. Posted ledger rows and audit events stay unchanged when a compensation attempt is rejected. Phase 3.2 development deployment remains pending.

Regression runners for Phase 2C.3, 3.1, 3.2, and 3.3 passed, including the compensation security SQL. Typecheck, lint, 48 unit tests, build, local database lint, and advisors passed. Append-only triggers stayed enabled. No phase fixtures or negative balances remained.

Browser checks used local Vite on port 5177. Admin saw the list and exceptional approval, and was denied creation and ordinary approval while another manager existed. The requesting manager created a draft from the server variance, saw submit, and had to confirm before posting. The second manager could approve the ordinary request. Store Keeper and Accounts could read history and could not create, approve, or post. Salesperson and Delivery Person had no Adjustments link, and the list, new, and detail routes were denied. At 390px the list cards were visible, the table wrapper was hidden, and `scrollWidth` was 390 on the list and detail. No console errors were recorded on the checked pages. The disposable users were removed.

## Local implementation

The local migration updates `stock.adjustment.exceptional_absolute_units` from the placeholder 50 to the approved 10. It adds `stock_adjustment_requests`, `stock_adjustment_lines`, and append-only `stock_adjustment_events`, and extends the ledger with `ADJUSTMENT` without changing opening stock, transfer, or receipt behavior.

Posting locks the request, then zones and crates through `prepare_stock_locations`, then balance rows. Any ledger row for that crate and product outside the verification snapshot and acknowledged ids is stale. The approved quantity is not rewritten. A valid variance cannot reduce stock below the recounted physical quantity, so a non-stale post cannot create a negative balance. A later movement is rejected as stale before the balance changes.

Ordinary approval requires a different assigned Godown Manager. Admin approves exceptional requests, and approves ordinary requests only when no other eligible manager exists. The requester cannot approve. Admin cannot post.

`compensates_request_id` has a check that it is null. The shared write guard rejects a non-null value before any other write. The request functions raise `compensation is not available` and do not continue. There is no reversal function.
