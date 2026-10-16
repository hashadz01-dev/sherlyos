# Phase 3.2 daily stock verification

Status: IMPLEMENTED LOCALLY — COMMITTED — DEVELOPMENT DEPLOYMENT PENDING.

Phase 3.2 is implemented locally and the local tests passed. Migration `supabase/migrations/20261015220000_daily_stock_verification.sql` is not applied to development Supabase `ypkfondrkhkydkgovwup`. Remote history still ends at `20261015200000`. The previous cloud push rolled back. The current blocker is a conflicting lock on `storage.objects`. Development JWT, row-level security, and cloud Storage verification remain pending. Production deployment has not been performed. Phase 3.3 stock adjustment approval has not started.

## Development deployment timeout

On 2026-10-16, `npx supabase db push --linked` (CLI 2.121.0) failed while applying this migration to `ypkfondrkhkydkgovwup`.

| Item | Result |
| --- | --- |
| Error | SQLSTATE 57014, canceling statement due to statement timeout |
| CLI statement | 65, `create policy stock_verification_evidence_insert on storage.objects` |
| History after failure | Still ends at `20261015200000` |
| Phase 3.2 objects | None. No verification tables, no `stock-verification-evidence` bucket, no storage policies |
| Ledger triggers | `stock_balances_match_ledger`, `stock_ledger_append_only`, and `stock_transactions_append_only` remain enabled |

`app_private.can_store_verification_photo(object_name text)` is created earlier in the same file. It is `security definer` with `search_path` empty. The insert policy allows `authenticated` only when the object name matches a pending evidence row, the uploader is the caller, the verification is open, the caller has `stock.verify` or `stock.count_assist`, and `can_work_at_branch` accepts that godown. There is no `anon` or `public` storage policy, and no authenticated update or delete policy. The policy stays as written.

PostgreSQL 17 takes `AccessExclusiveLock` for `CREATE POLICY`. That conflicts with `AccessShareLock` and `RowExclusiveLock`. Locally, an unblocked policy completed in about 400 ms. With either conflicting lock held, a 4 second `statement_timeout` produced SQLSTATE 57014. The linked query session shows `statement_timeout` of 2 minutes from the configuration file, `lock_timeout` 0, and `transaction_timeout` 0. The policy check itself is not expensive.

A `pg_dump` session was idle in a transaction during diagnosis and held `AccessShareLock` on `storage.objects`. That session was left running. It started after the failed push, so the original waiter is no longer visible. The same lock would block the next push until the dump transaction ends.

Reordering the migration would not release another session's lock. The file was not edited. Do not raise the database timeout, disable RLS, or remove the policy.

A later lock check, after approval to retry only if the table was clear, found the same `pg_dump` session still idle in a transaction and still holding `AccessShareLock` on `storage.objects`. The push was not started. No session was terminated. The pre-push backup still matches the remote baseline.

## BPM mapping

Branch 04 of the distribution BPM is the daily stock verification path.

| Step | What this phase does |
| --- | --- |
| DSV-01 | Godown Manager selects one assigned godown, one or more zones, and one or more crates in that godown. |
| DSV-02 | Godown Manager or assigned Store Keeper enters physical whole-case counts. |
| DSV-03 | The database compares the count with frozen expected stock plus later ledger movement. |
| DSV-04 | Godown Manager reports a discrepancy. This also requires `stock.discrepancy.report`. |
| DSV-05 | The verification stores the snapshot, lines, recounts, review, and photo evidence. |
| DSV-06 | A variance is recounted and reviewed before closure. |
| DSV-07 | The closed verification can record that a correction was requested. It does not post an adjustment. |

## Approved business rules

- A missing verification day is informational. Receiving, crate transfers, and other approved operations continue. There is no stock lock and no cutoff.
- One godown can have only one verification whose status is not `closed`. The partial unique index `stock_verifications_one_open_godown` enforces that. Closed verifications can repeat. There is no cancel or reopen action.
- At start, every positive `stock_balances` row in the selected crates becomes a line. A counter may add an active product found in a selected crate with `expected_cases` fixed at 0. The same verification, crate, and product cannot appear twice.
- Expected cases are copied from `stock_balances` inside the start transaction and are not rewritten when counts change.
- Ledger movement after the snapshot is detected from ledger ids that were not copied into `stock_verification_snapshot_entries`. Opposing quantities both remain visible when their net is zero.
- A non-zero final variance needs a recount before closure. The first count stays on the line. Recounts are also appended to `stock_verification_counts`.
- Godown Manager and assigned Store Keeper may recount, including the person who entered the first count. Only the Godown Manager reviews and closes.
- Closure is allowed with a remaining variance after recount and review. Results are `matched`, `variance_recorded`, and `correction_requested`. None of them change `stock_ledger` or `stock_balances`.
- At least one finalized photo is required. An upload that has not been finalized does not satisfy closure.
- Closed headers, lines, recounts, and evidence cannot be edited or deleted. Photos cannot be replaced or deleted after closure.
- If a selected crate, zone, or product becomes inactive, the line stays. The Godown Manager records a review reason before closure. The master record is not reactivated.

## Lifecycle

Start creates status `counting`. Submit moves it to `submitted` only when every line has a count. Requesting a recount moves it to `recount`. A completed discrepancy review moves it to `review` unless another line still has a recount request. Close is accepted from `submitted`, `recount`, or `review`.

`matched` is accepted only when every final variance is zero. `variance_recorded` and `correction_requested` are accepted only when a variance remains. `correction_requested` sets `correction_request_status` to `requested`.

## Database

| Table | Role |
| --- | --- |
| `stock_verifications` | Header, snapshot time, ledger boundary text `ledger-id-set`, status, and closure. |
| `stock_verification_scopes` | Selected zone and crate. A crate cannot be selected twice. |
| `stock_verification_lines` | Frozen expected cases, first count, latest recount, movement acknowledgement, and review. |
| `stock_verification_counts` | Append-only initial and recount events. |
| `stock_verification_snapshot_entries` | Ledger ids visible for the selected crates when the snapshot was taken. |
| `stock_verification_evidence` | Private storage path, MIME type, size, uploader, and finalization time. |

Row level security is enabled and forced. `authenticated` can select rows for a godown the caller may view. There are no client insert, update, or delete policies. Mutations go through the RPCs.

Quantities are whole cases from 0 through 1,000,000. A missing count stays null and is not treated as zero.

## Snapshot and movement

`start_stock_verification` locks zones and crates through `prepare_stock_locations`, then locks the selected balance rows. It does not lock products before zones, so it keeps the posting lock order used by opening stock and crate transfers. After those locks it copies the currently visible ledger ids for the selected crates.

A later movement for a line is a `stock_ledger` row for that crate and product whose id is absent from the snapshot set. `reconciled_expected_cases` is `expected_cases` plus the sum of those quantities. `final_variance_cases` is the recount, or the first count when there is no recount, minus the reconciled expected quantity.

Close rejects a line when the acknowledged ledger ids differ from the ids visible at close. A zero-variance movement can be acknowledged by review. A non-zero variance must already have been acknowledged by the recount. A ledger row for a selected crate and a product with no line also blocks closure until that product is added.

Close locks the verification row, then the selected zones and crates, then the lines. It does not lock products. Receipt posting locks a product before the destination zone, and a transfer can need a product share lock after it holds zones. Taking product locks inside close deadlocks with those postings.

Product, crate, and zone deactivation take a different lock before they change `is_active`. After the permission and existence checks, each function locks every open verification that references the object, ordered by verification id. Crate and zone deactivation do that before they lock the zone, crate, or balance rows. Counting does not hold any of these locks.

The resulting order is fixed:

1. If deactivation locks the open verification first, it changes `is_active` and commits. Close waits, then sees the inactive object and requires a current manager review.
2. If close locks the verification first, it reads the still-active flag and can commit. Deactivation waits, then changes `is_active` after the verification is closed. The closed record is not reopened, and no review is added after the fact. That later deactivation was not visible to the closure transaction.
3. A product with no open verification line locks no verification row, so its deactivation does not wait for an unrelated count.
4. A receipt or transfer that needs a selected zone waits while close holds that zone. It posts after close and is not part of the closed movement set. A receipt or transfer that commits before close locks the zone is visible and blocks close until it is acknowledged.

A review stores the active flags it observed. Close rejects the review when any current flag differs, including a deactivation that commits after the review and before close. Snapshot rows, verification lines, and stock balances are left unchanged. Nothing is reactivated automatically.

## Photos

Bucket `stock-verification-evidence` is private, limited to 10 MB, and allows JPEG, PNG, and WebP. The client creates a pending evidence row and receives the server path `{verification}/{evidence}`. Storage insert is allowed only for that pending row, the uploading user, an open verification, and `stock.verify` or `stock.count_assist` at that godown. Finalization checks storage metadata, magic bytes, and the MD5 etag. Signed download is allowed only after that check and the same view rule as the verification. There is no public URL and no authenticated delete or update policy.

## Permissions

Existing role grants are unchanged.

| Role | Access |
| --- | --- |
| Godown Manager | `stock.verify` and `stock.discrepancy.report`. Starts, counts, submits, requests recounts, reviews, attaches photos, and closes assigned-godown verifications. |
| Store Keeper | `stock.count_assist`. Views assigned verifications, saves counts and requested recounts, and attaches photos. Cannot start, submit, report, review, or close. |
| Admin | `operations.monitor`. Reads verifications and finalized photos. Cannot mutate them. |
| Accounts, Salesperson, Delivery Person | No verification permission. Navigation and direct routes are denied. |
| Inactive user | No access. |

## Screens

`/stock-verification` lists verifications and shows a missing-day note. Below the `md` breakpoint each verification is a card, so the number, date, godown, status, scope, starter, progress, and discrepancy count stay visible at 390px. The wide table remains at `md` and above. `/stock-verification/new` is Godown Manager only. `/stock-verification/:verificationId` is the count, recount, review, photo, and closure screen. Closed verifications are read-only. The closure confirmation says: "Closing this verification permanently records the physical stock check and its discrepancies. Inventory balances will not change."

## Tests

- `supabase/tests/phase_3_2_stock_verification.sql` covers the authorization, snapshot, recount, photo, inactive-object, movement, and regression cases and rolls back.
- `supabase/tests/phase_3_2_concurrency.mjs` runs overlapping sessions for start, counts, snapshot, movement, photos, and closure. The deactivation sessions lock through `set_product_active`, `set_crate_active`, and `set_zone_active`, not only a manual verification-row lock. Separate sessions cover product-row-first, closure-first, crate deactivation, deactivation after the count, a review that becomes stale, an unrelated product, zone deactivation, receipt and transfer on both sides of the zone lock, a product received into a selected crate with no line, and two closure requests.
- `supabase/tests/phase_3_2_storage.mjs` runs the local storage HTTP cases.
- `tests/unit/verification.test.ts` covers count validation, variance, permissions, closure, and photo state.

## Deferred

Phase 3.3 remains deferred: adjustment posting, exceptional approval, valuation, and any direct balance correction. Verification does not add a stock transaction type.
