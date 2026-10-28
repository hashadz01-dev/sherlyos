# M7.5C.3 — Financial integrity and regression stabilization

Local-only stabilization after owner-committed M7.5C.2 (`0bb03ee` on `main`). This phase does **not** finalize tax invoices, allocate statutory numbers, issue signed PDFs, post credit notes, collect payment, integrate TallyPrime, activate stock flags, migrate cloud databases, reset the owner's local database, or commit.

Starting HEAD: `0bb03ee6b217cc8cc381944ec6d6812420318f3c`  
`feat(m7.5c2): add GST calculation preview and financial integrity controls`

Working tree was clean at start. Owner had already committed M7.5C.2. This phase does not commit.

Local migration applied (Docker only, owner's existing database):

- `20261028210000_selling_price_exclusion_if_overlap_free.sql`

That migration **skipped** the exclusion constraint on the owner's database because overlapping active prices remain. It **installed** the constraint on a separate clean replay (`sherlyosc3`).

Local migration tip after apply: `20261028210000`.

Flags at start and end (operational values, unchanged):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false` (hardcoded in `src/lib/picking/rules.ts`)

---

## 1. Overlapping selling-price inventory (read-only)

Inspected on the owner's local database. No rows were deleted or deactivated.

### `m75bc_mvrw22dn-sku`

- Product ID: `53d2dfe5-53db-4335-964d-0a2f3c0124a8`
- Price list: default (`shop_id` null)
- Both rows active, open-ended, `effective_from = 2026-10-28`

| Price ID | Amount | Invoice-note `price_id` refs | Events |
|---|---|---|---|
| `f6cc8208-d294-4711-8010-f4e9e22cd0cc` | 10.0000 | 0 | 1 |
| `cf73921d-b8c8-4f50-a800-1e718bb57e50` | 11.0000 | 0 | 1 |

Leftover from the M7.5B concurrency harness (two winners before advisory locking).

### `m75c2race_mvrwkab4`

- Product ID: `8559cc64-d9bb-4cec-9e1a-1d81acc4b196`
- Price list: default (`shop_id` null)
- Both rows active, open-ended, `effective_from = 2026-10-28`

| Price ID | Amount | Invoice-note `price_id` refs | Events |
|---|---|---|---|
| `fd8cf747-5a23-4515-bec4-c4059ebf460a` | 10.0000 | 0 | 0 |
| `571287fc-990d-4831-99a9-bde7a57afc0f` | 11.0000 | 0 | 0 |

Leftover from the M7.5C.2 race that proved the pre-lock overlap (2 wins / 0 losses before `pg_advisory_xact_lock`).

### Why these are disposable test records, and why they were still not changed

- SKU prefixes match the local HTTP/concurrency harnesses (`m75bc_`, `m75c2race_`).
- Default list only; no shop-specific sibling.
- Zero invoice-note line references (`ON DELETE RESTRICT` on `invoice_note_lines.price_id` would have blocked deletion if they were billed).
- They are still **not** deactivated in this phase. SKU prefix is not proof of owner intent. C.2 left them in place; C.3 does the same.

`resolve_selling_price` remains fail-closed when more than one active window matches. Advisory `pg_advisory_xact_lock` on `(product_id, shop_id)` remains on both the overlap trigger and `upsert_product_selling_price`. New races serialize to one winner (M7.5C.2 concurrency 5/5 on this run).

---

## 2. Remediation recommendation (owner approval required)

**Do not delete the four price rows.** Prefer deactivation (`is_active = false`) of all but one surviving window per SKU, or close `effective_to` on the superseded row so the inclusive `daterange(..., '[]')` windows no longer overlap.

Suggested surviving rows (owner may choose the other amount):

- `m75bc_mvrw22dn-sku`: keep `f6cc8208-...` (10.0000); deactivate `cf73921d-...` (11.0000).
- `m75c2race_mvrwkab4`: keep `fd8cf747-...` (10.0000); deactivate `571287fc-...` (11.0000).

After deactivation, the exclusion constraint can be installed with the same `ALTER TABLE` as `20261028210000`. That migration **already ran** on the owner's database and skipped. Supabase will not replay it. A follow-up migration (or a one-shot local `ALTER TABLE`) is required after the data change. Isolated clean replay already has the constraint; no owner-DB reset.

Until then, advisory locks plus fail-closed resolution remain the protection.

---

## 3. Exclusion constraint status

Designed coverage:

- Default list (`shop_id` null) uses sentinel `00000000-0000-0000-0000-000000000000` so nulls still exclude.
- Shop-specific prices exclude per `(product_id, shop_id)`.
- Active rows only (`WHERE (is_active)`).
- Inclusive/open-ended windows via `app_private.selling_price_window` (`daterange(..., '[]')`, open end = infinity).
- Concurrent inserts/updates still take the existing transaction advisory lock before the `EXISTS` check.
- Deactivation and supersession fall out of the partial index predicate.

| Environment | Constraint `product_selling_prices_active_window_excl` |
|---|---|
| Owner local (`supabase_db_sherlyos`) | **Not installed** (overlap NOTICE; four active rows above) |
| Isolated replay (`supabase_db_sherlyosc3`) | **Installed** (zero overlapping active prices on a clean seed) |

`btree_gist` is installed in both. Historical price rows were not rewritten.

---

## 4. Playwright lot-reconciliation root cause

First full Playwright run this phase: **103 passed / 1 failed**.

Failure: `admin applies approved attribution after local legacy seed`.

Chain:

1. Invoice-note HTTP leftovers (`m75bhttp-*`, `m75c2http-*`) posted lot-attributed ledger and `invoice_note_lines.lot_id` (`ON DELETE RESTRICT`).
2. The old wipe treated **any** lot-attributed ledger as a hard refuse, including families this suite does not own.
3. Replacing that with a global `seed_legacy_stock_lots` call then failed: production seed is warehouse-wide and refuses unexpected existing lot balances.
4. A scoped m1s2qa seed without flipping `stock.lots.aggregate_only_blocked` left attribution ineligible (`Legacy lot seed must complete before attribution`).
5. A normal `UPDATE` of `aggregate_only_blocked` then hit cutover Rule C: `dual_write_enabled cannot be false while lot-attributed ledger rows exist`. Rule C only runs on flag writes, so the leftover attributed ledger can coexist with both flags false until someone updates a cutover flag.

The invoice-note FK behaviour is correct. The ledger rows are legitimate source integrity. The suite assumed an empty / wipeable lot table.

---

## 5. Test isolation solution

Preferred outcome: isolation, not destructive ledger cleanup.

- `wipeLocalLotsIfSafe` is scoped to `m1s2qa-%` only. If those lots are referenced by ledger or invoice-note lines, it skips deletes (`NOTICE`) instead of throwing or detaching `lot_id`.
- `seedLegacyLotsAsAdmin` seeds `legacy_unattributed` lots for m1s2qa grains only. It does not call global `seed_legacy_stock_lots`.
- `setAggregateOnlyBlocked` toggles the seed-complete flag with `session_replication_role = replica` **only for that flag write**. Dual-write stays false. Ledger is not touched. Wipe restores the flag false the same way.
- `DISPOSABLE_SKU_PATTERNS` includes `m75c%`. `cleanupDisposableTestStock` will not null `stock_ledger.lot_id` when `invoice_note_lines` pin the lot or product, and will not delete lots referenced by invoice-note lines.
- Attribution apply is wrapped in `try/finally` wipe.

Not done: deleting or detaching invoice HTTP leftover lots; disabling RLS/FKs; calling production `seed_legacy_stock_lots` on a polluted database.

---

## 6. M5.4D concurrency findings

Historical XOR (`ordinary_writeoff` XOR `quarantine_transfer`) is **not** a proven double saleable debit.

- Unique index is `(damage_report_id, damage_posting_kind)`.
- Both kinds may post on one report: transfer-then-write-off is the documented M5.4D pipeline and consumes remaining **transferred** holds, not two saleable crate debits.
- `assertNoNegative` still holds.
- Stock writers (`verify_stock_receipt`, `confirm_dispatch`, `post_delivery_return`, write-off, transfer) were **not** changed.

Harness change: `raceWriteoffTransfer` accepts write-off-only, transfer-only, or transfer-then-write-off. XOR was an incorrect test expectation.

Repeated isolated matrix (this phase, after the harness correction): **3 consecutive runs, 9/9 each**. That does not independently “resolve” a product XOR; it shows the writers did not produce negative stock under the allowed pipeline.

Remaining M5 design debt (separate milestone, owner decision): whether write-off and quarantine transfer should become mutually exclusive in product rules. Do not silently change stock writers for that.

---

## 7. Isolated migration replay

**Not skipped.** Separate disposable full Supabase stack:

- Directory: `C:\Users\Hash\Desktop\Hashdev\sherlyos-c3replay`
- `project_id = sherlyosc3`
- Ports remapped (`55321` API, `55322` DB, `55323` Studio, …)
- Owner stack (`sherlyos` on `54321`/`54322`) left running
- Owner Docker volumes not reset
- Cloud not touched

`npx supabase start` applied the full migration chain through `20261028210000`, then `supabase/seed.sql`. Exit 0.

Smoke on `supabase_db_sherlyosc3`:

- Exclusion constraint present
- Operational flags false
- Zero overlapping active prices
- `assess_invoice_finalization_readiness` exists; no `finalize_invoice` / `issue_tax_invoice` / `allocate_statutory_invoice_number`
- `phase_m7_5c1_statutory_foundation.sql` PASS (rolled back)
- `phase_m7_5c2_gst_calculation.sql` PASS (rolled back)
- HTTP: PostgREST on `127.0.0.1:55321` answered `42501` for anon `SELECT public.products` (RLS live; same as owner `54321`)

Stopped with `npx supabase stop` from the replay directory (`project_id_filter: sherlyosc3`). Owner containers remained healthy.

This was a full `supabase start`, not a partial SQL replay.

---

## 8. Statutory invoice safety

Authenticated admin `assess_invoice_finalization_readiness()` on the owner database:

- `ready=false`
- `legal_issuance_blocked=true`
- blockers include `tax_preview_is_not_a_tax_invoice` and `finalize_rpc_disabled`

No `public.finalize_invoice_note`, `public.issue_tax_invoice`, or `public.allocate_statutory_invoice_number`. No statutory number allocation, final signed PDF, credit-note posting, or invoice-driven stock ledger mutation was added. GST calculation rules were not changed.

---

## 9. Regression totals

Owner database. No result is recorded as a pass merely because a later retry succeeded. Playwright’s earlier 103/1 is recorded; the two later full runs are after the isolation fix.

| Check | Result |
|---|---|
| M7.5B SQL `phase_m7_5b_invoice_foundation.sql` | PASS (rolled back) |
| M7.5B HTTP | PASS 11 checks |
| M7.5B concurrency | PASS 2 checks |
| M7.5C.1 SQL `phase_m7_5c1_statutory_foundation.sql` | PASS (rolled back) |
| M7.5C.1 HTTP | PASS 9 checks |
| M7.5C.1 concurrency | PASS 2 checks |
| M7.5C.2 SQL `phase_m7_5c2_gst_calculation.sql` | PASS (rolled back) |
| M7.5C.2 HTTP | PASS 22 checks |
| M7.5C.2 concurrency | PASS 5 checks |
| M7.4B SQL `phase_m7_4b_delivery.sql` | PASS (rolled back) |
| M7.3B SQL `phase_m7_3b_short_shipment.sql` | PASS (rolled back) |
| M5.4D SQL `phase_m5_4d_verification_writeoff.sql` | PASS (rolled back) |
| M5.4D concurrency | 9/9, 9/9, 9/9 (three consecutive isolated runs) |
| Vitest | 39 files, **233 passed** |
| Playwright trial 1 (pre-isolation fix) | **103 passed / 1 failed** (attribution wipe/seed) |
| Playwright trial 1 (post-fix) | **104 passed** (7.0m) |
| Playwright trial 2 (post-fix) | **104 passed** (6.8m) |
| Typecheck | PASS |
| Lint (oxlint) | 0 errors; 4 pre-existing warnings (DamageReportEditorPage setState-in-effect; Transfers/OpeningStock/Products incompatible-library) |
| Production build | PASS (`tsc -b && vite build`) |
| Isolated replay C.1 SQL | PASS |
| Isolated replay C.2 SQL | PASS |

M7.5C.1 SQL/HTTP tolerate leftover open seller/policy rows from C.2 HTTP (unique open-ownership). That is fixture isolation, not a statutory-rule change.

---

## 10. Remaining risks (after C.3, before C.3A)

C.3 left overlapping active prices and a skipped exclusion on the owner database. C.3A closed that gap. Risks that remain after C.3A:

- Invoice HTTP leftovers still carry `lot_id` on ledger (`m75bhttp-*`, `m75c2http-*`). Correct, and they block legal cutover-flag updates via Rule C. The attribution e2e bypasses Rule C only for the seed-complete flag using replica.
- `lot-reconciliation.spec.ts` `afterAll` still nulls m1s2qa `stock_ledger.lot_id` under replica as dual-write hygiene for that family. It does not touch invoice-note families.
- `cleanupDisposableTestStock` may still null unpinned disposable ledger `lot_id`. Pinned invoice-note lots are excluded.
- M5.4D write-off vs transfer is an allowed sequential pipeline, not a product XOR. If the owner wants mutual exclusion, that is a separate stock-writer milestone.
- `supabase_vector_sherlyos` continues to restart. Pre-existing analytics sidecar; not changed.
- Isolated `sherlyosc3` replay from C.3 predates `20261028220000`. A later clean replay will apply 220000 as a verify-if-present install.

---

## 11. Owner approvals

1. **Done in C.3A:** deactivate the two first-committed-loser price IDs (not the C.3 amount-based suggestion) and install the exclusion via `20261028220000`.
2. Optional: decide whether ordinary write-off and quarantine transfer should become mutually exclusive (M5 product rule). Do not treat the harness correction as that decision.
3. Git commit of C.3 + C.3A (owner performs commits manually).

No Git commit, push, fetch, rebase, or reset was performed in this phase.

---

## 12. M7.5C.3A owner-approved closure

Owner authorized deactivation of exactly two records after the C.3A pre-flight. Criterion: first committed row stays active (amount was not the selector).

### Approved IDs

| Group | Product | Preserve (active) | Deactivate |
|---|---|---|---|
| A `m75bc_mvrw22dn-sku` | `53d2dfe5-53db-4335-964d-0a2f3c0124a8` | `cf73921d-b8c8-4f50-a800-1e718bb57e50` INR 11.0000 | `f6cc8208-d294-4711-8010-f4e9e22cd0cc` INR 10.0000 |
| B `m75c2race_mvrwkab4` | `8559cc64-d9bb-4cec-9e1a-1d81acc4b196` | `fd8cf747-5a23-4515-bec4-c4059ebf460a` INR 10.0000 | `571287fc-990d-4831-99a9-bde7a57afc0f` INR 11.0000 |

Writer: `public.deactivate_product_selling_price` as `admin.m75bc_mvrw22dn@example.com` (`39233b4a-814a-4b04-9edd-d227b21af648`). No deletes. No other prices changed.

### Before / after

| Price ID | Before | After | `updated_at` |
|---|---|---|---|
| `cf73921d-...` | active 11 | **active 11** | unchanged 2026-10-28 09:04:54.780229+00 |
| `f6cc8208-...` | active 10 | **inactive 10** | 2026-10-28 11:16:23.676343+00 |
| `fd8cf747-...` | active 10 | **active 10** | unchanged 2026-10-28 09:19:03.995443+00 |
| `571287fc-...` | active 11 | **inactive 11** | 2026-10-28 11:16:23.676343+00 |

Active overlap groups: 2 → **0**. `resolve_selling_price` on both survivors returns the single remaining default row.

### Audit / events at 2026-10-28 11:16:23.676343+00

- `product_selling_price_events.price_deactivated` on `f6cc8208-...` payload `{"unit_amount": 10.0000}`
- `product_selling_price_events.price_deactivated` on `571287fc-...` payload `{"unit_amount": 11.0000}`
- `audit_logs.price_deactivated` for both entity IDs, actor `39233b4a-...`

Create events for Group A were left in place. Group B still has no `price_created` row (pre-lock race insert).

### Constraint migration

`20261028220000_selling_price_exclusion_require_overlap_free.sql` applied locally with `npx supabase migration up --local`. It **fails** if active overlaps remain. If the constraint already exists (clean replay after 210000), it verifies the catalog definition instead of adding a duplicate. It never silent-skips a missing constraint.

Owner catalog proof:

```
conname = product_selling_prices_active_window_excl
contype = x
EXCLUDE USING gist (
  product_id WITH =,
  COALESCE(shop_id, '00000000-0000-0000-0000-000000000000'::uuid) WITH =,
  app_private.selling_price_window(effective_from, effective_to) WITH &&
) WHERE (is_active)
```

Tip: `20261028220000`. Advisory locks and fail-closed resolution kept.

`phase_m7_5c3a_exclusion.sql` (rolled back): overlapping open-ended insert rejected; non-overlapping later window allowed; different products allowed; shop-specific vs default allowed; inactive historical overlap allowed; survivor resolution unchanged.

### C.3A regression

| Check | Result |
|---|---|
| M7.5C.3A exclusion SQL | PASS (rolled back) |
| M7.5B SQL / HTTP / concurrency | PASS / 11 / 2 |
| M7.5C.1 SQL / HTTP / concurrency | PASS / 9 / 2 |
| M7.5C.2 SQL / HTTP / concurrency | PASS / 22 / 5 (1 winner / 1 loser × 3 default + shop) |
| M7.4B SQL | PASS |
| M7.3B SQL | PASS |
| M5.4D SQL / concurrency | PASS / 9/9 |
| Vitest | **233 passed** |
| Playwright | **104 passed** (6.7m) |
| Typecheck | PASS |
| Lint | 0 errors; 4 pre-existing warnings |
| Production build | PASS |
| `assess_invoice_finalization_readiness` | `ready=false`, `legal_issuance_blocked=true` |
| Flags | all false |
| Finalize / issue / allocate RPCs | absent |

### Verdict

**M7.5C.3 PRICE INTEGRITY CLOSED — READY FOR OWNER COMMIT**

Owner performs Git commits manually. No commit or push was made in this phase.
