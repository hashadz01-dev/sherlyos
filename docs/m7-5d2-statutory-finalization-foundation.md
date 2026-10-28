# M7.5D.2 — Statutory invoice finalization foundation (issuance still blocked)

Local-only foundation after owner-committed M7.5D.1 (`f7a4ad4` on `main`). This phase does **not** issue tax invoices, allocate legal invoice numbers, post credit notes, mutate stock, activate operational flags, assign a statutory verifier for issuance, or commit.

Starting HEAD: `f7a4ad48916c9563df81947c3b67bc7fff43f1a7`  
`feat(m7.5d1): add invoice PDF preview and handover workflow`

Working tree was clean at start. Owner had already committed M7.5D.1. This phase does not commit.

Local migration applied (Docker only):

- `20261028240000_statutory_invoice_finalization_foundation.sql`

Tip after apply: `20261028240000`.

Flags at start and end (unchanged):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false`

---

## 1. Architecture

D.2 adds the **record structure and eligibility gate** for a later issuance phase. It does not add an operational finalize, issue, allocate, or cancel RPC.

| Layer | Behaviour |
|---|---|
| `invoice_financial_years` / `invoice_number_series` | Configurable FY + series. `legal_allocation_enabled` is a hard `false` check. |
| `invoice_number_allocations` | Synthetic `PROOF-` rows only. `is_legal=false`, `proof_only=true`, `is_consumed=false`. |
| `statutory_invoices` + lines + tax components | Immutable snapshots copied from a reviewed invoice note and its current tax preview. Status is `foundation_reserved` or `blocked`. `issued_at` and `legal_invoice_number` stay null. |
| `statutory_invoice_cancellations` | Intent rows may exist only as `blocked_intent`. No completed cancellation, no credit-note posting, no history delete. |
| `assess_invoice_finalization_readiness` | Read-only structured blockers. Always `ready=false`, `legal_issuance_blocked=true`. |
| `assess_statutory_cancellation_readiness` | Read-only. Always `legal_cancellation_blocked=true`. |
| `app_private.allocate_synthetic_invoice_number` | Private, GUC `app.invoice_number_proof`. Revoked from application roles. |
| `app_private.reserve_statutory_invoice_foundation` | Private, GUC `app.statutory_invoice_write`. Cannot mark issued. |

D.1 preview watermarks and `get_invoice_note_preview` are unchanged. Viewing or printing still does not write dispatch, delivery, or stock.

---

## 2. Schema changes

New tables, all `ENABLE` + `FORCE ROW LEVEL SECURITY`. Clients have `SELECT` only. Writes require GUCs that application roles never receive.

Hard checks that keep this phase non-issuing:

- `invoice_financial_years.legal_allocation_enabled = false`
- `invoice_number_series.legal_allocation_enabled = false`
- synthetic series prefix must start with `PROOF-`
- allocations: `is_legal = false`, `proof_only = true`, `formatted_number like 'PROOF-%'`
- statutory invoices: `status in ('foundation_reserved','blocked')`, `issued_at is null`, `legal_invoice_number is null`
- cancellations: `status = 'blocked_intent'`, `credit_note_id is null`
- unique `statutory_invoices.invoice_note_id` prevents duplicate foundation rows
- unique `(series_id, allocated_number)` plus `FOR UPDATE` on the series row serializes concurrent synthetic allocation inside one transaction

Verified financial-year windows cannot overlap (`btree_gist` exclusion on ownership + `selling_price_window`).

No public `finalize_invoice_note`, `issue_tax_invoice`, `allocate_statutory_invoice_number`, or `cancel_statutory_invoice`.

---

## 3. Eligibility rules

`assess_invoice_finalization_readiness(note_id)` is STABLE SECURITY DEFINER with `search_path = ''`.

Org-level (no note id): `invoice_notes.prepare`, `invoices.review`, `operations.monitor`, or `statutory.config.read`.

Note-level: viewer permission **and** `can_work_at_branch`. Missing notes raise `P0002`. Cross-godown and drivers raise `42501`.

Diagnostic blockers (when applicable):

- `seller_identity_unverified`
- `signature_seal_unapproved`
- `tax_classification_unapproved`
- `tax_treatment_unapproved`
- `numbering_policy_unapproved`
- `invoice_date_policy_unapproved`
- `place_of_supply_unapproved`
- `gst_component_unapproved`
- `rounding_unapproved`
- `credit_note_tax_unapproved`
- `financial_year_unconfigured`
- `invoice_series_unconfigured`
- `statutory_verifier_unassigned`
- `invoice_note_not_reviewed`
- `dispatch_not_valid`
- `customer_identity_incomplete` / `customer_gstin_required`
- `product_hsn_missing`
- `pricing_billing_conversion_invalid`
- `tax_preview_missing` / `tax_preview_stale`
- `conflicting_finalization`

Hard blockers that remain even if every diagnostic is later cleared:

- `statutory_verifier_issuance_not_authorized`
- `tax_preview_is_not_a_tax_invoice`
- `finalize_rpc_disabled`
- `statutory_issuance_disabled`
- `legal_numbering_allocation_disabled`

A passing diagnostic set is **not** permission to issue.

---

## 4. Numbering design

Future legal numbers will be server-allocated inside one transaction:

1. lock the series row
2. take `next_number`
3. insert the allocation
4. advance the counter

If the transaction fails, the allocation rolls back with it. Clients cannot supply numbers.

D.2 only proves that algorithm against **synthetic** series (`PROOF-{prefix}/{fy}/{seq}`). Production consume is compile-time and constraint disabled. Tests must not, and did not, insert `is_legal=true` rows on the owner database.

---

## 5. Cancellation foundation

Cancellation is a new document intent, not a delete or rewrite:

- issued history (when it later exists) cannot be deleted
- financial snapshot columns cannot be updated
- credit notes remain a separate future document
- `assess_statutory_cancellation_readiness` always reports blocked

There is no cancel RPC.

---

## 6. Security model

- FORCE RLS on all new tables
- statutory invoice SELECT is branch-scoped through the source invoice note
- allocations SELECT is limited to proof rows for statutory readers
- SECURITY DEFINER functions use `search_path = ''`
- private allocators and foundation writers are revoked from `public`, `anon`, `authenticated`, and `service_role`
- no client-supplied financial snapshots: foundation copies note + tax-preview rows
- `invoices.issue` remains unused; D.2 does not grant finalize rights

---

## 7. Test evidence

| Proof | Result |
|---|---|
| SQL `phase_m7_5d2_finalization_foundation.sql` | PASS ROLLBACK |
| HTTP `phase_m7_5d2_http_integration.mjs` | PASS 10 checks |
| Concurrency `phase_m7_5d2_concurrency.mjs` | PASS 2 checks (unique `PROOF-` numbers, still `is_legal=false`) |
| SQL C.1 / C.2 / C.4 / D.1 | PASS ROLLBACK |
| HTTP C.2 | PASS 22 |
| HTTP D.1 | PASS 9 |
| Vitest | **236 passed** |
| Playwright invoice-notes + statutory-config | **6 passed** in the full run |
| Playwright full suite | 102 passed; 1 unrelated damage write-off flake; that spec **10/10** on isolated retry |
| Typecheck `tsc -b` | PASS |
| Lint `oxlint` | 0 errors, 4 pre-existing warnings |
| `npm run build` | PASS |

SQL/HTTP covered: immutable snapshots, duplicate foundation unique, stale tax-preview rejection, missing numbering/FY configuration, driver denial, cross-godown denial, financial line-amount preservation, zero stock mutation, no legal numbers, no public finalize/allocate RPCs, cancellation blocked, `ready=false`.

Playwright Chromium cannot inspect PostgreSQL constraints. Byte-level issuance absence is SQL/HTTP.

---

## 8. Outstanding accountant decisions

Unchanged from C.1, and still required before any later issuance phase:

- Who is assigned `statutory_verifier` for **issuance** (named accountant; leftover HTTP test users are not owner approval)
- Seller legal identity for the operating company
- Tax-inclusive vs exclusive selling prices (I3)
- Place of supply and CGST/SGST vs IGST
- Actual HSN/SAC per SKU and approved rate schedules (I11)
- Invoice date vs dispatch confirmed-at (I10)
- Numbering prefix, FY representation, sequence scope, reset rule (I7). Example `SDI/26-27/19656` is not the policy
- Rounding and credit-note tax treatment
- Signature/seal image custody
- Whether DN print identity should be superseded by verified seller identity on legal copies

D.2 did not invent or seed those values.

---

## 9. Exact activation gates (later phase, owner-approved)

Issuance must not be enabled until all of the following are true and explicitly approved:

1. Drop or replace the hard `legal_allocation_enabled = false` checks.
2. Add a public finalize/issue RPC that still cannot be called by GM/driver.
3. Allocate numbers only inside the same transaction as the immutable insert.
4. Keep `assess_invoice_finalization_readiness.ready` false until those RPCs exist **and** accountant configuration is verified.
5. Do not reuse `PROOF-` synthetic numbers as legal numbers.
6. Keep invoice RPCs from calling stock writers.
7. Keep D.1 watermarks on any remaining preview copies.

---

## 10. Remaining risks

- Leftover isolated `PROOF-m75d2c_*` series/allocations exist from the concurrency harness. They are proof-only and not legal invoice numbers.
- HTTP tests `verifier.m75c1http@example.com` and `verifier.m75c2http@example.com` still hold `statutory_verifier`. That does not authorize issuance; D.2 still appends `statutory_verifier_issuance_not_authorized`.
- Playwright damage write-off double-submit can race on the full suite; isolated retry passed. Unrelated to invoicing.
- Payment and TallyPrime remain out of scope.

---

## 11. Git

No commit, push, cloud migrate, Netlify deploy, or flag activation in this phase.
