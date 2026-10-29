# M8.1C — Isolated full-stack cutover validation and clean production baseline

Local-only. This milestone does **not** activate flags on the owner database, apply cloud migrations, reset the owner Supabase volume, issue statutory documents, backfill return lots, or commit.

Starting HEAD: `757f287c62699c03408451ac63d1958938969f57`  
`test(m8.1b): validate isolated stock cutover and recovery`

Branch `main`. Working tree was clean at start. Local migration tip `20261028253000`. M8.1B report present at `docs/m8-1b-disposable-stock-cutover-rehearsal.md`.

Owner flags at start and end:

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false` (source constant in `src/lib/picking/rules.ts`)

Statutory issuance RPCs remain absent. `ready=false`, `legal_issuance_blocked=true`, `legal_allocation_enabled=false` on every FY / invoice series / credit-note series.

---

## 1. Starting HEAD

Preflight on `main` matched M8.1B closure. No fetch, rebase, reset, deploy, cloud migration, or commit.

Owner PostgreSQL `system_identifier` `7699785797738577957`. 75 migrations, tip `20261028253000`.

---

## 2. Environment isolation

A second local Supabase stack was started from gitignored `.rehearsal/m81c/` with `project_id = "sherlyos_m81c"`. Studio, realtime, analytics, and edge runtime are disabled. API, Auth, Storage, Mailpit, and Postgres are enabled on non-owner ports. Seed is empty (`supabase/seed.sql` comment only).

| Surface | Owner | Isolated M8.1C |
|---|---|---|
| Project id | `sherlyos` | `sherlyos_m81c` |
| API / Kong | `127.0.0.1:54321` | `127.0.0.1:56321` |
| Postgres | `0.0.0.0:54322` | `0.0.0.0:56322` |
| Mailpit | `54324` | `56324` |
| Studio | `54323` (running) | disabled / not running |
| DB container | `supabase_db_sherlyos` | `supabase_db_sherlyos_m81c` |
| Image | `postgres:17.11.0.003` (2026-10-23) | `postgres:17.11.0.006` (2026-10-29) |
| Volume | `supabase_db_sherlyos` | `supabase_db_sherlyos_m81c` |
| Auth container | `supabase_auth_sherlyos` | `supabase_auth_sherlyos_m81c` |
| PostgREST container | `supabase_rest_sherlyos` | `supabase_rest_sherlyos_m81c` |
| `system_identifier` | `7699785797738577957` | `7702023892197691429` |
| Linked cloud project | `ypkfondrkhkydkgovwup` (untouched) | none |

Vite uses gitignored `.env.m81c.local` (`VITE_SUPABASE_URL=http://127.0.0.1:56321`). Playwright uses `playwright.m81c.config.ts` (`SHERLYOS_ISOLATED=1`, `SHERLYOS_VITE_MODE=m81c`, `SHERLYOS_PSQL_CONTAINER=supabase_db_sherlyos_m81c`, app port `4273`). HTTP integration reads status from `.rehearsal/m81c` and refuses API port `54321` and the owner sysid.

Default `playwright.config.ts` (`--mode m1s2` / `54321`) and historical `supabase/tests/*.mjs` files that hardcode `supabase_db_sherlyos` were **not** executed.

Local demo JWT material is shared between owner and isolated stacks (Supabase CLI default). Isolation is therefore ports, containers, volumes, and cluster identity — not a distinct signing secret. Isolated tests still refuse the owner API port.

M8.1B leftover Postgres `sherlyos_m81b_rehearsal` on `127.0.0.1:55532` was not used.

No writable owner volume was mounted into the isolated stack. No `npx supabase db reset` was run from the repository root.

---

## 3. Foreign-key audit

The sixteen constraints that failed `VALIDATE` after the M8.1B logical restore still exist as **VALID** on the owner (they were created before the orphans). They are **not** a migration defect: a clean migration-built database has zero orphans and zero `NOT VALID` foreign keys.

Owner orphan counts (read-only, no deletes, no constraint drops):

| Child column | Referenced table | Owner orphans | Isolated / clean |
|---|---|---:|---:|
| `damage_report_events.damage_report_id` | `damage_reports` | 4 | 0 |
| `damage_report_lines.crate_id` | `crates` | 5 | 0 |
| `damage_report_lines.lot_id` | `stock_lots` | 243 | 0 |
| `damage_report_lines.product_id` | `products` | 48 | 0 |
| `damage_reports.godown_id` | `branches` | 5 | 0 |
| `damage_stock_holds.lot_id` | `stock_lots` | 210 | 0 |
| `damage_stock_holds.source_reservation_id` | `stock_reservations` | 1 | 0 |
| `invoice_credit_adjustment_lines.return_lot_id` | `stock_delivery_return_lots` | 26 | 0 |
| `order_lines.product_id` | `products` | 15 | 0 |
| `orders.originating_shipment_id` | `order_shipments` | 24 | 0 |
| `stock_adjustment_line_lot_allocations.lot_id` | `stock_lots` | 6 | 0 |
| `stock_dispatch_requests.posted_transaction_id` | `stock_transactions` | 29 | 0 |
| `stock_lot_aware_applications.transaction_id` | `stock_transactions` | 82 | 0 |
| `stock_receipt_lines.product_id` | `products` | 18 | 0 |
| `stock_transactions.destination_crate_id` | `crates` | 207 | 0 |
| `stock_transactions.product_id` | `products` | 207 | 0 |

Example owner transaction references whose `product_id` no longer exists: `OS-20261026-001064`, `OS-20261026-001069`, `OS-20261026-001075`. These are replica-cleanup leftovers (opening-stock headers whose products were later deleted), not live cutover traffic.

Recommended resolution: **do not VALIDATE these names on the owner** without an authorized orphan-hygiene milestone. Do not delete historical rows to make a restore look clean. Production should start from a migration-built database, not a restored copy of the accumulated test instance.

Owner `pg_constraint` currently reports `convalidated = true` and `NOT VALID` count `0`. That is historical luck, not restore-safety.

---

## 4. Clean migration results

Isolated stack was built with `npx supabase db reset` **from `.rehearsal/m81c` only**. `phase_m8_1c_clean_baseline.sql` then passed:

| Check | Result |
|---|---|
| Refused owner sysid | PASS |
| Migrations | 75, tip `20261028253000` |
| `NOT VALID` foreign keys | 0 |
| Dual-write / aggregate-only blocked / damage holds | all `false` |
| Legal allocation on FY / invoice / credit series | all off |
| Public RLS policies | 103 |
| FORCE RLS on `stock_balances`, `stock_lot_balances`, `stock_lots`, `stock_transactions` | true |
| Authenticated policies on balances / ledger / lot balances | `SELECT` only (`polcmd = r`) |
| Extensions | `btree_gist`, `http`, `pg_stat_statements`, `pgcrypto`, `plpgsql`, `supabase_vault`, `uuid-ossp` |
| Products / operational users / stock qty | 0 / 0 / 0 before HTTP fixtures |

This empty migration-built database is the production candidate. The owner accumulated database is fixture-contaminated and must not be copied forward as production.

HTTP cutover later added three classified products and lot stock on the same isolated cluster. After that work, isolated still has **0 orphans and 0 `NOT VALID` FKs**. Fixture contamination on the owner did not reproduce on the clean chain.

---

## 5. HTTP / browser proof

Authenticated HTTP (`supabase/tests/phase_m8_1c_http_integration.mjs`) against `127.0.0.1:56321` and container `supabase_db_sherlyos_m81c`: **16 / 16 PASS**.

Staff JWTs used for masters, opening stock, picking, dispatch, POD, and lot-aware return. Privileged SQL was used only to create Auth users, assign roles, and perform the atomic cutover `UPDATE` of both lot flags (staff `UPDATE` on `app_configuration` cannot enable flags).

| Check | Result |
|---|---|
| Sign-in for admin, accounts, godown manager, store keeper, delivery person, peer GM | PASS |
| Authenticated staff cannot enable dual-write | PASS |
| Classified products + godown / zone / crate via RPCs | PASS |
| Atomic `dual_write_enabled` + `aggregate_only_blocked` | PASS; damage holds stayed false |
| Unclassified / missing-lot / driver / cross-godown writes | denied; no stock |
| Lot-aware openings | expiry 8 + non-expiring 6 = 14 = 14 |
| Duplicate opening idempotent | PASS |
| FEFO first slice `BATCH-EARLY`; FIFO first slice `NX-OLD` | PASS |
| Peer godown preview | denied |
| Store keeper `prepare_dispatch` | denied |
| Dispatch consume + duplicate confirm | one ledger |
| Proof of delivery | `delivered` |
| Failed-delivery return with lot rows | PASS; duplicate post did not double-credit |
| Final aggregate = lot | **7 = 7** |

Isolated Playwright (`npx playwright test -c playwright.m81c.config.ts`): **10 / 10 PASS**.

| Role | Proof |
|---|---|
| Isolation | sysid is not owner; isolated flags true after HTTP cutover |
| Admin | `/masters/products`, `/inventory/opening`, inventory shows `M81C Expiry` stock |
| Godown manager | picking, dispatch; no Users & role; lot reconciliation; `/users-roles` access denied |
| Store keeper | picking; dispatch heading absent; opening stock heading absent |
| Delivery person | delivery runs; orders capture denied; opening-stock writes denied |
| Accounts | orders, delivery notes, invoice-note watermark `DRAFT INVOICE NOTE — NOT A TAX INVOICE`, no finalize/issue/allocate controls, credit adjustments, picking denied |
| Invalid login | `Invalid login credentials`; URL stays `/login` |

Browser click-through of the full pick → dispatch → POD → return path was not repeated in Playwright; that path was proven with the same roles over authenticated PostgREST. Default owner Playwright was not substituted.

---

## 6. Role and security checks

- Cross-godown crate opening and peer-GM allocation preview denied on HTTP.
- Driver cannot post opening stock (HTTP and browser).
- Store keeper cannot prepare dispatch (HTTP and browser).
- Accounts cannot reach picking.
- Godown manager cannot administer users.
- Direct `stock_balances.quantity = 0` as `postgres` is rejected (`balance does not match the ledger`).
- Authenticated policies on stock balances / lot balances / ledger are SELECT-only. Mutations go through trusted RPCs.

---

## 7. Stock reconciliation

Isolated after HTTP cutover and recovery proof:

| Grain | Quantity |
|---|---|
| Aggregate `stock_balances` | 7 |
| Lot `stock_lot_balances` | 7 |
| Products | 3 classified HTTP fixtures |
| `NOT VALID` FKs | 0 |
| Dual-write / aggregate-only blocked | true / true (isolated only) |
| Damage holds | false |

Net path: open 14 → dispatch 5+2 → return-path dispatch 2 → lot-aware return +2 → **7**.

Owner remains 638 = 638 with flags false.

---

## 8. Recovery results

Recovery is restore of a verified disposable dump, not flag-off after lot ledger exists.

1. `pg_dump -Fc` of isolated `postgres` → gitignored `.rehearsal/m81c/post_cutover.dump`.
2. SHA-256 `568AF98A98985AC7E21A3AB8254A973ECEAA0295FAD1401D3BD6D8559EE95E8E` (3 082 446 bytes).
3. Restore into sibling database `m81c_recovered` on the **same isolated cluster**. Recovered agg/lot/flags matched live (7 / 7 / dual-write true).
4. `pg_restore` warned on `vault.secrets` and `pg_stat_statements_reset` grants. Public stock and configuration still restored and queried.
5. Live `UPDATE stock_balances SET quantity = 0` rejected by ledger trigger.
6. Live flag-off of both lot keys rejected: `stock.lots.aggregate_only_blocked cannot be false while lot inventory or lot-attributed ledger rows exist`.
7. After those rejected attempts, live isolated still 7 = 7 with flags true. Recovered sibling unchanged.

`phase_m8_1c_recovery.mjs` prints `M8.1C recovery PASS`.

---

## 9. Production setup strategy

Do **not** restore the owner test database into production. Build a new Supabase project and apply the migration chain.

1. Create a fresh Supabase project / PostgreSQL instance (cloud or dedicated host). Do not reuse `ypkfondrkhkydkgovwup` test data.
2. Apply all 75 migrations in order to tip `20261028253000` (or the then-current tip). Confirm 0 `NOT VALID` FKs, FORCE RLS, SELECT-only authenticated stock policies, flags false, legal allocation off.
3. Bootstrap the first Admin via Auth + `profiles` / `user_roles`. Do not copy `@example.com` test users.
4. Create real godowns (branches), then zones and crates.
5. Import products and suppliers. Classify every SKU that will hold stock (`expiry_controlled` or `non_expiring`). Unclassified products stay blocked.
6. Import shops and salespeople. Assign users to godowns and roles.
7. Post opening stock as lot-aware quantities. Reconcile aggregate = lot before cutover.
8. Take a verified backup. Rehearse restore on a disposable copy.
9. Owner-approved atomic cutover on that named database only:
   `UPDATE app_configuration SET value = 'true'::jsonb WHERE key IN ('stock.lots.dual_write_enabled','stock.lots.aggregate_only_blocked');`
10. Pilot one godown through pick → dispatch → delivery → return. Keep statutory issuance, payments, TallyPrime, damage holds, and short shipment off until separately approved.

Business must supply: legal entity and GST profile, godown list, zone/crate map, product catalogue with expiry class, suppliers, shops, salespeople, opening-stock counts with manufacturer lots / expiry dates, named staff and roles, backup retention, and a written cutover window.

Do not populate production from this rehearsal. Do not deploy from this milestone.

---

## 10. Remaining P0 / P1 / P2

**P0**

None on the isolated stack. Owner operational flags remain false.

**P1**

1. Owner accumulated database still has the sixteen orphan families above. Do not treat a restored copy of that database as a production baseline.
2. Historical Playwright / HTTP / concurrency helpers still hardcode owner `54321` / `supabase_db_sherlyos`. They must not be run until retargeted. Isolated M8.1C configs are the safe path.

**P2**

1. Local demo JWT secret is shared between owner and isolated stacks.
2. Full browser click-through of pick → dispatch → POD → return was not added; HTTP Auth covered that path.
3. Historical concurrency `.mjs` suites were not ported to the isolated stack. Isolated HTTP did prove duplicate opening, duplicate dispatch confirm, and duplicate return post.
4. `pg_restore` of a live Supabase catalog warns on `vault.secrets`. Use sibling-database restore plus the project backup runbook, not a naive dump onto another cluster’s `postgres` database.
5. 829 unclassified owner catalog SKUs remain on the accumulated instance. A clean production catalog must classify before stocking.

---

## 11. Owner approvals required

1. Accept the clean migration-built database as the production candidate (not the owner test instance).
2. Authorize a later named-database cutover. Do not enable flags on `supabase_db_sherlyos`.
3. Supply the business master data listed in section 9.
4. Decide whether owner orphan hygiene is a separate milestone or is discarded by starting fresh.
5. Keep statutory issuance, payments, TallyPrime, damage holds, and short shipment off until explicit later approval.
6. Review isolated stack teardown (`sherlyos_m81c` containers/volume) when inspection is finished.

---

## 12. Recommendation for M8.2

M8.2 should be **staff UAT on a clean project**, not flag activation on the owner local database.

Suggested M8.2 scope: production-project bootstrap, real master-data import, opening-stock verification, written cutover approval, one-godown pilot, backup/restore drill on that project. Leave owner `sherlyos` flags false.

---

## Regression counts

| Proof | Target | Result |
|---|---|---|
| `phase_m8_1c_clean_baseline.sql` | isolated, pre-HTTP | PASS |
| `phase_m8_1c_fk_orphans.sql` | owner read-only | 16 families, counts above |
| `phase_m8_1c_fk_orphans.sql` | isolated | 16 × 0 |
| `phase_m8_1c_http_integration.mjs` | isolated API 56321 | **16 / 16 PASS** |
| `playwright.m81c.config.ts` | isolated Vite 4273 | **10 / 10 PASS** |
| `phase_m8_1c_recovery.mjs` | isolated dump + sibling restore | PASS |
| Historical concurrency / HTTP / default Playwright | owner 54321 | **not run** |
| Vitest | no DB | **243 passed / 41 files** |
| `tsc -b` | n/a | PASS |
| `oxlint` | n/a | 0 errors, 4 pre-existing warnings |
| `npm run build` | n/a | PASS |

---

## Changed files (uncommitted)

- `docs/m8-1c-full-stack-cutover-and-clean-production-plan.md`
- `playwright.m81c.config.ts`
- `tests/e2e/assert-local-target.ts`
- `tests/e2e/disposable-stock.ts`
- `tests/e2e/m81c-isolated-cutover.spec.ts`
- `supabase/tests/phase_m8_1c_clean_baseline.sql`
- `supabase/tests/phase_m8_1c_fk_orphans.sql`
- `supabase/tests/phase_m8_1c_http_integration.mjs`
- `supabase/tests/phase_m8_1c_owner_invariance.sql`
- `supabase/tests/phase_m8_1c_recovery.mjs`

Gitignored: `.env.m81c.local`, `.rehearsal/m81c/`.

No migrations. No stock-writer edits. No owner flag activation. No user revocation. No commit, push, deploy, or cloud migration.
