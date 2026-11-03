# M7.6-DM — Defect register

Audit date: 2 November 2026. Local Docker `supabase_db_sherlyos`. HEAD `498dfb4`. No cloud writes.

Unresolved items only. Safe UX/test fixes completed in this audit are in §Fixes completed.

---

## P0 — Critical

None.

No stock corruption, duplicate deduction, RLS bypass, negative stock, data loss, or unauthorized inventory mutation was demonstrated against the current flags. Isolation submit fail-closes. Verify does not post stock. Concurrent posting is exact-once when holds exist.

---

## P1 — Essential UAT blocker

None for the **scoped** safe UAT (receiving + transit capture/verify, evidence, role denials, gated banners).

Warehouse/loading **submit** is fail-closed by design (GATED), not a crash. Store Keeper cannot create warehouse storage because the existing architecture requires `damage.verify` — see CLIENT DECISION CD-01, not a silent P1 bug.

---

## P2 — Functional or usability gap

| ID | Finding | Evidence | Recommended action |
|---|---|---|---|
| P2-01 | Damage type is free text, not a constrained enum | `damage_reason` 1–80 + datalist | Keep suggestions unless owner wants CHECK enum |
| P2-02 | No native multi-file picker | Repeatable single-file uploader; multiple evidence rows allowed | Do not add a fake multi-upload button |
| P2-03 | Submit RPC does not require photos; UI and verify do | `collectSubmitBlockers` vs `submit_damage_report` | Decide whether backend submit should match UI |
| P2-04 | List filters by internal scenario, not client three-tab | `DamageReportFilters` | Optional client-category filter |
| P2-05 | Receiving has no vehicle/driver | `stock_receipts` columns | Gap; do not invent |
| P2-06 | Transit has no accounting invoice number on the header | `damage_reports` columns | Safe null; later report join if needed |
| P2-07 | Undamaged cases are not stored | Loaded − damaged is not a column | Compute in a later report |
| P2-08 | Identification date is `created_at`, not a dedicated field | Header | Optional |
| P2-09 | Quarantine page can sit on “Loading page” longer than 5s (lazy chunk) | Playwright flake before 15s timeout | Already mitigated in e2e; watch UAT on slow PCs |
| P2-10 | Dashboard is carton cases, not rupees | `get_damage_dashboard` | Blocked on cost master |

---

## GATED — Intentionally disabled

| ID | Finding | Gate | Safe UAT behavior |
|---|---|---|---|
| G-01 | Storage / loading / shop-return submit | `damage.stock_hold_ready=false` | Expect failure + banner. Do not flip. |
| G-02 | Logical hold / quarantine intake | Same | Open damage is not quarantine |
| G-03 | Ordinary write-off posting | Needs verified + remaining holds | No live holds while G-01 holds |
| G-04 | Exceptional supplier-return / destroy posting | Admin approve + GM post + holds | Disposable SQL/HTTP only |
| G-05 | Lot dual-write | `stock.lots.dual_write_enabled=false` | Unchanged |
| G-06 | Aggregate-only blocked | `stock.lots.aggregate_only_blocked=false` | Unchanged |
| G-07 | Short shipment operational | `SHORT_SHIPMENT_OPERATIONAL=false` | Do not enable for loading tests |
| G-08 | Legal invoice / credit-note issuance | `legal_issuance_blocked=true`, allocation false | Untouched |

---

## CLIENT DECISION

| ID | Decision | Current software | Do not implement in this audit |
|---|---|---|---|
| CD-01 | May Store Keeper record warehouse (storage) damage? | Requires `damage.verify` → GM only | Do not grant SK storage create without owner |
| CD-02 | Cost per case master and whether it is live | No cost column; local selling prices 0 | Do not insert demonstration costs as live |
| CD-03 | Snapshot historical cost on the damage line | No snapshot | — |
| CD-04 | Client Closed as a header status | Verified + posted stays `verified` | Do not add Closed without owner |
| CD-05 | One crate = one SKU | Multiple SKUs allowed | Do not add unique constraint |
| CD-06 | Crate capacity 50 cases | Not enforced | Do not add without owner |
| CD-07 | Accounts damage financial read | Accounts denied `/damage` | Grant `damage.read` only if owner wants |
| CD-08 | Repacking / Inspection dispositions | Missing | New architecture; owner approval |
| CD-09 | Evidence retention / mandatory photos at submit RPC | UI yes, RPC no | — |
| CD-10 | Verification authority | Godown Manager; not reporter; not SK | Matches current RPCs |
| CD-11 | Final supplier-return and write-off policy | Exceptional Admin+GM vs ordinary GM | Keep until owner cutover |

---

## DEFERRED

| ID | Item |
|---|---|
| D-01 | GST credit notes for written-off or returned damage |
| D-02 | New damage state machine matching Excel three statuses only |
| D-03 | Stock-writer changes to `verify_stock_receipt` / `confirm_dispatch` / `post_delivery_return` |
| D-04 | Cloud migration of company-wide GM/SK (already uncommitted locally from M8.2; not this audit’s to deploy) |

---

## Fixes completed (this audit)

### FIX-01 Client Excel mapping in the existing UI

```text
Defect ID: FIX-01
Severity: P2
Root cause: Internal scenario/status labels did not show the client three-tab or Open/Verified language.
Files changed:
  src/features/damage/utils/labels.ts
  src/features/damage/components/DamageScenarioPicker.tsx
  src/features/damage/components/DamageLineEditor.tsx
  src/features/damage/DamageReportsPage.tsx
  src/features/damage/DamageReportDetailPage.tsx
  tests/unit/damage.test.ts
Behavior before: Unloading/Storage/Transit only; free-text reason; no Open/Verified.
Behavior after: Client category subtitle; Open/Verified badge mapping; classification datalist. Internal codes unchanged. Closed not invented.
Tests added: unit mapping for categories, Open/Verified, classifications.
Regression result: Vitest 344 passed. Playwright damage 42 passed after related e2e alignment.
Remaining risks: Closed still not a header status (CD-04). Classifications still free text (P2-01).
```

### FIX-02 Company-wide GM test realignment

```text
Defect ID: FIX-02
Severity: P2 (stale tests after owner-approved godowns.all)
Root cause: M5 suites treated fixture user "other" (godown_manager on another branch) as unauthorized. M8.2H `godown_manager.godowns.all` makes can_work_at_branch true at every active godown, so those tests failed with quantity/authorization mismatches — not stock-writer bugs.
Files changed:
  supabase/tests/phase_m5_2_damage_foundation.sql
  supabase/tests/phase_m5_4c_custody_quarantine.sql
  supabase/tests/phase_m5_4d_verification_writeoff.sql
  supabase/tests/phase_m5_4e_exceptional_disposition.sql
  supabase/tests/phase_m5_4f_damage_integration.sql
  supabase/tests/phase_m5_5_module_closure.sql
  supabase/tests/phase_m5_4e_http_integration.mjs
  supabase/tests/phase_m5_4f_http_integration.mjs
  tests/e2e/damage-custody.spec.ts
Behavior before: Expected 42501 / hidden other-godown rows for company-wide GM.
Behavior after: Salesperson/driver remain unauthorized. Company-wide GM may see/work at active godowns. Lost assignment no longer blocks completed exceptional replay; replay stays identification-only (ledger count unchanged). Dashboard/quarantine exact totals scoped to fixture godown so owner leftover rows cannot inflate counts.
Tests added: none new files; assertions updated.
Regression result: SQL 9/9, HTTP 68 checks, concurrency 38 races, custody e2e 6/6.
Remaining risks: Product policy is company-wide GM/SK. Transit driver remains assignment-scoped. Do not revert godowns.all.
```

No stock writers, flags, historical ledgers, or RLS were changed.

---

## Counts

| Class | Open |
|---|---|
| P0 | 0 |
| P1 | 0 |
| P2 | 10 |
| GATED | 8 |
| CLIENT DECISION | 11 |
| DEFERRED | 4 |
| Fixes completed | 2 |
