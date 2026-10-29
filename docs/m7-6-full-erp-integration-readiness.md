# M7.6 — Full ERP integration and operational-readiness assessment

Local-only integration-closure milestone after owner-committed M7.5F (`03ad94f` on `main`). This phase does **not** add statutory invoice issuance, GST credit notes, legal numbering, payment posting, stock-writer changes, operational flag activation, historical return-lot backfill, or a git commit.

Starting HEAD: `03ad94f733b687f82e88cf9b799c23a7d23951ca`  
`test(m7.5f): validate end-to-end commercial workflow`

Working tree was clean at start. Branch `main`. Local migration tip `20261028253000`. No new migrations.

Flags at start and end (unchanged):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false` (hardcoded in `src/lib/picking/rules.ts`)

Statutory status at start and end:

`ready=false`  
`legal_issuance_blocked=true`  
`legal_allocation_enabled=false` on every financial year, invoice series, and credit-note series

GiST `product_selling_prices_active_window_excl` present. Active selling-price overlaps: 0.

Public issuance RPCs remain absent: `finalize_invoice_note`, `issue_tax_invoice`, `allocate_statutory_invoice_number`, `create_invoice_credit_note`, `issue_gst_credit_note`, `allocate_credit_note_number`.

---

## 1. Starting HEAD

Preflight on `main`:

- HEAD `03ad94f`, working tree clean
- M7.5F already owner-committed
- FORCE RLS remains on `stock_ledger`, `stock_balances`, `invoice_notes`, `invoice_credit_adjustments`, `stock_delivery_returns`, `damage_reports`
- `stock_delivery_returns.dispatch_id` UNIQUE (one return wave per dispatch)
- invoice-note `tax_amount` is 0 on every stored row
- no cloud migration, reset, deploy, or commit

---

## 2. Actual implemented-module inventory

Status is taken from live writers, routes, permissions, and tests. Navigation entries alone are not treated as completion.

| # | Area | Implemented | Database writers | UI routes | Permissions | Gates | Automated tests | Incomplete / missing |
|---|---|---|---|---|---|---|---|---|
| 1 | Employees, roles, branches | Yes | `assign_user_role`, `revoke_user_role`, `assign_user_branch`, `create_branch`, profile activate/deactivate | `/employees`, `/users-roles`, `/branches`, `/audit` | `employees.*`, `roles.assign`, `branches.*`, `assignments.manage`, `audit.read` | None | access-control SQL; Playwright journeys | Settings is env-only. Profile identity fields are not a full HR module. |
| 2 | Product, supplier, shop masters | Yes | `create_product`, `create_supplier`, `create_shop`, `assign_shop_salesperson`, `revoke_shop_salesperson`, selling-price RPCs | `/masters/*` | `products.*`, `suppliers.*`, `shops.*`, `products.price.*` | GiST overlap exclusion | masters SQL/Vitest; product-search e2e | Catalog unclassified SKUs remain until owner classifies them. |
| 3 | Godowns, zones, crates | Yes | `create_zone`, `create_crate`; parent change is not exposed | `/masters/locations`, `/branches` | `locations.read/manage` | Mandatory crate hierarchy; inactive godown hardening | M4.1 SQL; reports e2e | Zone/crate parent moves stay unavailable by design. |
| 4 | Opening stock and receipts | Yes | `post_opening_stock`, `verify_stock_receipt` | `/inventory/opening`, `/receiving` | `stock.opening.post`, `receiving.execute/verify` | Whole-case; dual-write fail-closed for lot grain | receiving SQL/HTTP; opening e2e | Dual-write off: opening writes aggregate only. |
| 5 | Stock lots and expiry | Yes, gated | lot tables + `seed_legacy_stock_lots` (admin seed, not operational posting) | `/stock-lot-reconciliation` | `stock.lots.*` | dual-write and aggregate-only-blocked flags | M1 SQL/HTTP; lot-reconciliation e2e | Operational dual-write remains off. |
| 6 | FEFO/FIFO picking | Yes, gated | reservation/picking RPCs | `/picking` | `picking.allocate/manage/execute` | dual-write off ⇒ ATP `not_applicable`, allocate fail-closed | M2/M7.3 SQL/HTTP/e2e | Live warehouse picking is not operational. |
| 7 | Customer orders and dispatch | Yes | `create/submit/verify_order`, `confirm_dispatch` | `/orders`, `/dispatch`, `/deliveries` | `orders.*`, `dispatch.*`, `delivery_notes.*` | verify/picking require dual-write | M7.2/M7.4A SQL/HTTP/e2e | Order verification fail-closes while flags are false. |
| 8 | Driver delivery and confirmation | Yes | delivery-status RPCs (no ledger write) | `/delivery-runs` | `deliveries.assign/execute` | Delivery status ≠ stock credit | M7.4A e2e | Proof of delivery does not restock. |
| 9 | Customer delivery returns | Yes, gated | `post_delivery_return` only | `/delivery-runs` return panel | `deliveries.return_*` | dual-write required; one wave per dispatch | M7.4B SQL/HTTP/e2e | Historical posted returns have no lot rows. |
| 10 | Damage reporting and quarantine | Yes, gated | report/evidence/custody RPCs; isolation fail-closed | `/damage`, `/damage/reports`, `/damage/quarantine` | `damage.record/read` | `damage.stock_hold_ready=false` | M5 SQL/HTTP/e2e | Isolation does not post holds while the flag is false. |
| 11 | Damage verification and ordinary write-off | Yes, gated | `post_ordinary_damage_writeoff` | `/damage/verification` | `damage.verify` | hold-ready flag | M5.4D SQL/HTTP/e2e | Write-off posting stays fail-closed until holds are live. |
| 12 | Supplier returns and exceptional dispositions | Yes, gated | `request_exceptional_damage_disposition` + execute RPCs | `/damage/exceptional` | `damage.dispose` (admin) | hold-ready flag | M5.4E SQL/HTTP/e2e | Same activation gate. |
| 13 | Stock refill | Yes | refill request/comms RPCs; stock only via receiving | `/refill` | `refill.request/approve` | Approval is not a receipt | M6 SQL/HTTP/e2e | Complete for initial release. |
| 14 | Dashboards and operational reports | Yes | `get_operations_dashboard`, report RPCs | `/`, `/reports/*` | `stock.read`, `operations.monitor`, module perms | ATP `not_applicable` while dual-write off | M4 SQL; reports e2e; M7.6 HTTP | Movement type filter omits `DELIVERY_RETURN`. Dashboard omits some RPC KPIs. |
| 15 | Invoice notes and Accounts review | Yes | `prepare_invoice_note`, `review_invoice_note` | `/invoices` | `invoice_notes.prepare`, `invoices.review` | Internal `IN-…` drafts only | M7.5B–F | Not a tax invoice. |
| 16 | GST calculation previews | Yes | `preview_invoice_tax` | invoice detail | `invoices.review` / statutory read | Stored note `tax_amount` stays 0 | M7.5C.2 SQL/HTTP | Preview only. |
| 17 | Driver and Accounts PDF documents | Yes | `get_invoice_note_preview` | `/invoices/:id/preview` | prepare/review | Watermarks; driver omits prices | M7.5D.1 | Not a signed tax invoice. |
| 18 | Credit adjustments and reconciliation | Yes | `prepare_credit_adjustment`, `review_credit_adjustment` | `/credit-adjustments` | `invoices.review` | Requires return-lot grain; not a GST credit note | M7.5E.1/E.2/F | Historical posted returns are non-creditable. |
| 19 | Statutory readiness and legal issuance | Foundation only | `assess_*_readiness`; config RPCs | `/statutory` | `statutory.config.*`; `statutory_verifier` unassigned to owner users | `ready=false`; no issuance RPCs | M7.5C.1/D.2/F | Legal issuance is intentionally absent. |

Authoritative stock writers remain:

`post_opening_stock`, `post_crate_transfer`, `verify_stock_receipt`, `post_stock_adjustment`, `confirm_dispatch`, `post_delivery_return`, ordinary damage write-off, and exceptional disposition execute.

Invoice notes, GST previews, handover PDFs, credit-adjustment prepare/review, refill approval, and delivery-status updates do **not** post ledger rows. M7.6 did not modify those writers.

---

## 3. Cross-module architecture map

```
masters (product, shop, supplier, godown/zone/crate, price)
  → opening / receiving  → stock_balances (+ lots only if dual-write ON)
  → order capture / verify (verify fail-closes while dual-write OFF)
  → delivery-note handshake
  → FEFO/FIFO picking reserve (fail-closed while dual-write OFF)
  → confirm_dispatch  → DISPATCH ledger consume
  → prepare_invoice_note → Accounts review → GST preview → watermarked PDFs
  → driver delivery status (no stock write)
  → verified return → post_delivery_return (fail-closed while dual-write OFF)
  → prepare_credit_adjustment (fail-closed without return lots)
  → internal Accounts approve
  → assess_*_readiness always ready=false

damage: report → evidence → (holds gated) → verify → ordinary write-off
                                 ↘ exceptional request → admin dispose
refill: accounts request → admin approve → receiving verify (only then RECEIPT)
reports: read-only overlays of the same tables
```

Production guards that stay in force:

| Gate | Behaviour today |
|---|---|
| Dual-write off | Picking reserve, lot-aware dispatch consume, and `post_delivery_return` fail closed |
| `stock_delivery_returns.dispatch_id` UNIQUE | One return wave per dispatch |
| Empty `stock_delivery_return_lots` | `prepare_credit_adjustment` fails closed |
| Invoice notes | Internal `IN-…` drafts. `tax_amount` stays 0 |
| Credit adjustments | Internal `CA-…` preview/approved/rejected. Not GST credit notes |
| Legal numbering | Disabled on FY, invoice series, and credit-note series |
| Damage hold-ready | Isolation/write-off posting fail-closed |
| Short shipment | Workflow exists; `SHORT_SHIPMENT_OPERATIONAL=false` |

---

## 4. End-to-end workflow results

### A. Master data → inventory

Isolated M7.6 SQL (ROLLBACK) created a branch/zone/crate/product and posted 5 opening cases while dual-write stayed false. Independent oracle: ledger sum 5, balance 5. Dashboard on-hand for that branch 5. ATP `not_applicable`. Whole-case crate hierarchy held. Crates without zones: 0. Inactive godowns with stock: 0.

### B. Inventory → picking → dispatch

Live path remains fail-closed. Playwright picking/dispatch suites replica-enable dual-write only inside disposable fixtures and restore flags. Isolated retry after the p33 leftover allowlist: 16/16 passed, including cutover-disabled dispatch blocked. Concurrent stock safety remains in M3/M7 concurrency suites. Dual-write was **not** left on.

### C. Dispatch → delivery → returns

Driver assignment, proof of delivery, failed-delivery-without-restock, and posted return-to-stock remain covered by M7.4A/B e2e. `post_delivery_return` still raises when dual-write is off (M7.5F SQL). One-return-wave UNIQUE was re-asserted by M7.6 SQL and was not changed.

### D. Damage management

M5.4B–F SQL/HTTP/e2e plus this phase’s Playwright damage specs passed. `damage.stock_hold_ready` stayed false. Isolation/write-off remain fail-closed. No hold activation.

### E. Commercial workflow

M7.5F SQL/HTTP/concurrency re-passed (ROLLBACK / 15 HTTP checks / 3 concurrency checks). Path remains:

Order → DN → (seeded pick/dispatch) → invoice note → Accounts review → GST preview → PDF handover → GUC-inserted return grain → credit adjustment → internal approve.

No legal invoice or credit-note issuance. Independent billed oracle unchanged from F.

### F. Reporting

M7.6 HTTP and `erp-readiness` e2e confirmed:

- dashboard cutover-inactive copy and ATP not applicable
- movement report returns scoped document totals
- `DELIVERY_RETURN` type filter still rejected (`movement type is invalid`)
- rows of type `DELIVERY_RETURN` still appear under All types (filter whitelist is the gap, not row omission)
- driver denied credit adjustments and inventory dashboard KPIs

Dashboard RPC also computes `dispatched_cartons` and `pending_physical_returns`; the Overview page does not render those two KPIs. That is a display gap, not double counting of on-hand.

---

## 5. Inventory and financial reconciliation

End-of-phase local snapshot (after Playwright disposable cleanup; dual-write off):

| Check | Result |
|---|---|
| Aggregate on-hand | 626 |
| Lot on-hand | 626 |
| Lot grains that exist disagreeing with aggregate | 0 |
| Unclassified products in catalog | 822 |
| Unclassified products with stock | 0 |
| Invoice-note `tax_amount` ≠ 0 | 0 |
| Active selling-price overlaps | 0 |
| Crates without a zone | 0 |
| Inactive godowns with stock | 0 |

Financial overlays did not mutate stock. Invoice notes: 58 reviewed, 22 cancelled. Credit adjustments: 14 approved, 12 preview. All notes keep `tax_amount = 0`.

Global ledger-vs-balance across the whole owner database is **not** a valid conservation proof: disposable HTTP/e2e cleanups delete ledger/lots/balances for test SKUs and leave some `stock_transactions` behind. Isolated M7.6 opening (5/5) and F commercial proofs remain the independent oracles.

`p33-race-soap` (40 aggregate-only cases, 0 lots) was leftover phase_3_3 concurrency residue. It is a test SKU, not an operational product. M7.6 added `p33-race%` to the disposable allowlist so existing prefix-scoped cleanup could remove that unmatched grain. Owner SKUs were not deleted.

---

## 6. Role and permission matrix

Live `role_permissions` (server-side, not frontend visibility):

| Action | Admin | Accounts | Godown Manager | Store Keeper | Delivery Person | Salesperson | Statutory verifier |
|---|---|---|---|---|---|---|---|
| Master data / employees | yes | suppliers, shops read | products/locations | no | no | shops | config read/verify only |
| Opening / transfer | yes | `stock.read` | transfer | no | no | no | no |
| Receiving | monitor | no | verify | execute | no | no | no |
| Picking / dispatch | yes | no | yes | pick execute | no | no | no |
| Driver delivery | monitor | no | assign | no | execute | no | no |
| Return count / post | return_view | no | approve/post | count | handback | no | no |
| Damage | read/dispose | no | record/verify | record | transit view only | no | no |
| Prepare invoice note | no (`invoice_notes.prepare` is GM) | no | yes | no | no | no | no |
| Review invoice / credit adj | yes | yes | no | no | denied | no | no |
| GST / Accounts PDF | review | review | prepare-scoped preview | denied | denied | no | no |
| Statutory config | prepare/read | prepare/read | denied | denied | denied | no | verify only |
| Inventory dashboard KPIs | yes | `stock.read` | yes | `stock.read` | hidden | no | no |

FORCE RLS remains on operational tables. Trusted writes stay GUC-gated. Application roles never receive those GUCs.

`statutory_verifier` is assigned only to leftover HTTP fixtures `verifier.m75c1http@example.com` and `verifier.m75c2http@example.com`. No owner operator holds that role. Issuance still cannot run: there is no issuance RPC and legal allocation is disabled.

Cross-godown: `can_work_at_branch` plus `branches.access_all` (admin only). Playwright and HTTP continue to deny delivery personnel on invoices, credit adjustments, refill, damage queues, and inventory reports.

---

## 7. Dashboard / reporting verification

| Surface | Reconciles with | Gap |
|---|---|---|
| Overview cartons on hand | `stock_balances` (aggregate) | ATP empty / not applicable while dual-write off (correct) |
| Stock by godown | branch-scoped balances; inactive labeled | none observed |
| Dispatch KPI `dispatched` | dispatch request count | RPC `dispatched_cartons` is not shown on Overview |
| Pending physical returns | RPC field exists | not rendered on Overview |
| Movement report All types | document-grain `stock_transactions` including `DELIVERY_RETURN` | type filter and summary omit `DELIVERY_RETURN` |
| Inventory / lot / dispatch reports | existing M4 RPCs | no double-count of current on-hand from movement sums (page copy warns) |
| Financial preview totals | invoice-note snapshots | tax preview is not stored on the note |
| Credit-adjustment totals | adjustment snapshots | cannot credit posted returns that lack lots |

Preventing double counting: movement summary is document-grain and does not claim to equal on-hand. Dispatch consume and delivery-return credit are separate transaction types. Invoice/credit overlays do not post stock.

---

## 8. Concurrency and idempotency

Reconfirmed from M5–M7.5 suites (47 Node scripts, 0 failed) plus F:

| Request | Result |
|---|---|
| Repeated `prepare_invoice_note` | Same note id |
| Repeated invoice-note review | Rejected |
| Concurrent credit-adjustment prepare | One row |
| Concurrent Accounts approve | One winner |
| Duplicate approve | `already reviewed` |
| Second return on one dispatch | UNIQUE `dispatch_id` |
| Dispatch confirm | Exactly-once consume |
| Return post | Idempotent on the dedicated writer when dual-write is on in isolated fixtures |
| Cutover flags | HTTP/concurrency restore in `finally`; M7.6 HTTP proved flags false afterwards |

Lock ordering and trusted-writer security were not changed.

---

## 9. Operational cutover readiness (read only)

Current remaining balances are fully lot-attributed (626 = 626) and unclassified-with-stock is 0. That is **not** permission to enable dual-write.

Still required before any owner cutover:

1. Owner approval to set `stock.lots.dual_write_enabled=true` (and later `aggregate_only_blocked`).
2. Expiry-policy classification of 822 unclassified catalog products (no stock today; they would fail dual-write opening/receipt).
3. Decision on 55 posted delivery returns with zero lot rows (see §10).
4. Decision on leftover test transactions whose ledger rows were prefix-cleaned.
5. Rollback plan: flags can be returned to false only while aggregate-only-blocked is not forcing lot inventory to remain; M1-S1 SQL proved the safety trigger refuses `aggregate_only_blocked=false` while lot rows exist. That trigger is working.
6. Isolated disposable rehearsal, not the owner database.

FEFO/FIFO is eligible on current lot-attributed on-hand **once dual-write is on**. While the flag is false, allocate/verify stay fail-closed.

M7.6 did not enable dual-write, did not seed owner lots, and did not modify owner operational SKUs.

---

## 10. Historical return-lot impact

Known baseline: 49 posted delivery returns with zero lot rows.

End of M7.6 local snapshot:

| Metric | Count |
|---|---|
| Posted returns | 55 |
| Posted returns with zero lot rows | 55 |
| `stock_delivery_return_lots` rows | 0 |
| `DELIVERY_RETURN` transactions | 55 |
| Return ledger lines | 31 |
| Return transactions without ledger | 26 |

Interpretation:

- The original 49 owner posted returns still have no lots. They were not backfilled.
- About six additional posted headers are disposable-test residue whose lot rows were later removed by prefix-scoped e2e cleanup. Cleanup deletes disposable lots/ledger/balances; it does not delete posted return headers or `stock_transactions`.
- 26 `DELIVERY_RETURN` transactions without ledger include designed `closed_missing` closes (no stock credit) plus leftover test headers after ledger cleanup.

Operational impact **today**:

- `prepare_credit_adjustment` fail-closes on every current posted return (`no creditable carton cases`).
- New dual-write-on `post_delivery_return` will write lot grain for **new** dispatches.
- Historical posted-without-lots returns stay non-creditable until an owner remediation milestone.
- One-return-wave UNIQUE means a second physical wave cannot be posted on those dispatches either.

Do not automatically backfill. Do not enable dual-write to paper over this. Remediation is an owner decision (see §12).

---

## 11. P0 / P1 / P2 issues

### P0

None demonstrated in production writers, RLS, financial snapshots, or statutory issuance.

### P1

None remaining in product code.

Fixed this phase (test harness only): unmatched leftover `p33-race-soap` blocked Playwright flag-enable for picking/dispatch. Allowlisted as disposable test SKU. Isolated 16/16 then full Playwright 111/111.

### P2

1. Movement report type filter and summary omit `DELIVERY_RETURN`. Rows still appear under All types. M7.6 HTTP asserts the filter stays rejected until an owner report change.
2. Overview dashboard does not render RPC KPIs `dispatched_cartons` and `pending_physical_returns`.
3. Settings page is public-env status only.
4. Leftover HTTP `statutory_verifier` fixtures remain assigned (two `@example.com` users). Issuance still blocked by missing RPCs and `legal_allocation_enabled=false`.
5. Disposable HTTP/e2e residue: product catalog growth, some transactions without ledger after prefix cleanup, extra posted return headers without lots.
6. Early-phase SQL scripts (`bootstrap_initial_admin`, `phase_3_3`, `phase_m1_s1`, `phase_m4_operational_intelligence`) are not re-entrant on this populated local database. That is harness debt, not a live writer bug.

### GATED

- Lot dual-write and aggregate-only-blocked
- Damage stock holds
- Short shipment operational flag
- Statutory tax-invoice and GST credit-note issuance
- Legal numbering allocation
- Multi-wave returns (UNIQUE `dispatch_id`)
- Historical return-lot remediation
- Payments and TallyPrime

### DEFERRED

- Full HR/employee profile management beyond role/site assignment
- Accountant-approved GST/numbering/signature policy
- Changing stock writers

---

## 12. Owner-gated decisions

Do not treat these as M7.6 defects:

1. **Enable lot dual-write** for live picking, dispatch consume, and return-to-stock. Requires a cutover rehearsal and rollback plan. Not done.
2. **Remediate historical posted returns with no lot rows** (49 original; 55 headers currently). Options: leave non-creditable; owner-authorized backfill; or a dedicated remediation writer. Not done.
3. **Replace one-return-wave UNIQUE** if multi-wave physical returns are required. Not done.
4. **Classify 822 unclassified catalog products** before dual-write opening/receipt on those SKUs.
5. **Revoke leftover HTTP statutory_verifier fixtures** if the unassigned-verifier invariant must be restored on this local database.
6. **Add `DELIVERY_RETURN` to the movement-report filter/summary** if Accounts wants a dedicated return total.
7. **Statutory issuance** after accountant policies exist. No issuance RPC should be added without that approval.
8. **Payments and TallyPrime** remain out of scope.
9. **Activate `damage.stock_hold_ready` / `SHORT_SHIPMENT_OPERATIONAL`** only after the matching operational rehearsals.

M7.6 does not invent those approvals.

---

## 13. Test evidence

| Proof | Result |
|---|---|
| M7.6 SQL `phase_m7_6_erp_readiness.sql` | PASS ROLLBACK (twice) |
| M7.6 HTTP `phase_m7_6_http_integration.mjs` | 7/7 PASS (before Playwright and after SQL) |
| M7.6 Playwright `erp-readiness.spec.ts` | PASS (in the 111-test run) |
| M5–M7 HTTP + concurrency Node scripts (47 files) | 47 passed / 0 failed (this phase, before Playwright) |
| Focused SQL rollback M1-S1 through M7.6 (23 files) | 21 passed / 2 failed |
| `phase_m1_s1_cutover_flag_safety.sql` | FAIL as designed: cannot set `aggregate_only_blocked=false` while lot rows exist |
| `phase_m4_operational_intelligence.sql` | FAIL: `verify_order` fail-closes with dual-write off (`insufficient stock`) |
| Early M1–M3 SQL loop | Not re-run this phase (non-reentrant `bootstrap_initial_admin` / `phase_3_3`; prior loop 49 pass / 25 fail) |
| Vitest | 243 passed / 41 files / 0 failed |
| Playwright trial 1 | 95 passed / 3 failed / 13 did not run (`p33-race-soap` unmatched grain) |
| Playwright picking/dispatch retry | 16 passed |
| Playwright trial 2 (full suite) | 111 passed / 0 failed / 0 skipped (7.4m) |
| `tsc -b` | PASS |
| `oxlint` | 0 errors, 4 pre-existing warnings |
| `npm run build` | PASS |

Changed files (uncommitted):

- `docs/m7-6-full-erp-integration-readiness.md` (this file)
- `supabase/tests/phase_m7_6_erp_readiness.sql`
- `supabase/tests/phase_m7_6_http_integration.mjs`
- `tests/e2e/erp-readiness.spec.ts`
- `tests/e2e/disposable-stock.ts` (disposable prefix allowlist only)

No migrations. No stock-writer edits. No flag activation.

---

## 14. Recommended M8.1 scope

M8.1 should be **owner cutover planning**, not feature expansion and not production activation.

Suggested contents:

1. Owner decisions from §12, written as go/no-go.
2. Disposable-environment dual-write rehearsal with restore, without touching the owner database.
3. Return-lot remediation design (no automatic backfill).
4. Movement-report `DELIVERY_RETURN` filter only if Accounts requests it.
5. Cleanup policy for leftover HTTP verifier fixtures and disposable posted-return headers.
6. Keep statutory issuance, payments, TallyPrime, damage holds, and short shipment gated.

Do not start M8.1 by flipping `stock.lots.dual_write_enabled` on the owner database.

---

## Completion flags

`ready=false`  
`legal_issuance_blocked=true`  
`legal_allocation_enabled=false`  
All four operational stock flags remain false.

No commit, push, deploy, or cloud migration.
