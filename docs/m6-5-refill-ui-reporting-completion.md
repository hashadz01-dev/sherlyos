# M6.5 — Stock refill UI, reporting, and workflow completion

Local-only UI and reporting completion for PDF Branch 05 REF-02–REF-07. Existing M6.2–M6.4 RPCs remain the workflow authority. **`verify_stock_receipt` is unchanged and remains the sole accepted-stock writer.**

Starting HEAD: `8667e3bac947bd7cd281a1318f6f557681718452`  
`feat(m6.4): integrate partial refill receipts with stock receiving` on `main`. Working tree was clean before this phase.

## 1. Screens completed

| Route | Role | Purpose |
| --- | --- | --- |
| `/refill` | Accounts, Admin | Server-filtered queue with receiving progress, reserved vs verified cases, pagination |
| `/refill/new` | Accounts | Existing draft create. No new transitions |
| `/refill/:id` | Accounts, Admin | Lifecycle, supplier communication, reconciliation, audit, in-page navigation |
| `/refill/:id/edit` | Accounts creator | Existing held/draft edit |
| `/reports/refill` | Accounts, Admin | Read-only refill report and CSV export |
| `/receiving/new` and `/receiving/:id` | Store Keeper / GM | Reserved vs outstanding copy; Keepers see refill number without a refill-detail link |

No new lifecycle transitions. Approved requests are not auto-closed.

## 2. Queue and filter behavior

`list_stock_refill_requests` now accepts optional filters, all applied in SQL after `can_view_refill_at_godown`:

- approval status
- supplier
- destination godown (active and inactive/historical)
- communication (`not_sent` / `sent`)
- acknowledgement (`none` / `pending` / `acknowledged` / `declined`)
- dispatch (`not_recorded` / `recorded`)
- receiving progress (`not_started` / `pending_verification` / `partially_received` / `fully_received` / `excess_requires_review`)
- created-from / created-to (half-open UTC days)

Pagination remains 25 per page on the queue and 50 on the report. Unauthorized rows are never fetched.

## 3. Reconciliation and draft reservation

Authoritative `app_private.stock_refill_progress_totals` / snapshot fields:

| Field | Meaning |
| --- | --- |
| `requested_cases` | Approved request lines |
| `reserved_cases` | Accepted cases on every **non-cancelled** linked receipt |
| `draft_reserved_cases` | Accepted cases on **draft** linked receipts |
| `accepted_cases` | Posted receipts only |
| `pending_receipt_cases` | Counted cases on submitted/held receipts |
| `outstanding_cases` | `greatest(requested - accepted, 0)` |
| `excess_cases` | Historical posted excess only |

Reserved quantity is **not** stock. Accounts see receipt numbers without `/receiving/:id` links and cannot cancel Store Keeper drafts. Keepers with receiving permission can open the draft to complete or cancel it using existing receiving actions. No expiry policy was added.

## 4. Reporting contract

New read-only RPCs, `SECURITY DEFINER`, execute granted to `authenticated` only, same refill permission gate as the queue:

- `list_stock_refill_report`
- `export_stock_refill_report`

Filtered totals cover the authorized set, not only the current page. Inactive godowns remain visible for historical reporting. The report does not calculate ledger balances and does not post stock.

Accounts with only `refill.request` can open `/reports` and see the refill card. Operations reports stay gated on existing operations permissions.

## 5. Permission boundaries

| Action | Accounts `refill.request` | Admin `refill.approve` | Store Keeper / GM |
| --- | --- | --- | --- |
| Queue, detail, refill report | Assigned godown, including inactive | `branches.access_all` or assignment | No |
| Create / send / ack / dispatch | Existing M6.2–M6.3 rules | No | No |
| Linked receiving | No | No | Existing receiving permissions |
| Open `/receiving/:id` from refill | Number only | Number only | Yes, if receiving-authorized |
| Open `/refill/:id` from receiving | Yes | Yes | Number only |

FORCE RLS unchanged. No permission expansion for convenience.

## 6. Database changes

Forward-only local migration `20261027190000_stock_refill_ui_reporting.sql`.

Does **not** rewrite 170000/180000. Does **not** modify `verify_stock_receipt`. Shared local database was not reset.

## 7. Tests

- M6.5 SQL: passed, rolled back
- M6.5 HTTP: **8/8**
- M6.4 / M6.3 / M6.2 SQL: passed, rolled back
- Vitest: **212/212** (34 files)
- Playwright: **88/88** (includes M6.5 4/4, M6.2–M6.4 refill specs)
- Typecheck, oxlint (pre-existing warnings only), production build: pass

## 8. Remaining limitations

- No owner-approved request auto-completion or over-delivery acceptance.
- Abandoned drafts still reserve quantity until cancelled.
- Linked receiving still does not require REF-05/REF-06 send or dispatch.
- Accounts still cannot open receipt detail.
- Isolated empty-database migration replay was not run.

## 9. M6.6 handoff

Out of scope here: automated supplier messaging, financial settlement, supplier credits, request auto-close, over-delivery exception workflow, and any second stock writer.

Suggested M6.6 questions: whether send/dispatch should be required before linkage; whether draft reservations should expire; when an authorized person may mark a request complete; whether Accounts should get read-only receipt detail.
