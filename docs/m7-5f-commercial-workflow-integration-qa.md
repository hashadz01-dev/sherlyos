# M7.5F — End-to-end commercial workflow integration & QA

Local-only integration and quality closure after owner-committed M7.5E.2 (`8f15554` on `main`). This phase does **not** add statutory invoice issuance, GST credit notes, legal numbering, payment posting, stock-writer changes, operational flag activation, or a git commit.

Starting HEAD: `8f15554bab239cc1b6541991babef1a82e9006aa`  
`feat(m7.5e2): add credit adjustment review and reconciliation controls`

Working tree was clean at start. Branch `main`. Local migration tip `20261028253000`. No new migrations.

Flags at start and end (unchanged):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false`

Statutory status at start and end:

`ready=false`  
`legal_issuance_blocked=true`  
`legal_allocation_enabled=false` on every financial year, invoice series, and credit-note series

GiST `product_selling_prices_active_window_excl` present. Active selling-price overlaps: 0.

---

## 1. Starting baseline

Preflight on `main`:

- HEAD `8f15554`, working tree clean
- E.2 already owner-committed; D.1 `get_invoice_note_preview` remains STABLE SECURITY DEFINER
- no public `finalize_invoice_note`, `issue_tax_invoice`, `allocate_statutory_invoice_number`, `create_invoice_credit_note`, `issue_gst_credit_note`, or `allocate_credit_note_number`
- `statutory_invoices_not_issued` still forbids `issued_at` / `legal_invoice_number`

---

## 2. Workflow architecture (actual state)

The commercial path is already implemented as separate modules. F proved they compose. It did not invent missing writers.

```
customer order
  → delivery-note handshake
  → picking (requires dual-write ON to seed)
  → confirm_dispatch (posted DISPATCH consume)
  → prepare_invoice_note (shop or default price snapshot, billed-unit conversion)
  → submit / Accounts review_invoice_note
  → preview_invoice_tax (when verified GST config exists; else fail-closed)
  → get_invoice_note_preview driver | accounts (watermarked PDFs)
  → verified customer return (post_delivery_return requires dual-write ON)
  → prepare_credit_adjustment (reviewed note snapshots + return-lot grain)
  → review_credit_adjustment approve | reject
  → assess_*_readiness always ready=false
```

Authoritative stock writers remain `confirm_dispatch` and `post_delivery_return`. Invoice notes, GST previews, handover PDFs, credit-adjustment prepare/review, and reconciliation are financial overlays. They do not post ledger rows.

Production guards that stay in force:

| Gate | Behaviour today |
|---|---|
| Dual-write off | Picking reserve, lot-aware dispatch, and `post_delivery_return` fail closed |
| `stock_delivery_returns.dispatch_id` UNIQUE | One return wave per dispatch |
| Empty `stock_delivery_return_lots` | `prepare_credit_adjustment` fails closed (`no creditable carton cases`) |
| Invoice notes | Internal `IN-…` drafts. `tax_amount` stays 0 |
| Credit adjustments | Internal `CA-…` preview/approved/rejected. Not GST credit notes |
| Legal numbering | Disabled on FY, invoice series, and credit-note series |

Isolated F HTTP replica-enables dual-write only to seed opening stock and one dispatch, then restores flags **before** invoice, GST, return-adjustment, and review RPCs.

---

## 3. Happy-path test evidence

F HTTP (`m75fhttp`, flags restored before financial RPCs) completed this path on a two-line order:

1. Create shop order (2 cases product A, 1 case product B).
2. DN handshake → pick → `confirm_dispatch`.
3. Posted DISPATCH consumption confirmed (`stock_consumed` and `posted_transaction_id`).
4. `prepare_invoice_note` idempotent; Accounts `review_invoice_note`; duplicate review rejected.
5. Product A used shop-specific ₹11.00 (`price_scope=shop`), not the ₹10.50 default.
6. Product B used default ₹7.25 (`price_scope=default`). Billing conversion 12 and 6 units/case.
7. Accounts review succeeded with `invoices.review`.
8. `preview_invoice_tax` calculated because verified statutory configuration exists. Invoice-note `tax_amount` stayed 0.
9. Driver handover omitted unit prices, totals, and tax.
10. Accounts copy kept reviewed prices and subtotal.
11. Repeated accounts preview kept the same snapshot version and amounts.
12. Return writer was not called. GUC-inserted `closed_missing` grain after empty-lot fail-closed.
13. `prepare_credit_adjustment` credited 1 returned case of A at the original ₹11.00 after the live shop price was changed to ₹99.
14. Accounts approved the internal adjustment. Duplicate approve rejected.
15. Remaining eligible cases = 0. Independent billed math matched.
16. `assess_invoice_finalization_readiness` and `assess_credit_note_issuance_readiness` both `ready=false`, `legal_issuance_blocked=true`. No legal numbers.

SQL additionally proved `post_delivery_return` raises `lot-aware delivery returns require dual-write to be enabled` while flags are false.

---

## 4. Financial reconciliation results

Independent oracle (JavaScript `Number((qty * unit).toFixed(2))` / PostgreSQL `round(..., 2)`). Not `gst_line_calc`.

| Item | Independent expected | Observed |
|---|---|---|
| A dispatched whole cases | 2 | 2 |
| A billed units per case | 12 | 12 |
| A billed quantity | 24 | 24 |
| A original unit price | ₹11.00 shop | ₹11.00 `price_scope=shop` |
| A line subtotal | ₹264.00 | ₹264.00 |
| B dispatched whole cases | 1 | 1 |
| B billed units per case | 6 | 6 |
| B billed quantity | 6 | 6 |
| B original unit price | ₹7.25 default | ₹7.25 `price_scope=default` |
| B line subtotal | ₹43.50 | ₹43.50 |
| Invoice-note subtotal | ₹307.50 | ₹307.50 |
| Invoice-note `tax_amount` | 0 | 0 |
| Verified returned cases (A only) | 1 | 1 |
| Credit billed quantity | 12 | 12 |
| Credit subtotal | ₹132.00 | ₹132.00 |
| Remaining unadjusted cases | 0 | 0 |
| Live price after review | ₹99.00 | snapshot stayed ₹11.00 |

GST: where a current tax preview exists, F SQL compared stored CGST/SGST/IGST to `round(taxable * rate / 100, 2)` (exclusive) or the inclusive extract formula. Stored lines matched. Zero-tax lines remain 0 when rates are 0. Missing tax on credit adjustments does not invent tax amounts.

Partial return, multi-line document, historical price change, shop-vs-default fallback, and rounding to 0.01 were all covered.

---

## 5. Role matrix

Server-side RPC denials (not hidden buttons):

| Action | Admin | Accounts | Godown Manager | Store Keeper | Delivery Person | Cross-godown |
|---|---|---|---|---|---|---|
| Prepare invoice note | yes | no | yes at branch | no | no | no |
| Review invoice note | yes | yes | no | no | no | no |
| Driver handover RPC | yes | yes | yes at branch | no | denied | denied |
| Accounts financial preview | yes | yes | prepare permission | denied | denied | denied |
| GST preview | yes | yes | no | denied | denied | denied |
| Prepare credit adjustment | yes | yes | denied | denied | denied | denied |
| Review credit adjustment | yes | yes | denied | denied | denied | denied |

FORCE RLS remains on invoice notes, credit adjustments, delivery returns, and return lots. Trusted writes stay GUC-gated (`app.invoice_write`, `app.credit_adjustment_write`, `app.delivery_return_write`, `app.tax_preview_write`). Application roles never receive those GUCs.

Browser: delivery personnel hitting `/invoices` and `/credit-adjustments` see “You do not have access to this page”. No Issue / Finalize / Allocate controls on either screen.

---

## 6. Idempotency and concurrency

| Request | Result |
|---|---|
| Repeated `prepare_invoice_note` same key | Same note id |
| Repeated invoice-note review | Rejected (`only submitted invoice notes can be reviewed`) |
| Concurrent `get_invoice_note_preview` | Same snapshot totals |
| Concurrent `preview_invoice_tax` | At most one current snapshot; identical tax when both calculate |
| Repeated PDF/handover generation | Same note version and amounts |
| Duplicate credit-adjustment prepare | Same adjustment id and subtotal |
| Concurrent credit-adjustment prepare | Collapses to one row |
| Concurrent Accounts approve | Exactly one winner |
| Duplicate approve | `already reviewed` |
| Second return on one dispatch | UNIQUE `dispatch_id` |
| Cumulative over-credit | Remaining eligible cases 0 after occupying the returned case |

Retries do not rewrite historical invoice-note or credit-adjustment snapshots.

---

## 7. Stock-ledger integrity

Ledger row counts were unchanged across invoice prepare/review, GST preview, handover reads, credit-adjustment prepare, and approval.

`post_delivery_return` remains the only return-to-stock writer and still fail-closes when dual-write is off. F did not modify `verify_stock_receipt`, `confirm_dispatch`, or `post_delivery_return`.

---

## 8. Existing return limitations

### A. One return wave per dispatch

`stock_delivery_returns.dispatch_id` is UNIQUE. A second wave correctly fails closed. This was not removed.

Works today: one verified return document per dispatch, then one open/approved credit adjustment occupying that grain.

Correctly fails closed: a second return document; a second credit adjustment after approval.

Owner-gated later: multi-wave returns. Not required to start the initial production workflow **if** each dispatch is returned once.

### B. Posted returns lacking lot-grain records

Current local owner data: 49 `posted` returns, 0 `stock_delivery_return_lots` rows on those posted headers.

Works today: isolated fixtures that GUC-insert `closed_missing` lots matching reviewed invoice-note lines (F/E.1/E.2). Dual-write-on `post_delivery_return` in M7.4B tests.

Correctly fails closed: `prepare_credit_adjustment` on posted returns with no lots.

Owner-gated later: data remediation of historical posted returns. F did not backfill lots and did not manufacture financial source records.

Neither limitation blocks the **initial** production workflow once dual-write is on for new dispatches and new returns write lot grain. Historical posted-without-lots returns stay non-creditable until an owner remediation milestone.

---

## 9. Statutory safety

- No public tax-invoice issuance RPC
- No public GST credit-note issuance RPC
- No legal invoice-number or credit-note-number allocation
- No unauthorized statutory verifier assignment
- No signed finalized tax invoice
- Approval of a credit adjustment is internal reconciliation only

Watermarks retained:

- `DRAFT INVOICE NOTE — NOT A TAX INVOICE`
- `DRAFT INVOICE PREVIEW — NOT A TAX INVOICE`
- `TAX CALCULATION PREVIEW — NOT A TAX INVOICE`
- `CREDIT ADJUSTMENT PREVIEW — NOT A GST CREDIT NOTE`

---

## 10. Regression

| Proof | Result |
|---|---|
| M7.4B delivery SQL / HTTP / concurrency / hardening | PASS ROLLBACK / 7 / 4 / 7 |
| M7.5B invoice SQL / HTTP / concurrency | PASS ROLLBACK / 11 / 2 |
| M7.5C.1 statutory SQL / HTTP / concurrency | PASS ROLLBACK / 9 / 2 |
| M7.5C.2 GST SQL / HTTP / concurrency | PASS ROLLBACK / 22 / 5 |
| M7.5C.3A exclusion SQL | PASS ROLLBACK |
| M7.5C.4 financial integrity SQL | PASS ROLLBACK |
| M7.5D.1 handover SQL / HTTP | PASS ROLLBACK / 9 |
| M7.5D.2 foundation SQL / HTTP / concurrency | PASS ROLLBACK / 10 / 2 |
| M7.5E.1 SQL / HTTP / concurrency | PASS ROLLBACK / 10 / 2 |
| M7.5E.2 SQL / HTTP / concurrency | PASS ROLLBACK / 13 / 4 |
| M7.5F SQL / HTTP / concurrency | PASS ROLLBACK / 15 / 3 |
| Vitest | 243 passed / 41 files |
| Playwright | 110 passed / 0 failed / 0 skipped (7.0m) |
| `tsc -b` | PASS |
| `oxlint` | 0 errors, 4 pre-existing warnings |
| `npm run build` | PASS |

Focused SQL rolls back. HTTP and concurrency restore operational flags in `finally`. F HTTP restores flags before financial RPCs as well.

Targeted test-isolation fix: `phase_m7_5e2_concurrency.mjs` now includes `RUN` in synthetic credit-note `series_code` and `prefix`. Re-running the suite no longer collides with leftover `PROOF-CN-m75e2conc/26-27/00001` rows. Production numbering RPCs were not changed.

---

## 11. Remaining owner-gated milestones

Do not treat these as F defects:

- Turn on lot dual-write for live picking, dispatch consume, and return-to-stock
- Remediate historical posted returns that have no lot rows
- Multi-wave returns (requires replacing the UNIQUE dispatch-return rule)
- Statutory tax-invoice issuance and legal invoice numbering
- GST credit-note issuance after original legal invoices exist
- Accountant policies: `credit_note_tax`, numbering, verifier, signature/seal
- Payments and TallyPrime

F does not invent those approvals.

---

## 12. Completion flags

`ready=false`  
`legal_issuance_blocked=true`  
`legal_allocation_enabled=false`  
All four operational stock flags remain false.

No commit, push, deploy, or cloud migration.
