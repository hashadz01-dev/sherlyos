# M7.6-DM — Damage Management system audit

Local-only audit of Pipeline 2 Damage Management against the client Excel blueprint (Version 1.0, 23 September 2026). This phase does **not** add stock posting, activate operational flags, issue statutory documents, reset owner data, or create a git commit.

Starting HEAD: `498dfb404ec7ec5b6bb41830f60788df856e627a`  
`top-bar Ui fix done` on `main`.

Ending HEAD: **unchanged** (`498dfb4`). Working tree remains dirty with prior uncommitted M8.2C–J / live-UAT work, plus the M7.6-DM files listed in §14.

Local migration tip (uncommitted, already present before this audit): `20261102160000_store_keeper_company_wide_godown_access.sql`.

Damage schema tip (committed): `20261026181000_damage_dashboard_posted_totals.sql`.

Flags at start and end (unchanged):

```text
damage.stock_hold_ready=false
stock.lots.dual_write_enabled=false
stock.lots.aggregate_only_blocked=false
SHORT_SHIPMENT_OPERATIONAL=false
```

Legal issuance at start and end:

```text
ready=false
legal_issuance_blocked=true
legal_allocation_enabled=false   (0 financial years, 0 invoice series, 0 credit-note series)
```

Owner data preserved: local `damage_reports` count stayed **0**. SQL/HTTP/e2e suites used rollback transactions or disposable `PREFIX` fixtures. No cloud migration, no production write, no commit.

---

## 1. Git preflight

| Item | Evidence |
|---|---|
| Branch | `main` |
| HEAD | `498dfb4` |
| Starting working tree | Dirty. Uncommitted M8.2C–J, godown-scope, invoice-note queue, packing/dispatch UAT follow-ups. Preserved as-is. |
| Damage migrations | `20261026140000` … `20261026181000` |
| Later uncommitted migrations | Accounts / GM / SK company-wide godown access (`20261102130000`–`20261102160000`) plus invoice eligible-dispatch read. Not applied to cloud by this audit. |

M7.6-DM edits are distinguishable from owner M8.2 files: they touch only damage labels/UI, M5 tests, and these docs.

---

## 2. Architecture inventory

| Area | Actual file / object | Implemented behavior | Dependencies | Risk |
|---|---|---|---|---|
| Damage entry | `create_damage_report`; `/damage/new`; `DamageReportEditorPage` | Six internal scenarios. Draft starts `draft`. Idempotency key unique. | `assert_damage_create_auth`, site scope `can_work_at_branch` | Low for inbound/transit. Storage/loading/shop-return submit is fail-closed. |
| Receiving damage | Scenarios `refill_supply`, `unloading`; receipt + receipt_line FKs | SK/GM with `receiving.execute` or `damage.verify`. Qty ≤ remaining receipt damaged cases. Submit does not post accepted RECEIPT stock. | Posted `stock_receipts` | Client vehicle/driver fields are absent on receipts. |
| Warehouse damage | Scenario `storage` | GM (`damage.record` + `damage.verify`). Crate must be in godown. Qty from `stock_balances`. Submit calls isolation and **fails** while `damage.stock_hold_ready=false`. | Isolation RPC, crate/zone | SK cannot create storage. Hold is GATED. |
| Loading damage | Scenario `loading`; `picking_request_id` | SK with `loading.assist` or GM. Converts reservation when isolation is ready. Currently submit fail-closed. | Packing allocation | Distinct from storage. Short-shipment flag stays false. |
| Transit damage | Scenario `transit`; `dispatch_id` / `order_id` | Delivery person on **assigned consumed** dispatch, or GM with `damage.record`. May submit without holds. | Dispatch assignment | No accounting invoice number on the damage header. |
| Verification | `verify_damage_report`; `/damage/verification` | GM `damage.verify`. Not the reporter. ≥1 finalized photo. Isolation scenarios need matching holds. Does **not** post stock. | Evidence, holds | Self-verify denied (HTTP + SQL). |
| Hold / quarantine | `damage_stock_holds`; `/damage/quarantine`; transfer RPC | Logical hold vs quarantine intake vs transferred. Banner explains `stock_hold_ready=false`. | Isolation installed + flag | GATED. Open damage is not approved quarantine. |
| Supplier return | Exceptional kind `return_supplier` | GM requests, Admin `damage.dispose` approves, GM posts. Hold becomes `returned_supplier`. Saleable stock is not restored. | Isolated holds, Admin | GATED without holds. Posted path is exact-once when holds exist. |
| Write-off | Ordinary `post_ordinary_damage_writeoff` (GM `damage.verify`); exceptional `destroy` (Admin approve + GM post) | Ordinary write-off is not a separate `damage.writeoff` permission. Header stays `verified`. | Isolated holds | GATED without holds. Not a GST credit note. |
| Repacking / inspection | None | No disposition kind, RPC, or UI | — | MISSING / CLIENT DECISION |
| Closure | Header statuses `cancelled` / `rejected`; ledger events for posting | Client **Closed** is not a header status. Verified + posted write-off remains `verified`. | Events table | Map in UI; do not invent Closed. |
| Reporting | `get_damage_dashboard`; `/damage`; `/damage/reports` | Carton-case counts by status/queue/godown. Filters: search, status, scenario, godown, dates. | `can_view_damage_report` | No Damage Value. Accounts has no `damage.*` grant. |
| Audit history | `damage_report_events`; detail timeline | Created/submitted/verified/returned/rejected/posted actors and timestamps. | RLS + RPCs | Direct table updates are not the product path. |

**Implemented:** six-scenario capture, evidence, verification, gated isolation, exceptional queue, dashboard, activity.

**Planned / gated / missing:** stock-hold cutover, lot dual-write, client Closed, cost master, crate 50-case rule, one-SKU-per-crate rule, receiving vehicle/driver, Accounts financial view, Repacking/Inspection.

---

## 3. Client three-tab mapping

| Client tab | Internal scenarios | UI label added this audit |
|---|---|---|
| Receiving / Stock-In Damage | `refill_supply`, `unloading` | Receiving / Stock-In Damage |
| Warehouse Damage | `storage` (and `shop_return` as extra warehouse-class work) | Warehouse Damage |
| Transit Damage | `transit` | Transit Damage |
| Extra operational (not a client tab) | `loading` | Loading Damage |

Internal statuses stay `draft | submitted | returned | verified | cancelled | rejected`.

| Client status | Internal mapping |
|---|---|
| Open | `draft`, `submitted`, `returned` |
| Verified | `verified` |
| Closed | **Not a header status.** Ledger posting (`ordinary_writeoff`, `exceptional_posted`) keeps `verified`. `cancelled` / `rejected` stay internal and are **not** shown as Closed. |

---

## 4. Six-scenario workflow audit

### DM-01 Receiving / Stock-In — PARTIAL, safe for UAT

- Links to a posted receipt and receipt line. SKU must belong to that line. Damaged cases cannot exceed remaining receipt damaged quantity (`23514`).
- Quantity CHECK `quantity_cases >= 1` (integer). Frontend `parseCartonQuantity` rejects 0, negative, and fractions.
- Create starts `draft`. Duplicate create key is unique (`damage_reports_idempotency_key`).
- Submit does not insert `stock_transactions` for inbound (M5.2 HTTP).
- Verify is GM-only, not SK, not the reporter, requires finalized evidence.
- **Gaps:** `stock_receipts` has `supplier_id` but no incoming vehicle or driver. Classify as client gap, not invented integration.

### DM-02 Warehouse — GATED (create as GM, submit blocked)

- Godown → zone → crate → SKU is selected from catalogs. Backend rejects crate outside godown.
- Authoritative on-hand comes from `stock_balances`, not trusted user input.
- **One crate / one SKU is not enforced.** `stock_balances` PK is `(crate_id, product_id)` — multiple SKUs per crate are allowed. Client 50-case crate cap is not on `crates` (`capacity_cases` exists only on vehicles).
- Open/draft storage does not reduce stock. Submit calls isolation and fails while the flag is false (HTTP 4f, e2e reporting).
- SK cannot create storage: UX `scenariosAvailableForPermissions` and `assert_damage_create_auth` both require `damage.verify`.

### DM-03 Loading — GATED (create as SK/GM, submit blocked)

- Traceable to packing request, crate, SKU, reserved qty.
- Distinct scenario `loading` vs `storage`.
- SK has `loading.assist`. There is no Loading Assistant role.
- Submit fail-closed. `SHORT_SHIPMENT_OPERATIONAL` remains hardcoded `false`. Do not enable it for UAT.
- No duplicate consumption while isolation is off because submit never posts.

### DM-04 Transit — PARTIAL, safe for UAT

- Assigned delivery person can create/submit transit for consumed assigned dispatch. Other dispatches `42501`.
- GM with `damage.record` can also record transit.
- Damaged qty cannot exceed loaded/reserved source lines.
- Transit may submit without holds. Does not mark goods delivered. Does not backfill lots on historical returns.
- Missing accounting invoice number on the damage header — handle as gap.
- Driver cannot see unrelated storage reports (e2e `damage.spec.ts`).

### DM-05 Hold / Inspection / Repacking — GATED / MISSING

- Hold = `damage_stock_holds` after isolation. Inspection and Repacking are not disposition kinds.
- Open damage is not quarantine. Banner: “Damage stock isolation not ready”.
- Transfer-to-quarantine requires verified storage + active on-hand holds + `damage.verify`.
- Flag remains false. Attempted submit of hold-required scenarios fails safely and is auditable via error, not silent stock change.

### DM-06 Supplier Return / Write-off / Closure — GATED

- Supplier return is exceptional `return_supplier` (Admin approve, GM post). Ordinary write-off is GM `damage.verify` (`post_ordinary_damage_writeoff`).
- Closure ≠ stock deduction. Verify posts zero ledger rows (SQL 4d).
- Idempotent posting when holds exist (concurrency 4d/4e exact-once).
- Financial value is not stored. Dashboard carton counts are not accounting entries.
- Repeated verify after verified is denied. Historical headers are not rewritten by verify.

---

## 5. Database / RPC audit

Quantity: `damage_report_lines_qty_check` (`>= 1`, integer). Unique `report_number` and `idempotency_key`. Scenario and status CHECKs.

Transaction: isolation/write-off/exceptional post use row locks and idempotency keys. Concurrent verify serializes (M5.2 concurrency). Concurrent write-off exact-once (M5.4D). Concurrent exceptional post exact-once (M5.4E).

Stock: inbound submit does not mutate accepted stock. Isolation scenarios fail-closed. Ordinary/exceptional posting is GATED without holds. Dual-write and aggregate-only-blocked remain false.

Referential: receipt, picking, dispatch, order, shop, product, crate, lot, employee FKs exist and are used where the scenario requires them. Vehicle/driver are not damage FKs.

Audit: reporter, submitted_by/at, verifier/at, returned, rejected, cancelled, custody, events, evidence checksum/finalize.

FORCE RLS remains on `damage_reports`. Product path is security-definer RPCs with permission + `can_work_at_branch` / assignment checks. Hidden UI is not the security boundary (HTTP denials for SK/driver/sales).

---

## 6. Role / RLS audit

| Role | Create | Verify | Write-off / exceptional | Notes |
|---|---|---|---|---|
| Store Keeper | Inbound + loading + transit | Denied | Denied | `damage.record`, `receiving.execute`, `loading.assist`. Company-wide godowns (`store_keeper.godowns.all`). |
| Loading Assistant | N/A | N/A | N/A | Not a role. Use Store Keeper. |
| Delivery Person | Transit on assigned consumed dispatch | Denied | Denied | `deliveries.execute` only. No `damage.record`. |
| Godown Manager | All six (storage/shop_return because `damage.verify`) | Yes | Ordinary write-off; request + execute exceptional | Company-wide active godowns (`godown_manager.godowns.all`). Cannot self-verify. |
| Accounts | None | None | None | No `damage.*`. `/damage` shows access denied (e2e). |
| Admin | Operational create denied | Monitor/read | `damage.dispose` approve/reject only; cannot execute post | Must still respect flags. |

Wrong-role, unauthenticated, and actor-spoofing: RPCs use `auth.uid()`, not client-supplied actor IDs. Salesperson inbound/exceptional `42501`. Driver quarantine `42501`.

Cross-godown: after owner-approved M8.2H/J, GM/SK company-wide access is **policy**, not a leak. Tests that still expected assignment-only GM isolation were realigned to salesperson as the unauthorized actor. Transit driver path remains assignment-scoped.

---

## 7. Feature-flag enforcement

| Flag | Local value | Enforcement |
|---|---|---|
| `damage.stock_hold_ready` | false | Storage/loading/shop_return submit raises. Banner on dashboard/editor/quarantine. HTTP 4f. |
| `stock.lots.dual_write_enabled` | false | Concurrency suites enable only inside disposable seed and restore. |
| `stock.lots.aggregate_only_blocked` | false | Unchanged. |
| `SHORT_SHIPMENT_OPERATIONAL` | false (code) | Not flipped. |

---

## 8. Frontend audit

Routes: `/damage`, `/damage/reports`, `/damage/quarantine`, `/damage/verification`, `/damage/exceptional`, `/damage/new`, `/damage/:id`, `/damage/:id/edit`.

Nav: Operations → **Damage**.

This audit added client category under each scenario, Open/Verified badges on the list, Client category / Client workflow on detail, and a datalist of the ten client classifications on **Damage reason** (label unchanged for e2e).

Evidence: private bucket, JPEG/PNG/WebP, 10 MB, multiple rows, repeatable single-file picker (not a multi-select control). Verify requires ≥1 finalized photo; submit RPC does not, UI does.

Validation: required scenario, source, lines, reason 1–80, positive whole cases, duplicate-click busy flags, idempotency keys in localStorage.

---

## 9. Reporting and cost

Client formula `Damage Value = Damaged Cases × Cost Per Case` is **not implemented**. No cost column on `products` or `damage_report_lines`. Local `product_selling_prices` count is 0. Dashboard is carton cases, not currency.

Dimensions present: godown filter, scenario, status, reporter, date, source document. Missing: supplier/vehicle/damage-value totals as first-class report measures.

Open vs Verified counts exist (`pending_verification`, `verified`). Closed is not counted as a client status.

---

## 10. Test execution (this audit)

See §14 of this file and `docs/m7-6-dm-defect-register.md` for commands. Summary:

| Suite | Result |
|---|---|
| SQL M5.2–M5.5 (9 files, rollback) | 9 passed |
| HTTP M5.2–M5.4F (7 files, 54321) | 68 checks passed after fixture alignment |
| Concurrency M5.2–M5.4E (5 files) | 38 races passed |
| Vitest | 344 passed / 57 files |
| Playwright `tests/e2e/damage*.spec.ts` | 42 passed after custody scope/timeout alignment |
| Typecheck | passed |
| Oxlint | 0 errors; pre-existing warnings remain |
| Production build | passed; pre-existing >500 kB chunk warning |

Flags restored false after every HTTP/concurrency run.

---

## 11. Local UAT identities discovered

Local Docker `supabase_db_sherlyos` does **not** contain persistent Test Storekeeper / Test Godown Manager / Test Deliveryperson accounts. Stable local logins:

- `jeffinpappachan110@gmail.com` — owner Admin. Do **not** use for operational damage UAT.
- `admin.m1s2qa@example.com` — QA Admin.

Active godowns/crates currently on local are leftover disposable M7.2 / M8.2 fixtures, not a named Godown-1 master. `damage_reports = 0`. `suppliers = 0`.

Playwright and HTTP tests create their own disposable users (password `local-only-m54ae2e` / `local-only-m54ce2e` / etc.) against `127.0.0.1:4173` (`npm run dev -- --mode m1s2`) and `127.0.0.1:54321`.

Cloud port 5173 (prior live UAT) was **not** used and must not be written by this milestone.

---

## 12. Safe remediations applied

UX mapping only. No schema, RPC, stock-writer, or flag changes.

1. Client category and Open/Verified labels.
2. Classification datalist on Damage reason.
3. Test realignment for company-wide GM (unauthorized actor = salesperson/driver, not `other` GM).
4. Quarantine e2e: company-wide GM can see another active godown; home filter still hides it.

---

## 13. Verdict

**M7.6-DM AUDIT COMPLETE — PARTIAL UAT ONLY**

Safe to exercise: receiving capture/submit/verify, transit capture/submit/verify, evidence, role denials, gated isolation messaging.

Do not exercise as live stock posting: warehouse/loading/shop-return submit, hold/quarantine activation, write-off/supplier-return posting, cost/value, Accounts financial review.

---

## 14. Files modified in this audit

| File | Why |
|---|---|
| `src/features/damage/utils/labels.ts` | Client category, classifications, Open/Verified mapping |
| `src/features/damage/components/DamageScenarioPicker.tsx` | Show client category under scenario |
| `src/features/damage/components/DamageLineEditor.tsx` | Classification datalist |
| `src/features/damage/DamageReportsPage.tsx` | Category + workflow on cards |
| `src/features/damage/DamageReportDetailPage.tsx` | Header Client category / workflow |
| `tests/unit/damage.test.ts` | Mapping unit tests |
| `tests/e2e/damage-custody.spec.ts` | Company-wide GM quarantine scope + heading timeout |
| `supabase/tests/phase_m5_2_damage_foundation.sql` | Company-wide GM inbound qty vs salesperson 42501 |
| `supabase/tests/phase_m5_4c_custody_quarantine.sql` | Scope exact totals to fixture godown |
| `supabase/tests/phase_m5_4d_verification_writeoff.sql` | GM list + salesperson verify deny |
| `supabase/tests/phase_m5_4e_exceptional_disposition.sql` | GM list; salesperson replay; lost-assignment identification |
| `supabase/tests/phase_m5_4f_damage_integration.sql` | Company-wide dashboard totals |
| `supabase/tests/phase_m5_5_module_closure.sql` | Same dashboard alignment |
| `supabase/tests/phase_m5_4e_http_integration.mjs` | Salesperson as unauthorized actor |
| `supabase/tests/phase_m5_4f_http_integration.mjs` | Dashboard scoped to fixture godown |
| `docs/m7-6-dm-*.md` | This deliverable set |
