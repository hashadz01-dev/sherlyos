# DMG-06 — Shop Return Damage manual UAT preparation

**Verdict: BLOCKED — AWAITING CLOUD MIGRATION + AUTH VERIFIER APPROVAL**

Fixture **A** is created and validated on development cloud (`5173` → `ypkfondrkhkydkgovwup`).  
Restricted-verifier design is **implemented on disposable m82c only** (`docs/dmg-06-restricted-verifier-design.md`). Cloud migration, Auth verifier create, and DMG-06 report UAT are **not** done.

No damage report, custody, submit, quarantine post, flag change, commit, or push.

---

## 1. Fixture status (created)

| Field | Value |
|-------|--------|
| Product | `TEST-DMG06-ONLY` (`5f1c1730-fc91-4be0-bc3f-92cbc925184c`) |
| Lot | `TEST-LOT-DMG06` (`ddc2aace-6102-429e-94e6-aa4b9ae16075`) |
| Opening | `OS-20261103-000057` — **2** cases @ Godown-1 / `uat_c1` |
| Aggregate = lot | **2 = 2** |
| Shop source | **SHOPPE FRESH** (active; selectable in transit-style shop picker for `shop_return`) |
| Product selectable | **Yes** (`list_damage_report_sources` shop_return catalog) |
| Order / dispatch / delivery return | **None** |
| Shop-return damage reports | **0** |

### Baselines after fixture (unchanged except TEST-DMG06)

| SKU | Qty |
|-----|-----|
| AVT-CATER-BLEND-1KG | 17 |
| GOODLIFE-MILK-500ML | 18 |
| TEST-DMG03M-ONLY | 2 |
| TEST-DMG04-ONLY | 3 |
| TEST-DMG05-ONLY | 1 |
| TEST-DMG06-ONLY | **2** |

Script: `scripts/dmg06/prepare-shop-return-fixture-cloud.mjs`.

---

## 2. Independent verifier — creation stopped (godown scope)

Owner approved account creation, then required Godown-1-only scope if supported, else STOP.

### Authorization model finding

| Fact | Evidence |
|------|----------|
| Role `godown_manager` includes `godown_manager.godowns.all` | Cloud `role_permissions` |
| That permission makes `can_work_at_branch` true for **every active** godown | Migration pattern `20261102140000_godown_manager_company_wide_godown_access.sql` |
| Explicit `user_branch_assignments` to Godown-1 alone does **not** cancel `godowns.all` | Assignment is OR’d with company-wide check |
| Removing `godowns.all` from the role would change **all** GMs including Test Godownmanager | Forbidden |
| Verify-only custom role / user-level deny | Would need migration / permission redesign — forbidden this pass |

**Therefore the account was not created.** Creating it as `godown_manager` would grant all-godown access.

### Also true if creation proceeds later

| Item | Value |
|------|--------|
| Email | `testgodownverifier@gmail.com` |
| Name | Test Godown Verifier |
| Role | `godown_manager` |
| Damage perms with role | `damage.read`, `damage.record`, `damage.verify` (+ other GM grants such as `deliveries.assign`, return approve/post) |
| Self-verify | Backend already rejects reporter = verifier |
| Password | Unique strong temporary (not `12345678`) — generated only after scope approval |

### Suggested confirmation (choose one)

**Option 1 — proceed with inherent company-wide GM scope (recommended for UAT speed):**

```text
APPROVED: Create testgodownverifier@gmail.com as godown_manager knowing this
includes godown_manager.godowns.all (all active godowns). Generate a unique
strong temporary password (not 12345678). Do not change other users, permissions,
or flags. Do not create/submit/verify any DMG-06 report automatically.
```

**Option 2 — redesign (separate work):** approve a verify-scoped role or user-level site restriction via a dedicated migration/plan (out of this UAT create step).

---

## 3. Expected stock after future manual submit (planning)

Damage qty **1** case on TEST-DMG06:

| Location | After submit |
|----------|--------------|
| `uat_c1` saleable | still **2** |
| `QRN-01` quarantine | **+1** intake |
| Commercial / DMG-03/04/05 | unchanged |

Custody confirmation alone posts **no** stock.

---

## 4. Manual browser UAT steps (actual UI labels)

App: `http://127.0.0.1:5173`  
Sidebar: **Damage** → page title **Damage Management**.

### 1. Reporter login

1. Open `/login`.
2. Sign in: `testgodownmanager@gmail.com` / `12345678`.
3. Open **Damage**.
4. Confirm green banner: **Damage stock isolation ready: …**

### 2. Shop Return Damage selection

1. Click **New report** → `/damage/new`.
2. **Godown**: **Godown-1**.
3. **Scenario**: select **Shop return**  
   Helper: *DMG-06. Shop, expired, or returned-goods damage. Physical custody must be confirmed at the receiving godown before submit.*
4. Confirm other scenarios remain available to GM; Delivery Person / Store Keeper must **not** get Shop return enabled.

### 3. Shop and damaged product selection

1. Under source search, select **SHOPPE FRESH**  
   Helper: *Active shops. Custody confirmation is a later workflow.*
2. Add line:
   - **Product**: `TEST-DMG06-ONLY`
   - **Crate (optional)**: may leave blank or choose `uat_c1` (not quarantine)
   - **Stock lot**: not required for shop_return in UI (lot selector is storage-only)
   - Quantity: **1**
   - Damage reason: short text
3. Save draft (stay on editor / open detail).

### 4. Custody confirmation

1. Stay on the draft **edit** page (`/damage/:id/edit`) or open detail (`/damage/:id`).
2. Panel **Shop-return custody** shows **Custody outstanding** (edit and detail both expose it).
3. Click **Confirm physical custody** → dialog shows shop, product, cases, godown → **Confirm physical custody now**.
4. Expect toast **Physical custody confirmed** and badge **Custody confirmed**.
5. Expect **no** inventory change (saleable still 2; quarantine still 0 for this SKU).
6. Submit blocker for custody should clear after confirmation + refresh of readiness.

**Missing / denied controls to note:** Store Keeper must not see the confirm action. No separate “receiving document” control exists for DMG-06 (by design).

### 5. Evidence upload

1. On the same report, use the evidence uploader (photographic evidence panel).
2. Upload jpeg/png/webp ≤ 10 MB.
3. Finalize so status is finalized for this report.
4. Submit remains blocked in UX until custody + evidence rules are satisfied.

### 6. Damage submission

1. **Review and Submit** (or equivalent submit control on the editor).
2. Expect status **Submitted**.
3. Expect quarantine intake **+1** on Godown-1 `QRN-01` for TEST-DMG06; saleable `uat_c1` still **2**.
4. Do **not** proceed if commercial or DMG-03/04/05 balances change.

### 7. Independent verification (different user)

**Blocked until verifier confirmation above.**

1. Sign out reporter.
2. Sign in as `testgodownverifier@gmail.com` (once created).
3. **Damage** → **Verification** (`/damage/verification`) or open the submitted report.
4. Panel **Godown verification** — verify (not self).
5. Expect status **Verified**; verify posts **no** extra stock.
6. Confirm original reporter still cannot verify own report.

### 8. Quarantine, inventory, stock-history reconciliation

1. **Damage** → **Quarantine** (`/damage/quarantine`) — TEST-DMG06 intake visible.
2. Confirm saleable TEST-DMG06 = 2; quarantine = 1.
3. Confirm one `ADJUSTMENT` / `quarantine_intake` for the report (no double post on re-submit attempt).
4. Confirm AVT 17 / GOODLIFE 18 / TEST-DMG04 3 / TEST-DMG05 1 unchanged.
5. Optional disposition (write-off / exceptional) is **out of this pack** unless separately approved.

---

## 5. Controls check (implementation)

| Control | Present? |
|---------|----------|
| Scenario **Shop return** | Yes |
| Shop source picker | Yes |
| Product catalog (needs on-hand > 0) | Yes after fixture |
| **Shop-return custody** / Confirm physical custody | Yes |
| Evidence upload + finalize | Yes |
| Submit gated on custody | Yes (UI + backend) |
| Independent verify (second GM) | **Account missing** until B confirmed |
| Delivery-return prerequisite UI | **Not present** — correct; not required |

---

## 6. Stop

- Fixture A: **done**
- Verifier B: **awaiting your separate confirmation** (exact proposal in §2)
- No damage create/submit performed

Reply with the §2 confirmation text to provision the verifier, then the pack can move to **READY FOR MANUAL DMG-06 TEST**.
