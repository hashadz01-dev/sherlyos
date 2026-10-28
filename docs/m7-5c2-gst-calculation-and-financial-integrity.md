# M7.5C.2 — GST calculation engine and financial-integrity hardening

Local-only calculation foundation after owner-committed M7.5C.1 (`eba4f0b` on `main`). This phase does **not** finalize tax invoices, allocate statutory numbers, issue signed PDFs, post credit notes, collect payment, integrate TallyPrime, activate stock flags, migrate cloud databases, or commit.

Starting HEAD: `eba4f0b95fc14597b6ec85f3f4942c033a57543b`  
`feat(m7.5c1): implement statutory configuration and readiness controls`

Working tree was clean at start. Owner had already committed M7.5C.1. This phase does not commit.

Local migrations applied (Docker only):

- `20261028170000_selling_price_window_serialization.sql`
- `20261028180000_statutory_operating_ownership.sql`
- `20261028190000_gst_calculation_preview.sql`
- `20261028200000_tax_preview_config_serialization.sql`

Local migration tip after apply: `20261028200000`.

Flags at start and end (operational values, unchanged):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false` (hardcoded in `src/lib/picking/rules.ts`)

---

## 1. Price-window concurrency

### Root cause

M7.5B overlap protection was a `BEFORE` trigger `EXISTS` check with **no writer lock**. Two sessions could both pass the check against the pre-insert snapshot and both commit.

Reproduction (two simultaneous `upsert_product_selling_price` sessions, open-ended `current_date` windows, amounts 10 and 11):

- Before the lock: **2 wins / 0 losses** on SKU `m75c2race_mvrwkab4`.
- Leftover overlap from the M7.5B harness also remains on SKU `m75bc_mvrw22dn-sku` (amounts 10 and 11, both active, both open-ended from 2026-10-28).

Those rows were **not deleted or silently deactivated**. They are test-harness residue, not operational catalogue prices.

### Database-enforced prevention

`btree_gist` is installed. The preferred exclusion constraint (`product_selling_prices_active_window_excl`) is **not installed** because the leftover overlaps would make `ALTER TABLE ... EXCLUDE` fail.

Prevention that **is** installed:

1. `app_private.lock_selling_price_scope(product_id, shop_id)` takes `pg_advisory_xact_lock(hashtextextended('selling-price:' || product || ':' || shop, 0))`. Null shop (default list) is a distinct key from any shop-specific price.
2. The overlap trigger takes that lock **before** the `EXISTS` window check.
3. `upsert_product_selling_price` takes the same lock at the start of the writer.

Effective-date semantics are unchanged (`app_private.selling_price_window`). Historical rows are not rewritten.

After the lock, three repeated default races and one shop-specific race each produced **1 winner / 1 loser**. `resolve_selling_price` already fail-closes when `hit_count > 1`, so the leftover overlapping SKUs cannot be billed ambiguously.

Installing the exclusion constraint later requires an explicit owner decision to deactivate (not delete) the two leftover test SKUs.

---

## 2. Ownership isolation proof

SherlysOS is a **single operating company**, not a multi-tenant split.

| Control | Behaviour |
|---|---|
| Singleton `statutory_operating_ownership` | One open row (`draft` / `submitted` / `verified`). Clients cannot invent a second company code. |
| `app_private.require_operating_ownership` | Empty input stamps the registered code. Any other code raises `42501`. |
| Stamp trigger | Seller, shop tax, HSN, tax schedules, and policies all receive the registered code on insert/update. |
| `SECURITY DEFINER` RPCs | Still check `can_prepare_statutory_config` / `can_verify_statutory_config` / `can_read_statutory_config` with `search_path = ''`. They do not accept an arbitrary ownership as a tenant switch. |
| Seller identities | Unique open draft/submitted per registered ownership. |
| Customer tax identities | Per shop, stamped to the operating ownership. GSTIN required by table check when `registration_status = 'gst_registered'`. |
| HSN / schedules / policies | Stamp + permission + verified-window overlap. Preview lookup is ownership-scoped. |
| Drivers / store keepers | No statutory prepare/verify; no tax-preview permission (`invoice_notes.prepare` or `invoices.review` required). |
| Cross-godown | Preview checks `can_work_at_branch(note.branch_id)`. |

Arbitrary `ownership_code` `'NOT-THE-OWNER'` / `'ZZ-OTHER'` is rejected in SQL and HTTP.

No company/org table beyond this singleton was added.

---

## 3. GST calculation formulas

All arithmetic is PostgreSQL `NUMERIC`. The browser never computes GST (`src/lib/invoices/tax-preview.ts` only calls RPCs).

There is **no default** tax-inclusive versus exclusive treatment. `app_private.gst_round` rejects any mode other than explicit `nearest_half_up` at increment `0.01`. `app_private.verified_policy` requires exactly one verified row for the ownership and as-of date.

### Exclusive

- Taxable value = `round(line_amount, 2)`
- Intra-state: `cgst = round(taxable * cgst_rate / 100, 2)`, `sgst = round(taxable * sgst_rate / 100, 2)`, `igst = 0`
- Inter-state: `igst = round(taxable * igst_rate / 100, 2)`, `cgst = sgst = 0`
- Line total = taxable + tax

Worked exclusive intra-state: 100 at 2.5% + 2.5% → taxable 100.00, CGST 2.50, SGST 2.50, line 105.00.

Worked exclusive IGST: 200 at 18% → IGST 36.00, line 236.00.

### Inclusive

- Rate = CGST+SGST (intra) or IGST (inter)
- Taxable = `round(line_amount * 100 / (100 + rate), 2)`
- Tax = `round(line_amount, 2) - taxable` (residual paisa stays in tax, not lost)
- Intra-state split: CGST = `round(tax * cgst / rate, 2)`, SGST = tax − CGST
- Inter-state: IGST = tax

Worked inclusive intra-state: 105 at 2.5% + 2.5% → taxable 100.00, tax 5.00, line 105.00.

Worked inclusive IGST: 118 at 18% → taxable 100.00, IGST 18.00.

### Zero rate

Explicit 0% is allowed only as recorded schedule rates. Taxable = rounded line amount, tax = 0. Silent null rates fail closed (`tax_rate_incomplete`).

### Rounding

PostgreSQL `round(numeric, 2)` is half away from zero. For positive INR amounts that is nearest-half-up at 0.01.

Proofs: `1.255 → 1.26`, `0.005 → 0.01`, `1.225 → 1.23`. Mode `floor` is rejected.

Invoice totals are the NUMERIC sum of per-line results, not a second round of the header.

---

## 4. Configuration dependencies

Preview calculates only when every input is explicit and verified as-of the invoice-note date:

- Registered operating ownership
- Verified seller GSTIN + state code
- Verified shop tax identity; GSTIN if `gst_registered`; state code for place of supply
- Verified HSN/SAC per billed product (exactly one window)
- Verified tax schedule for that HSN + resolved supply kind (exactly one window)
- Verified policy `tax_inclusive_exclusive.payload.pricing` in (`inclusive`, `exclusive`)
- Verified policy `place_of_supply.payload.basis` in (`billing_state`, `shipping_state`)
- Verified policy `rounding` = `nearest_half_up` / `0.01`
- Verified policy `gst_component` intra=`cgst_sgst`, inter=`igst`

`shipping_state` currently **fail-closes**. `shop_tax_identities` stores one billing `state_code` and a shipping address text; there is no shipping-state field. The engine does not infer billing state as place of supply.

Missing, unapproved, overlapping, or stale configuration returns structured blockers and `calculated: false`. It does not invent rates.

Synthetic HTTP/SQL rates (2.5/2.5, 18, 0) are **not** production verified configuration.

---

## 5. Place of supply

Resolver inputs: seller state, customer billing state, approved `basis`, tax registration, invoice-note `as_of_date`.

- `basis = billing_state` and seller state = customer state → `intra_state` (CGST/SGST)
- States differ → `inter_state` (IGST)
- Incomplete states → blocker `place_of_supply_incomplete`
- Unapproved / missing policy → `place_of_supply_unapproved`
- `basis = shipping_state` → `place_of_supply_shipping_state_unavailable`

No IGST/CGST default is inferred from shop type or HSN name.

---

## 6. Preview lifecycle and snapshot integrity

`preview_invoice_tax(note_id, expected_version)`:

1. Requires `invoice_notes.prepare` or `invoices.review`, plus `can_work_at_branch`.
2. Locks the invoice note (`FOR UPDATE`) and the tax-config advisory key for the operating ownership.
3. Requires status `reviewed`. Draft/submitted notes cannot calculate.
4. Validates source snapshots (reviewed line amounts, HSN version, schedule version, policy versions).
5. On blockers: returns watermarked JSON, writes nothing to `invoice_notes`.
6. On success: fingerprints inputs, reuses the current preview when the fingerprint matches, otherwise marks the previous current row `is_current=false` and inserts a new header + lines.

Watermark (check-constrained): `TAX CALCULATION PREVIEW — NOT A TAX INVOICE`.

`invoice_notes.tax_amount` stays `0` (`invoice_notes_amount_check`). Reviewed price snapshots are not rewritten.

`get_invoice_tax_preview` marks `stale=true` when the note version moved or any snapshotted seller/shop/policy/HSN/schedule row is no longer the live verified version. Regeneration is a new `preview_invoice_tax` call.

Returns / short shipment: billed quantities stay as reviewed. Delivery returns are **not netted**; the payload sets `returns_not_netted` when `stock_delivery_returns` exist for the dispatch. Credit notes are not posted.

Writes use GUC `app.tax_preview_write`. Clients have SELECT only. FORCE RLS on preview tables.

---

## 7. Statutory readiness gate

`assess_invoice_finalization_readiness` always returns:

- `ready: false`
- `legal_issuance_blocked: true`

Hard blockers: `tax_preview_is_not_a_tax_invoice`, `finalize_rpc_disabled`.

There is still no `finalize_invoice_note`, `issue_tax_invoice`, or `allocate_statutory_invoice_number`. Completing a calculated preview cannot flip `ready`.

`confirm_dispatch`, `post_delivery_return`, and `verify_stock_receipt` were not changed.

---

## 8. Security model

- FORCE RLS on statutory and preview tables
- Trusted RPC boundary; `SECURITY DEFINER` with `search_path = ''`
- Explicit permission and branch checks inside definers
- `statutory_verifier` still not granted to Admin/Accounts by default
- No direct client financial writes
- No stock ledger mutation in this phase
- No privilege expansion to drivers or store keepers
- Concurrent preview vs policy/schedule verify serializes on `lock_tax_config_scope`

---

## 9. Test evidence

| Proof | Result |
|---|---|
| SQL `phase_m7_5c2_gst_calculation.sql` | PASS ROLLBACK |
| HTTP `phase_m7_5c2_http_integration.mjs` | PASS 22 checks |
| Concurrency overlapping default (×3) + shop-specific prices | PASS 5 checks |
| SQL `phase_m7_5c1_statutory_foundation.sql` | PASS ROLLBACK |
| HTTP `phase_m7_5c1_http_integration.mjs` | PASS 9 checks |
| Concurrency C.1 open HSN drafts | PASS 2 checks |
| SQL `phase_m7_5b_invoice_foundation.sql` | PASS ROLLBACK |
| HTTP `phase_m7_5b_http_integration.mjs` | PASS 11 checks |
| Concurrency M7.5B overlapping prices | PASS 2 checks |
| SQL `phase_m7_4b_delivery.sql` | PASS ROLLBACK |
| SQL `phase_m7_3b_short_shipment.sql` | PASS ROLLBACK |
| SQL M5.2 / M5.4B / M5.4D | PASS ROLLBACK |
| M5.4D concurrency (isolated this run) | PASS 9/9 |
| Vitest full suite | **233 passed / 0 failed / 0 skipped** (39 files) |
| Typecheck `tsc -b` | PASS |
| Lint `oxlint` | PASS (4 pre-existing warnings, 0 errors) |
| `npm run build` | PASS |

C.2 SQL/HTTP covered: 0% and nonzero tax, inclusive and exclusive, CGST/SGST and IGST, multi-line NUMERIC sum, rounding boundaries, unapproved rounding mode, unapproved policy lookup, GSTIN-required constraint, arbitrary ownership, driver/store-keeper/cross-godown denial, duplicate preview idempotency, concurrent duplicate preview, price update vs preview (reviewed amounts unchanged), policy supersession vs preview, schedule approval vs preview, permission revocation vs preview, readiness `ready=false`, note `tax_amount=0`.

Playwright full suite: **103 passed / 1 failed / 0 skipped** (104 tests). The failure is `lot-reconciliation` “admin applies approved attribution after local legacy seed”: `wipeLocalLotsIfSafe` correctly refused because lot-attributed ledger rows remain from local HTTP invoice-note seeds. Those lots are referenced by invoice-note lines and were not deleted. Not a GST calculation defect.

Clean-database migration replay was **not** performed on a separate full Supabase instance.

---

## 10. Remaining accountant approvals

Still required before any issuance phase:

- Named `statutory_verifier` assignment
- Real seller legal identity / GSTIN / state (do not copy another company’s GSTIN)
- Tax-inclusive vs exclusive selling prices
- Place-of-supply basis, including whether a shipping-state column is needed
- Actual HSN/SAC per SKU and approved rate schedules
- Invoice date vs dispatch confirmed-at
- Numbering prefix, FY, sequence scope
- Rounding and credit-note tax treatment
- Signature/seal image custody
- What to do with leftover overlapping **test** selling prices (`m75bc_mvrw22dn-sku`, `m75c2race_mvrwkab4`) so the gist exclusion can be installed

---

## 11. Statutory issuance blockers (unchanged)

No legal invoice finalization, statutory numbering, signed final PDF, credit-note posting, payment collection, or TallyPrime.

---

## 12. Git

No commit, push, fetch, rebase, reset, cloud migrate, Netlify deploy, or flag activation in this phase.
