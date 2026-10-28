# M7.5B — Priced invoice foundation, pricing engine, and draft workflow

Local-only implementation after owner-committed M7.5A (`5eab4e1` on `main`). This phase does **not** issue tax invoices, consume statutory numbers, calculate GST, post credit notes, activate stock flags, migrate cloud databases, or commit.

Starting HEAD: `5eab4e1791c3ac4416dc400784b719c095cdc267`  
`docs(m7.5a): define invoice architecture and approved business rules`

Working tree was clean at start. Owner had already committed M7.5A. This phase does not commit.

Local migrations applied (Docker only):

- `20261028100000_product_selling_prices.sql`
- `20261028110000_invoice_note_drafts.sql`
- `20261028120000_invoice_note_payload_shop.sql`
- `20261028130000_prepare_invoice_note_grain_alias.sql`

Flags at start and end (operational values, unchanged):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false` (hardcoded in `src/lib/picking/rules.ts`)

Approved owner rules implemented in draft form: **D3**, **I1–I12**. Accountant-dependent rules stay blocked: **I3, I7, I10, I11**.

---

## 1. What this phase added

### B1 — Product / shop pricing

- `products.billing_unit` and `products.billed_units_per_case` (both null or both set, conversion > 0). Stock remains whole cases. Invoice billed quantity = shipped cases × conversion. Never assume 1 case = 1 nos.
- `product_selling_prices` in **INR only**. `shop_id` null is the default; shop-specific rows override. Overlapping **active** windows fail closed via `daterange` (no `btree_gist`).
- Permissions: `products.price.manage` / `products.price.read` for Admin and Accounts. Godown Manager does not browse the price book.
- RPCs: `set_product_billing_conversion`, `upsert_product_selling_price`, `deactivate_product_selling_price`, `list_product_selling_prices`.

### B2 — Priced invoice-note drafts from posted DISPATCH

- Tables `invoice_notes`, `invoice_note_lines`, `invoice_note_events`. FORCE RLS. Writer GUC `app.invoice_write`.
- Statuses: `draft → submitted → reviewed`, or `cancelled`. Unique **open** note per dispatch.
- Quantity source: `dispatch_return_source_grains` crossed with the posted DISPATCH ledger. Delivery-note ordered quantity is not billed.
- Price snapshot frozen at prepare. Review re-resolves as-of dispatch date and fails closed on fingerprint mismatch.
- Draft number `IN-YYYYMMDD-######` is **not** a tax invoice number. Sequence is revoked from clients.
- Tax amount is forced to 0. No GST rate, HSN, or inclusive/exclusive engine.

### B3 — Accounts review and draft print preview

- New permission `invoices.review` (Admin, Accounts). Unused `invoices.issue` is **not** used for review.
- GM submits drafts. Accounts reviews. GM may cancel draft/submitted; Accounts may cancel submitted/reviewed. Correction path is cancel + re-prepare.
- Preview copies: recipient / transporter / accounts. Watermark: `DRAFT INVOICE NOTE — NOT A TAX INVOICE`. No legal seal (I9).
- `assess_invoice_finalization_readiness()` always returns `ready: false` with accountant blockers. **No finalize / issue RPC exists.**

Credit notes: related delivery returns appear as `credit_note_candidates` with `issuable: false` (I5). Nothing is posted.

---

## 2. Exact files

New schema:

- `supabase/migrations/20261028100000_product_selling_prices.sql`
- `supabase/migrations/20261028110000_invoice_note_drafts.sql`
- `supabase/migrations/20261028120000_invoice_note_payload_shop.sql`
- `supabase/migrations/20261028130000_prepare_invoice_note_grain_alias.sql`

New client:

- `src/lib/invoices/rules.ts`, `src/lib/invoices/api.ts`, `src/lib/pricing/api.ts`
- `src/features/invoices/InvoicesPage.tsx`
- `src/features/invoices/InvoiceNoteDetailPage.tsx`
- `src/features/invoices/InvoiceNotePreviewPage.tsx`
- `src/features/masters/prices/PricesPage.tsx`

Wired: `src/app/navigation.ts`, `src/app/router.tsx`, `src/app/lazy-pages.ts`, `src/features/masters/products/ProductsPage.tsx` (billing conversion), `src/lib/masters/product-search.ts` (billing columns on getProduct).

Tests:

- `supabase/tests/phase_m7_5b_invoice_foundation.sql`
- `supabase/tests/phase_m7_5b_http_integration.mjs`
- `supabase/tests/phase_m7_5b_concurrency.mjs`
- `tests/unit/invoice-note.test.ts`
- `tests/e2e/invoice-notes.spec.ts`
- `tests/e2e/disposable-stock.ts` (`m75b%` prefix)

---

## 3. Proofs run locally

| Proof | Result |
|---|---|
| SQL `phase_m7_5b_invoice_foundation.sql` | PASS ROLLBACK |
| HTTP `phase_m7_5b_http_integration.mjs` | PASS 11 checks |
| Concurrency overlapping prices | PASS 2 checks |
| Vitest invoice-note + product-search + rpc-user-error | PASS |
| Typecheck (`tsc -b`) | PASS |
| Playwright invoice-notes + product-search | PASS after exact heading match |
| `npm run build` | PASS |

HTTP proofs: Accounts/driver cannot prepare; GM draft bills DISPATCH consume (2 cases × 12 nos × ₹10.50 = ₹252); idempotent prepare; unique open note; submit; review fails after a live shop price change; cancel; replacement uses shop price; review succeeds; transporter preview has no seal; readiness never ready.

HTTP replica-enables dual-write only for the disposable pick/dispatch seed, then restores flags false. Invoice-note lines keep lot FKs, so the harness does not delete those lots.

---

## 4. Still pending (accountant / later phases)

- I3 tax-inclusive vs exclusive
- I7 financial-year statutory numbering
- I10 invoice date vs dispatch date
- I11 GST rates, HSN, verified GST identity
- Finalize / issue RPC and legal seal on PDF
- Credit-note issuance after verified return
- Payment collection and TallyPrime (out of M7.5)

Unresolved from earlier phases (unchanged): **M5.4D** write-off vs transfer XOR harness remains too strict relative to `consume_damage_holds` including `transferred`. Not an invoice blocker.

---

## 5. Git

No commit, push, cloud migrate, Netlify deploy, or flag activation in this phase.
