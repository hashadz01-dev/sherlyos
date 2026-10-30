# M8.2C — Isolated Branch-1 UAT preparation

Assessment and scripts only. No isolated stack was started. Development cloud `ypkfondrkhkydkgovwup` was not written. Owner local Docker `supabase_db_sherlyos` (54321/54322) and cutover replica `supabase_db_sherlyos_m81c` (56321/56322) were not used as UAT data sources.

**HEAD:** `234cbaededafec5c21ecafc2d239406089dfcb13` on `main`.

---

## 1. Environment isolation verification

| Environment | Identity | Role for M8.2C |
|---|---|---|
| Development cloud | `https://ypkfondrkhkydkgovwup.supabase.co` | **Not a UAT execution target.** Flags stay false. No synthetic stock/prices. |
| Owner local Docker | `supabase_db_sherlyos`, sysid `7699785797738577957`, API 54321 | Historical fixture DB. Do not treat shop/product totals as owner business data. Do not seed M82C here. |
| M8.1C cutover replica | `supabase_db_sherlyos_m81c`, sysid `7702023892197691429`, API 56321 | Cutover rehearsal. Dual-write was enabled there for M8.1C. **Do not reuse.** |
| Isolated Branch-1 UAT | proposed `sherlyos_m82c`, API **57321**, DB **57322**, app **4373** | **Does not exist yet.** Scripts are prepared; `--start` is gated on `M82C_OWNER_APPROVED=1`. |
| Supabase cloud branches | `list_branches` returned **[]** | No hosted isolated UAT project. |

Cloud migrations include shop sales statement (`20261030112536`). Local files use `20261030190000`. Functions exist. Do not `db reset` the cloud to align timestamps.

Vite `--mode m82c` loads gitignored `.env.m82c.local`. Default `npm run dev` (5173) stays on `.env` / `.env.local` (cloud).

---

## 2. Required TEST ONLY dataset

Synthetic labels only. Not company prices, physical counts, GSTINs, or credit balances. **Do not activate Sunpure / AVT / other owner suppliers.** A new TEST ONLY supplier is created on the isolated database.

| Record | TEST ONLY value | Status |
|---|---|---|
| Godown | `m82c_gd1` / TEST ONLY Godown-1 | Scripted, not inserted |
| Zone | `m82c_z1` / TEST ONLY Zone 1 | Scripted |
| Crates | `m82c_c1`, `m82c_c2` | Scripted (two crates) |
| Route | `m82c_rt` / TEST ONLY Route M82C | SQL insert (no create-route RPC) |
| Shops | TEST ONLY Shop Alpha, TEST ONLY Shop Beta | Scripted + assigned to salesperson |
| Admin | admin.m82c@example.test | Scripted Auth user |
| Accounts | accounts.m82c@example.test | Scripted |
| Godown Manager | gm.m82c@example.test | Scripted + Godown-1 |
| Salesperson | sales.m82c@example.test | Scripted + both shops |
| Store Keeper | keeper.m82c@example.test | Scripted + Godown-1 |
| Delivery Person | driver.m82c@example.test | Scripted + Godown-1 |
| Vehicle | TEST-UAT-0001 / TEST ONLY Vehicle | Scripted; capacity null |
| Supplier / category | TEST ONLY UAT Supplier / TEST ONLY Category | New rows, not owner masters |
| Products | `m82c-expiry` (expiry_controlled), `m82c-stable` (non_expiring), `m82c-spare` (non_expiring) | nos × 10 |
| Prices | INR 10 / 25 / 40 from 2026-01-01 | Synthetic |
| Opening lots | 20 cases each in crate 1 | Only after isolated dual-write |

Password for the isolated Auth users is `local-only-m82c` (local disposable, not an owner credential).

Contract file: `src/lib/uat/m82c-manifest.ts`.

---

## 3. Flag activation prerequisites (isolated UAT only)

Development cloud must remain:

- `damage.stock_hold_ready=false`
- `stock.lots.dual_write_enabled=false`
- `stock.lots.aggregate_only_blocked=false`
- `SHORT_SHIPMENT_OPERATIONAL=false` (source)

Isolated UAT safe sequence:

1. Fresh `npx supabase start` in `.rehearsal/m82c` (all three flags **false**).
2. `phase_m8_2c_isolation_guards.sql` — refuses owner and m81c sysids; requires companion flags false; legal allocation off.
3. Seed users and TEST ONLY masters (`http-seed.mjs --masters`). **No stock yet.**
4. Owner approval to enable dual-write **on this sysid only**.
5. `activate-dual-write.sql` via `http-seed.mjs --cutover` (GUC `app.m82c_seed_approved=on`). Enables **only** `stock.lots.dual_write_enabled`. Leaves `aggregate_only_blocked` and damage holds false. Unlike M8.1C, this UAT does **not** set `aggregate_only_blocked`.
6. Classify policies already set in masters; `http-seed.mjs --stock` posts opening lots with TEST-LOT-* codes. Expiry SKU uses synthetic date `2099-12-31`.
7. Authenticated staff JWT must still be unable to update `app_configuration`.

Do **not** run step 5 automatically. `M82C_OWNER_APPROVED=1` is an explicit shell gate, not a product flag.

---

## 4. Reproducible setup plan (not executed)

```text
node scripts/m8-2c/bootstrap.mjs --plan
node scripts/m8-2c/bootstrap.mjs --write-rehearsal
# STOP. Owner sets M82C_OWNER_APPROVED=1 only after reviewing this document.
M82C_OWNER_APPROVED=1 node scripts/m8-2c/bootstrap.mjs --start
node scripts/m8-2c/bootstrap.mjs --guards
# Copy isolated anon key into gitignored .env.m82c.local
M82C_OWNER_APPROVED=1 node scripts/m8-2c/http-seed.mjs --masters
# STOP FOR dual-write approval
M82C_OWNER_APPROVED=1 node scripts/m8-2c/http-seed.mjs --cutover
M82C_OWNER_APPROVED=1 node scripts/m8-2c/http-seed.mjs --stock
npx playwright test -c playwright.m82c.config.ts
```

`--start` / `--seed` / `--cutover` / `--stock` refuse the owner API (54321), m81c API (56321), cloud hostname `supabase.co`, and sysids `7699785797738577957` / `7702023892197691429`.

---

## 5. Rollback and cleanup

Preferred: destroy the isolated volume. Do not delete ledger rows to “undo” UAT.

```text
# From .rehearsal/m82c only — never from the repository supabase/ directory
npx supabase stop --no-backup
docker volume rm supabase_db_sherlyos_m82c
```

Optional isolated dual-write off: `scripts/m8-2c/rollback.sql` with the same GUC and sysid refusals. It does not touch the owner or m81c databases.

Do not merge TEST ONLY lots, prices, or users onto development cloud.

---

## 6. Role readiness

| Role | Isolated user | Cloud today | Ready to UAT? |
|---|---|---|---|
| Admin | Scripted | Jeffin exists | After isolated seed |
| Accounts | Scripted | testaccounts@gmail.com, no godown | Isolated only |
| Godown Manager | Scripted | testgodownmanager, no godown | Isolated only |
| Salesperson | Scripted + shop assignments | testsalesperson, **0 shop assignments** | Isolated only |
| Store Keeper | Scripted | teststorekeeper, no godown | Isolated only |
| Delivery Person | Scripted | **0 users on cloud** | Isolated only |

Cloud is not role-ready for Order-to-Delivery UAT (no driver, no shop assignments, no dual-write). Isolated scripts cover the six roles after owner-approved start.

---

## 7. Stock and pricing readiness

| Item | Development cloud | Isolated UAT after approved seed |
|---|---|---|
| Zones / crates | 0 / 0 | 1 zone, 2 crates |
| Selling prices | 0 | 3 synthetic defaults |
| Lots / balances | 0 | 3 TEST lots × 20 cases after cutover |
| Dual-write | false (must stay) | true after explicit --cutover |
| Owner catalogue SKUs | 102 live products | **not copied** |
| Owner suppliers | 6 inactive | **not activated** |

Picking on cloud remains fail-closed. Isolated picking is possible only after step 5–6.

---

## 8. Tests executed in this phase

| Check | Target | Result |
|---|---|---|
| Isolation SQL refuse path | owner local `supabase_db_sherlyos` | **PASS** — raised `M8.2C guards refused the owner database` |
| Isolation SQL | M82C stack | **NOT RUN** (stack absent) |
| HTTP seed | M82C stack | **NOT RUN** (approval gate; no writes) |
| Playwright `playwright.m82c.config.ts` | M82C stack | **NOT RUN** |
| Default Playwright (4173 / m1s2) | owner local | **NOT RUN** (would use fixture Docker, not Branch-1 UAT) |
| Cloud writes | ypkfondrkhkydkgovwup | **NOT RUN** (forbidden) |
| Vitest `tests/unit/m8-2c-workflow.test.ts` | local unit | **PASS** (8) |
| Vitest full suite | local unit | **PASS** 51 files / 289 tests |
| `npm run typecheck` | workspace | **PASS** |
| `npm run lint` | workspace | **PASS** (pre-existing warnings only) |
| `npm run build` | workspace | **PASS** |

Scenarios A–F are **not** marked PASS.

---

## 9. Owner decisions required

1. Create `sherlyos_m82c` locally (`M82C_OWNER_APPROVED=1`).
2. Enable dual-write **only** there; keep the other three operational flags false.
3. Accept TEST ONLY prices 10/25/40 and opening 20 cases as synthetic.
4. Do not copy 565 shops or 102 products into the UAT stack as “business truth.”
5. Do not reuse m81c.
6. Do not point Netlify / 5173 at the isolated stack without a separate decision.

---

## 10. Final readiness verdict

Isolated Branch-1 UAT is **designed and scripted**, not provisioned. Workflow mismatches are documented rather than patched. Development-cloud Order-to-Delivery UAT remains blocked by flags, missing driver, missing prices/lots, and missing shop assignments.
