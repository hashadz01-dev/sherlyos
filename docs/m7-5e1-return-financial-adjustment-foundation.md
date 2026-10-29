# M7.5E.1 — Verified returns and credit-adjustment financial foundation (preview only)

Local-only financial foundation after owner-committed M7.5D.2 (`af3e36a` on `main`). This phase does **not** issue GST credit notes, allocate legal credit-note numbers, post ledgers or payments, mutate stock, activate operational flags, or commit.

Starting HEAD: `af3e36afbcbab6b8c393c711b008e233f46a239a`  
`feat(m7.5d2): add guarded statutory invoice foundation`

Working tree was clean at start. Owner had already committed M7.5D.2. This phase does not commit.

Local migrations applied (Docker only):

- `20261028250000_credit_adjustment_preview.sql`
- `20261028251000_credit_adjustment_payload.sql`

Tip after apply: `20261028251000`.

Flags at start and end (unchanged):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false`

Statutory status at start and end:

`ready=false`  
`legal_issuance_blocked=true`  
`legal_allocation_enabled=false` on every financial year and series

---

## 1. Starting baseline

Preflight on `main`:

- HEAD `af3e36a`, working tree clean
- GiST `product_selling_prices_active_window_excl` present
- overlapping active selling prices: 0
- D.1 `get_invoice_note_preview` remains STABLE SECURITY DEFINER
- no public `finalize_invoice_note`, `issue_tax_invoice`, `allocate_statutory_invoice_number`, `create_invoice_credit_note`, or `issue_gst_credit_note`
- `statutory_invoices_not_issued` still forbids `issued_at` / `legal_invoice_number`

---

## 2. Existing return-workflow findings

Authoritative customer-return workflow is **M7.4B delivery returns**, not a new lifecycle.

| Object | Role |
|---|---|
| `stock_dispatch_requests` | Posted consume. `stock_consumed` and `posted_transaction_id` required. |
| `stock_delivery_returns` | One return **wave per dispatch** (`dispatch_id` UNIQUE). |
| `stock_delivery_return_lots` | Grain `(return_id, order_line_id, lot_id, source_crate_id)`. |
| Statuses | `awaiting_handback` → `handed_back` → `counted` → `approved` → `posted` or `closed_missing`. |
| Creditable buckets | `saleable_cases + damaged_cases + uncertain_cases + missing_cases` (whole carton cases). Delivered cases are not credited. |
| Stock writer | `post_delivery_return` — **not modified**. |
| Invoice notes | Internal `IN-…` drafts. Reviewed notes are the financial source. Not GST tax invoices. |

Owner posted returns currently have **zero** `stock_delivery_return_lots` rows. Tests GUC-insert `closed_missing` lots matching reviewed `invoice_note_lines` and do not call `post_delivery_return`.

Ordinary stock adjustments, supplier returns, and damage write-offs are **not** customer financial returns.

Schema limitation: multiple verified returns against one dispatch are impossible while `stock_delivery_returns.dispatch_id` is UNIQUE. Cumulative credited-cases protection still exists per invoice-note line for a later multi-wave model.

---

## 3. Database architecture

New tables, all `ENABLE` + `FORCE ROW LEVEL SECURITY`. Clients have `SELECT` only. Writes require GUC `app.credit_adjustment_write`, which application roles never receive.

| Table | Purpose |
|---|---|
| `invoice_credit_adjustments` | Internal candidate. Status `preview` or `blocked`. Internal number `CA-YYYYMMDD-######`. |
| `invoice_credit_adjustment_lines` | Immutable billed qty / INR price snapshots copied from reviewed invoice-note lines. |
| `invoice_credit_adjustment_events` | Append-only `prepared` / `previewed`. |

Hard checks:

- watermark = `CREDIT ADJUSTMENT PREVIEW — NOT A GST CREDIT NOTE`
- `legal_credit_note_number`, `issued_at`, and `statutory_credit_note_id` must stay null
- unique open row per `return_id`
- unique `idempotency_key`

RPCs:

- `prepare_credit_adjustment(return_id, idempotency_key, expected_version)`
- `get_credit_adjustment(id)`
- `list_credit_adjustments(status, branch_id)`

Lock order: dispatch → return → reviewed invoice note → advisory `credit-adj:{invoice_note_id}`. No stock-lot locks.

---

## 4. Source-linkage integrity

**Verified customer return → original dispatch line → reviewed invoice-note line → financial-adjustment candidate**

`prepare_credit_adjustment` enforces:

1. Return exists and version matches
2. Status is `posted` or `closed_missing`
3. Dispatch is a posted consume
4. A **reviewed** invoice note exists for that dispatch
5. Shop matches the order; branch matches the return
6. Return lot grain matches `invoice_note_lines` `(order_line_id, lot_id, crate_id, product_id)`
7. Credited cases are whole cartons and ≤ original `shipped_cases`
8. Cumulative credited cases per invoice-note line cannot exceed original billed cases
9. `can_work_at_branch` plus `invoices.review`

Frontend cannot supply amounts, tax rates, billing conversions, or original snapshot values.

---

## 5. Financial snapshot model

Server copies:

- original dispatch / invoice-note / return identifiers
- shop and branch
- original shipped cases, billed units per case, unit selling price
- returned cases × **snapshot** billed units per case
- line subtotal `round(billed_qty * unit_amount, 2)`
- tax only from a matching current tax-preview snapshot via `app_private.gst_line_calc`

Live `product_selling_prices` and live `products.billed_units_per_case` are never used.

Header and lines are insert-once. UPDATE of financial columns is rejected.

---

## 6. Quantity and duplicate protections

- Unique open adjustment per `return_id`
- Unique idempotency key; retries return the original row and original amounts
- Concurrent prepares of the same return collapse to one row
- Over-credit versus original `shipped_cases` raises `23514`
- Whole-case arithmetic only (integer case buckets)

Multiple concurrent partial returns against one dispatch cannot be exercised until R7’s one-wave unique is lifted. The cumulative line check is still present.

---

## 7. Tax-preview behavior

| State | Meaning |
|---|---|
| `tax_preview` | Current snapshot matches the reviewed note; CGST/SGST/IGST copied from `gst_line_calc`. |
| `tax_unavailable` | No current snapshot. Tax amounts stay 0. |
| `tax_stale` | Snapshot version/dispatch mismatch. Tax amounts stay 0. |
| `tax_incomplete` | Snapshot header exists but a credited line is missing. Tax amounts stay 0. |

Every candidate also carries `gst_credit_note_disabled`. Missing/stale/incomplete tax is an explicit blocker, not an invented rate.

---

## 8. Security model

- FORCE RLS on all three tables
- SELECT requires `invoices.review` and `can_work_at_branch`
- SECURITY DEFINER RPCs with `search_path = ''`
- no client INSERT/UPDATE/DELETE
- Admin and Accounts retain `invoices.review`; Godown Manager, Store Keeper, and Delivery Person do not
- cross-godown denied
- audit `credit_adjustment.prepared`

---

## 9. Stock-ledger invariance

Preparing or viewing an adjustment does not:

- increase or deduct stock
- reverse DISPATCH
- modify lots, crates, quarantine, or damage write-offs
- change return verification or delivery confirmation
- modify the original invoice note

SQL and HTTP compared `stock_ledger` counts before and after prepare. Unchanged. `post_delivery_return` was not called.

---

## 10. Automated test evidence

| Proof | Result |
|---|---|
| SQL `phase_m7_5e1_credit_adjustment.sql` | PASS ROLLBACK |
| HTTP `phase_m7_5e1_http_integration.mjs` | PASS 10 checks |
| Concurrency `phase_m7_5e1_concurrency.mjs` | PASS 2 checks |
| SQL `phase_m7_4b_delivery.sql` | PASS |
| SQL `phase_m7_5b_invoice_foundation.sql` | PASS ROLLBACK |
| SQL `phase_m7_5c1_statutory_foundation.sql` | PASS ROLLBACK |
| SQL `phase_m7_5c2_gst_calculation.sql` | PASS ROLLBACK |
| SQL `phase_m7_5c3a_exclusion.sql` | PASS ROLLBACK |
| SQL `phase_m7_5c4_financial_integrity.sql` | PASS ROLLBACK |
| SQL `phase_m7_5d1_handover.sql` | PASS ROLLBACK |
| SQL `phase_m7_5d2_finalization_foundation.sql` | PASS ROLLBACK after E.1A assumption fix (see appendix) |
| HTTP B / C.1 / C.2 / D.1 / D.2 | PASS 11 / 9 / 22 / 9 / 10 |
| D.2 concurrency | PASS 2 |
| Vitest | 240 passed / 40 files |
| Playwright full suite | 108 passed (6.9m) after E.1A fixture isolation |
| Playwright `credit-adjustments.spec.ts` | 2 passed (watermark, no Issue/Finalize, driver denied) |
| Typecheck `tsc -b` | PASS |
| Lint `oxlint` | 0 errors, 4 pre-existing warnings |
| `npm run build` | PASS |

---

## 11. Statutory blockers

No public credit-note issuance RPC. Candidates cannot store a legal credit-note number. Invoice-note issuance remains blocked. Synthetic `PROOF-` numbering remains the only allocation path and stays `is_legal=false`.

---

## 12. Operational flags

All four remain false. Dual-write is replica-enabled only inside HTTP/concurrency seed transactions and restored in `finally`.

---

## 13. Remaining risks

- One return wave per dispatch (`dispatch_id` UNIQUE). Multi-return cumulative over-credit cannot be live-tested until a later owner-approved return-wave change.
- Owner posted returns still have empty lot tables; financial prepare requires lot grain. Tests insert `closed_missing` lots; they do not backfill owner data.
- Local verified FY `26-27` rows remain in the owner database with `legal_allocation_enabled=false`. They correctly omit `financial_year_unconfigured` while `ready` stays false. Those rows were not deleted.

---

## 14. Recommended next milestone

**M7.5E.2** — owner-approved statutory credit-note policy, numbering, and issuance gate, still fail-closed until accountant rules exist. Do not enable legal credit-note allocation in E.1 leftover work.

Optional operational follow-up (separate owner approval): a second verified return wave per dispatch, if Accounts must credit successive customer returns against one invoice-note line.

---

## Appendix A — M7.5E.1A QA stabilization

Local-only test corrections after E.1. HEAD remained `af3e36afbcbab6b8c393c711b008e233f46a239a`. Working tree stayed dirty with the completed E.1 implementation. No commit, push, reset, stash, cloud migration, stock-writer change, or flag activation.

### A.1 Root causes

**D.2 SQL `financial_year_unconfigured`.** Production `assess_invoice_finalization_readiness()` is correct. Org-level assessment uses `as_of = CURRENT_DATE`. Two leftover owner rows (`PROOF-m75d2c_mvs48ktx`, `PROOF-m75d2c_mvt54qwt`) are verified FY `26-27` covering 2026-04-01..2027-03-31 with `legal_allocation_enabled=false`. A covering verified year correctly **omits** `financial_year_unconfigured`. The D.2 SQL test still required that code unconditionally, so it failed against a configured owner database. Hard issuance blockers (`finalize_rpc_disabled`, `statutory_issuance_disabled`, `legal_numbering_allocation_disabled`, `tax_preview_is_not_a_tax_invoice`) were already present. `ready` stayed false.

**Damage Playwright `product expiry policy is unclassified`.** `post_opening_stock` calls `require_product_expiry_policy` only when `stock.lots.dual_write_enabled` is on. Isolated `damage-exceptional` / `damage-verification` runs passed because flags were false. The full suite left dual-write on from an earlier spec, so the same unclassified product fixtures failed closed at opening-stock. Production expiry-policy validation was doing its job.

### A.2 Exact fixes

D.2 SQL (`supabase/tests/phase_m7_5d2_finalization_foundation.sql`):

- Always require the four hard issuance blockers and `ready=false` / `legal_issuance_blocked=true`.
- Assert no FY or series row has `legal_allocation_enabled`.
- If a covering verified FY exists, assert `financial_year_unconfigured` is **absent**; otherwise require it.
- Isolated missing-FY coverage: replica-set one reviewed note `as_of_date` to `1990-01-01`, assess that note, restore the original date. Owner FY rows are not deleted.

Damage Playwright (`tests/e2e/damage-exceptional.spec.ts`, `tests/e2e/damage-verification.spec.ts`):

- Call `set_product_expiry_policy(..., 'expiry_controlled')` before opening stock.
- If dual-write is on, post with lot code and expiry; if off, post without lot metadata (the off-path still rejects lot fields).

Production expiry-policy, FEFO/FIFO classification, inventory accounting, stock writers, statutory gates, legal numbering, and all four operational flags were not changed.

### A.3 Test evidence (E.1A)

| Proof | Result |
|---|---|
| D.2 SQL | PASS ROLLBACK |
| E.1 SQL | PASS ROLLBACK |
| E.1 HTTP | PASS 10 |
| E.1 concurrency | PASS 2 |
| Damage exceptional + verification together | 19/19 |
| Full Vitest | 240 passed / 40 files |
| Full Playwright | 108 passed / 0 failed / 0 skipped (6.9m) |
| `tsc -b` | PASS |
| `oxlint` | 0 errors, 4 pre-existing warnings |
| `npm run build` | PASS |

Owner FY rows after the run: two verified `26-27` proof years, both `legal_allocation_enabled=false`. Series legal allocation count: 0. Schema check `invoice_financial_years_legal_off` still forbids enabling allocation.

### A.4 Financial and stock invariants (reconfirmed)

- Invoice-note `unit_amount` and `billed_units_per_case` snapshots are copied; later master-price and conversion edits do not change the candidate.
- Credited quantity is whole cases × billed units per case (`1 × billed_units_per_case`).
- Unique open adjustment per `return_id`; second idempotency key returns the same id.
- Concurrent prepare stays unique and snapshot-stable.
- Cumulative credited cases cannot exceed original billed/shipped cases.
- Empty or unmatched lot grain fails closed (`verified return has no creditable carton cases` / `return grain does not match a reviewed invoice-note line`).
- `stock_ledger` row count unchanged across prepare.
- `legal_credit_note_number`, `issued_at`, and `statutory_credit_note_id` stay null.
- No public `finalize_invoice_note`, `issue_tax_invoice`, `allocate_statutory_invoice_number`, `create_invoice_credit_note`, or `issue_gst_credit_note`.

### A.5 Statutory blockers

`ready=false`. `legal_issuance_blocked=true`. `legal_allocation_enabled=false` on every financial year and series. Watermark remains `CREDIT ADJUSTMENT PREVIEW — NOT A GST CREDIT NOTE`. UI has no Issue/Finalize credit-note action.

### A.6 Operational flags after E.1A

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false`

### A.7 Remaining limitations

Unchanged from E.1: one return wave per dispatch; owner return-lot tables still empty; `post_delivery_return` not modified; no owner lot backfill; statutory issuance still disabled.

### A.8 Recommendation

E.1 plus these test-only corrections are ready for a single owner commit. Do not enable statutory issuance or operational flags in that commit.
