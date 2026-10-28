# M7.5C.1 — GST configuration and statutory readiness foundation

Local-only configuration foundation after owner-committed M7.5B (`b32235e` on `main`). This phase does **not** calculate GST, allocate statutory invoice numbers, finalize tax invoices, issue credit notes, collect payment, integrate TallyPrime, activate stock flags, migrate cloud databases, or commit.

Starting HEAD: `b32235e0447811fa4b1d728c3be2305d2e2c9648`  
`feat(m7.5b): implement priced invoice foundation and draft workflow`

Working tree was clean at start. Owner had already committed M7.5B. This phase does not commit.

Local migrations applied (Docker only):

- `20261028140000_statutory_configuration_foundation.sql`
- `20261028150000_statutory_configuration_rpcs.sql`
- `20261028160000_statutory_hsn_policy_and_readiness.sql`

Local migration tip after apply: `20261028160000`.

Flags at start and end (operational values, unchanged):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false` (hardcoded in `src/lib/picking/rules.ts`)

---

## 1. Schema changes

Versioned configuration tables, FORCE RLS, writer GUC `app.statutory_write`. Clients have SELECT only. Writes go through SECURITY DEFINER RPCs with `search_path = ''`.

| Table | Purpose |
|---|---|
| `statutory_seller_identities` | Company legal name, address, state/code, GSTIN, PAN, FSSAI, MSME, contacts, bank, signature/seal **captions and private storage paths**, effective dates, verification metadata |
| `shop_tax_identities` | Separate from `shops`. Billing/shipping, optional GSTIN, registration status (`unknown` / `unregistered` / `gst_registered` / `composition`) |
| `product_hsn_classifications` | Accountant-prepared HSN/SAC (4–8 digits). No auto-classification from names |
| `tax_rate_schedules` | CGST/SGST/IGST columns reserved. No default rate. Treatment `unspecified` / `intra_state` / `inter_state` |
| `statutory_policies` | Pending policies: `invoice_date`, `tax_inclusive_exclusive`, `place_of_supply`, `gst_component`, `rounding`, `credit_note_tax`, `numbering` |
| `statutory_config_events` | Append-only configuration history |

Private bucket `statutory-identity-assets` (`public=false`). No client storage policies and no bytes uploaded in this phase. Paths must start with `statutory-identity-assets/`.

Overlap of **verified** windows fails closed via `daterange` (reuses `app_private.selling_price_window`). Duplicate open draft/submitted rows per key fail unique.

Material edit of a verified row supersedes it and inserts a new draft. Edit of submitted/draft invalidates approval back to `draft`.

Historical dispatch posting, invoice-note pricing, and M7.5B draft RPCs are unchanged. `invoice_note_payload` now passes the note id into the extended readiness gate.

---

## 2. Permissions and approval lifecycle

| Permission | Roles |
|---|---|
| `statutory.config.prepare` | `admin`, `accounts` |
| `statutory.config.read` | `admin`, `accounts`, `statutory_verifier` |
| `statutory.config.verify` | `statutory_verifier` only |

New role `statutory_verifier` is **not assigned to existing users**. Accounts can prepare and submit. Accounts **cannot** approve. No automatic grant of verify to Admin or Accounts.

Lifecycle: `draft → submitted → verified`, or copy-on-write `verified → superseded` + new `draft`. `cancelled` is reserved. Version mismatch returns `PT409`.

Godown Manager has none of these permissions (cross-godown / warehouse operators cannot read or write statutory identity).

---

## 3. Sample invoice field mapping

The sample layout `SDI/26-27/19656` is a **field reference only**. Those values are not seeded.

| Sample field | Configuration home | This phase |
|---|---|---|
| Seller legal name / address / GSTIN / PAN / FSSAI | `statutory_seller_identities` | Configurable, not hardcoded |
| Customer billing name / address / GSTIN | `shop_tax_identities` | GSTIN optional unless `gst_registered` |
| HSN | `product_hsn_classifications` | Manual; no name inference |
| Tax rates / CGST-SGST-IGST | `tax_rate_schedules` | Columns exist; **no calculation** |
| Invoice number `PREFIX/FY/seq` | `statutory_policies.numbering` payload | Policy record only; **no allocate/consume** |
| Invoice date vs dispatch date | `statutory_policies.invoice_date` | Unapproved until verifier |
| Signature / seal | captions + private path | Metadata only; no public asset |

Draft invoice-note numbers remain `IN-YYYYMMDD-######` and are not tax invoice numbers.

---

## 4. Readiness-gate evidence

`assess_invoice_finalization_readiness(p_invoice_note_id uuid default null)` always returns:

- `ready: false`
- `legal_issuance_blocked: true`
- hard blockers `tax_calculation_unimplemented` and `finalize_rpc_disabled`

Diagnostic blockers (when applicable): seller identity unverified, signature/seal unapproved, customer identity incomplete, product HSN missing, pricing/billing conversion invalid, tax classification unapproved, tax treatment unapproved, numbering unapproved, invoice date unapproved, place of supply / GST component / rounding / credit-note tax unapproved.

Completing and verifying every configuration record **cannot** set `ready` true. There is no `finalize_invoice_note`, `issue_tax_invoice`, or `allocate_statutory_invoice_number` RPC.

---

## 5. Accountant-pending decisions

Still required before any later issuance phase (M7.5C.2+):

- Who is assigned `statutory_verifier` (named accountant, not a role rename of Accounts)
- Seller legal identity for the operating company (do not copy another company’s GSTIN)
- Tax-inclusive vs exclusive selling prices (I3)
- Place of supply and CGST/SGST vs IGST selection
- Actual HSN/SAC per SKU and approved rate schedules (I11) — zero is allowed only as an explicit recorded value, never as a silent default
- Invoice date vs dispatch confirmed-at (I10)
- Numbering prefix, FY representation, sequence scope (company vs godown), reset rule (I7). Example `SDI/26-27/19656` is not the policy
- Rounding and credit-note tax treatment
- Signature/seal image custody (private bucket only)
- Whether DN print identity (`company.legal_name` in `app_configuration`) should later be superseded by verified seller identity on legal copies

---

## 6. Test results

| Proof | Result |
|---|---|
| SQL `phase_m7_5c1_statutory_foundation.sql` | PASS ROLLBACK |
| HTTP `phase_m7_5c1_http_integration.mjs` | PASS 9 checks |
| Concurrency duplicate open seller drafts | PASS 2 checks |
| SQL `phase_m7_5b_invoice_foundation.sql` | PASS ROLLBACK |
| HTTP `phase_m7_5b_http_integration.mjs` | PASS 11 checks |
| Concurrency M7.5B overlapping prices | PASS 2 checks on retry (see note) |
| SQL `phase_m7_4b_delivery.sql` | PASS ROLLBACK |
| SQL `phase_m7_3b_short_shipment.sql` | PASS ROLLBACK |
| Vitest full suite | **233 passed / 0 failed / 0 skipped** (39 files) |
| Playwright `invoice-notes` + `statutory-config` + `product-search` | **6 passed / 0 failed / 0 skipped** |
| Typecheck `tsc -b` | PASS |
| Lint `oxlint` | PASS (4 pre-existing warnings, 0 errors, none in C.1 files) |
| `npm run build` | PASS |

C.1 SQL/HTTP covered: missing GSTIN (seller submit blocked; unregistered shop allowed), invalid GSTIN, missing/short HSN, unspecified tax schedule cannot verify, overlapping verified tax windows, unauthorized Accounts verify, stale version, configuration edit invalidates submitted approval, godown cannot list, no issuance RPC, readiness stays false after a complete verified set, M7.5B `list_invoice_notes` still works, `post_delivery_return` still registered, flags false.

M7.5B overlapping-price concurrency failed once (`wins=2`) then passed on retry. That race is the pre-existing trigger-only overlap check (no `btree_gist` exclusion). C.1 did not change selling-price writers.

---

## 7. Remaining implementation dependencies

M7.5C.2 (not this phase): validated GST calculation, statutory number consume, legal finalize RPC, and only then may `ready` become true.

Unresolved from earlier phases (unchanged): **M5.4D** write-off vs transfer XOR harness. Not an invoice blocker.

---

## 8. Git

No commit, push, cloud migrate, Netlify deploy, or flag activation in this phase.
