# Phase 3.1 stock receiving

Migration `supabase/migrations/20261015200000_stock_receiving.sql` is applied on local Supabase and on development project `ypkfondrkhkydkgovwup`. It is committed to `main`.

Phase 2C.3 remains deployed and committed. Remote history now ends at `20261015200000_stock_receiving.sql`. Phase 3.2 Daily Stock Verification has not started. Phase 3.3 has not started.

## BPM workflow

STK-01 through STK-06 are the receiving path from the distribution BPM.

1. FMCG goods arrive at one godown.
2. The Store Keeper compares the supplier document with the cases counted.
3. Quantity differences and damaged cases are recorded on the receipt line.
4. Accepted cases are allocated to a zone and crate in that godown.
5. The Godown Manager verifies quantities and locations.
6. Only accepted, verified cases enter available inventory.

An unverified, held, or cancelled receipt does not change `stock_balances`. Damaged cases are stored on the line and never become a ledger quantity.

## Approved business rules

- Every receipt has an existing supplier, one godown, and a nonempty supplier document reference.
- Document identity is unique for supplier, godown, and normalized reference. Normalization trims the value, collapses whitespace, and lowercases it. A cancelled receipt still occupies that identity.
- The same reference may be used for another supplier, or at another godown.
- Each line stores document cases, counted cases, damaged cases, and accepted cases.
- `accepted_cases` is generated as `counted_cases - damaged_cases`. The database does not trust a client-supplied accepted quantity.
- Quantities are whole carton integers from 0 to 1,000,000. Damaged cases cannot exceed counted cases.
- Document quantity may differ from counted quantity.
- A receipt has at least one line and at most 100 lines. Several products and several crates are allowed. The same product and crate may appear on more than one line. Each accepted line posts once.
- Every destination crate belongs to the receipt godown.
- A receipt whose accepted total is zero can still be verified. It keeps its history and creates no stock movement.
- Verification is the posting step. There is no separate posting permission.
- A posted receipt cannot be edited, cancelled, or voided. Removing posted stock requires a later approved adjustment workflow, which is not in this phase.

## Receipt status machine

| From | Action | To | Who |
| --- | --- | --- | --- |
| draft | Submit | submitted | Creator with `receiving.execute` |
| draft | Cancel | cancelled | Creator with `receiving.execute` |
| draft or submitted | Hold | held | Godown Manager with `receiving.verify` at that godown |
| held | Return for correction | draft | Godown Manager at that godown, or the original Store Keeper |
| submitted | Verify | posted | Godown Manager with `receiving.verify` at that godown |
| draft, submitted, or held | Cancel | cancelled | Godown Manager at that godown |

Submit does not post inventory. Verify is accepted only from `submitted`. Posted and cancelled are terminal. A cancelled receipt cannot be reopened. Held and cancelled receipts cannot post.

## Role permission matrix

Existing grants are unchanged.

| Role | Receiving access |
| --- | --- |
| Store Keeper | `receiving.execute`. Creates and edits own drafts, submits them, and cancels own drafts. Cannot verify. |
| Godown Manager | `receiving.verify`. Views, holds, returns, cancels, and verifies receipts in assigned godowns. Cannot open `/receiving/new`. |
| Admin | `operations.monitor`. Can list and read receipts. Cannot create, hold, cancel, or verify. |
| Accounts | No receiving permission. Direct receiving routes are denied. |
| Salesperson | No receiving permission or navigation. |
| Delivery Person | No receiving permission or navigation. |

`stock.read` is unchanged. Receipt entry uses `list_receiving_options`, so a Store Keeper does not need `products.read` or `locations.read`. Every action also requires `can_work_at_branch`. A receiving permission does not grant every godown.

## Database schema

`stock_receipts` stores the receipt number, godown, supplier, document reference, normalized reference, received date, status, notes, hold reason, creator, verifier, cancellation, and posting idempotency fields. Lifecycle columns are written by the RPCs.

`stock_receipt_lines` stores product, destination crate, document cases, counted cases, damaged cases, and generated accepted cases.

Uniqueness:

- `receipt_number`
- `posting_idempotency_key`
- `(godown_id, supplier_id, normalized_document_reference)`, including cancelled rows

Checks require posted rows to have verifier, timestamps, and a posting key and fingerprint. Held and cancelled rows require a reason. Line quantities are nonnegative integers, and damaged cases cannot exceed counted cases.

Row level security is enabled and forced. `authenticated` has select only. Policies follow the same visibility rule as the RPCs: the creator with `receiving.execute` and a godown assignment, a verifier assigned to that godown, or `operations.monitor`. There is no client insert, update, or delete grant.

A line trigger allows changes only while the receipt is `draft`, and it requires the crate's zone to belong to the receipt godown.

## Ledger integration

`RECEIPT` was added to the existing `stock_transactions` type check. The shape check requires `receipt_id` and `receipt_line_id` for a receipt, and requires both to be null for opening stock and transfers. One transaction row is allowed per receipt line.

Verification, inside one transaction:

1. Authenticates the caller and requires `receiving.verify` and an active godown assignment.
2. Locks the receipt, then the supplier, then products by id.
3. Locks zones by id, then crates by id, through the existing location helper, then rechecks that locations are active.
4. Reads accepted cases from the stored generated column.
5. For each line with accepted cases greater than zero, appends one positive ledger entry, updates `stock_balances`, and records a `RECEIPT` transaction.
6. Marks the receipt posted and writes audit rows.

Zero-accepted lines create no ledger row. If any step fails, the receipt stays unposted and the ledger, balances, transactions, and audit writes roll back. Opening-stock uniqueness, transfer net-zero checks, balance nonnegativity, and ledger immutability are unchanged. The deferred completeness check accepts a receipt only when it has one positive entry and both receipt references.

Inventory history labels these rows Receipt. The transaction notes carry the receipt number. `list_stock_transactions` was not replaced.

## Idempotency

Verification takes a posting idempotency key. The fingerprint is the godown, supplier, normalized document, and sorted lines. The receipt row is locked before that state is evaluated.

An exact retry of a posted receipt returns the posted payload. A different key or fingerprint raises `idempotency key was already used for a different request`. Two overlapping verifications cannot both insert ledger rows: the receipt lock and the unique receipt-line transaction index leave one post. Document uniqueness is separate from the posting key.

## Concurrency locking

Lock order matches Phase 2C.3: zones by id, then crates by id, then balances by destination crate, product, and line. The receipt and supplier are locked before locations. Location, product, and supplier status are checked again after the locks.

This covers two managers verifying one receipt, an edit or cancellation racing verification, two receipts adding the same product and crate, posting racing crate or zone deactivation in either direction, duplicate document submission, and product or supplier deactivation during verification.

## Audit

Status changes use the existing `write_audit` function. The receipt payload returns that history. Created, submitted, held, returned, verified, and cancelled events are preserved. There is no second audit table.

## Local test results

| Check | Result |
| --- | --- |
| `npx supabase db reset --local` | Passed through `20261015200000_stock_receiving.sql`. |
| `npx supabase db lint --local` | No schema errors. |
| `npx supabase db advisors --local` | No issues. |
| Phase 2C.1, 2C.2, and 2C.3 SQL | Passed and rolled back on this schema before the browser seed. |
| `supabase/tests/phase_3_1_stock_receiving.sql` | Passed and rolled back. Covers the six roles, an inactive user, document identity, quantities, posting, idempotency, rollback, direct writes, audit, opening stock, transfer, reconciliation, and receipt references. |
| `phase_3_1_concurrency.mjs` | Eleven overlapping sessions passed. |
| `npm run typecheck` | Passed. |
| `npm run lint` | Passed. Three existing React Hook Form warnings remain. |
| `npm test` | Passed. 9 files, 30 tests. |
| `npm run build` | Passed. JS chunk about 1,005 kB. CSS about 84 kB. |

The Phase 2C SQL files call `bootstrap_initial_admin`. A clean `npx supabase db reset --local` removed the earlier disposable browser administrator, and Phase 2C.1, 2C.2, 2C.3, and Phase 3.1 SQL then passed and rolled back. Opening stock and same-godown transfer still posted inside those rolled-back tests.

Browser checks used local Vite on port 5175 and local Supabase. The cloud app on port 5173 was left alone.

- Store Keeper created a two-line receipt for soap and oil, saw accepted cases of 5 and 4, saved the draft, and submitted it. The keeper had no verify action.
- The keeper cancelled a separate draft. The cancelled page was read-only.
- Godown Manager held the submitted receipt, returned it for correction, and after resubmission verified it. The confirmation stated that verification permanently posts accepted carton cases and cannot be undone. Totals were document 12, counted 10, damaged 1, accepted 9.
- Posting created `RR-20261015-000026` for 5 cases and `RR-20261015-000027` for 4 cases. Inventory balances were 5 soap in `bca1` and 4 oil in `bca2`. History labeled both rows Receipt.
- The manager assigned to the other godown saw an empty list and `not authorized` for the posted receipt. `/receiving/new` was denied.
- Admin could read the receipt list and the posted references, and had no create or verify action. `/receiving/new` was denied.
- Accounts, Salesperson, and Delivery Person had no Receiving navigation. `/receiving` was denied and did not show receipt data.
- At 390px the sidebar was hidden, filters stacked, and the receipt table scrolled inside the page without widening the document.

After that post, local reconciliation reported 0 balance mismatches, 0 negative balances, and 0 receipt ledger rows missing a receipt reference. The later local reset removed those disposable rows.

## Development cloud results

The dry run listed only `20261015200000_stock_receiving.sql`. `npx supabase db push --linked` applied that migration to `ypkfondrkhkydkgovwup`. Local and remote migration histories match and end at that version. The remote database was not reset.

`stock_receipts` and `stock_receipt_lines` exist with forced row level security. Authenticated users have `SELECT` only on receipts. The ten receiving functions are `SECURITY DEFINER` with an empty `search_path`. `RECEIPT` is an allowed ledger type. Append-only ledger triggers stayed enabled. Role grants remain Admin `operations.monitor`, Store Keeper `receiving.execute`, and Godown Manager `receiving.verify`.

JWT checks with disposable users passed for all six roles and an inactive user. Store Keeper could create and submit an assigned-godown receipt and could not verify. Godown Manager verification, accepted-only posting, idempotent retry, conflicting retry, posted and cancelled immutability, opening stock, and transfer were proven inside a statement that rolled back. Cross-godown access, duplicate documents, invalid quantities, and direct writes were denied. Unverified receipts did not change balances.

The cloud browser on `[::1]:5173` confirmed the same screen permissions. Store Keeper saw the form and scoped godown, zone, and crate options. Godown Manager saw the verify action. Admin monitoring was read-only. Accounts, Salesperson, and Delivery Person were denied the receiving routes. At 390px the list fit the viewport. The verify confirmation was not opened, and no cloud browser action posted stock.

Before and after those checks, the development ledger had 0 transactions, 0 balances, 0 mismatches, and 0 negatives. Disposable fixtures were then removed. One Auth user and `godown_main` remain. No test stock remains.

## Known limitations

- Posted receipt corrections, reversals, and generic stock adjustments are not implemented.
- Daily stock verification, discrepancy approval, refill, orders, delivery, and damage posting are not implemented.
- Damaged cases are recorded only. They do not create a damage inventory balance.
- Cross-godown transfers, pricing, batch or expiry tracking, crate capacity, and piece conversion remain out of scope.
- The clean local reset removed the disposable browser seed and its posted receipt. Do not copy local test data to the development project.
- The production JavaScript chunk is about 1,005 kB, above Vite's 500 kB notice. The build still succeeds.

## Deferred correction workflow

A posted receipt is immutable. A later phase must define a separate stock-adjustment workflow before a verified quantity can be corrected. That workflow is not approved for Phase 3.1, and `stock.adjustment.post` is not used here.
