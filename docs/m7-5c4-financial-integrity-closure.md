# M7.5C.4 — Financial integrity closure

Local-only review of the priced invoice + GST-preview foundation after the owner committed M7.5C.3 / C.3A (`f838089` on `main`). This phase does **not** finalize tax invoices, allocate statutory numbers, issue signed PDFs, post credit notes, collect payment, integrate TallyPrime, activate stock flags, migrate cloud databases, reset the owner's local database, or commit.

Starting HEAD: `f8380892a5f6b7766f093becc6ae2e050940659e`  
`fix(m7.5c3): enforce selling price integrity and stabilize regressions`

Working tree was clean at start. Owner had already committed M7.5C.3. This phase does not commit.

No schema migrations were added. Local migration tip remained `20261028220000`.

Flags at start and end (operational values, unchanged):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false` (hardcoded in `src/lib/picking/rules.ts`)

---

## 1. Baseline

Confirmed on the owner's local database before review work:

| Check | Result |
|---|---|
| Branch | `main` |
| HEAD | `f838089` M7.5C.3 |
| Working tree | clean |
| Migration tip | `20261028220000` |
| GiST exclusion `product_selling_prices_active_window_excl` | present (`contype=x`) |
| Active selling-price overlap groups | 0 |
| `finalize_invoice_note` / `issue_tax_invoice` / `allocate_statutory_invoice_number` | absent |
| Operational stock flags | all false |

---

## 2. Schema and RPC review

No new public RPCs. Financial writers remain `SECURITY DEFINER` with `search_path = ''`:

- `upsert_product_selling_price`
- `deactivate_product_selling_price`
- `prepare_invoice_note`
- `review_invoice_note`
- `preview_invoice_tax`
- `get_invoice_tax_preview`
- `assess_invoice_finalization_readiness` (stable; always `ready=false`)

FORCE RLS remains on `product_selling_prices`, `product_selling_price_events`, `invoice_notes`, `invoice_note_lines`, `invoice_tax_previews`, and `invoice_tax_preview_lines`. Client table grants are select-only. Writes require GUC `app.invoice_write` / `app.tax_preview_write` plus the per-row guards.

`invoice_notes_amount_check` still requires `tax_amount = (0)::numeric` and `grand_total = subtotal_amount`. Reviewed notes never absorb GST into the priced snapshot.

`assess_invoice_finalization_readiness` always appends `tax_preview_is_not_a_tax_invoice` and `finalize_rpc_disabled`, returns `legal_issuance_blocked=true`, and never allocates a number.

---

## 3. Price integrity

Shop override beats default. Inclusive `daterange(..., '[]')` via `app_private.selling_price_window`. Open end is infinity. Missing and ambiguous windows fail closed (`hit_count <> 1`).

Independent lifecycle fixture (`phase_m7_5c4_financial_integrity.sql`, rolled back):

| As-of | Scope | Expected |
|---|---|---|
| 2026-03-15 | shop present | historical default Jan–Jun INR 8 |
| 2026-07-15 | shop present | shop override INR 11.5 |
| 2026-07-15 | no shop | current default INR 10 |
| 2025-12-01 | any | missing → fail closed |
| after shop deactivation | shop present | fallback current default |
| live default rewritten to INR 99 | snapshot variable | stays 11.5 |

Overlapping active insert is rejected by GiST exclusion. Inactive historical rows may occupy the same window as the active successor.

HTTP: review fails closed when the live price fingerprint changes; review succeeds when fingerprints still match; a later price update does not rewrite a reviewed snapshot or its tax preview.

C.2 concurrency: three default races and one shop-specific race each serialize to **1 winner / 1 loser**. Exclusion plus `pg_advisory_xact_lock` remain.

Prices still cannot be deleted (`42501`). Deactivation writes `price_deactivated` events and audit.

---

## 4. Billing conversion

Inventory grain stays whole cases. Billed quantity is derived:

`billed_qty := dispatched_cases * billed_units_per_case`  
`line_amount := round(billed_qty * resolved.unit_amount, 2)`

Independent conversion (not taken from `gst_line_calc`):

`3 cases × 12.5000 billed units × INR 10.1234` → billed qty `37.5000`, line `379.63`.

Prepare reads posted `DISPATCH` consume only. Short-shipment operational billing is not enabled (`SHORT_SHIPMENT_OPERATIONAL=false`). Prepare is idempotent for the same dispatch key (M7.5B / C.2 HTTP). Billing-unit changes after review cannot rewrite pinned line snapshots because reviewed notes are immutable and prepare does not reopen them.

---

## 5. GST mathematics

`app_private.gst_round` is `round(numeric, 2)` and accepts only `nearest_half_up` / `0.01`. There is no JavaScript float path.

Independent expected values use PostgreSQL `round()` in the C.4 SQL file, then compare to `gst_line_calc` output. The engine is never used as both sides of an assertion.

| Case | Independent expected | Engine |
|---|---|---|
| Exclusive intra 100 at 2.5+2.5 | taxable 100.00, CGST 2.50, SGST 2.50, total 105.00 | match |
| Exclusive IGST 200 at 18 | IGST 36.00, total 236.00 | match |
| Multi-line header | 105.00 + 236.00 = 341.00 | match |
| Inclusive intra 105 at 5% | taxable 100.00, tax 5.00, total 105.00 | match |
| Inclusive IGST 118 at 18 | taxable 100.00, IGST 18.00 | match |
| Exclusive zero-rate 50 | tax 0, total 50.00 | match |
| Rounding 1.255 / 0.005 / 1.225 | 1.26 / 0.01 / 1.23 | `gst_round` matches `round()` |
| Inclusive 10.01 at 18% | residual paisa stays in tax; taxable+tax = 10.01 | match |

Missing / unapproved / ambiguous policy (`verified_policy`) fail closed. Overlapping verified statutory windows stay fail-closed (C.1 HTTP). Stale schedule approval versus preview stays fail-closed (C.2 HTTP). Tax policy supersession versus an existing preview stays deterministic (C.2 HTTP).

Inclusive residual stays in tax: `tax := round(line) - taxable`.

---

## 6. Tax preview snapshots

Preview is allowed only on **reviewed** notes. Watermark is exactly `TAX CALCULATION PREVIEW — NOT A TAX INVOICE`.

C.2 HTTP (22 checks) on the owner database:

- Draft preview watermarked, no legal seal
- Driver / store keeper cannot preview
- Duplicate preview is idempotent
- Concurrent duplicate preview requests share one current snapshot
- Price update versus preview leaves reviewed snapshots unchanged
- Tax policy supersession versus preview stays deterministic
- Tax schedule approval versus preview stays fail-closed
- Cross-godown manager cannot preview another branch note
- Permission revocation versus preview leaves one current snapshot
- Statutory readiness never reports ready

Preview does not mutate stock, statutory numbers, or reviewed `tax_amount` / `grand_total`.

---

## 7. Independent reconciliation

C.4 SQL computes billed qty, line amount, taxable, CGST, SGST, IGST, tax, and header totals with inline `round()`, then compares those figures to engine JSON. It does not call `gst_line_calc` twice and treat agreement as proof.

Posted-dispatch pipeline reconciliation (cases → billed qty → price snapshot → preview) is the C.2 HTTP path, which also asserts that a later live price change cannot rewrite the reviewed note or the stored preview.

---

## 8. Security and audit

| Control | Proof |
|---|---|
| FORCE RLS | catalog + C.4 SQL |
| SECURITY DEFINER financial RPCs | `prosecdef=true` |
| Accountant vs operations | Accounts cannot prepare; GM prepares; Accounts review/cancel; Accounts cannot verify statutory config |
| Ownership isolation | arbitrary `ownership_code` rejected |
| Cross-godown | preview denied |
| Client financial writes | GUC off → `42501` on price update and tax-preview INSERT (INSERT is required because UPDATE of zero rows does not fire the per-row guard) |
| Immutable reviewed notes | price-fingerprint review gate + snapshot variables unchanged after live rewrite |
| Anon PostgREST | isolated replay `SELECT public.products` → `42501` |

---

## 9. Concurrency

| Suite | Result |
|---|---|
| M7.5B overlapping default prices | 1 winner / 1 loser |
| M7.5C.1 duplicate open HSN | 1 winner / 1 loser |
| M7.5C.2 default ×3 + shop | 1 winner / 1 loser each (5 checks) |
| C.2 concurrent duplicate tax preview | one current snapshot |
| C.2 permission revocation versus preview | one current snapshot |
| C.2 price update versus review/preview | fail-closed / snapshot unchanged |
| M5.4D | 9/9 |

GiST exclusion is now installed on the owner database (C.3A). Advisory locks remain.

---

## 10. Isolated clean migration replay

Separate disposable stack only. Directory `C:\Users\Hash\Desktop\Hashdev\sherlyos-c4replay`, `project_id=sherlyosc4`, remapped ports `55321/55322/55320/55323/55324/55327`. Owner `sherlyos` on `54321/54322` was not stopped.

`npx supabase start` exit 0. Applied the full chain through `20261028220000`, then `supabase/seed.sql`. This was a full `supabase start`, not a partial SQL replay.

Smoke on `supabase_db_sherlyosc4`:

- Tip `20261028220000`
- Exclusion present, overlap groups 0
- Operational flags false
- No finalize / issue / allocate RPCs
- `phase_m7_5c4_financial_integrity.sql` PASS (rolled back)
- `phase_m7_5c2_gst_calculation.sql` PASS (rolled back)
- `phase_m7_5c1_statutory_foundation.sql` PASS (rolled back)
- Anon PostgREST `42501` on `public.products`

`phase_m7_5c3a_exclusion.sql` was **not** used as isolated smoke: it binds owner-database survivor price UUIDs. Exclusion on the clean replay is already proven by catalog + C.4 SQL.

Stopped with `npx supabase stop` from the replay directory (`project_id_filter: sherlyosc4`). Owner containers remained healthy.

---

## 11. Statutory invoice safety

Authenticated admin `assess_invoice_finalization_readiness()` on the owner database after the suites:

- `ready=false`
- `legal_issuance_blocked=true`
- blockers include `tax_preview_is_not_a_tax_invoice` and `finalize_rpc_disabled`

Actor used: `admin.m75bc_mvrw22dn@example.com` (`39233b4a-814a-4b04-9edd-d227b21af648`).

No statutory number allocation, final signed PDF, credit-note posting, or invoice-driven stock ledger mutation was added.

---

## 12. Regression totals

Owner database. Playwright trial 1 is recorded; trial 2 is after the reports KPI timeout bump (test-only).

| Check | Result |
|---|---|
| M7.5C.4 SQL `phase_m7_5c4_financial_integrity.sql` | PASS (rolled back) |
| M7.5C.3A exclusion SQL | PASS (rolled back) |
| M7.5B SQL / HTTP / concurrency | PASS / 11 / 2 |
| M7.5C.1 SQL / HTTP / concurrency | PASS / 9 / 2 |
| M7.5C.2 SQL / HTTP / concurrency | PASS / 22 / 5 |
| M7.4B SQL `phase_m7_4b_delivery.sql` | PASS (rolled back) |
| M7.3B SQL `phase_m7_3b_short_shipment.sql` | PASS (rolled back) |
| M5.4D SQL / concurrency | PASS / 9/9 |
| Vitest | 39 files, **233 passed** |
| Playwright trial 1 | **100 passed / 1 failed / 3 did not run** (`reports.spec.ts` KPI 5s timeout while `get_operations_dashboard` took ~5.16s against 1053 leftover branches) |
| Playwright reports retry after timeout bump | **5 passed** |
| Playwright trial 2 (full suite) | **104 passed** (7.0m) |
| Typecheck | PASS |
| Lint (oxlint) | 0 errors; 4 pre-existing warnings |
| Production build | PASS (`tsc -b && vite build`) |
| Isolated replay C.4 / C.2 / C.1 SQL | PASS |

---

## 13. Remaining accountant decisions

1. Statutory issuance (finalize, number allocation, signed tax invoice) remains owner-gated and is **not** opened by C.4.
2. Payment collection and TallyPrime remain out of M7.5 unless separately approved.
3. Optional: decide whether ordinary write-off and quarantine transfer should become mutually exclusive (M5 product rule). The M5.4D harness still allows the sequential pipeline.
4. Optional: clean leftover local test **branches** (1053 on the owner database). Do not delete historical financial records or invoice-pinned lots to do that.

---

## 14. Remaining risks

- Local leftover HTTP/e2e **branches** (~1053) make `get_operations_dashboard` scan `can_work_at_branch` per branch (~5.16s for `godown.m4e2e`). Reports KPI assertions now wait 20s. This is fixture volume, not a GST/price defect.
- Invoice HTTP leftovers still carry `lot_id` on ledger (`m75bhttp-*`, `m75c2http-*`). Correct, and they block legal cutover-flag updates via Rule C.
- `cleanupDisposableTestStock` may still null unpinned disposable ledger `lot_id`. Pinned invoice-note lots are excluded.
- M5.4D write-off vs transfer is an allowed sequential pipeline, not a product XOR.
- `supabase_vector_sherlyos` continues to restart. Pre-existing analytics sidecar; not changed.
- Isolated `sherlyosc4` was stopped; replay artifacts live outside the git worktree.

---

## 15. Owner approvals / git

No Git commit, push, fetch, rebase, or reset was performed in this phase. Owner commits manually.

Changed files for owner review:

- `supabase/tests/phase_m7_5c4_financial_integrity.sql` (new independent recon + catalog proofs)
- `tests/e2e/reports.spec.ts` (KPI visibility timeout 20s)
- `docs/m7-5c4-financial-integrity-closure.md` (this file)

No new migrations.

### Verdict

**M7.5C.4 FINANCIAL INTEGRITY CLOSED — READY FOR OWNER REVIEW**
