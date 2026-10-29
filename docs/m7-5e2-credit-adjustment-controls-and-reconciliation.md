# M7.5E.2 — Credit-adjustment controls, reconciliation, and statutory credit-note readiness

Local-only controls on top of owner-committed M7.5E.1 (`7ae2579` on `main`). This phase does **not** issue GST credit notes, allocate legal credit-note numbers, post ledgers or payments, mutate stock, activate operational flags, or commit.

Starting HEAD: `7ae257996fe019f83d193040258de29821f40873`  
`feat(m7.5e1): add verified return credit adjustment previews and QA stabilization`

Working tree was clean at start. Owner had already committed E.1 and E.1A together.

Local migrations applied (Docker only):

- `20261028252000_credit_adjustment_review.sql`
- `20261028253000_credit_note_readiness_and_numbering.sql`

Tip after apply: `20261028253000`.

Flags at start and end (unchanged):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false`

Statutory status at start and end:

`ready=false`  
`legal_issuance_blocked=true`  
`legal_allocation_enabled=false` on every financial year, invoice series, and credit-note series

---

## 1. Review workflow

Prepared E.1 candidates remain `preview` (or `blocked`). Accounts with `invoices.review` may:

| Decision | From | To | Meaning |
|---|---|---|---|
| approve | `preview` | `approved` | Internal reconciliation only |
| reject | `preview` or `blocked` | `rejected` | Reason required; return slot is freed |

`blocked` cannot be approved. `approved` and `rejected` are terminal. Duplicate review raises `23514`. Stale version raises `PT409`.

Approval never:

- allocates `legal_credit_note_number`
- sets `issued_at` or `statutory_credit_note_id`
- posts accounts, tax, or stock
- changes billed quantities, unit prices, or billing-unit snapshots

Watermark remains `CREDIT ADJUSTMENT PREVIEW — NOT A GST CREDIT NOTE`.

Rejected returns may receive a replacement preview. Approved returns stay uniquely occupied.

---

## 2. Reconciliation model

`get_credit_adjustment_reconciliation` is read-only whole-case arithmetic:

- billed cases from the reviewed invoice-note line (`shipped_cases`)
- dispatched cases from the matching return-lot grain
- returned cases = `saleable + damaged + uncertain + missing`
- prepared cases = open `preview`/`blocked` adjustment lines
- approved cases = `approved` adjustment lines
- remaining eligible = `max(0, min(billed, returned) − occupied cases)`

Prices and billing conversion come from the reviewed invoice-note snapshot. Live product masters are not read.

Structured discrepancy blockers: `returned_exceeds_billed`, `dispatched_differs_from_billed`, `adjustment_exceeds_returned`, `missing_return_lot_grain`.

---

## 3. Quantity integrity

- Whole carton cases only.
- Cumulative occupied cases (`preview` + `blocked` + `approved`) cannot exceed original billed cases.
- Empty or unmatched lot grain still fails closed in `prepare_credit_adjustment`.
- One return wave per dispatch remains (`stock_delivery_returns.dispatch_id` UNIQUE).
- Owner return-lot rows were not backfilled.

---

## 4. Statutory blockers

`assess_credit_note_issuance_readiness` always returns `ready=false` and `legal_issuance_blocked=true`.

Hard blockers always present:

- `credit_note_issue_rpc_disabled`
- `statutory_credit_note_issuance_disabled`
- `legal_credit_note_numbering_disabled`

Current-environment blockers (not invented policy):

- `original_legal_invoice_missing` — statutory invoices cannot be issued yet
- `credit_note_tax_unapproved`
- `numbering_policy_unapproved`
- `credit_note_series_unconfigured` for non-synthetic series
- `statutory_verifier_unassigned` when no active verifier exists
- `signature_seal_unapproved` when seller seal/signature metadata is missing
- `original_tax_basis_unavailable` when the tax preview is missing or stale

No public `issue` / `allocate` credit-note RPC exists.

---

## 5. Numbering foundation

New tables `invoice_credit_note_number_series` and `invoice_credit_note_number_allocations`.

- `legal_allocation_enabled` is check-constrained false
- allocations are `is_legal=false`, `proof_only=true`, `PROOF-CN-%` only
- `app_private.allocate_synthetic_credit_note_number` is private and GUC-gated
- synthetic fixtures are isolated; they are never attached to a credit adjustment

---

## 6. Security

- FORCE RLS on adjustment, line, event, and numbering tables
- clients have SELECT only
- writes require `app.credit_adjustment_write` or numbering GUCs that application roles never receive
- `search_path = ''` on SECURITY DEFINER functions
- Accounts `invoices.review` plus `can_work_at_branch`
- Godown Manager, Store Keeper, and Delivery Person denied
- financial snapshot columns remain immutable under the write guard
- audit `credit_adjustment.approved` / `credit_adjustment.rejected`
- unique legal-number index reserved for a later issuance phase (currently unused because the not-issued check keeps the column null)

---

## 7. UI / reporting

Credit-adjustment list and preview show review status, reviewer, reason, reconciliation, remaining eligible cases, tax readiness, and statutory blockers.

No Issue, Finalize, Post to Accounts, or Allocate Legal Number controls.

---

## 8. Test evidence

| Proof | Result |
|---|---|
| E.2 SQL `phase_m7_5e2_credit_adjustment_controls.sql` | PASS ROLLBACK |
| E.2 HTTP `phase_m7_5e2_http_integration.mjs` | PASS 13 |
| E.2 concurrency `phase_m7_5e2_concurrency.mjs` | PASS 4 |
| E.1 SQL / HTTP / concurrency | PASS ROLLBACK / 10 / 2 |
| D.2 SQL / HTTP | PASS ROLLBACK / 10 |
| M7.4B delivery SQL | PASS ROLLBACK |
| Vitest | 240 passed / 40 files |
| Playwright | 108 passed / 0 failed / 0 skipped (7.2m) |
| `tsc -b` | PASS |
| `oxlint` | 0 errors, 4 pre-existing warnings |
| `npm run build` | PASS |

Focused SQL rolls back. HTTP and concurrency restore operational flags in `finally`.

---

## 9. Remaining accountant decisions

- GST credit-note tax treatment (`credit_note_tax`)
- numbering policy and a non-synthetic credit-note series
- statutory verifier assignment
- signature/seal captions
- original legally issued tax invoice (blocked until a later issuance phase)

E.2 does not invent those approvals.

---

## 10. Outstanding operational dependencies

- One return wave per dispatch
- Owner posted returns still have empty lot tables
- `post_delivery_return` unchanged
- Operational stock flags remain false
- Statutory invoice issuance remains disabled, so real legal credit-note readiness cannot become true
