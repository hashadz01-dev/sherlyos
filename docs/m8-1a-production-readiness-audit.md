# M8.1A — Production readiness audit, data hygiene classification, and cutover safety closure

Read-only for owner business data. This milestone does **not** activate operational flags, delete records, backfill return lots, issue statutory documents, revoke users, or commit.

Starting HEAD: `ff719ae2b591ec191f9838b53a7f743f5fbd7cea`  
`test(m7.6): validate full ERP integration and operational readiness`

Branch `main`. Working tree was clean at start. Local migration tip `20261028253000`. M7.6 report present at `docs/m7-6-full-erp-integration-readiness.md`.

Flags at start and end:

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false`

Statutory: `ready=false`, `legal_issuance_blocked=true`, `legal_allocation_enabled=false` on every FY / invoice series / credit-note series. GiST exclusion present. Active selling-price overlaps: 0.

---

## 1. Starting HEAD

Preflight on `main` matched M7.6 closure. No cloud migration, reset, deploy, or commit.

---

## 2. SQL test closure

M7.6 recorded two focused SQL failures. Both were **expected production fail-closed behaviour on a populated database**, not writer defects.

### A. `phase_m1_s1_cutover_flag_safety.sql`

**Root cause.** The script assumed a greenfield database: enable `dual-write+blocked`, then restore `false/false`. On this working DB, lot inventory and lot-attributed ledger already exist (replica-restored flags after e2e). Rule B forbids `aggregate_only_blocked=false` while lots exist. Rule C forbids `dual_write=false` while lot-attributed ledger exists. Sequential `blocked=true` with dual-write still false is also illegal under Rule C. Global `seed_legacy_stock_lots()` refuses when owner grains already have lots.

The production trigger is correct. Weakening it would reopen aggregate-only posting beside lot ledger.

**Test correction (justified).** Detect lot activity at start. Skip greenfield restore and dual-write bounce. Prove Rule C when sequential `blocked=true` is attempted. If global seed refuses, attribute **only this fixture’s unmatched openings** inside the transaction (ROLLBACK). Keep unauthorized-update, non-boolean, aggregate opening, unclassified rejection, orphan-grain, atomic true/true enable, Rule B, and Rule C proofs.

**Result.** PASS ROLLBACK on the populated local database.

### B. `phase_m4_operational_intelligence.sql`

**Root cause.** After M7.2, `verify_order` fail-closes while dual-write is off (`insufficient stock` / ATP eligible 0). The script still called `verify_order` in the cutover-off reporting block. That is the live ATP gate, not a KPI bug.

**Test correction (justified).** Expect fail-closed verify; assert the order stays `submitted`; scope godown KPIs to the fixture branch (`verified=0`, `awaiting_picking=0`); deny DN on unverified orders. After replica dual-write enable, prove verified workload, DN handshake, and that DN is not customer POD / stock consume. Dispatch confirm path unchanged.

**Result.** PASS ROLLBACK. Do not run this script in parallel with M1-S1: both take advisory lock `(88104301,1)`.

Safety triggers, dual-write requirements, and lot-classification checks were not weakened.

---

## 3. Data hygiene inventory

This local instance is an **accumulated test database**. Prefix alone was not used as proof. Additional signals: `@example.com` emails, fixture branch codes, synthetic numbering series, and absence of legal allocation.

| Class | Count | Evidence | Disposable? | Safe cleanup possible? |
|---|---|---|---|---|
| Auth users / profiles | 1150 / 1150 | Every email matches `example.com` | Test identities | Only with owner approval. Do not revoke in M8.1A. |
| Products | 1624, all active | 1621 match `m[0-9]` / `m1s` / `zzz-` / `p33-race`; remaining 3 are `p42b-race`, `p42c-race`, `p43e2b2-race` | Test catalog | Product rows are shared reference data; posted transactions are not deleted just to tidy SKUs. |
| Godowns | 1298 (1201 active, 97 inactive) | Fixture codes (`m74b*`, `m4e2e_`, …) | Test sites | Inactive with stock: 0. Leave in place. |
| Zones / crates | 1133 / 1242 | Mandatory crate hierarchy; crates without zone: 0 | Mixed test locations | No orphan crates. |
| Invoice notes | 58 reviewed, 22 cancelled | `tax_amount=0` | Internal drafts | Do not delete financial snapshots. |
| Credit adjustments | 14 approved, 12 preview | Internal `CA-…` | Test financial overlays | Do not delete. |
| Numbering series | 4 invoice + 4 credit-note | `is_synthetic=true`, prefix `PROOF-m75d2c_*` / `PROOF-CN-m75e2conc*` | Synthetic | Leave; legal allocation is off. |
| Statutory verifiers | 2 | `verifier.m75c1http@example.com`, `verifier.m75c2http@example.com` | HTTP leftovers | Owner may revoke later. Issuance still impossible. |
| Damage reports | 722 | Fixture history | Test | Do not delete. |
| `stock_transactions` without ledger | 1439 | Prefix-scoped e2e cleanup deleted ledger/lots/balances and left headers | Test residue | Do not delete historical txn headers in M8.1A. |

**Operational products:** none identified on this local database. Every catalog SKU is a phase/HTTP/Playwright fixture. If a future restore of real owner masters is planned, treat this instance as disposable and restore from backup onto a separate database.

---

## 4. Historical return classification

Baseline: 55 posted returns, 0 `stock_delivery_return_lots` rows.

| Class | Count | Signals |
|---|---|---|
| Owner operational | **0** | No posted return lacks test email **and** fixture branch code |
| Test-generated | **55** | `created_by` is `godown.m74b*@example.com`; branch codes `m74bhttp_*` / `m74bc_*` / `m74bh_*` / `m74b_*`; linked orders `SO-20261027`–`SO-20261029` |
| Ambiguous | **0** | Multi-signal, not prefix-only |

Associations:

- Reviewed invoice notes on the same dispatch: **0**
- Credit adjustments on the return: **0**
- Posted `DELIVERY_RETURN` transaction: **55** (all have `posted_transaction_id`)
- Ledger lines on that transaction: 29 of 55 have ≥1 line; 26 have 0 (lot rows later prefix-cleaned)
- Customer orders / dispatches: all 55 have both

**Remediation matrix (owner decision, not executed):**

| Option | Use when | Effect |
|---|---|---|
| Leave non-creditable | Default | `prepare_credit_adjustment` stays fail-closed. Correct. |
| Authorized header cleanup | Owner confirms all 55 are test | Still must not delete ledger/txn blindly; requires a dedicated disposable cleanup, not production writers. |
| Backfill lots | Never without accountant/owner design | Would fabricate grain. Forbidden in M8.1A. |
| Second return wave | Needs UNIQUE drop | Owner-gated; not required if each dispatch is returned once. |

Do not backfill. Do not change return statuses.

---

## 5. Product expiry classification

822 unclassified products. **All active. Zero with current stock.**

| Slice | Count |
|---|---|
| Unclassified active | 822 |
| Unclassified inactive | 0 |
| Unclassified with on-hand | 0 |
| Unclassified with any `stock_transactions` | 451 |
| Unclassified never moved | 371 |
| `expiry_controlled` | 649 |
| `non_expiring` | 153 |

**Worksheet (owner-ready, not auto-assigned):**

1. SKUs that already have `expiry_controlled` or `non_expiring` need no action for current on-hand.
2. Unclassified **with history but no stock** (451): classify before any future dual-write receipt/opening on that SKU.
3. Unclassified **never moved** (371): classify before first stock post, or leave unused.
4. Do not infer `non_expiring` from a soap/oil name. Perishable vs non-perishable is a business decision.
5. Dual-write enable currently passes the classification guard because unclassified-with-stock is 0. Using an unclassified SKU after cutover would fail closed at posting.

M8.1A did not call `set_product_expiry_policy` on owner/catalog rows outside rolled-back SQL fixtures.

---

## 6. Stock reconciliation

Independent snapshot after Playwright:

| Check | Result |
|---|---|
| Aggregate on-hand | 626 |
| Lot on-hand | 626 |
| Positive aggregate grains | 137 |
| Positive lot grains | 137 |
| Lot grains that exist and disagree with aggregate | 0 |
| Negative aggregate / lot | 0 / 0 |
| Unclassified with stock | 0 |
| Crates without zone | 0 |
| Inactive godowns with stock | 0 |
| Invoice-note `tax_amount` ≠ 0 | 0 |

**FEFO/FIFO prerequisites on balances:** current on-hand is fully lot-attributed and classified. Picking still fail-closes because dual-write is off.

**Configuration blocker (not a grain mismatch):** lot-attributed ledger exists while both cutover flags are false. That pair can only exist via replica restore after tests. A privileged non-replica UPDATE of `false/false` is rejected (Rule B/C). The legal cutover step is a **single statement** setting both flags to true, after grains and classification already match.

**Other residue:** 1439 transactions without ledger (749 opening, 305 receipt, 141 dispatch, 26 delivery-return, …). Isolated writers still reconcile inside a transaction. Global ledger-vs-balance across leftover headers is not a conservation proof.

Exact readiness blockers for live picking/dispatch/returns: dual-write still off; damage holds off; short shipment off; posted returns lack lot grain for credit adjustments.

---

## 7. Security audit

- Roles in use: admin (283), godown_manager (364), accounts (216), store_keeper (206), delivery_person (59), salesperson (7), statutory_verifier (2).
- Every auth user is `@example.com`. No non-test identity was found on this instance.
- Admin includes `branches.access_all` (283 grants). Cross-godown is intentional for admin, not a leak.
- Trusted writers remain GUC-gated. FORCE RLS remains on operational tables.
- Leftover verifiers: two HTTP fixtures. `assess_*_readiness` stays `ready=false` because issuance RPCs are absent and legal allocation is off.
- Delivery personnel remain denied inventory KPIs and credit adjustments (M7.6 HTTP).

**Authorized revocation plan (not executed):**

1. Owner confirms no real operator uses this local database.
2. Revoke `statutory_verifier` from the two `verifier.m75c*http@example.com` users.
3. Optionally deactivate leftover HTTP/Playwright users after backup.
4. Re-verify `assess_invoice_finalization_readiness` still `ready=false`.
5. Do not touch authentication users in M8.1A.

---

## 8. Disposable cutover rehearsal plan

Execute on a **separate** database restored from backup. Do not run on this owner/working instance.

| Step | Action | Reversible? | Owner approval? |
|---|---|---|---|
| 1 | Backup current local DB; restore onto a new Docker volume / project | Restore is reversible; original stays untouched | Yes to copy |
| 2 | `supabase migration list` — tip `20261028253000` | Read-only | No |
| 3 | Re-run grain SQL: agg=lot, no negatives, unclassified-with-stock=0 | Read-only | No |
| 4 | Classify remaining unclassified SKUs **on the copy** if that copy will post stock | Irreversible policy on the copy only | Yes |
| 5 | Single UPDATE both flags to `true` (not sequential) | Irreversible without Rule C; rollback of the copy is the recovery | Yes |
| 6 | FEFO/FIFO allocate → pick → handoff on copy | Irreversible postings on the copy | Yes |
| 7 | `confirm_dispatch` consume | Irreversible posting | Yes |
| 8 | `post_delivery_return` with lot grain | Irreversible posting | Yes |
| 9 | Damage report path with `damage.stock_hold_ready` still false unless separately approved | Hold enable is gated | Yes to holds |
| 10 | Failure injection: unmatched grain, unclassified SKU, duplicate dispatch confirm, second return wave UNIQUE | Expected fail-closed | No |
| 11 | Recovery: do **not** set dual-write false after lot ledger exists. Recovery is restore-from-backup of the copy | Backup restore | Yes |
| 12 | Final agg=lot, dispatch qty, return lots present, invoice/credit overlays unchanged | Read-only | No |

Distinguish:

- **Reversible configuration:** flag reads, report filters, watermarked PDFs.
- **Irreversible postings:** opening, receipt, dispatch consume, delivery-return credit, damage write-off.
- **Owner/accountant:** dual-write enable, damage holds, short shipment, statutory issuance, return UNIQUE change, any deletion.

---

## 9. P0 / P1 / P2 / GATED

### P0

None. No stock/financial writer corruption or RLS bypass demonstrated.

### P1 (cutover blockers, not product defects)

1. **Flags false while lot ledger exists.** Evidence: 626 lot-attributed cases + Rule C. Impact: sequential flag edits fail; live picking still off. Resolution: disposable rehearsal, then atomic true/true. Approver: owner. Verify: M1-S1 on copy.
2. **Posted returns without lots.** Evidence: 55/55, all m74b fixtures, 0 invoice/credit links. Impact: credit adjustment fail-closed. Resolution: leave, or authorized test cleanup on a copy. Approver: owner. Do not backfill.
3. **822 unclassified catalog SKUs.** Evidence: 0 with stock; 451 with history. Impact: future dual-write posting on those SKUs fail-closes. Resolution: owner worksheet. Approver: owner/warehouse.

### P2

- Movement report type filter omits `DELIVERY_RETURN`.
- Overview omits RPC KPIs `dispatched_cartons` and `pending_physical_returns`.
- 1439 transactions without ledger after disposable cleanup.
- Two leftover HTTP statutory verifiers.
- Early-phase SQL still non-reentrant (`bootstrap_initial_admin`).

### GATED

Dual-write, aggregate-only-blocked, damage holds, short shipment, statutory issuance, legal numbering, multi-wave returns, payments/TallyPrime, any user revocation, any historical delete.

Intentionally disabled features are not defects.

---

## 10. Owner decisions required

1. Confirm this local database is test-only (1150 `@example.com` users; no operational SKU found).
2. Approve a separate disposable restore for M8.1B rehearsal.
3. Approve atomic dual-write+blocked enable **on the copy only**.
4. Choose return-lot policy: leave non-creditable vs authorized test-header cleanup. No backfill.
5. Classify 822 unclassified SKUs before they receive stock under dual-write.
6. Optionally revoke the two HTTP verifier roles after backup.
7. Keep statutory issuance, payments, TallyPrime, damage holds, and short shipment off.

---

## 11. Test evidence

| Proof | Result |
|---|---|
| Corrected M1-S1 SQL | PASS ROLLBACK |
| Corrected M4 SQL | PASS ROLLBACK |
| M7.6 SQL | PASS ROLLBACK (unclassified-with-stock NOTICE 0) |
| M7.6 HTTP | 7/7 PASS |
| Vitest | 243 passed / 41 files |
| Playwright | 111 passed / 0 failed / 0 skipped (7.3m) |
| `tsc -b` | PASS |
| `oxlint` | 0 errors, 4 pre-existing warnings |
| `npm run build` | PASS |

Changed files (uncommitted):

- `supabase/tests/phase_m1_s1_cutover_flag_safety.sql`
- `supabase/tests/phase_m4_operational_intelligence.sql`
- `docs/m8-1a-production-readiness-audit.md`

No migrations. No stock-writer edits. No flag activation. No user revocation.

---

## Completion flags

`ready=false`  
`legal_issuance_blocked=true`  
`legal_allocation_enabled=false`  
All four operational flags remain false.

No commit, push, deploy, or cloud migration.
