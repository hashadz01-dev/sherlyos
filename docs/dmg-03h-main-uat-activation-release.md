# DMG-03H — Main UAT Storage Damage Activation Release

**FINAL STATUS: READY FOR EXPLICIT CLOUD ACTIVATION APPROVAL**

This document is the controlled release package for making **Review and submit** work on `http://127.0.0.1:5173` (cloud backend).  

**Nothing in this document has been executed against cloud.**  
No migrations applied. No flags flipped. No commit/push/deploy. No change to `DMG-20261103-000013`.

The issue is **not fixed** until the owner separately approves the checkpoint in §H and post-approval execution completes with 5173 verification.

---

## A. Preflight verdict

| Check | Result | Gate |
|-------|--------|------|
| Target frontend | `127.0.0.1:5173` → `.env.local` `VITE_SUPABASE_URL=https://ypkfondrkhkydkgovwup.supabase.co` | OK |
| Cloud project | `ypkfondrkhkydkgovwup` (`https://ypkfondrkhkydkgovwup.supabase.co`) | OK |
| Migration tip | `20261102125515_damage_evidence_cloud_storage_fetch` | OK |
| `stock.lots.dual_write_enabled` | **true** | OK |
| `damage.stock_hold_ready` | **false** ← why submit is disabled | Expected |
| `stock.lots.aggregate_only_blocked` | **true** (leave unchanged) | OK — do not flip |
| Aggregate vs lot | **mismatched=0**, agg=35, lot=35 | OK |
| Active/transferred damage holds | **0** | OK |
| Damage reports | draft=1, verified=2 (prior snapshot) | OK |
| Reservations | 1 `consumed` row only | OK |
| Lot catalog helper | `build_damage_storage_catalogs` **absent** | Must migrate |
| Transfer hold early-fail helpers | `unreserved_lot_cases` **absent** | Must migrate |
| Hold-ready guard requires dual-write | **false** on cloud today | Must migrate `…130000` |
| Evidence / SK draft foundation | Present via tip + prior damage migrations | OK |
| P0 blockers for *planning* activation | **None** | Proceed to approval |

**Why 5173 still blocks submit:** frontend reads `damage_stock_hold_ready_status`; Storage submit adds an isolation blocker while `damage.stock_hold_ready=false`. That is correct fail-closed behavior. Disposable 5174 works only because m82c already has hold_ready=true.

---

## B. Exact cloud migrations required

### Filename correction vs informal notes

| Informal / mis-typed | **Actual repo filename** |
|----------------------|--------------------------|
| `20261103190000` inbound lock | **`20261102190000_damage_inbound_receipt_line_lock.sql`** |
| evidence fetch hardening | **`20261103100000_damage_evidence_drop_followlocation.sql`** |
| dual-write guard | **`20261103130000_damage_hold_ready_requires_lot_dual_write.sql`** |
| transfer/adjustment holds | **`20261103140000_transfer_adjustment_honor_damage_holds.sql`** |
| storage lot catalog | **`20261103160000_damage_storage_lot_catalog.sql`** |

### Already on cloud (do not re-apply)

- Tip: `20261102125515_damage_evidence_cloud_storage_fetch` (local twin `20261102180000_…` — same concern, already applied under cloud timestamp).
- Damage foundation through `20261026181000`.
- SK storage draft behavior already present in `assert_damage_create_auth` (local `…120000` may be a no-op verify).

### Ordered apply list (owner-approved only)

1. `supabase/migrations/20261102190000_damage_inbound_receipt_line_lock.sql`  
2. `supabase/migrations/20261103100000_damage_evidence_drop_followlocation.sql`  
3. `supabase/migrations/20261103120000_damage_storage_store_keeper_draft.sql` *(verify / history catch-up; expect no functional change)*  
4. `supabase/migrations/20261103130000_damage_hold_ready_requires_lot_dual_write.sql`  
5. `supabase/migrations/20261103140000_transfer_adjustment_honor_damage_holds.sql`  
6. `supabase/migrations/20261103160000_damage_storage_lot_catalog.sql`  

### Explicitly excluded

- `20261103170000_damage_evidence_disposable_kong_hosts.sql` — disposable Kong hosts; **not for cloud**.
- Any change to `stock.lots.aggregate_only_blocked`.
- Any GST / legal issuance flag.
- Reordering or rewriting already-applied cloud migrations.

### Post-migration verify (before flag)

```text
build_damage_storage_catalogs present = true
unreserved_lot_cases present = true
guard_damage_hold_configuration includes dual_write check = true
aggregate/lot mismatched = 0
```

---

## C. Flag activation procedure

**Trusted admin SQL only** (Supabase SQL editor / MCP after approval / CLI with owner credentials). Never from browser/app code.

### Preconditions (all must pass)

1. Migrations in §B applied and recorded.  
2. Dual-write still `true`.  
3. Reconciliation `mismatched = 0`.  
4. Active damage holds still expected (normally 0).  
5. Rollback (§E) understood.

### Activation command

```sql
-- AFTER approved migrations + recon gate
update public.app_configuration
set value = 'true'::jsonb
where key = 'damage.stock_hold_ready'
  and value is distinct from 'true'::jsonb;

select key, value #>> '{}' as val
from public.app_configuration
where key = 'damage.stock_hold_ready';
```

Expect: succeeds. Post-`…130000`, this must fail if dual-write were false.

### Readiness RPC check

As authenticated Store Keeper (or any damage-capable role):

```text
select public.damage_stock_hold_ready_status();
-- expect stock_hold_ready: true
```

### Frontend

Hard refresh `http://127.0.0.1:5173` (readiness query staleTime 15s + focus refetch). New Storage draft with evidence + lot → **Review and submit** enabled.

### Do not enable / do not touch

- `stock.lots.aggregate_only_blocked` (already true; leave alone)  
- GST legal issuance controls  
- Browser service-role  

---

## D. Operational risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Storage/loading/shop-return submits isolate stock | Medium | Pilot on disposable qty only |
| Commercial SKU write-off during pilot | High | Use disposable UAT SKU; forbid AVT/GOODLIFE without separate OK |
| Transfer/adjustment blocked by holds after cutover | Medium | Expected; apply `…140000` first |
| Evidence finalize regression | Medium | Apply `…100000`; smoke finalize before flag |
| Accidental dual-write disable attempt | High | Cutover validator blocks; rollback via hold_ready only |
| Submitting legacy draft without lot | High | Do not use `DMG-20261103-000013` until lot authorized (§G) |

---

## E. Rollback procedure

1. Immediately:

```sql
update public.app_configuration
set value = 'false'::jsonb
where key = 'damage.stock_hold_ready';
```

2. 5173 returns to draft-only Storage submit (fail-closed).  
3. **Do not** set `stock.lots.dual_write_enabled=false` if lot-attributed ledger rows exist.  
4. **Do not** delete ledger / hold history.  
5. If a migration is defective: restore DB branch/snapshot; keep hold_ready false.  
6. Holds created during a bad window: settle via trusted quarantine / write-off / exceptional RPCs only.

---

## F. Pilot UAT steps (after approval + activation)

Use a **new** Storage draft. Prefer disposable UAT SKU/qty. Godown with stock today: `gd_1` / `uat_c1`.

1. SK login @ 5173.  
2. New Storage Damage → godown, product, crate, **lot**, qty=1, reason.  
3. Finalize photo evidence.  
4. Confirm **Review and submit** enabled.  
5. Submit → exactly **one** `active` hold; physical unchanged; picking available −1 on that lot/crate.  
6. SK cannot verify self.  
7. GM verifies.  
8. Optional: quarantine → ordinary write-off **only** on approved disposable qty.  
9. Duplicate submit does not double-hold.  
10. Reconcile: no negatives, no stranded holds, audit events present.

Do **not** claim fixed until steps 4–7 pass on 5173.

---

## G. Existing draft compatibility

**`DMG-20261103-000013`** (read-only):

| Field | Value |
|-------|-------|
| Status | `draft` |
| Scenario | `storage` |
| Version | 5 |
| Line | AVT-CATER-BLEND-1KG @ `uat_c1`, qty 1 |
| `lot_id` | **null** |

After `…160000` + dual-write, Storage submit/isolation **requires** a lot. This draft is **not** auto-safe to submit.

**Recommendation:** leave untouched; create a **new** post-cutover test draft with an explicit lot. Any lot repair of `000013` needs separate owner authorization (not part of this release).

---

## H. Approval checkpoint — STOP

### Explicit request

Reply with approval of **all** of the following before any cloud write:

1. **Target project:** `ypkfondrkhkydkgovwup` (`https://ypkfondrkhkydkgovwup.supabase.co`)  
2. **Migrations (in order):**  
   - `20261102190000_damage_inbound_receipt_line_lock.sql`  
   - `20261103100000_damage_evidence_drop_followlocation.sql`  
   - `20261103120000_damage_storage_store_keeper_draft.sql`  
   - `20261103130000_damage_hold_ready_requires_lot_dual_write.sql`  
   - `20261103140000_transfer_adjustment_honor_damage_holds.sql`  
   - `20261103160000_damage_storage_lot_catalog.sql`  
3. **Skip:** `20261103170000_damage_evidence_disposable_kong_hosts.sql`  
4. **Flag change:** `damage.stock_hold_ready` `false` → `true` (trusted SQL only)  
5. **Do not change:** `aggregate_only_blocked`, GST issuance, `DMG-20261103-000013`  
6. **Pilot:** new Storage draft on disposable qty @ `gd_1` / `uat_c1` (commercial SKU write-off needs extra OK)  
7. **Inventory now:** mismatched=0; dual-write=true; holds=0  
8. **Impact:** Storage/loading/shop-return submits will isolate stock; picking availability decreases by holds  
9. **Rollback:** set `damage.stock_hold_ready=false` immediately  

### Suggested approval phrase

> APPROVED: Apply the six DMG-03H migrations listed above to ypkfondrkhkydkgovwup, then set damage.stock_hold_ready=true. Skip …170000. Do not modify DMG-20261103-000013. Pilot with a new disposable Storage draft only.

Until that (or equivalent) is received, **no cloud migration and no flag change will be performed.**

---

## Post-approval execution checklist (not authorized yet)

1. Apply only the six approved migrations; verify each version in `list_migrations`.  
2. Re-run recon → mismatched must stay 0.  
3. Confirm helpers + dual-write guard.  
4. Activate hold_ready (§C).  
5. Verify readiness RPC.  
6. Refresh 5173; run pilot (§F).  
7. Publish short completion note (actual pass/fail).  

---

## Final status (plan package)

**READY FOR EXPLICIT CLOUD ACTIVATION APPROVAL** (planning package only)

Preflight is green for a controlled cutover. Migrations and flag procedure are exact. Disposable workflow is already proven. Cloud activation waits on explicit owner approval plus the mandatory preconditions below.

---

## DMG-03H execution attempt — STOPPED (preconditions)

Owner provided controlled activation approval. Mandatory preconditions were re-checked **before** any migration or flag change.

| # | Precondition | Result | Evidence |
|---|--------------|--------|----------|
| 1 | Intended non-production UAT project | **UNPROVEN** | Target is `ypkfondrkhkydkgovwup` as requested, but DB contains 7 operational godowns (`gd_1`…`gd_7`) and commercial SKUs; MCP cannot certify “not live production” |
| 2 | No real inventory/orders/users affected | **FAIL** | Positive stock only on `AVT-CATER-BLEND-1KG` (17) and `GOODLIFE-MILK-500ML` (18) @ `uat_c1`; **0** disposable/`TEST ONLY`/`m82c` SKUs; 1 `verified` order; 1 `consumed` reservation |
| 3 | Recoverable database backup taken & verified | **FAIL** | `list_branches` empty; `create_branch` creates a **fresh** DB without copying production data — not a recoverable inventory backup; no PITR/snapshot tool available via this agent |
| 4 | Aggregate/lot mismatches = 0 | **PASS** | `mismatched=0` |
| 5 | Dual-write enabled & healthy | **PASS** | `stock.lots.dual_write_enabled=true` |
| 6 | Frontend / trusted RPC compatible | **PARTIAL** | Local frontend ready; cloud still missing lot-catalog / transfer-hold migrations |
| 7 | Picking/dispatch/transfer/adjustment honor holds | **FAIL to establish** | Cloud lacks `unreserved_lot_cases` / `unreserved_grain_cases` until `…140000` is applied — cannot claim verified on cloud yet |
| 8 | Migration plan reviewed for data compatibility | **PASS** (plan) | Reviewed in DMG-03G/H; not executed |

### Actions taken

- **No** cloud migrations applied  
- **No** flag changes (`damage.stock_hold_ready` remains `false`)  
- **No** modification of `DMG-20261103-000013`  
- **No** pilot submit / hold / write-off  

### What owner must provide to unblock

1. Written confirmation that `ypkfondrkhkydkgovwup` is acceptable as the UAT cutover target despite commercial-named SKUs.  
2. Either: (a) seed **test-only disposable** stock/SKU for pilot, or (b) explicit approval to use 1 case of a named commercial SKU for hold-only pilot (no write-off without further OK).  
3. A **verified recoverable backup** (Supabase dashboard PITR/snapshot, or owner-confirmed backup) — agent cannot create a data-preserving backup via `create_branch`.  
4. Re-issue activation approval after 1–3 are satisfied.

### Execution verdict

**BLOCKED — mandatory preconditions 2, 3 (and 1/7 incompletely established). No cloud changes made.**
