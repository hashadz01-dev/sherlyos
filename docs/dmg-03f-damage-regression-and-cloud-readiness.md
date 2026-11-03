# DMG-03F — Fixture Recovery, Full Damage Regression & Cloud Readiness

**Verdict: PASS**

Disposable identity confirmed before any recovery: `supabase_db_sherlyos_m82c`, system_identifier `7702447407569928229` (not owner `7699785797738577957`, not m81c). API `57321`, app `5174`. Cloud read-only only. `DMG-20261103-000013` left as cloud draft `storage`. No commit/push/deploy. No cloud migrations. No flag flips. No ledger history deletes. No browser service-role.

## A. Executive verdict

DMG-03F acceptance criteria are met on disposable m82c:

1. Reproducible isolated fixtures via trusted opening + transfer recovery.  
2. C / D / E.1 / E.2 Playwright all green on the recovered grain.  
3. Aggregate/lot reconciliation exact; no negatives; no stranded cancelled holds.  
4. No unexpected stock mutations outside trusted recovery + damage workflows.  
5. Six-scenario audit completed with evidence-based statuses (Storage PASS; others PARTIAL / SQL-backed).  
6. Typecheck and build green.  
7. Cloud readiness documented without cloud changes.

## B. Disposable fixture recovery

### Why C/D/E.1 broke

Legitimate DMG-03E.2 ordinary/exceptional write-offs reduced `m82c-stable` @ `m82c_c1` from **17 → 7** physical. Remaining cases were fully covered by active holds → **avail = 0**. Suites hard-coded `physical === 17` and/or required free cases on `TEST-LOT-STABLE-B`.

Ledger integrity remained sound (C1 aggregate = lot sum) — this was fixture capacity exhaustion, not corruption.

### Recovery (trusted, idempotent)

Script: `scripts/dmg03f/recover-m82c-stable-fixture.sql`

1. Refuse owner / m81c / unexpected sysid.  
2. As `admin.m82c@example.test`, `post_opening_stock` on **`m82c_c2`** (never previously opened for stable) → lot `TEST-LOT-DMG03F`, 20 cases, key `dmg03f-open-stable-c2` (replay-safe).  
3. `post_crate_transfer` C2 → C1 for the deficit until C1 free cases ≥ 10 (lot moves JSON).  
4. Does **not** delete or rewrite historical ledger rows.

Post-recovery (before this pass’s re-runs): C1 aggregate **17 = lot sum 17**; `TEST-LOT-DMG03F` on C1 had **10 avail**.

### Test fixture policy change

C/D/E.1 no longer hard-require a permanent `17` after destructive disposition UATs. They capture `physicalBefore` and assert isolation leaves physical unchanged. Selected lot for free-case UATs is **`TEST-LOT-DMG03F`**.

## C. Full regression results

| Suite | Result |
|-------|--------|
| DMG-03C Playwright | **5/5 PASS** |
| DMG-03D Playwright | **6/6 PASS** |
| DMG-03E.1 Playwright | **4/4 PASS** |
| DMG-03E.2 Playwright | **5/5 PASS** |
| M5.3 isolation SQL | **PASS** (`ROLLBACK`) |
| M5.3 concurrency | **9/9 PASS** |
| Vitest full | **368/368 PASS** (60 files) |
| Damage + lot/inventory unit subset | **144/144 PASS** (17 files) |
| `npm run typecheck` | **PASS** |
| `npm run lint` | **PASS** (existing warnings only) |
| `npm run build` | **PASS** |

No product defects required fixes beyond fixture recovery + baseline softens (test/fixture only).

## D. Six-scenario compliance matrix

Statuses are evidence-based for this pass. **PASS** only where browser or concurrency proof covers the lifecycle claim.

| ID | Scenario | Status | Evidence (this pass / prior locked) | Gaps |
|----|----------|--------|-------------------------------------|------|
| DMG-01 | `refill_supply` Refill Supplier | **PARTIAL** | UX/rules + M5.4b SQL source pickers; inbound submit without on-hand hold | No disposable browser end-to-end this pass; no vehicle/driver on receipt |
| DMG-02 | `unloading` Unloading | **PARTIAL** | Same inbound path as DMG-01 (receipt line lock migrations exist locally) | No disposable browser E2E this pass |
| DMG-03 | `storage` Storage | **PASS** | C/D/E.1/E.2 Playwright: lot UI, evidence finalize, isolate, verify, quarantine, write-off, exceptional destroy/reject | — |
| DMG-04 | `loading` Loading | **PARTIAL** | M5.3 concurrency race C (loading hold vs `confirm_dispatch`); rules require packing source | Full browser create→disposition not re-run this pass |
| DMG-05 | `transit` Transit | **PARTIAL** | May submit without hold; driver/GM auth in rules + M5.4b source list | No disposable browser E2E this pass; no invoice number on damage header (known) |
| DMG-06 | `shop_return` Shop Return | **PARTIAL** | M5.3 race F (intake idempotency); custody confirmation required before some paths | Full browser custody→disposition not re-run this pass |

### Lifecycle checklist (Storage = PASS evidence)

| Step | Storage (DMG-03) |
|------|------------------|
| Authorized reporter | SK `damage.record` draft; GM verify |
| Source / qty / lot / crate | UI catalogs + dual-write lot required |
| Evidence finalize | Browser-only finalize (E.1) |
| Submit isolation | Hold +1; physical unchanged (C/D/E.1) |
| Manager verify | Not reporter (C/D/E.1) |
| Quarantine / write-off / exceptional | E.2 PASS |
| Audit | Events include submit/verify/quarantine/writeoff/exceptional |

Inbound/loading/transit/shop-return share the same backend RPCs and unit/SQL coverage; classify **PARTIAL** until disposable browser fixtures exist for each.

## E. Stock reconciliation

After C→E.2 re-run on recovered grain (m82c disposable):

| Check | Result |
|-------|--------|
| C1 `m82c-stable` aggregate vs lot sum | **15 = 15** (2 cases written off in E.2 after recovery baseline 17) |
| Negative balances | **0** |
| Stranded active holds on cancelled reports | **0** |
| Quarantine remains unpickable | avail **0** on QRN lots |
| Cloud aggregate≠lot mismatches | **0** (read-only; 35 aggregate cases) |

Unexpected mutations: none outside `recover-m82c-stable-fixture.sql` trusted posts and damage disposition RPCs exercised by Playwright.

## F. Security findings

| Control | Status |
|---------|--------|
| Disposable sysid / container guards in Playwright | Enforced |
| Store Keeper self-verify blocked | C/D/E.1 |
| Store Keeper cannot quarantine / approve exceptional | E.2 |
| Admin required before exceptional stock post | E.2 |
| Duplicate submit / write-off / exceptional post | C + E.2 + M5.3 D/E |
| M5.3 concurrent pick/transfer/write-off races | 9/9 |
| Browser service-role | Not used |
| Cloud draft `DMG-20261103-000013` | Untouched (`draft` / `storage`) |

## G. Cloud migration dependencies

### Cloud flags (read-only)

| Key | Cloud value |
|-----|-------------|
| `damage.stock_hold_ready` | **false** |
| `stock.lots.dual_write_enabled` | **true** |
| `stock.lots.aggregate_only_blocked` | **true** |

### Cloud migration tip

Last applied (MCP `list_migrations`): `20261102125515_damage_evidence_cloud_storage_fetch`.

### Local damage-related migrations not confirmed on cloud

Apply only after owner approval (order matters):

1. `20261102180000_damage_evidence_cloud_storage_fetch.sql` — verify vs cloud `20261102125515` (possible timestamp twin; do not double-apply equivalent).  
2. `20261102190000_damage_inbound_receipt_line_lock.sql`  
3. `20261103100000_damage_evidence_drop_followlocation.sql`  
4. `20261103120000_damage_storage_store_keeper_draft.sql`  
5. `20261103130000_damage_hold_ready_requires_lot_dual_write.sql`  
6. `20261103140000_transfer_adjustment_honor_damage_holds.sql`  
7. `20261103160000_damage_storage_lot_catalog.sql`  
8. `20261103170000_damage_evidence_disposable_kong_hosts.sql` — **disposable Kong hosts; review before cloud** (may be no-op / skip on cloud).

Also confirm non-damage local migrations after cloud tip (`accounts_*`, `godown_manager_*`, `store_keeper_*`, etc.) are already represented by the cloud list’s `20261102*` entries.

### Proposed deployment sequence (owner approval required — DO NOT RUN NOW)

1. **Backup / branch** cloud DB (Supabase branch or snapshot).  
2. **Reconcile** aggregate vs lot (must stay `mismatched = 0`).  
3. Apply pending **non-flag** migrations in version order (skip disposable-only `…170000` unless needed).  
4. Smoke: cloud draft `DMG-20261103-000013` still readable; create/submit of a **new** disposable cloud draft with hold_ready still false remains fail-closed for storage isolation.  
5. Owner cutover window: set `damage.stock_hold_ready=true` **only if** dual-write already true (enforced by `…130000`).  
6. Post-cutover: one Storage draft→submit→verify on a non-owner SKU; confirm hold + unchanged physical; then quarantine/write-off on disposable qty only.

### Proposed rollback sequence

1. Set `damage.stock_hold_ready=false` immediately (submit of hold scenarios fail-closed again).  
2. Do **not** reverse ledger history.  
3. Restore DB branch/snapshot if a migration is defective.  
4. Leave dual-write / aggregate_only flags as owner-decided; do not casually flip them.

## H. Remaining P0 / P1 / P2 gaps

| Priority | Gap |
|----------|-----|
| P0 | Cloud `damage.stock_hold_ready` still false — storage/loading/shop-return isolation not live in cloud |
| P0 | Pending local migrations not applied to cloud (owner approval) |
| P1 | Disposable browser UAT packs for refill/unloading/loading/transit/shop_return |
| P1 | Review whether `…170000` Kong allowlist belongs on cloud |
| P2 | Client “Closed” status mapping; repacking/inspection disposition; receipt vehicle/driver fields |

## I. Owner approval requirements

- Apply any cloud migration listed in §G.  
- Flip `damage.stock_hold_ready` (or any other operational flag).  
- Commit / push / deploy.  
- Touch owner stock or `DMG-20261103-000013`.  
- Enable GST legal issuance.

## J. Recommended next milestone

**DMG-03G — Multi-scenario disposable browser matrix + cloud migration rehearsal (branch-only)**  

1. Build disposable fixtures for DMG-01/02/04/05/06 (independent of Storage grain).  
2. Rehearse pending migrations on a Supabase preview branch with hold_ready still false.  
3. Owner-gated cutover checklist for hold_ready with rollback drill.

## Files changed this pass

| Path | Purpose |
|------|---------|
| `scripts/dmg03f/recover-m82c-stable-fixture.sql` | Trusted idempotent C1 capacity recovery |
| `tests/e2e/dmg03c-isolation-uat.spec.ts` | Dynamic physical baseline; prefer DMG03F lot |
| `tests/e2e/dmg03d-lot-aware-storage-uat.spec.ts` | Same |
| `tests/e2e/dmg03e1-evidence-browser-only.spec.ts` | Same |
| `tests/e2e/dmg03e2-disposition-uat.spec.ts` | Prefer DMG03F lots |
| `docs/dmg-03f-damage-regression-and-cloud-readiness.md` | This report |

## Final verdict

**PASS** — Fixture recovery reproducible; C/D/E.1/E.2 + M5.3 + Vitest + typecheck/build green; Storage lifecycle fully evidenced; other scenarios PARTIAL with SQL/concurrency evidence; cloud readiness documented with no cloud writes.
