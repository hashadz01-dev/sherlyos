# M8.1B — Disposable stock cutover rehearsal and recovery validation

Local-only. This milestone does **not** activate flags on the owner database, apply cloud migrations, reset local Supabase volumes, issue statutory documents, backfill return lots, or commit.

Starting HEAD: `bd4abfede8347501dc69748ac807597de0c7d1ab`  
`test(m8.1a): audit production readiness and cutover safety`

Branch `main`. Working tree was clean at start. Local migration tip `20261028253000`. M8.1A report present at `docs/m8-1a-production-readiness-audit.md`.

Owner flags at start and end:

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false` (source constant)

Statutory issuance RPCs remain absent. `legal_allocation_enabled=false` on every FY / invoice series / credit-note series.

---

## 1. Starting HEAD

Preflight on `main` matched M8.1A closure. No fetch, rebase, reset, deploy, cloud migration, or commit.

---

## 2. Environment identities (no secrets)

| Surface | Identity |
|---|---|
| Cloud project (untouched) | `https://ypkfondrkhkydkgovwup.supabase.co` |
| Owner local container | `supabase_db_sherlyos` |
| Owner image | `public.ecr.aws/supabase/postgres:17.11.0.003` |
| Owner volume | `supabase_db_sherlyos` → `/var/lib/docker/volumes/supabase_db_sherlyos/_data` |
| Owner API | `http://127.0.0.1:54321` |
| Owner Postgres | `127.0.0.1:54322` |
| Owner `system_identifier` | `7699785797738577957` |
| Disposable container | `sherlyos_m81b_rehearsal` |
| Disposable volume | `sherlyos_m81b_rehearsal_pgdata` → `/var/lib/docker/volumes/sherlyos_m81b_rehearsal_pgdata/_data` |
| Disposable Postgres | `127.0.0.1:55532` (bound to localhost) |
| Disposable database | `m81b_rehearsal` |
| Disposable `system_identifier` | `7702016443865817122` |

Rehearsal-only connection file: `.env.m81b.rehearsal.local` (gitignored). Playwright and Vite were not pointed at it. Cloud and owner service credentials were not reused.

Leftover volumes `supabase_db_sherlyosc3` / `sherlyosc4` were not used.

---

## 3. Isolation evidence

1. New Docker volume `sherlyos_m81b_rehearsal_pgdata`, created 2026-10-29T09:17:01Z. Distinct from `supabase_db_sherlyos`.
2. New container `sherlyos_m81b_rehearsal` on a non-overlapping host port. Owner stack on 54321/54322 was not stopped, reset, or volume-mounted.
3. Cluster identity differs (`7699785797738577957` vs `7702016443865817122`). Logical restore cannot clone `system_identifier`.
4. Rehearsal SQL refuses to run when `pg_control_system().system_identifier = 7699785797738577957` or `current_database() <> 'm81b_rehearsal'`.
5. `npx supabase db reset --local` was not run. Owner volume files were not modified.
6. Dump was written to container `/tmp` then copied to gitignored `.rehearsal/`. Owner `/tmp/m81b_source.dump` was removed after copy.

---

## 4. Backup and restore

Read-only `pg_dump -Fc` of owner `postgres` as a 9.0 MiB custom file.

SHA-256 (source dump): `B6DC8D8B72192D09E716C91D0C3110DB9160F6018FA074C2D09A598B12ACE2AB`

Restored with `pg_restore` as `supabase_admin` into disposable database `m81b_rehearsal`. Missing roles `supabase_functions_admin` and `supabase_realtime_admin` were created on the empty cluster first.

Row-count match after restore:

| Object | Owner | Disposable |
|---|---|---|
| Migrations | 75, tip `20261028253000` | 75, tip `20261028253000` |
| Auth users | 1150 | 1150 |
| Products | 1636 | 1636 |
| Aggregate rows / qty | 140 / 638 | 140 / 638 |
| Lot-balance rows / qty | 140 / 638 | 140 / 638 |
| Lots | 141 | 141 |
| Ledger | 1054 | 1054 |
| Stock transactions | 2483 | 2483 |
| Posted returns | 56 | 56 |
| Return-lot rows | 0 | 0 |

Sixteen owner FKs failed `VALIDATE` on restore because replica-role test leftovers left child rows whose parents were later deleted. Those constraints exist as `VALID` on the owner only because they were added before the orphans. Disposable replay added the same names `NOT VALID` (new writes still enforced). Checkpoint dump SHA-256: `06498DD9C54AA7F3CC6290FF6302B0AD8EBED27ACA0E8DC76B29ECF850E43AE3`.

---

## 5. Pre-cutover stock readiness (disposable)

`app_private.assert_lot_inventory_grains_reconciled()` passed.

| Check | Result |
|---|---|
| Aggregate on-hand = lot on-hand | 638 = 638 |
| Negative aggregate / lot balances | 0 / 0 |
| Stocked unclassified products | 0 |
| Unclassified catalog SKUs (must stay blocked) | 829 |
| Historical posted returns | 56 preserved |
| Historical return-lot rows | 0 (none manufactured) |
| Ledger rows without transactions | 0 |
| Damage holds / short shipment / statutory issuance | all off |

---

## 6. Atomic cutover (disposable only)

Sequential `aggregate_only_blocked=true` while dual-write stayed false was rejected (`55000`, Rule C / lot-attributed ledger). That is the populated-database safety rule, not a defect.

One statement:

```sql
update public.app_configuration
set value = 'true'::jsonb
where key in (
  'stock.lots.dual_write_enabled',
  'stock.lots.aggregate_only_blocked'
);
```

Accepted. Resulting state: dual-write **true**, aggregate-only blocked **true**, damage holds **false**.

After cutover:

- Aggregate-only `post_opening_stock` (no lot fields) failed closed (`23514`).
- Lot-aware openings with classified products and valid expiry policy succeeded.

Damage holds, short shipment, and statutory issuance were not enabled.

---

## 7. End-to-end lot operations

Isolated prefix `m81b-*`. Independent oracles in `app_private.m81b_oracles` (wiped by recovery).

| Step | Oracle |
|---|---|
| Classified products + godown/zone/crate | `m81b_a` / `z1` / `ca`+`cb`; peer godown `m81b_b` |
| Lot-aware opening | exp 0→8 (`BATCH-EARLY` 2027-01-15, `BATCH-LATE` 2028-12-01); nx 0→6 (`NX-OLD` then `NX-NEW`) |
| FEFO | `preview_order_allocation` first expiry slice = `BATCH-EARLY` |
| FIFO | first non-expiring slice = `NX-OLD` |
| Dispatch consume | exp 8→3 (−5), nx 6→4 (−2); grains still matched |
| POD | `acknowledge_dispatch_delivery` → `delivered` |
| Return-path dispatch | exp 3→1 (−2) |
| Lot-aware return post | exp 1→3 (+2); payload lots length 1 |
| Net vs pre-cutover 638 | 638 + 8 + 6 − 5 − 2 − 2 + 2 = **645** aggregate and lot |

Historical posted returns stayed at 56 + 1 fixture = 57 during rehearsal. Historical return lots were not backfilled.

---

## 8. Failure injection

Rejected operations did not change oracles.

| Case | Result |
|---|---|
| Unclassified stocked product | `23514` |
| Missing lot / aggregate-only after cutover | `23514` |
| Expiry-controlled without expiry | `23514` |
| Non-expiring with expiry | `23514` |
| Cross-godown crate (GM of A onto crate in B) | `42501` or `23514` |
| Cross-godown dispatch preview | `42501` |
| Cross-godown return receiving crate | `23514` |
| Driver opening stock | `42501` |
| Direct `stock_balances` update | `42501`; qty unchanged |
| Over-pick (reserved+1) | `23514`; picked qty not stored |
| Duplicate dispatch confirm | no second consume (5 exp / 2 nx held) |
| Duplicate return post | qty unchanged after second call |

---

## 9. Recovery

Recovery was **restore of the verified checkpoint**, not flag-off after lot-ledger activity.

`DROP DATABASE m81b_rehearsal` then `pg_restore` of `m81b_checkpoint.dump`.

| Check after restore | Result |
|---|---|
| Flags | false / false / false |
| Migration tip | `20261028253000` |
| Aggregate / lot qty | 638 / 638 |
| `m81b-%` products | 0 |
| `%.m81b@example.com` users | 0 |
| `app_private.m81b_oracles` | absent |
| Posted returns / return lots | 56 / 0 |

Disposable `system_identifier` remained `7702016443865817122` (same cluster, restored data). Rehearsal transactions did not survive.

---

## 10. Source database invariance

Owner after rehearsal and recovery:

| Check | Start | End |
|---|---|---|
| `system_identifier` | `7699785797738577957` | `7699785797738577957` |
| Dual-write | false | false |
| Aggregate-only blocked | false | false |
| Damage holds | false | false |
| Aggregate / lot qty | 638 / 638 | 638 / 638 |
| Ledger / transactions | 1054 / 2483 | 1054 / 2483 |
| Posted returns | 56 | 56 |
| `m81b-%` products | 0 | 0 |
| Migration tip | `20261028253000` | `20261028253000` |

No `supabase db reset`. No owner volume writes. No cloud API calls that mutate `ypkfondrkhkydkgovwup`.

---

## 11. Regression

Mutating tests that hardcode `supabase_db_sherlyos` or `127.0.0.1:54321` were **not** executed. That includes Playwright (`--mode m1s2`), HTTP integration `.mjs` files, and `phase_m1_s2_concurrency.mjs`.

| Proof | Target | Result |
|---|---|---|
| M8.1B rehearsal SQL | disposable `m81b_rehearsal` | COMMIT, then recovered |
| `phase_m1_s1_cutover_flag_safety.sql` | disposable | PASS ROLLBACK |
| `phase_m3_dispatch_delivery.sql` | disposable | PASS ROLLBACK |
| `phase_m7_4b_delivery.sql` | disposable | PASS ROLLBACK |
| `phase_m1_lot_aware_operational_posting.sql` | disposable | FAIL as designed: sequential `blocked=true` hits Rule C while lot ledger exists |
| `phase_m2_fefo_fifo_picking.sql` | disposable | FAIL as designed: same sequential flag write before replica enable |
| Vitest | no DB | 243 passed / 41 files |
| Playwright | owner API | **not run** (would mutate owner) |
| `tsc -b` | n/a | PASS |
| `oxlint` | n/a | 0 errors, 4 pre-existing warnings |
| `npm run build` | n/a | PASS |

FEFO/FIFO, dispatch, and delivery-return were proven on the disposable cutover path (section 7) and again via M3 / M7.4B rollback scripts after recovery.

---

## 12. Remaining risks

1. Sixteen owner FKs would not re-validate because replica leftovers orphaned children. Live owner constraints are already `VALID` from an earlier clean state. Do not `VALIDATE` those names on owner without an authorized orphan cleanup.
2. Playwright / PostgREST / GoTrue were not stood up against the disposable cluster. A second full Supabase API stack is required before HTTP or browser cutover rehearsal.
3. Early-phase SQL (`phase_m1_lot_aware_operational_posting`, `phase_m2_fefo_fifo_picking`) still sequential-enable flags and cannot run on a populated lot-ledger database without replica or the atomic pair. Production trigger is correct.
4. 829 unclassified catalog SKUs remain. They stay blocked after dual-write; they must be classified before they receive stock.
5. Historical posted returns still have zero return-lot rows. Do not backfill. New lot-aware returns write lots going forward.
6. Local catalog remains test fixtures (`@example.com`). Owner must still confirm this instance is not operational production data before any live cutover.

---

## 13. Recommendations for M8.1C

1. Keep owner flags false until an explicit owner go-ahead on a named database.
2. If HTTP/Playwright cutover is required, start a second Supabase stack (`project_id` and ports distinct from `sherlyos` / 54321 / 54322) and restore the same dump there. Do not retarget `.env.m1s2.local`.
3. Cutover runbook: one `UPDATE` of both lot flags to true. Never sequential enable. Never flag-off after lot ledger exists; recovery is restore.
4. Classify or keep blocked the 829 unclassified SKUs before they are stocked.
5. Leave statutory issuance, payments, TallyPrime, damage holds, and short shipment off.
6. Optionally repair owner replica orphans under a separate approved hygiene milestone.

---

## Changed files (uncommitted)

- `docs/m8-1b-disposable-stock-cutover-rehearsal.md`
- `supabase/tests/phase_m8_1b_disposable_cutover_rehearsal.sql`
- `.gitignore` (ignores `.rehearsal/`)

Gitignored local artefacts: `.rehearsal/m81b_source.dump`, `.rehearsal/m81b_checkpoint.dump`, `.env.m81b.rehearsal.local`.

No migrations. No stock-writer edits. No owner flag activation. No user revocation.

Disposable container `sherlyos_m81b_rehearsal` and volume `sherlyos_m81b_rehearsal_pgdata` remain on the machine for owner inspection. They are not the owner database.

---

## Completion flags

Owner: all four operational flags remain false. Statutory issuance remains impossible.

Disposable: recovered to false/false/false with original 638/638 balances.

No commit, push, deploy, or cloud migration.
