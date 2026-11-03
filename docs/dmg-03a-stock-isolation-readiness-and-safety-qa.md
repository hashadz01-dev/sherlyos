# DMG-03A — Stock isolation readiness and safety QA

## 1. Executive summary

The warehouse damage **stock-isolation engine is already implemented** (M5.3) and
was re-validated under disposable local fixtures. Operational submission remains
**fail-closed** while `damage.stock_hold_ready=false`.

This milestone:

- Audited submit → isolate → verify → quarantine → disposition coupling.
- Confirmed picking/FEFO/ATP availability subtracts active damage holds.
- Added an additive cutover guard: **hold-ready cannot enable without lot dual-write**.
- Added `phase_dmg03a_isolation_readiness.sql` proving the 17→1→16 availability
  contract inside a rolled-back transaction.
- Re-ran M5.3 SQL isolation and concurrency suites (9/9 races).
- Did **not** enable operational flags, submit UAT `DMG-20261103-000013`, or
  apply cloud migrations.

**Readiness verdict for owner review:** isolation engine is ready for a
**future cutover review**. Activation is still owner-gated.

## 2. Implementation inventory (matrix)

| Component | Existing behavior | Safety gap | Required change | Risk |
|-----------|-------------------|------------|-----------------|------|
| Damage submission | Always calls `apply_damage_stock_isolation` for hold scenarios before `submitted` | Intentional gate while flag false | Keep fail-closed | — |
| Stock holds | `damage_stock_holds`; on-hand deduction at submit | None core | None | — |
| FEFO/FIFO picking | `picking_line_plan` → `picking_available_cases` | None | None | — |
| Packing reservations | Allocation uses hold-aware avail | None | None | — |
| Crate balances | Physical qty unchanged on isolate; writers floor on reserved+held | Transfer/adjustment **pre-check** uses raw qty (trigger still fails closed) | Optional additive pre-check alignment | P1 |
| Manager verification | Requires holds + evidence; no self-verify | None | None | — |
| Quarantine | `transfer_verified_damage_to_quarantine` after verified storage | Needs live holds (flag) | Cutover UAT only | — |
| Write-off / exceptional | Consume holds via trusted GUC | Needs verified/isolated stock | Cutover UAT only | — |
| Cutover config | Installed=true; flag=false | Hold-ready without dual-write left null-lot avail hole | **Guard added** this milestone | Was P0 cutover; mitigated |
| SK draft (DMG-03) | `damage.record` drafts; submit blocked | UI messaging clarified earlier | Keep | — |

## 3. Root causes and dependencies

UAT “Review and submit” disabled because:

1. Frontend `collectSubmitBlockers` isolation code when `!stockHoldReady`.
2. Backend `apply_damage_stock_isolation` raises when flag is false.
3. Verify requires matching holds for storage.

**Not** a missing isolation engine. Dependency for safe activation:

1. Lot dual-write enabled and stable on the target environment.
2. Owner approval to set `damage.stock_hold_ready=true`.
3. Fresh reconciliation / UAT on disposable then persistent local before any cloud.

## 4. Database / RPC architecture

Canonical migration:
`supabase/migrations/20261026160000_damage_stock_isolation_and_disposition.sql`

| Function | Role |
|----------|------|
| `submit_damage_report` | Lock → auth → **isolate** → status `submitted` (one TX) |
| `apply_damage_stock_isolation` | Fail-closed on flag; dispatches scenario isolators; idempotent if holds exist |
| `isolate_storage_damage` | Lock grains → capacity check → insert `on_hand_deduction` holds |
| `picking_available_cases` | Authoritative pickable qty |
| `verify_damage_report` | Evidence + hold qty match; no stock post |
| `release_damage_holds` | Return/reject release for on-hand/conversion |
| `transfer_verified_damage_to_quarantine` | Physical move; hold → `transferred` |
| `consume_damage_holds` | Write-off / exceptional debit |

New this milestone:
`supabase/migrations/20261103130000_damage_hold_ready_requires_lot_dual_write.sql`
— extends `guard_damage_hold_configuration` so `damage.stock_hold_ready=true`
requires `stock.lots.dual_write_enabled=true`.

## 5. Stock availability formula

```text
picking_available_cases(lot, crate) =
  0  if crate is quarantine
  else greatest(
    lot_on_hand
      − active_reserved_lot_cases(lot, crate)
      − active_damage_hold_lot_cases(lot, crate),   -- active on_hand_deduction + reservation_conversion
    0
  )
```

Storage isolate capacity:

```text
line.qty ≤ on_hand − reserved − held
```

Physical `stock_balances.quantity` / lot balances **do not decrease** at submit.
Ledger is **not** written at storage isolate.

### Fixture proof (rolled-back)

| Metric | Before isolate | After 1-case hold |
|--------|----------------|-------------------|
| Physical on-hand | 17 | 17 |
| Active damage hold | 0 | 1 |
| Reserved | 0 | 0 |
| Available for picking | 17 | 16 |
| Quarantined | 0 | 0 |
| Ledger row count | unchanged | unchanged |

## 6. FEFO/FIFO and packing integration

- `picking_line_plan` (FEFO/FIFO) reads `picking_available_cases`.
- Order ATP / DN picking gate re-check the same function.
- No silent P0 bypass of holds on allocate/pick paths found.
- P1: some transfer/adjustment **pre-checks** ignore holds; commit triggers still
  enforce `reserved + held` floor.

## 7. Permission matrix

| Action | Store Keeper | Godown Manager |
|--------|--------------|----------------|
| Storage draft | Yes (`damage.record` + godown) | Yes |
| Submit while flag false | Blocked | Blocked |
| Submit while flag true (fixture) | Yes if reporter | Yes if reporter |
| Verify | No | Yes if not reporter |
| Quarantine / write-off | No | Yes after verified (+ dispose where required) |

FORCE RLS retained. No browser service-role. Isolation RPCs remain security definer
with private grants.

## 8. Isolation lifecycle

```text
Draft
  → Submit + isolate (atomic) → Submitted (+ active holds)
  → GM verify → Verified (holds unchanged)
  → Optional quarantine transfer → hold transferred
  → Ordinary / exceptional disposition → hold written_off / returned_supplier
```

Return/reject releases on-hand/loading holds (shop-return quarantine intake stays
until disposition).

## 9. Quarantine and disposition readiness

Implemented and covered by M5.3 / M5.4 suites. Not activated operationally while
flag is false. Do not quarantine or write off UAT stock in this milestone.

## 10. Concurrency and idempotency

`phase_m5_3_concurrency.mjs`: **9/9 PASS** including storage vs picking, dual
storage submits, loading vs dispatch, write-off races, quarantine vs picking.

Submit idempotency key + apply early-return when holds already exist.

**Ops note:** concurrency temporarily sets dual-write / aggregate / hold-ready
true and restores in `finally`. Do not run parallel suites against the same local
DB during that window.

## 11. Changes implemented

| Path | Change |
|------|--------|
| `supabase/migrations/20261103130000_damage_hold_ready_requires_lot_dual_write.sql` | Cutover guard |
| `supabase/tests/phase_dmg03a_isolation_readiness.sql` | Readiness SQL (T01–T04, T06, T09–T10, T13, T15, avail formula) |
| `docs/dmg-03a-stock-isolation-readiness-and-safety-qa.md` | This report |

Prior (still relevant): SK storage draft auth, submit copy explaining draft-only.

## 12. Migration details

- Additive `CREATE OR REPLACE` of config guard only.
- No data rewrite; no ledger mutation; flags unchanged by migration.
- Applied **local Docker only** for validation. **Not** applied to cloud.
- Rollback: reinstall prior `guard_damage_hold_configuration` from
  `20261026140000_…` (installed-only check). Safe: no stock rows touched.

## 13. Test results

| Suite | Result | Notes |
|-------|--------|-------|
| `phase_dmg03a_isolation_readiness.sql` | **PASS** | Rolled back; flags restored false |
| `phase_m5_3_damage_stock_isolation.sql` | **PASS** | Rolled back |
| `phase_m5_3_concurrency.mjs` | **PASS 9/9** | Cleanup restores flags |
| `phase_dmg03_storekeeper_storage_draft.sql` | **PASS** | Gate while flag false |
| Vitest `damage-editor` / `damage` / `damage-verification` | **43 passed** | |
| Playwright full damage e2e | **NOT RUN** this pass | |
| Production build / full tsc | **NOT RUN** this pass | Pre-existing `ReceivingPage.tsx` TS issue known |
| Cloud migration apply | **NOT RUN** | Owner gate |

Operational flags after validation (local):

```text
damage.stock_hold_ready=false
stock.lots.dual_write_enabled=false
stock.lots.aggregate_only_blocked=false
```

## 14. Outstanding risks

| ID | Severity | Item |
|----|----------|------|
| R1 | P0 ops | Enabling hold-ready on cloud/UAT without owner dual-write cutover — **blocked by new guard** |
| R2 | P1 | Transfer/adjustment optimistic pre-check ignores holds (trigger fail-closed) |
| R3 | P1 | Cloud may already have dual-write true from prior UAT — do not flip hold-ready without owner |
| R4 | P2 | Display on-hand readers are gross; ATP/picking authoritative |
| R5 | P2 | Shop-return reject leaves quarantine intake until disposition (documented) |

## 15. Operational cutover checklist (owner)

- [ ] Dual-write enabled and stable on target DB
- [ ] Aggregate-only policy decided and validated
- [ ] All stock availability readers honor holds (picking/ATP/DN gate)
- [ ] Stock writers protected (triggers + optional pre-check hardening)
- [ ] FEFO/FIFO cannot allocate held cases (proven in M5.3)
- [ ] Reservations + holds cannot overallocate (concurrency 9/9)
- [ ] Crate/lot integrity enforced (`isolate_storage_damage`)
- [ ] Concurrent submission safe (proven)
- [ ] Idempotency proven
- [ ] Manager permissions / no self-verify
- [ ] Quarantine + disposition UAT on disposable fixtures
- [ ] Rejection/release rules accepted
- [ ] Audit events reviewed
- [ ] Inventory reconciles before/after pilot
- [ ] Rollback/recovery procedure agreed
- [ ] **Owner written approval** to set `damage.stock_hold_ready=true`
- [ ] UI submit blockers re-tested after flag flip

**Do not mark cutover approved in this document.**

## 16. Safe manual UAT plan (current stage)

1. Sign in as Test Storekeeper; open `DMG-20261103-000013`.
2. Confirm draft editable; evidence present; Review and submit **disabled**.
3. Confirm warning: submit isolates stock; cartons stay pickable until cutover.
4. Confirm inventory for `AVT-CATER-BLEND-1KG` unchanged.
5. Do **not** flip flags; do **not** submit this UAT draft.

After a future owner-approved cutover (separate change window):

1. Disposable fixture only first (not this UAT SKU if production-like).
2. Submit → confirm hold 1, physical unchanged, avail −1.
3. Second GM verifies; Store Keeper cannot.
4. Optional quarantine; no accidental write-off.

## 17. Rollback / incident response

- If hold-ready flipped by mistake: set back to `false` immediately (guard allows
  false). Existing active holds remain until authorized release/disposition —
  treat as incident; do not mass-delete holds.
- Migration guard rollback: restore prior function body (see §12).
- Concurrency suite leaves flags false via `finally`; if interrupted, manually set
  the three keys to `false` under `session_replication_role = replica`.

## 18. Final readiness verdict

**READY FOR OWNER CUTOVER REVIEW** — engine proven in isolated tests; production-
facing gate remains closed; dual-write-before-hold-ready guard installed locally.

Activation of DMG-03 submit for real godowns still requires owner cutover approval.
