# DMG-03I — Isolated Cloud UAT Environment & Storage Damage Activation

**Final verdict: BLOCKED (awaiting owner-provisioned isolated cloud project)**

No changes were made to `ypkfondrkhkydkgovwup`.  
No migrations or flags applied there.  
`DMG-20261103-000013` untouched (`draft` / `storage`).  
No commit/push/deploy. No new cloud project created (requires separate owner authorization).

Disposable Docker (`m82c` / port **5174**) remains the only environment where Storage Damage isolation is fully proven. Port **5173** still targets the existing cloud with `damage.stock_hold_ready=false`.

---

## A. Environment strategy

| Surface | Role | Backend | Hold ready |
|---------|------|---------|------------|
| `127.0.0.1:5173` | Existing main UAT UI | `ypkfondrkhkydkgovwup` | `false` (unchanged) |
| `127.0.0.1:5174` | Disposable Docker UAT | Kong `57321` / `supabase_db_sherlyos_m82c` | `true` |
| `127.0.0.1:5175` | **Planned** isolated cloud UAT UI | **New** Supabase project (not created) | to be enabled after seed |

### Strategy

1. **Do not** activate isolation on `ypkfondrkhkydkgovwup` (commercial SKUs, no disposable stock, no verified data backup).  
2. Provision a **separate** Supabase cloud project with migrations + TEST ONLY fixtures.  
3. Bind a dedicated Vite mode/env to port **5175** so 5173 stays on the existing project.  
4. Only after that isolated project passes browser UAT may the owner separately decide whether to cut over the existing cloud (DMG-03H).

### Separate cloud project availability

- MCP / Cursor is linked only to `https://ypkfondrkhkydkgovwup.supabase.co`.  
- `list_branches` on that project is empty; branching would create a **fresh** DB without copying data (still incurs cost; still not used here).  
- **No second isolated cloud project exists today.** Owner must create one.

---

## B. Exact provisioning requirements

### Owner authorization required to create

1. Create new Supabase project (name suggestion: `sherlyos-dmg03i-uat`).  
2. Enable Auth email provider; create TEST ONLY users.  
3. Copy publishable/anon key into gitignored `.env.dmg03i.local` (from `.env.dmg03i.example`).  
4. `supabase link --project-ref <NEW_REF>` then push migrations through `20261103160000`.  
5. Seed fixtures per `scripts/dmg03i/fixture-contract.md` using trusted RPCs (`post_opening_stock`, masters APIs).  
6. Set `stock.lots.dual_write_enabled=true` → recon `mismatched=0` → `damage.stock_hold_ready=true`.  
7. Run UI:

```bash
npm run dev -- --mode dmg03i --host 127.0.0.1 --port 5175 --strictPort
```

Vite loads `.env.dmg03i.local` / `.env.dmg03i` for mode `dmg03i`.  
**Do not** change `.env.local` (5173) without a separate change-control decision.

### Env vars (isolated app)

| Variable | Purpose |
|----------|---------|
| `VITE_SUPABASE_URL` | New project HTTPS URL |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | Anon/publishable key |
| `SUPABASE_URL` / `SUPABASE_ANON_KEY` | Scripts only |
| `SUPABASE_SERVICE_ROLE_KEY` | Seed scripts only — **never** `VITE_` |

Checklist helper: `scripts/dmg03i/provision-checklist.sh` (prints steps only).

### 5173 unchanged (verified this pass)

| Check | Result |
|-------|--------|
| `.env.local` URL | `https://ypkfondrkhkydkgovwup.supabase.co` |
| Cloud `damage.stock_hold_ready` | `false` |
| Cloud dual-write | `true` |
| Cloud aggregate_only_blocked | `true` |
| Migration tip | still `20261102125515_damage_evidence_cloud_storage_fetch` |
| Draft `DMG-20261103-000013` | `draft` / `storage` |

---

## C. Migration readiness

### Required on the **new** isolated project (ordered)

1. Full chain from repo foundation through current tip **including**:  
2. `20261102190000_damage_inbound_receipt_line_lock.sql`  
3. `20261103100000_damage_evidence_drop_followlocation.sql`  
4. `20261103120000_damage_storage_store_keeper_draft.sql`  
5. `20261103130000_damage_hold_ready_requires_lot_dual_write.sql`  
6. `20261103140000_transfer_adjustment_honor_damage_holds.sql`  
7. `20261103160000_damage_storage_lot_catalog.sql`  

### On existing cloud `ypkfondr…` (do not apply in this milestone)

Same six remain **pending**; tip is `20261102125515`. Left untouched by design.

### Exclude unless proven necessary

- `20261103170000_damage_evidence_disposable_kong_hosts.sql` — Docker Kong aliases. New cloud project should use the project HTTPS URL already allowlisted in evidence fetch patterns; add an isolated allowlist only if finalize fails on that host.

### Compatibility notes

- Dual-write must be true before hold_ready (guard in `…130000`).  
- Lot catalog (`…160000`) required for Storage lot select under dual-write.  
- Transfer/adjustment early hold checks (`…140000`) required for negative-case UAT.  
- Do not copy commercial ledgers/customers into the new project.

---

## D. Disposable fixture plan

Documented in `scripts/dmg03i/fixture-contract.md`.

Summary:

- Godown / zone / crate: `dmg03i_*` + `TEST ONLY` names  
- Products: `dmg03i-stable-a`, `dmg03i-stable-b`  
- Lots: `TEST-LOT-DMG03I-A`, `TEST-LOT-DMG03I-B` with expiry dates  
- Opening: 20 cases each via **`post_opening_stock`** (idempotent keys)  
- Users: `keeper.dmg03i@example.test`, `gm.dmg03i@example.test`, `admin.dmg03i@example.test`  
- Pattern reference: `scripts/m8-2c/http-seed.mjs` (adapt; refuse `ypkfondr` / owner ports)

No fixture seed was executed against the existing cloud.

---

## E. Browser UAT results

### Isolated cloud (5175)

**Not executable** — no isolated cloud project provisioned.

### Disposable Docker (5174 / m82c) — cutover rehearsal evidence

| Item | Result |
|------|--------|
| Flags | hold_ready=`true`, dual_write=`true`, aggregate_only_blocked=`true` |
| Agg/lot mismatched | **0** |
| Lot catalog + unreserved helpers | Present |
| Playwright DMG-03E.1 | **4/4 PASS** (evidence → submit → verify; SK self-verify blocked) |
| Playwright DMG-03E.2 (prior + smoke) | Quarantine / write-off / exceptional proven on m82c |
| M5.3 concurrency | **9/9 PASS** (this pass) |

These results **do not** constitute isolated-cloud UAT PASS.

---

## F. Stock reconciliation

| Environment | Result |
|-------------|--------|
| Existing cloud | mismatched **0**; commercial stock unchanged; no new holds from this milestone |
| Disposable m82c | mismatched **0** under activated isolation |

---

## G. Security and permission checks

| Check | Status |
|-------|--------|
| Existing cloud not written | Confirmed (flags/draft/migrations tip unchanged) |
| No browser service-role | Continues to hold |
| SK cannot self-verify | Proven on disposable E.1 |
| Isolation fail-closed on 5173 | Still true (`hold_ready=false`) |
| New project must use distinct credentials | Required in `.env.dmg03i.local` |

---

## H. Remaining blockers

1. **No isolated Supabase cloud project** exists for DMG-03I.  
2. Owner must authorize project creation + key handoff.  
3. Until then, browser “Review and submit” on **5173** remains correctly disabled.  
4. Existing cloud still lacks DMG-03H migrations (intentionally not applied here).

---

## I. Owner actions required

1. **Authorize** creation of a new Supabase project (or provide an already-empty unused project ref).  
2. Supply URL + publishable key for `.env.dmg03i.local`.  
3. Authorize migration push + TEST ONLY seed on that project only.  
4. Authorize enabling `damage.stock_hold_ready=true` on the **new** project after recon.  
5. Keep 5173 → `ypkfondrkhkydkgovwup` until a separate DMG-03H decision.  
6. Optional later: cut over existing cloud only after backup + disposable SKU policy (DMG-03H).

### Suggested approval phrase for next step

> APPROVED: Create isolated Supabase project for DMG-03I; push migrations through 20261103160000; seed TEST ONLY fixtures; enable damage.stock_hold_ready on that project only; run UAT on port 5175. Do not modify ypkfondrkhkydkgovwup.

---

## J. Final verdict

**BLOCKED** — isolated cloud UAT not provisioned.

Planning, fixture contract, env example, and disposable Docker regression are complete. Existing cloud is unchanged. **Cloud UAT PASS is not claimed.**

### Regression snapshot (disposable / local tooling)

| Suite | Result |
|-------|--------|
| Typecheck | PASS |
| Lint | PASS (existing warnings) |
| Vitest damage units | 102/102 PASS |
| Build | PASS |
| Playwright E.1 | 4/4 PASS |
| M5.3 concurrency | 9/9 PASS |

### Artifacts added this milestone

| Path | Purpose |
|------|---------|
| `docs/dmg-03i-isolated-cloud-uat-and-activation.md` | This report |
| `.env.dmg03i.example` | Env template for port 5175 |
| `scripts/dmg03i/fixture-contract.md` | TEST ONLY fixture design |
| `scripts/dmg03i/provision-checklist.sh` | Owner provisioning checklist |
