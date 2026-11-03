# DMG-06 — Restricted independent verifier design

**Status: LOCALLY IMPLEMENTED (m82c only) — STOP for separate cloud migration + Auth user approval**

Implemented on disposable `supabase_db_sherlyos_m82c` (sysid `7702447407569928229`) only.  
**Not** applied to development cloud `ypkfondrkhkydkgovwup`, production, or owner local DB `supabase_db_sherlyos` (sysid `7699785797738577957`).  
No Auth verifier account created. No operational flag flips. No DMG-06 reports created/submitted/verified/disposed. No commit/push/deploy.

Environment context: `5173` → development cloud. Fixture `TEST-DMG06-ONLY` already exists. Reporter remains `testgodownmanager@gmail.com`.

---

## 1. Problem

Independent verification requires a second user with `damage.verify`.  
Assigning role `godown_manager` also grants `godown_manager.godowns.all` (every active godown) plus dispatch, opening/adjustment, and damage creation powers — rejected by owner.

**Goal:** Godown-1–scoped account that can view submitted reports + evidence and verify (and reject) DMG-06, without company-wide or stock-mutating extras.

---

## 2. Current authorization model (inspected)

### 2.1 Permissions that matter

| Permission | Who has it today (before this change) | Used for |
|------------|----------------------------------------|----------|
| `damage.read` | admin, GM, store_keeper | View via `can_view_damage_report` + `can_work_at_branch` |
| `damage.record` | GM, store_keeper | Create/edit/submit (and with verify: shop-return create + custody) |
| `damage.verify` | **GM only** | Verify / return / reject; **also** (pre-split) ordinary write-off, exceptional request/execute, quarantine transfer |
| `damage.dispose` | admin | Exceptional approve/reject |
| `godown_manager.godowns.all` | GM (cloud / repos with Nov migrations) | Company-wide **active** godown scope in `can_work_at_branch` |
| `stock.adjustment.post` / `dispatch.confirm` / etc. | GM | Stock mutation / dispatch (not needed for verify) |

### 2.2 Site scope

`app_private.can_work_at_branch(godown)` is true when:

1. `branches.access_all`, or  
2. any `*.godowns.all` (accounts / GM / store_keeper / delivery_person) **and** godown active, or  
3. row in `user_branch_assignments` for that godown (active).

Verify RPC calls `assert_damage_godown_active_unlocked` → **`can_work_at_branch`**.  
View path uses `can_view_damage_report` → `damage.read` + **`can_work_at_branch`**.

**Conclusion:** A user with `damage.read` + `damage.verify` and **only** a Godown-1 assignment (and **no** `*.godowns.all`) is site-scoped server-side today. No UI-only trick required for godown restriction.

### 2.3 Self-verify

`verify_damage_report` / `reject_damage_report` already raise if `reporter_user_id = auth.uid()`. Preserve; add regression tests for the new role.

### 2.4 Coupling problem (must fix in design)

Today **`damage.verify` alone** authorizes:

- `verify_damage_report`, `return_damage_report`, `reject_damage_report` — wanted  
- `post_ordinary_damage_writeoff`  
- `request_exceptional_damage_disposition` / execute exceptional  
- `transfer_verified_damage_to_quarantine`  

Granting only `damage.verify` **without** a disposition split would still allow write-offs — violates owner requirement “must NOT have damage write-off permissions.”

---

## 3. Can an existing role do this without a migration?

| Role | Verdict |
|------|---------|
| `godown_manager` | **No** — includes `godowns.all`, `damage.record`, dispatch, adjustments, write-off path |
| `store_keeper` | **No** — no `damage.verify` |
| `admin` | **No** — no `damage.verify`; has admin/dispose/access_all |
| `accounts` / `salesperson` / `delivery_person` | **No** — no damage verify |

**Answer: No existing role can safely provide Godown-1–only independent verification without a migration (or forbidden permission-matrix edits on shared roles).**

---

## 4. Proposed design (implemented)

### 4.1 New role

| Field | Value |
|-------|--------|
| Role code | `damage_verifier` |
| Role name | Damage Verifier |
| Description | Independent verification of submitted damage at assigned godowns only. No stock posting, dispatch, or damage create. |

### 4.2 New permission (disposition split)

| Permission | Description | Grant to |
|------------|-------------|----------|
| `damage.disposition` | Post ordinary write-off, request/execute exceptional disposition, transfer verified damage to quarantine | **`godown_manager` only** (existing GM behaviour preserved) |

Move those RPC asserts from `damage.verify` alone → require **`damage.disposition`** (and keep godown active / disposition-ready checks).

Leave **`damage.verify`** for: verify, return-for-correction, reject, verification queue reads.

### 4.3 Role permission grants

| Permission | `damage_verifier` | `godown_manager` (unchanged extras) |
|------------|-------------------|-------------------------------------|
| `damage.read` | **Yes** | Yes (existing) |
| `damage.verify` | **Yes** | Yes (existing) |
| `damage.record` | **No** | Yes |
| `damage.disposition` | **No** | **Yes (new grant)** |
| `damage.dispose` | **No** | No (admin only) |
| `godown_manager.godowns.all` | **No** | Yes (when that permission exists in the DB) |
| `stock.adjustment.*` / `dispatch.*` / opening / admin | **No** | Yes (existing) |

### 4.4 Account (after separate owner approval — NOT DONE)

| Field | Value |
|-------|--------|
| Email | `testgodownverifier@gmail.com` |
| Name | Test Godown Verifier |
| Role | `damage_verifier` |
| Branch | **Godown-1 only** via `assign_user_branch` (`gd_1`) |
| Password | Unique strong temporary (not `12345678`) |
| Do not grant | any `*.godowns.all` |

### 4.5 Effective capabilities

| Action | Allowed? | Enforcement |
|--------|----------|-------------|
| See Damage nav / verification queue | Yes | `damage.verify` / `damage.read` |
| View Godown-1 submitted reports + evidence | Yes | `can_view_damage_report` + assignment |
| View other godowns’ reports | **No** | `can_work_at_branch` false |
| Verify / reject others’ reports at Godown-1 | Yes | `damage.verify` + self-verify guard |
| Verify own report | **No** | Existing reporter check |
| Create damage / Shop return / custody | **No** | No `damage.record` |
| Ordinary write-off / exceptional / quarantine transfer | **No** | Requires new `damage.disposition` |
| Opening stock / dispatch / adjustments | **No** | No those permissions |
| All-godown access | **No** | No `godowns.all` |

Reject remains available (inspection outcome). Shop-return **return-to-draft** stays backend-blocked for `shop_return` regardless of role.

---

## 5. Objects / files changed

### 5.1 Database migration (applied on m82c only)

`supabase/migrations/20261103190000_damage_verifier_role_and_disposition_split.sql`

1. `insert` permission `damage.disposition`  
2. `insert` role `damage_verifier`  
3. Grant `damage.read` + `damage.verify` → `damage_verifier`  
4. Grant `damage.disposition` → `godown_manager`  
5. Disposition writers require `damage.disposition`:
   - `post_ordinary_damage_writeoff`
   - `request_exceptional_damage_disposition`
   - `post_exceptional_damage_disposition`
   - `transfer_verified_damage_to_quarantine`
6. Patch `list_exceptional_damage_requests` gate: `damage.verify` → `damage.disposition`

### 5.2 Frontend / rules

| Path | Change |
|------|--------|
| `src/lib/damage/rules.ts` | Disposition eligibility / blockers use `canDisposition` |
| `src/features/damage/hooks/use-damage-access.ts` | `canDisposition = can("damage.disposition")`; write-off / exceptional / quarantine off verify-only |
| Disposition panels | Gate actions on `canDisposition` |

### 5.3 Tests

| Path | Coverage |
|------|----------|
| `supabase/tests/phase_dmg06_damage_verifier.sql` | Godown-A verify OK; other godown denied; self-verify denied; disposition denied for verifier; GM disposition permission + verify OK; no privilege escalation |
| Unit damage tests | `canDisposition: false` blocks write-off / exceptional / transfer |

---

## 6. Security implications

| Risk | Mitigation |
|------|------------|
| Verifier gains write-off via old `damage.verify` coupling | Disposition permission split — **implemented** |
| Verifier creates shop_return (needs record+verify) | Omit `damage.record` |
| Verifier acts at all godowns | Omit all `*.godowns.all`; assign Godown-1 only |
| UI hide-only bypass | All sensitive paths are SECURITY DEFINER RPCs with `assert_permission` + `can_work_at_branch` |
| Self-verify | Existing backend check; regression test |
| Reject releases holds / leaves quarantine intake | Existing shop-return semantics; document; still not a saleable restore |
| Role name confusion with full GM | Distinct code `damage_verifier`; employee UI shows role name |

---

## 7. Impact on DMG-01 through DMG-05

| Scenario | Create | Verify | Disposition |
|----------|--------|--------|-------------|
| DMG-01/02 inbound | Unchanged (record + receiving/verify helpers) | Still `damage.verify` (GM or new verifier at assigned godown) | Write-off N/A / unchanged paths |
| DMG-03 storage | Unchanged (`damage.record`) | Same | Ordinary/exceptional now need `damage.disposition` — **GM keeps it** |
| DMG-04 loading | Unchanged | Same | Same as storage |
| DMG-05 transit | Driver/GM create unchanged | GM or verifier (if assigned to that godown) | Disposition rare; GM retains |
| DMG-06 shop_return | Still GM (record+verify) for create/custody | **New verifier** at Godown-1 (after Auth step) | Disposition still GM-only |

GM regression: after migration, GM must have `damage.disposition` or disposition UAT breaks — migration grants it in the same change set.

---

## 8. Migration and rollback strategy

### Apply cloud (requires separate owner approval)

1. ~~Review SQL locally / disposable m82c first~~ **DONE**  
2. Apply to development cloud via approved migration process only — **NOT DONE**  
3. Confirm GM still has disposition  
4. Then separately approve Auth user create + role `damage_verifier` + Godown-1 branch  

### Rollback

- **Forward-fix preferred:** revoke `damage_verifier` role from users; leave permission in catalog  
- Emergency: re-point disposition RPCs to accept `damage.verify` **or** `damage.disposition` (compat window), then drop role grants  
- Do **not** delete permission rows that may be referenced in audits  
- Never delete Auth users’ ledger-linked history  

---

## 9. Local verification results (2026-11-03)

| Check | Result |
|-------|--------|
| Migration on m82c | **PASS** (recorded `20261103190000`) |
| SQL `phase_dmg06_damage_verifier.sql` | **PASS** (rolled back) |
| Typecheck | **PASS** |
| Lint (oxlint) | **PASS** (pre-existing warnings only) |
| Vitest (full) | **PASS** — 60 files / 369 tests |
| Build | **PASS** |
| SQL `phase_m5_4d_verification_writeoff.sql` on m82c | **FAIL (pre-existing / stale harness)** — `product expiry policy is unclassified` on opening-stock seed; unrelated to disposition split. Covered by DMG-06 SQL permission asserts + unit tests |
| Playwright default / damage-*.spec | **NOT RUN** — harness targets owner `supabase_db_sherlyos` (sysid `769978…`); forbidden by isolation rules |
| Playwright m82c disposition UAT | **NOT RUN** — would mutate disposable stock; out of DMG-06 “no dispose / no historical stock edits” scope this turn |

### m82c schema lag note

Disposable m82c tip was behind several Nov migrations (including `godown_manager.godowns.all`). `can_work_at_branch` on m82c remains assignment-based until those prerequisites are applied. DMG-06 SQL soft-asserts `godowns.all` only when the permission row exists. **Cloud already expected to have the godowns.all chain before or with this migration.**

---

## 10. Cloud migration readiness

**Verdict: READY for cloud migration after separate owner approval**, provided:

1. Cloud migration history already includes (or will include in order) prerequisites that define `can_work_at_branch` with `*.godowns.all` as on repo tip.  
2. Apply **only** `20261103190000_damage_verifier_role_and_disposition_split.sql` (or equivalent via approved process).  
3. Post-apply: confirm `godown_manager` has `damage.disposition`; disposition RPCs assert it; `verify_damage_report` still asserts `damage.verify`.  
4. **Do not** create Auth verifier until a further approval.

**Not ready to:** create Auth user, assign roles on cloud users, flip flags, run DMG-06 report UAT.

---

## 11. Owner next approvals needed

Reply with one of:

```text
APPROVED: Apply 20261103190000_damage_verifier_role_and_disposition_split.sql
to development cloud ypkfondrkhkydkgovwup only. Do not create Auth user yet.
Do not flip operational flags. Do not touch production.
```

and/or:

```text
APPROVED: Create Auth user testgodownverifier@gmail.com with role damage_verifier
and Godown-1 assignment only on development cloud. No godowns.all. No other roles.
```

**STOP — local implementation complete. Awaiting separate cloud / Auth approvals.**
