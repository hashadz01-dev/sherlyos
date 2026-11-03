# DMG-03 Storage — report-only submission safety review

## 1. UAT evidence

- App: `http://127.0.0.1:5173` (Vite → cloud Supabase)
- Report: `DMG-20261103-000013` (Storage / Warehouse Damage)
- Actor: Test Storekeeper · Godown-1 · `uat_c1` · 1 case · evidence finalized
- Status: **Draft**
- UI: Review and submit disabled with isolation-not-ready messaging

Draft create/list for Store Keeper already works after the DMG-03 permission fix.

## 2. Root cause of disabled submission

Submission is **intentionally coupled** to stock isolation for hold scenarios
(`storage`, `loading`, `shop_return`).

| Layer | Behavior | Evidence |
|-------|----------|----------|
| Frontend | `collectSubmitBlockers` adds `isolation` when `scenarioRequiresStockHold` and `!stockHoldReady` | `src/features/damage/utils/submit.ts` |
| Backend submit | If `damage_requires_stock_hold(scenario)`, **always** calls `apply_damage_stock_isolation` before flipping to `submitted` | `public.submit_damage_report` |
| Isolation RPC | Raises `damage stock isolation is not ready` when `damage.stock_hold_ready` is false; flag may only fail-closed | `app_private.apply_damage_stock_isolation` |
| Verify | Hold scenarios require matching `damage_stock_holds` (`active`/`transferred`); otherwise raises the same isolation error | `public.verify_damage_report` |

Comments in foundation migrations state: hold-required submit always calls
isolation; toggling the flag cannot skip isolation.

This is not a frontend-only bug. Enabling the button alone would hit the RPC
raise (or, if isolation were skipped unsafely, create a false “submitted”
warehouse incident while stock remains pickable).

## 3. Current workflow (as designed)

```
Draft (document only)
  → Submit  ==  validate + isolate on-hand stock + status submitted
  → Verify  ==  GM confirm after holds exist (no extra stock post at verify)
  → Quarantine / write-off / exceptional  ==  separate stock writers (also gated)
```

Contrast:

- **DMG-01 / DMG-02** (inbound): damaged cases never posted as accepted stock →
  submit allowed without hold.
- **DMG-05** (transit): consumed dispatch path → submit without on-hand hold.
- **DMG-03 / DMG-04 / DMG-06**: on-hand / custody isolation required at submit.

## 4. Is report-only submission safe today?

**No — not under the current lifecycle without an owner-approved redesign.**

### Why

1. **Submit is the isolation transaction boundary.** Skipping isolation while
   setting `submitted` would leave cases in `stock_balances` / allocatable
   quantity while the UI and queues treat the incident as escalated.
2. **Verify assumes holds.** Without holds, GM verify fails closed. A
   submitted-but-unisolatable report is a dead-end queue, not a complete
   workflow.
3. **No schema for “reported, stock still available”.** Status check only
   allows `draft|submitted|returned|verified|cancelled|rejected`. There is no
   `pending_isolation` (or equivalent) column/status. Introducing one touches
   dashboards, list filters, verification queues, and disposition gates.
4. **False inventory assurance.** Staff and managers reasonably read
   “Submitted” / “Verified” warehouse damage as “those cases are no longer
   sellable/pickable.” That would be false without holds.
5. **Fail-closed policy is deliberate.** `damage.stock_hold_ready` is a
   kill-switch that blocks isolation; it must not become a silent skip of
   stock writers.

Therefore this review **retains the submission block** and does **not**
implement report-only submit/verify.

## 5. Proposed safe lifecycle (owner decision required)

Do **not** implement without explicit owner approval of one option.

### Option A — Recommended interim (current)

Keep DMG-03 as **draft-only** until an approved isolation cutover:

1. Store Keeper drafts with evidence (already working).
2. Submit/verify/quarantine/write-off stay blocked while
   `damage.stock_hold_ready=false`.
3. UI explains that cartons remain allocatable.

**Pros:** Inventory truth preserved; matches existing RPCs.  
**Cons:** No formal “submitted incident” until cutover.

### Option B — Explicit `pending_isolation` lifecycle (policy + schema)

Additive design sketch only:

1. New status or flag meaning: incident recorded; **stock not isolated**.
2. Submit report-only → that state (not plain `submitted` if `submitted`
   currently implies holds for storage).
3. UI mandatory banner: “Damage reported — stock not isolated. Inventory
   remains available until authorized stock isolation.”
4. Separate owner-gated `isolate_damage_report` RPC creates holds when ready.
5. Verify either:
   - allowed only after isolation, or
   - split into “acknowledge incident” vs “confirm isolation” with distinct
     labels (never reuse “verified” alone for unisolated stock).
6. Dashboards/queues must filter and label the unisolated state so picking
   availability is never implied secured.

**Pros:** Matches the desired A/B/C separation.  
**Cons:** Cross-cutting schema/UI/RPC work; easy to mislabel; needs UAT of
picking interaction.

### Option C — Soft reservation at draft/submit

Reserve damaged qty without full hold/quarantine pipeline.

**Out of scope** here: overlaps reservation engines, picking availability, and
lot dual-write — larger inventory redesign.

## 6. Inventory availability implications

Until isolation runs (`isolate_storage_damage`):

- On-hand balances unchanged
- No `damage_stock_holds`
- No ledger / stock_transactions for damage isolation
- Reservations unchanged
- Picking/dispatch can still consume those cases

Inbound DMG-01/02 do not share this risk (cases never accepted onto stock).

## 7. Database / code changes in this review

| Change | Purpose |
|--------|---------|
| `src/features/damage/utils/submit.ts` | Clearer isolation blocker + storage hint (gate **retained**) |
| `tests/unit/damage-editor.test.ts` | Assert new explanatory copy |
| This document | Safety review + owner options |

**No** migration to skip isolation. **No** cloud apply. **No** flag flips.

## 8. Permission matrix (unchanged by this review)

| Action | Store Keeper | Godown Manager |
|--------|--------------|----------------|
| DMG-03 draft | Yes (authorized godown) | Yes |
| DMG-03 submit while isolation off | **Blocked** | **Blocked** |
| Verify | No | Yes after submit+holds |
| Self-verify | No | No (reporter blocked) |
| Isolate / quarantine / write-off | Gated by readiness + verify | Same |

## 9. Test results

| Suite | Result |
|-------|--------|
| Unit tests for isolation blocker copy | Updated; run with damage-editor suite |
| Backend report-only submit | **Not implemented** — no new SQL tests for skip-isolation |
| Prior DMG-03 draft SQL (`phase_dmg03_…`) | Still valid: draft OK, submit gated, no stock change |

## 10. Manual UAT (expected after this review)

1. Sign in as Test Storekeeper; open `DMG-20261103-000013` or new storage draft.
2. Confirm Save draft works; evidence remains.
3. Confirm **Review and submit** stays disabled.
4. Confirm messaging states draft-only and that cartons remain allocatable.
5. Confirm inventory / ledger unchanged.
6. Confirm Shop Return still permission-gated; loading/transit gates unchanged.

## 11. Remaining operational restrictions

- Full DMG-03 operational path requires owner-approved
  `damage.stock_hold_ready` cutover with isolation installed and validated.
- Report-only / `pending_isolation` needs a separate owner policy decision
  (Option B) before any schema work.
- Cloud lot flags may differ from local disposable defaults; this review must
  not flip `damage.stock_hold_ready`, dual-write, aggregate-only, or short
  shipment operational flags.

## 12. Owner decisions requested

1. Accept **Option A** (draft-only until isolation cutover) for ongoing UAT, or
2. Approve a written **Option B** design (status semantics + UI labels + verify
   rules) before implementation, or
3. Defer warehouse damage submission until isolation readiness project starts.

**Recommendation:** Option A now; Option B only with explicit inventory-control
policy sign-off.
