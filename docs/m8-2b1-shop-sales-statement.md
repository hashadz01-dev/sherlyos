# M8.2B.1 — Shop sales statement and customer ledger foundation

**Verdict: `IMPLEMENTED READ-ONLY — STOP FOR OWNER REVIEW`**

Shop detail is additive. The Shops master list still groups by route. Clicking a shop opens `/masters/shops/:shopId`. Payment posting is **not** activated. Statutory GST issuance stays blocked. Stock writers and operational flags are unchanged.

This phase did not commit, push, or deploy.

---

## 1. Existing financial-data audit

| Record | What it is | Authoritative for a customer statement? |
|---|---|---|
| `orders` | Shop request. No price. | Operational history only (Orders tab). |
| `delivery_notes` | Warehouse paperwork. No amount. | Delivery history. Not a bill. |
| `stock_dispatch_requests` | Physical dispatch. Stock already consumed when posted. | Delivery operations, not a bill. |
| `invoice_notes` | Priced **draft**. Unique open note per dispatch. Watermark: not a tax invoice. `legal_issuance_blocked = true`. | **Billing preview only.** Draft/submitted/reviewed are not issued invoices. |
| `invoice_credit_adjustments` | Internal credit **preview**. Not a GST credit note. | Reconciliation preview only. |
| `statutory_invoices` | Foundation table. Issuance RPCs disabled. Count remains 0. | Not used. |
| Customer receipts / receivables | **No tables.** Supplier `stock_receipts` are inbound stock, not shop cash. | None. |

`formatInr(null)` would print `₹0.00`. Statement payment columns therefore never call `formatInr` on a missing receipt. They render **Unavailable**.

---

## 2. Shop detail

Tabs:

1. **Overview** — identity, route, visit sequence, assignments, edit.
2. **Orders** — `list_orders` filtered to this shop (existing order permissions).
3. **Deliveries** — `list_delivery_notes(shop_filter)` (existing DN permissions).
4. **Sales Statement** — `get_shop_sales_statement` (`shops.statement.read`).
5. **Payments** — pending copy. No posting UI.

List page still supports New shop, activate/deactivate, and salesperson assign/revoke.

---

## 3. Read-only statement

Columns match the paper register: Date, Particulars, Bill/ref., Bill amount, Cash received, Balance, Ack., Remarks, Status.

- Invoice notes keep their draft numbering (`IN-…`) and watermark.
- Delivery notes have no bill amount (`—`).
- Credit adjustments are labelled as previews, not GST credit notes.
- Cash received, balance, and acknowledgement are always **Unavailable**.
- Date filter and bill/reference search.
- Print (`window.print`) and PDF (`jspdf` + autotable) copy the authorized payload. They do not recalculate GST or allocate numbers.

---

## 4. Proposed payment and receivables architecture (not activated)

Immutable event tables, not an editable running total:

| Table | Purpose |
|---|---|
| `shop_ledger_accounts` | One receivables account per shop. Opening balance is an event, not a column overwrite. |
| `shop_financial_events` | Append-only: `opening_balance`, `invoice_note_reviewed` (still not legal until issuance exists), `payment_receipt`, `payment_allocation`, `credit_adjustment_approved`, `receipt_reversal`. |
| `shop_payment_receipts` | Cash / bank / UPI header. Method required. Cannot update amount after post. |
| `shop_payment_allocations` | One receipt may settle many bills. Partial allocation allowed. Sum ≤ receipt. |
| `shop_payment_reversals` | Counter-event; never delete the original receipt. |
| `shop_statement_watermarks` | Printed-at snapshot for reconciliation, not a live editable balance. |

Running balance is always `sum(signed events)` as of a timestamp. Clients cannot write the projection.

Do **not** auto-promote `invoice_notes` to legal invoices or `invoice_credit_adjustments` to GST credit notes when this ledger is later built.

---

## 5. Role-permission matrix

| Role | Shop list/detail | Orders tab | Deliveries tab | Sales statement / payments tab |
|---|---|---|---|---|
| Admin | Yes (`shops.assign` / `shops.read`) | Yes | Yes | **Yes** (`shops.statement.read`) |
| Accounts | Yes (`shops.read_all` active shops) | Yes | Yes | **Yes** |
| Salesperson | Assigned shops only | Own capture scope | No, unless a later DN grant | **No** |
| Delivery person | No shop master | No | Assigned DNs | **No** |
| Store keeper | No shop master | No | No | **No** |
| Godown manager | No shop master (no `shops.read`) | Ops | Ops | **No** (prepares invoice notes elsewhere) |

Enforced by `shops.statement.read` on `get_shop_sales_statement`, not by hiding the tab alone. Tab hide is extra.

---

## 6. Tests

Run on 30 Oct 2026. No commit, push, deploy, stock-writer change, payment posting, or GST issuance.

| Check | Result |
|---|---|
| Vitest `tests/unit/shop-statement.test.ts` | 6 passed. Missing receipts stay `Unavailable`, not `₹0.00`. Outstanding stays unavailable. Duplicate source keys collapse. Malformed payload receipts are forced off. |
| SQL `supabase/tests/phase_m8_2b1_shop_statement.sql` | Passed on local Docker (`BEGIN` / `DO` / `ROLLBACK`). `shops.statement.read` is Admin + Accounts only. |
| Cloud grant query | `shops.statement.read` → `{accounts, admin}` |
| Playwright `tests/e2e/shop-statement.spec.ts` | Passed on 4173 / m1s2. Local QA admin is seeded only if missing. Statement watermark, Unavailable cash/outstanding, Payments pending. |
| `npm run typecheck` | Passed |
| `npm run lint` | Passed (existing warnings only) |
| `npm run build` | Passed. `ShopDetailPage` chunk emitted. |
| Browser 5173 (Jeffin, cloud) | Shop name opens `/masters/shops/:id`. Family supermarket keeps Thevara sequence 1. Statement shows watermark, billed totals as `—`, Cash received / Outstanding **Unavailable**. Payments tab pending. Orders and deliveries empty for that shop (no sample rows). Back to shops restores the route list. |

`sherlyos_m81c` was not touched. Local `schema_migrations` records `20261030190000` / `shop_sales_statement`. Cloud applied the same SQL as migration name `shop_sales_statement`.

---

## 7. Outstanding owner decisions

1. Import the handwritten paper register as opening events, or start the ledger from zero when payments go live?
2. Should reviewed invoice notes become receivable events before statutory issuance exists?
3. Should `godown_manager` receive `shops.statement.read`? Currently no.
4. Cash vs bank vs UPI: one receipt table with method, or separate books?
5. Customer signature: photo evidence, OTP, or paper scan?
6. Print for the shop: hide draft notes, or print the watermarked preview as-is?

Payment posting, GST issuance, legal numbering, stock writers, and flag flips stay off until those answers exist.
