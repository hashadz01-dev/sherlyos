# M1-S2 — Physical Stock Reconciliation and Legacy Lot Attribution

**Stage:** M1-S2.1 architecture and implementation contract  
**Date:** 2026-10-22  
**Git HEAD at design:** `cb4760ab6f2e1976aa8a699e66a0788e1b3a6c7d`  
**Cloud migration tip at last QA (M1-S1.4):** `20261022200000`  
**Development project:** `ypkfondrkhkydkgovwup` (do not contact in this stage)

This document is the implementation contract for M1-S2.2–S2.5. M1-S2.2 implemented the backend locally. Frontend is M1-S2.3.

Legend:

- **Confirmed** — already true in the shipped system, or explicitly required by this milestone.
- **Approved (D1–D14)** — owner-locked on 2026-10-22. Do not silently change them.
- **Proposed** — remaining implementation detail that is not an owner decision.
- **Out of scope** — must not be built in M1-S2.

---

## 1. Current architecture findings

### 1.1 Inventory grain and units

**Confirmed.** Live inventory is the projection `stock_balances(crate_id, product_id)` with `quantity integer >= 0`. Grain is crate + product. Quantities are whole carton cases. Crate assignment is mandatory. Clients cannot write balances or ledger; posting RPCs (`receive_verified_stock`, `record_opening_stock`, `transfer_stock`, `post_stock_adjustment`) maintain ledger and balances in one transaction.

`stock_ledger` and `stock_transactions` are append-only. Historical rows are not rewritten.

### 1.2 Locations

**Confirmed.** Branches (godowns and shops), zones, crates, products. Crates belong to a zone that belongs to a branch. Stock posting already requires crate and product identity. Branch isolation uses `app_private.can_work_at_branch`. Admin `access_all` sees every branch.

### 1.3 Product expiry policy

**Confirmed.** `products.expiry_policy` is nullable: `expiry_controlled` | `non_expiring` | `NULL` (unclassified). Admin-only RPC `set_product_expiry_policy`. Policy is frozen once any `stock_lots` row exists for the product. Dual-write enable (`stock.lots.dual_write_enabled`) fail-closes unless every product with positive aggregate stock is classified (`20261022200000`).

Lot posting (`20261022190000`) already requires:

- `expiry_controlled` → `expiry_date` present; expired lots cannot be `available`.
- `non_expiring` → `expiry_date` must be null.
- Unclassified products cannot take lot-attributed posts.

### 1.4 Lot tables and seed

**Confirmed.**

| Object | Role |
|---|---|
| `stock_lots` | Lot identity. `branch_id` NOT NULL. Statuses include `available`, `quarantined`, `expired_blocked`, `legacy_unattributed`. Origins include `receipt`, `opening`, `legacy_reconciliation`, `adjustment`. |
| `stock_lot_balances` | Lot quantity at grain `(crate_id, lot_id)`. Check `quantity >= 0`. Unique `(crate_id, product_id)` is **not** on this table; multiple lots may share a crate+product. |
| `stock_legacy_lot_seeds` | Seed idempotency marker. PK `(crate_id, product_id)`, unique `lot_id`. |
| `public.seed_legacy_stock_lots()` | Admin `stock.lots.seed`. Exclusive advisory lock `(88104301, 1)` via `lot_seed_lock_exclusive`. Creates one `legacy_unattributed` lot per **positive** aggregate grain, copies quantity, writes a seed marker, sets `stock.lots.aggregate_only_blocked = true`. Does **not** rewrite `stock_ledger`. Fails closed if unexpected lot balances already exist for a grain. Idempotent when markers already cover every positive grain. |

Cutover flags after M1-S1.4 (development): both `false`. Dual-write read path takes the **shared** advisory lock first. Flag transitions take the **exclusive** lock, then ordered `FOR UPDATE` on balances, lot balances, positive-stock products, and flag rows.

### 1.5 Daily stock verification — related, not reusable as the session store

**Confirmed existing module.** Tables `stock_verifications`, `stock_verification_scopes`, `stock_verification_lines` (unique verification + crate + product, frozen expected quantity), counts, snapshot ledger ids, photo evidence. States: `draft` / `counting` / `submitted` / `recount` / `review` / `closed`. One **open** verification per godown. RPCs: `start_stock_verification`, `save_verification_count`, `submit_stock_verification`, `close_stock_verification`, and related recount/review helpers. UI `/stock-verification`. Permissions `stock.verify`, `stock.count_assist`.

**Confirmed behaviour:** closing a verification does **not** mutate `stock_balances` or `stock_ledger`. Discrepancies are evidence only.

**Why it must not host M1-S2 sessions (design finding, not a product fork):**

- Daily cycle vs one-time cutover lot attribution.
- Godown Manager **closes** daily verification; this milestone requires **Admin approval**.
- No lot / batch / expiry columns.
- One-open-per-godown unique index would collide with a parallel cutover session.
- Store Keeper `stock.count_assist` is in the daily workflow; this milestone names Godown Manager + Admin only.

Reuse the **patterns** (frozen expected qty, grain unique, append-only events, SECURITY DEFINER RPCs, `LoadingBlock` / `StatusBadge` / `PageHeader` / `RequirePermission`) — not the tables.

### 1.6 Stock adjustments — the only approved path that changes aggregate stock

**Confirmed.** `stock_adjustment_requests`: `draft` / `submitted` / `returned` / `approved` / `rejected` / `posted`, optimistic `version`, `idempotency_key`, append-only events. **Approval does not post.** Posting is a separate RPC. Stale version uses `PT409`. UI `/stock-adjustments`. Permissions `stock.adjustment.request`, `stock.adjustment.post`, `stock.adjustment.approve_exceptional`.

M1-S2 must not silently post adjustments. Quantity mismatch is a **stop** for attribution, not an implicit delta.

### 1.7 Permissions already in the catalog

**Confirmed.**

| Code | Typical grant | Used by |
|---|---|---|
| `stock.read` | GM, SK, Admin | Balance lists |
| `stock.verify` | GM, Admin | Daily verification |
| `stock.count_assist` | Store Keeper | Daily count assist |
| `stock.adjustment.*` | GM / Admin as assigned | Adjustments |
| `stock.lots.seed` | Admin | `seed_legacy_stock_lots` |
| `stock.lots.legacy.reconcile` | Admin | Reserved. Posting helpers reject `legacy_unattributed` lot deltas unless this permission is held. **No public RPC uses it yet.** |
| `products.expiry_policy.manage` | Admin | Classify products |
| `operations.monitor` | Admin | Read-only operational views |
| `access_all` | Admin | Bypass branch and permission checks |

### 1.8 Audit

**Confirmed.** `app_private.write_audit(actor, action, target_table, target_id, details jsonb)` writes `audit_logs`. Adjustment and verification mutations already emit audit plus domain event tables. RLS: clients do not write inventory tables.

### 1.9 Frontend patterns

**Confirmed.** Vite + React + TanStack Query. Feature screens under `src/features`. API modules under `src/lib/<domain>/api.ts`. Router in `src/app/router.tsx` with `RequirePermission` / `RequireAnyPermission`. Navigation in `src/app/navigation.ts`. Shared UI: `PageHeader`, `StatusBadge`, `LoadingBlock`, `AppModal`, `Button`, `Input`. Case counts parsed as integers (`parseCaseCount` in verification rules). Mobile-usable warehouse forms already exist on verification detail.

### 1.10 Cutover runbook (M1-S1)

**Confirmed intent in `docs/m1-s1-cutover-runbook.md`:** freeze posting → classify products → physical reconciliation → seed → ordered flag enable. Physical reconciliation is a **named pre-seed gate**. It does not yet exist as a product workflow. This milestone is that gate.

---

## 2. Approved existing requirements

These are treated as **confirmed** for M1-S2. They are already product law or are stated in the M1-S2.1 brief.

1. Inventory is whole carton cases. No fractional cases.
2. Every stock row has a crate. Every reconciliation line has a crate and a product in the session's godown.
3. Product identity on a line cannot change after submit (same rule as adjustment lines).
4. Aggregate `stock_balances` / `stock_ledger` are not mutated by reconciliation save, submit, approve, or reject.
5. Lot quantities on a line must sum to the counted carton cases for that grain.
6. No negative quantities.
7. No duplicate attribution of the same physical stock (one grain cannot be attributed twice).
8. No fabricated manufacturer batch numbers. No fabricated expiry dates.
9. Unknown legacy expiry stays explicitly unknown (`expiry_date` null **and** an explicit unknown flag). It is not defaulted to a date.
10. Expired or quarantined stock must not become `available`.
11. Every approve and reject is auditable.
12. Approval does not mean live stock changed.
13. Actual lot attribution runs only in a separately authorized cutover process.
14. Godown Manager records and submits; Admin reviews and approves or rejects.
15. Existing branch isolation remains. Frontend checks are not security.
16. Deployed migrations through `20261022200000` are not edited.
17. FEFO/FIFO is not implemented in M1-S2.
18. Feature flags stay off during M1-S2.2–S2.4 local work. Seed is not run on working or development databases as a casual action.

---

## 3. Proposed workflow

### 3.1 Lifecycle (confirmed shape, proposed mechanics)

```
Admin creates session (draft)
        │
        ▼
Godown Manager records crate/product counts and lot lines (draft)
        │
        ├── Admin cancels ──► cancelled (releases crate scope)
        │
        ▼
Godown Manager submits (submitted)
        │
        ├── Admin rejects ──► rejected ──► GM corrects ──► draft ──► submit again
        │                     │
        │                     └── Admin cancels ──► cancelled
        │
        └── Admin approves ──► approved (locked until M1-S3)
```

`rejected` is not terminal; Godown Manager may reopen to `draft`. `cancelled` releases overlapping crate scope. `applied` is **not** implemented in M1-S2.2.

**Confirmed:** approve does not post stock and does not seed lots.  
**Approved D13:** `apply_legacy_lot_attribution` is deferred to M1-S3. No stub RPC.

### 3.2 Actors and steps

1. **Admin** opens a reconciliation session for one godown (and, **proposed**, an optional crate list; default = every crate in the godown).
2. Server snapshots in-scope grains from `stock_balances` into session lines (`expected_quantity`). Zero-quantity grains: **proposed — exclude** unless the crate is in scope and the Godown Manager adds a found product (mirrors daily verification “found product”).
3. **Godown Manager** physically counts by crate and product, then records lot identity (or explicit unknown identity) so that lot-entry quantities sum to `counted_quantity`.
4. Submit validates grain membership, quantity conservation on each line, expiry-policy compatibility, and uniqueness of lot identity within a line. Submit re-reads current `stock_balances` under row locks and stores `expected_at_submit`. If current aggregate ≠ original snapshot, submit **fails closed** with a stale-baseline error; GM must refresh expected quantities (new RPC) and recount. **Proposed:** no silent overwrite of counted figures.
5. **Admin** reviews discrepancy summary (counted vs expected, unidentified remainder, expired, quarantined, missing expiry).
6. **Admin** approves or rejects with a reason. Approve is allowed only when every in-scope **positive** grain is counted and `counted_quantity = expected_at_submit` and lot entries sum to counted. Any mismatch → reject or leave submitted; **do not** invent an adjustment.
7. Approved session is **eligible** for attribution. Attribution is a separate Admin RPC, not a button on the GM form, and not invoked by approve.
8. Attribution (authorized cutover): see §4. It mutates **lot** tables only, never aggregate ledger/balances.

### 3.3 Discrepancy handling (confirmed policy, proposed procedure)

| Physical finding | System behaviour |
|---|---|
| Counted = expected, lots sum to counted | Line is attribution-eligible after approve. |
| Counted = 0, expected > 0 (missing stock) | Variance. Session cannot be approved. Use existing daily verification + adjustment, then a **new** session. |
| Counted > expected (excess) | Variance. Same stop. No silent opening-stock post. |
| Counted < expected (shortage, not zero) | Variance. Same stop. |
| Expected = 0, counted > 0 (found stock) | Variance. Same stop. Optional found-product add is evidence only until an adjustment posts. |
| Partial lot identity (some cases identified, rest unknown) | Allowed on a **matched** line. Unidentified remainder is an explicit `identity_unknown` lot entry. No fake batch code. |
| Duplicate manufacturer+expiry on one line | Rejected at save/submit. |
| Unclassified product on a matched line | Count may be recorded. **Proposed:** identified expiry-bearing lots cannot be attributed until the product is classified. Session can still be approved for quantity match; attribution skips or fail-closes those grains until classified. |
| Expired date entered | Lot entry condition `expired`; after attribution the live lot is `expired_blocked`, never `available`. |
| Quarantined physical stock | Lot entry condition `quarantined`; live lot `quarantined`. |

Zero-stock grains that stay zero are not required for approval (**proposed**).

---

## 4. Legacy attribution strategy

### 4.1 Comparison

**Approach A — extend `seed_legacy_stock_lots` to consume approved sessions.**

- Seed would grow a second input path, new failure modes, and new idempotency rules on top of `stock_legacy_lot_seeds`.
- Dual-write / blocked-flag side effects of seed would mix with lot-identity application.
- Harder to keep “seed may run when no session exists” as a fallback.
- Larger migration surface against a function already lock-ordered and flag-coupled.

**Approach B — keep `seed_legacy_stock_lots` unchanged; add a separate controlled attribution RPC.**

- Seed remains the only writer that creates the first `legacy_unattributed` blob and the seed marker, and the only writer that sets `aggregate_only_blocked` as part of seed.
- Attribution runs **after** seed, **before** dual-write enable, under the same exclusive advisory lock class `(88104301, 1)`.
- Attribution splits or relabels the existing `legacy_unattributed` lot on a grain so that lot quantities still sum to the aggregate. It does not insert `stock_ledger` rows and does not update `stock_balances`.
- Historical audit trails stay intact (append-only ledger; new lots get origin `legacy_reconciliation`).
- If a grain has no approved eligible line, it stays a single `legacy_unattributed` lot (current seed behaviour).
- Idempotency is a new marker table keyed by session line / grain, not a change to `stock_legacy_lot_seeds`.

### 4.2 Recommendation

**Proposed: Approach B.** Smallest migration surface, preserves M1-S1 lock/flag/seed tests, matches “attribution is a separately authorized cutover step.”

**Proposed cutover order (updates the M1-S1 runbook in M1-S2.2 docs only; flags stay off until a later authorized stage):**

1. Freeze operational posting.
2. Classify products that will receive attributed lots.
3. Complete and **approve** physical reconciliation (this feature). All positive in-scope grains must match.
4. `seed_legacy_stock_lots()` — unchanged. Creates unattributed lots; sets blocked.
5. `apply_legacy_lot_attribution(session_id)` — splits unattributed lots from approved lines.
6. Verify grain match (existing dual-write enable predicate).
7. Enable dual-write (already guarded by `20261022200000`).

**Confirmed non-goal for M1-S2.3 UI:** no control that calls seed or attribution. Those stay Admin RPC / SQL during an authorized window.

### 4.3 Attribution invariants

**Confirmed intent / proposed enforcement:**

- Require `stock.lots.aggregate_only_blocked = true` and `stock.lots.dual_write_enabled = false`.
- Require a seed marker for the grain and exactly one live `legacy_unattributed` lot covering the grain whose qty equals `stock_balances.quantity` and equals the approved counted qty.
- New lots: origin `legacy_reconciliation`. Identified + in-date + `available` condition → status `available`. Expired → `expired_blocked`. Quarantined → `quarantined`. `identity_unknown` or `expiry_unknown` on `expiry_controlled` → remain `legacy_unattributed` (must not become `available`). `non_expiring` identified lots → `available`, `expiry_date` null.
- Sum of lot balances on the grain after apply = aggregate quantity = pre-apply unattributed quantity.
- Original unattributed lot is reduced to the unidentified remainder or deleted only if remainder is 0 **and** the seed marker is updated to the surviving attributed lot **or** a new remainder marker policy — **proposed:** never delete the seed-marker lot_id if it still holds remainder; if remainder is 0, keep the seed row pointing at the retired lot and add per-line attribution markers. Exact marker update is an S2.2 implementation detail that must not allow a second seed on that grain (`stock_legacy_lot_seeds` PK stays).
- Re-apply is idempotent: second call on an `applied` session no-ops; second call on a grain already attributed no-ops.

---

## 5. Data model

### 5.1 Tables to reuse (no change)

`branches`, `crates`, `products`, `stock_balances`, `stock_ledger`, `stock_transactions`, `stock_lots`, `stock_lot_balances`, `stock_legacy_lot_seeds`, `app_configuration`, `permissions`, `role_permissions`, `audit_logs`, `stock_verifications*` (pattern only), `stock_adjustment_requests*` (pattern only).

Do not add columns to `stock_balances` or `stock_ledger`. Do not change seed RPC signature.

### 5.2 New tables (proposed names)

Prefix `stock_lot_reconciliation_*` to avoid collision with daily `stock_verification_*`.

#### `stock_lot_reconciliations`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | `gen_random_uuid()` |
| `session_number` | text UNIQUE NOT NULL | e.g. `LR-20261022-0001`, allocated like other numbered docs |
| `godown_id` | uuid NOT NULL | FK `branches(id)`; check branch `kind` is godown |
| `status` | text NOT NULL | `draft` / `submitted` / `approved` / `rejected` / `applied` |
| `version` | integer NOT NULL DEFAULT 1 | Optimistic concurrency; bump on every mutating RPC |
| `idempotency_key` | text UNIQUE | Client key on create |
| `created_by` | uuid NOT NULL | FK `profiles` |
| `submitted_by` | uuid | |
| `submitted_at` | timestamptz | |
| `reviewed_by` | uuid | Approver or rejector |
| `reviewed_at` | timestamptz | |
| `rejection_reason` | text | Required on reject |
| `review_notes` | text | Optional on approve |
| `applied_by` | uuid | |
| `applied_at` | timestamptz | |
| `expected_frozen_at` | timestamptz | Last snapshot of expected quantities |
| `notes` | text | |
| `created_at` / `updated_at` | timestamptz | |

**Proposed unique partial index:** one non-terminal session per godown  
`unique (godown_id) where status in ('draft','submitted','rejected')`.  
`approved` is held until attribution; **proposed:** also treat `approved` as blocking a second session for that godown so two approved-unapplied sessions cannot both attribute. Unique where `status in ('draft','submitted','rejected','approved')`. `applied` releases the slot.

#### `stock_lot_reconciliation_scope_crates` (proposed)

Optional crate filter. Empty scope = all crates in the godown at snapshot time. PK `(session_id, crate_id)`. Crate must belong to `godown_id`. Frozen at create; not editable after first count (**proposed:** frozen at create always).

#### `stock_lot_reconciliation_lines`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `session_id` | uuid NOT NULL | FK session ON DELETE RESTRICT |
| `crate_id` | uuid NOT NULL | FK crates |
| `product_id` | uuid NOT NULL | FK products |
| `expected_quantity` | integer NOT NULL CHECK `>= 0` | From `stock_balances` at last freeze |
| `counted_quantity` | integer CHECK `>= 0` | NULL until counted |
| `counted_by` / `counted_at` | | |
| `is_found_product` | boolean NOT NULL DEFAULT false | Expected was 0 at freeze |

**Unique** `(session_id, crate_id, product_id)`.  
Trigger: crate’s godown = session godown.

#### `stock_lot_reconciliation_lot_entries`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `line_id` | uuid NOT NULL | FK line ON DELETE CASCADE (draft only; block cascade after submit — enforce in RPC) |
| `manufacturer_lot_code` | text | NULL iff `identity_unknown` |
| `expiry_date` | date | NULL if unknown or non-expiring |
| `expiry_unknown` | boolean NOT NULL DEFAULT false | |
| `identity_unknown` | boolean NOT NULL DEFAULT false | |
| `quantity` | integer NOT NULL CHECK `> 0` | |
| `condition` | text NOT NULL | `available` / `quarantined` / `expired` |

**Unique** on `(line_id, manufacturer_lot_code, expiry_date, identity_unknown)` using `NULLS NOT DISTINCT` so two unknown-identity rows cannot exist on one line.

**Check constraints (proposed):**

- `identity_unknown` ⇒ `manufacturer_lot_code IS NULL` AND `expiry_unknown = true` AND `expiry_date IS NULL` AND `condition in ('available','quarantined')` (expired requires a date).
- `NOT identity_unknown` ⇒ `length(trim(manufacturer_lot_code)) > 0`.
- `expiry_unknown` ⇒ `expiry_date IS NULL`.
- `expiry_date IS NOT NULL` ⇒ `expiry_unknown = false`.
- `condition = 'expired'` ⇒ `expiry_date IS NOT NULL`.
- No leading/trailing-space-normalized duplicate codes: store trimmed uppercase or trimmed as-entered; **proposed:** trim, preserve case, reject empty after trim.

#### `stock_lot_reconciliation_events` (append-only)

Columns: `id`, `session_id`, `event_type`, `actor_id`, `from_status`, `to_status`, `payload jsonb`, `created_at`.  
Trigger: no UPDATE/DELETE (reuse `reject_stock_history_change` or a sibling).

#### `stock_lot_reconciliation_attributions` (idempotency for apply)

PK `(session_id, crate_id, product_id)`. Columns: `line_id`, `source_lot_id` (the unattributed lot split), `applied_at`, `applied_by`. Prevents double split of the same grain.

### 5.3 State transitions (server-enforced)

| From | To | RPC | Actor |
|---|---|---|---|
| — | `draft` | `create_lot_reconciliation` | Admin |
| `draft` | `draft` | save count / save lots / add found product / refresh expected | GM |
| `draft` | `submitted` | `submit_lot_reconciliation` | GM |
| `submitted` | `approved` | `approve_lot_reconciliation` | Admin, not the submitter (**proposed**) |
| `submitted` | `rejected` | `reject_lot_reconciliation` | Admin |
| `rejected` | `draft` | `reopen_lot_reconciliation` | GM (same godown) |
| `approved` | `applied` | `apply_legacy_lot_attribution` | Admin `stock.lots.legacy.reconcile` + `stock.lots.seed` window (**proposed:** require `legacy.reconcile` only) |
| Any non-applied | — | no client DELETE | — |

Illegal: GM approve; Admin submit unless they also hold GM permission **and** `can_work_at_branch` — **proposed:** create is Admin-only; submit is `stock.lots.physical_reconcile` (GM); an Admin with `access_all` could submit, then must **not** approve their own session.

### 5.4 RPC contract

All `SECURITY DEFINER`, `search_path = ''`, `REVOKE ALL FROM PUBLIC`, `GRANT EXECUTE` only to `authenticated`. Permission + branch checks inside. `version` argument on mutating calls; mismatch → `PT409`.

| RPC | Responsibility | Transaction |
|---|---|---|
| `create_lot_reconciliation(godown_id, crate_ids, idempotency_key, notes)` | Admin. Insert session+scope+lines from current balances. Return existing row on idempotency hit if same godown/scope. | Single TX |
| `list_lot_reconciliations()` | Branch-scoped list | Read |
| `get_lot_reconciliation(id)` | Header, lines, lot entries, events, discrepancy flags | Read |
| `save_lot_reconciliation_count(session_id, version, crate_id, product_id, counted_quantity)` | Draft only. GM. | Single TX |
| `save_lot_reconciliation_lots(session_id, version, line_id, lots jsonb)` | Draft only. Replace all lot entries for the line. Validate sum = counted. | Single TX |
| `add_lot_reconciliation_found_product(session_id, version, crate_id, product_id)` | Draft. expected=0 line | Single TX |
| `refresh_lot_reconciliation_expected(session_id, version)` | Draft or rejected. Re-copy expected from balances. Does not clear counts (**proposed:** fail if any counted ≠ new expected, forcing GM to reclear those lines). Simpler alternative **proposed:** allowed only when no counts yet, or always overwrites expected and marks mismatched lines `stale`. **Owner decision.** Default if unapproved: overwrite expected, keep counts, submit will still fail until counts match. |
| `submit_lot_reconciliation(session_id, version)` | Shared advisory lock; `FOR UPDATE` balances of scoped grains ordered `(crate_id, product_id)`; compare expected; validate lots; status submitted | Single TX |
| `approve_lot_reconciliation(session_id, version, review_notes)` | Admin. Shared lock + re-read balances; require every positive grain counted and matched; status approved | Single TX |
| `reject_lot_reconciliation(session_id, version, reason)` | Admin. Status rejected | Single TX |
| `reopen_lot_reconciliation(session_id, version)` | GM. rejected → draft | Single TX |
| `apply_legacy_lot_attribution(session_id)` | Exclusive advisory lock (same class as seed). Split lots. Mark applied. **Not called from UI in S2.3.** | Single TX |

Helpers (private, no GRANT): snapshot lines, discrepancy view, lock wrappers using existing `acquire_stock_cutover_shared_lock` / `lot_seed_lock_exclusive`.

**Do not** add a public RPC that writes `stock_balances`.

### 5.5 Lock ordering

Reuse class `(88104301, 1)`.

| Operation | Locks |
|---|---|
| Draft saves | Session row `FOR UPDATE`. No advisory lock. No balance locks. |
| Submit / approve | Shared advisory → session `FOR UPDATE` → `stock_balances` for scoped grains ordered `(crate_id, product_id)` `FOR UPDATE`. |
| Attribution | Exclusive advisory (blocks posting and seed) → session `FOR UPDATE` → balances then `stock_lot_balances` ordered `(crate_id, lot_id)` as in `20261022200000` → split lots. |
| Seed | Unchanged exclusive path. |

Never take exclusive for counting. Never lock flag rows in submit/approve (those RPCs do not change flags).

### 5.6 RLS

New tables: **no client DML**. `GRANT SELECT` to `authenticated` with using-expression `can_work_at_branch(godown_id)` (and Admin `access_all`). INSERT/UPDATE/DELETE only via SECURITY DEFINER RPCs (`REVOKE` client writes). Events table: SELECT only. Same pattern as `stock_verifications` / adjustments.

---

## 6. Permission matrix

### 6.1 New permission (**proposed**)

`stock.lots.physical_reconcile` — Godown Manager + Admin.

Why not reuse `stock.verify`: daily verification and cutover reconciliation would share start/submit rights and confuse Store Keepers who have `count_assist` only.

Why not give GM `stock.lots.legacy.reconcile`: that key already gates `legacy_unattributed` lot **writes** in trusted writers. Using it for floor counting would let a GM call attribution if we later GRANT that RPC.

### 6.2 Matrix

| Action | GM `physical_reconcile` | Admin `legacy.reconcile` | Admin `lots.seed` | SK `count_assist` | `stock.read` / monitor |
|---|---|---|---|---|---|
| Create session | No | Yes | No | No | No |
| List / get own godown | Yes | Yes | — | No | Yes (read) |
| Save counts / lots | Yes | Yes (branch) | No | No | No |
| Submit | Yes | No* | No | No | No |
| Reject / approve | No | Yes | No | No | No |
| Reopen rejected | Yes | No | No | No | No |
| Apply attribution | No | Yes | No (seed stays seed) | No | No |
| Seed (existing) | No | No | Yes | No | No |

\*Admin `access_all` currently bypasses `has_permission`. **Proposed:** approve RPC additionally requires `reviewed_by <> submitted_by` so an Admin who submitted cannot approve. Create remains Admin-only so the normal path is Admin opens, GM submits, Admin approves.

Same actor cannot bypass approval by calling `approve_lot_reconciliation` as GM: function checks `stock.lots.legacy.reconcile` (or `access_all` plus not submitter). There is no client UPDATE on `status`.

Store Keeper is **not** in this workflow unless the owner adds them later.

---

## 7. Inventory invariants

Enforced in RPCs and table checks, not in the SPA.

1. Case quantities are integers `>= 0`; lot entry quantities `> 0`.
2. Line crate ∈ session godown; product is active (**proposed:** inactive products with stock still appear; cannot add new inactive found products).
3. After submit, `product_id` / `crate_id` / `expected_quantity` are immutable except via `refresh` in draft.
4. `sum(lot_entries.quantity) = counted_quantity` at save-lots and at submit. If counted is null, lots must be empty.
5. Approve requires `counted_quantity = expected_quantity` for every line with `expected_quantity > 0`, and every such line must have lots (or a single unknown-identity remainder covering the full count).
6. Approve re-reads live `stock_balances` under `FOR UPDATE`; mismatch vs `expected_quantity` → fail (baseline moved). GM must reopen/refresh after Admin reject, or Admin rejects.
7. Reconciliation RPCs never `INSERT`/`UPDATE` `stock_ledger` or `stock_balances`.
8. Attribution never changes aggregate quantity. Lot split is conservation-only.
9. Manufacturer codes are operator-entered. Server does not generate batch numbers or expiry dates.
10. `expiry_unknown` is stored explicitly; UI may not hide it as blank expiry.
11. Dual-write / blocked flags are not flipped by reconciliation RPCs.
12. `applied` grains cannot be attributed again (`stock_lot_reconciliation_attributions`).

---

## 8. Concurrency and rollback

| Risk | Control |
|---|---|
| Two GMs edit one draft | Session `version`; lost update → `PT409`. |
| Duplicate create | `idempotency_key` unique. |
| Duplicate submit | Status guard + version. |
| Approve while GM still editing | Submit first; draft saves rejected after submit. |
| Stock posted during count | Submit/approve lock balances; qty change → fail. Operator uses freeze window from the M1-S1 runbook. |
| Concurrent seed vs attribution | Same exclusive advisory lock. |
| Concurrent posting vs attribution | Posting takes shared; attribution exclusive; posting waits or fail-closes mid-flight via existing helpers. |
| Failed attribution mid-loop | Single transaction; full rollback. Session stays `approved`. |
| Failed submit mid-validation | Single transaction; stays `draft`. |
| Two sessions one godown | Partial unique index. |
| Client retries apply | Attribution marker + `applied` status; second call returns success no-op (**proposed**). |

---

## 9. Frontend contract

Do not implement in M1-S2.1. Smallest extension of existing Inventory navigation.

### 9.1 Routes

| Path | Gate | Page |
|---|---|---|
| `/stock-lot-reconciliation` | `stock.lots.physical_reconcile` OR `stock.lots.legacy.reconcile` OR `operations.monitor` | Session list |
| `/stock-lot-reconciliation/new` | `stock.lots.legacy.reconcile` | Admin create |
| `/stock-lot-reconciliation/:sessionId` | same as list | Detail: count + lots + discrepancy + approve + events |

Nav item in Inventory, after Stock verification: label **Lot reconciliation**, icon `ClipboardCheck` or `Library`.

### 9.2 Components to reuse

`PageHeader`, `StatusBadge`, `LoadingBlock`, `AppModal`, `Button`, `Input`, `RequirePermission` / `RequireAnyPermission`, verification-style crate/product pickers if already exported; otherwise copy the local form pattern from `VerificationDetailPage` / `AdjustmentDetailPage` (do not refactor those pages).

New files (**expected S2.3**):

- `src/features/stock-lot-reconciliation/LotReconciliationPage.tsx`
- `src/features/stock-lot-reconciliation/NewLotReconciliationPage.tsx`
- `src/features/stock-lot-reconciliation/LotReconciliationDetailPage.tsx`
- `src/lib/lot-reconciliation/api.ts`
- `src/lib/lot-reconciliation/rules.ts`

### 9.3 Screens (one detail page, sections — not six routes)

1. **List** — number, godown, status, submitted at, variance count.
2. **Verification form** — crate groups, product rows, integer case input, save per line (existing warehouse pattern). Tablet-first: large numeric inputs, crate filter, sticky submit.
3. **Lot entry** — per line modal or expandable: manufacturer code, expiry date, expiry-unknown checkbox, identity-unknown checkbox, condition, quantity. Sum vs counted shown live (client convenience only).
4. **Discrepancy summary** — unmatched grains, unidentified qty, expired qty, quarantined qty, unclassified products.
5. **Admin approval** — approve / reject modal with required reason on reject. Hidden unless `legacy.reconcile` and status=`submitted`.
6. **Events** — timeline from `stock_lot_reconciliation_events` plus link to `audit_logs` if the existing audit screen can filter by entity; otherwise embed events only.

No seed button. No apply button in S2.3.

### 9.4 Form rules (client; server is source of truth)

- Counted: integer `>= 0`, same parser as `parseCaseCount`.
- Lot qty integers `> 0`.
- Identity unknown disables batch and expiry inputs and forces expiry-unknown.
- Expiry unknown disables date.
- `non_expiring` product: hide expiry; reject dates.
- Unclassified: warn; still allow count; block identified expiry on submit via RPC.

### 9.5 Data fetching

TanStack Query keys: `["lot-reconciliations"]`, `["lot-reconciliation", id]`. Mutations invalidate both. Loading: `LoadingBlock`. Errors: `notify` + RPC `message` / `PT409` stale banner. Permission miss: `AccessDeniedPage`.

---

## 10. Test matrix

Isolated local SQL (rollback) and frontend tests. **No development-cloud writes. No production. Do not run `phase_m1_concurrency.mjs` against the working database.**

### 10.1 SQL / RPC (new `supabase/tests/phase_m1_s2_lot_reconciliation.sql`)

| ID | Case | Expect |
|---|---|---|
| T01 | Counted = expected, lots sum | Submit + approve OK; balances unchanged |
| T02 | Lots sum ≠ counted | Save/submit fail |
| T03 | Duplicate submit | Second submit fail; one submitted row |
| T04 | GM other godown | `42501` / permission fail |
| T05 | GM calls approve | Fail |
| T06 | Admin approve own submit | Fail if self-approve rule adopted |
| T07 | Concurrent save stale version | `PT409` |
| T08 | Transfer posts after freeze of expected, before submit | Submit fail; stock unchanged by recon |
| T09 | Approve after baseline change | Approve fail |
| T10 | Missing expiry on expiry_controlled identified lot | Submit fail |
| T11 | `expiry_unknown` stored; `expiry_date` null | OK |
| T12 | Duplicate lot identity on one line | Fail |
| T13 | Identity unknown + fabricated code | Check constraint fail |
| T14 | Negative count | Fail |
| T15 | Cross-crate line | Fail |
| T16 | Two open sessions same godown | Unique fail |
| T17 | Reject then reopen then submit | OK |
| T18 | Approve with shortage | Fail; no adjustment row |
| T19 | Flags remain false after approve | OK |
| T20 | Attribution without seed | Fail |
| T21 | Attribution splits lot; aggregate conserved; ledger row count unchanged | OK |
| T22 | Attribution idempotent | Second apply no extra lots |
| T23 | Attribution rollback (forced error mid-TX) | Session still approved; lots unsplit |
| T24 | Concurrent attribution vs seed | Exclusive lock; one winner |
| T25 | Expired entry → lot `expired_blocked` | Not `available` |
| T26 | Unknown expiry expiry_controlled → stays `legacy_unattributed` | Not `available` |
| T27 | Unauthenticated / anon GRANT | Execute revoked |

### 10.2 Two-session (`phase_m1_s2_concurrency.mjs`)

Rollback-only. Do not commit dual-write. Proofs: stale version; submit vs posting on same grain; attribution vs shared posting lock.

### 10.3 Browser / component (S2.3–S2.4)

List gated; GM can save draft; Admin sees approve; reject reason required; mobile viewport count form; no apply button.

### 10.4 Regression (S2.2 / S2.4)

Re-run local: `phase_m1_s1_cutover_flag_safety.sql`, `phase_m1_lot_aware_operational_posting.sql`, `phase_4_3e2b1_ledger_integrity.sql`, `phase_4_3e2b2_trusted_writer_security.sql`, `phase_4_3e1a_lock_order_hardening.sql`. Flags-off compatibility: existing posting still aggregate-only.

---

## 11. Implementation file plan

### M1-S2.2 — Backend (next stage)

| File | Action |
|---|---|
| `supabase/migrations/20261022210000_lot_physical_reconciliation.sql` | **New.** Tables, constraints, RPCs, RLS, permission grant. Does **not** replace seed. |
| `supabase/tests/phase_m1_s2_lot_reconciliation.sql` | **New.** T01–T27 style, wrapped in rollback. |
| `supabase/tests/phase_m1_s2_concurrency.mjs` | **New.** Two-session, rollback-only. |
| `docs/m1-s1-cutover-runbook.md` | **Edit.** Insert approved-recon → seed → attribute order. No flag values changed. |
| `docs/m1-s2-physical-stock-reconciliation-contract.md` | Existing; S2.2 may footnote RPC signatures if they match this contract. |

No `src/**` in S2.2. No cloud push. No git commit unless the owner asks.

### M1-S2.3 — Frontend

Files in §9.2 plus `src/app/router.tsx`, `src/app/navigation.ts`. No schema edits.

### M1-S2.4 — Integrated QA

Local SQL + vitest + lint + build + browser verification of the six panels. No cloud.

### M1-S2.5 — Development deploy

Applied 2026-10-22 17:41 +05:30 to `ypkfondrkhkydkgovwup` from `bbe20a2` via `npx --yes supabase@2.121.0 db push --linked --skip-vault`. Cloud tip `20261022210000`. Inventory and cutover flags unchanged. Attribution not implemented. Production was not touched.

---

## 12. Owner decisions (locked 2026-10-22)

These are approved. M1-S2.2 implemented them. Do not silently change them.

| ID | Locked decision |
|---|---|
| D1 | Sessions cover **selected crates** in one godown. |
| D2 | Unexpected physical stock is a **discrepancy** (found-product evidence). No automatic aggregate stock or adjustment. Zero-quantity grains are omitted from the snapshot. |
| D3 | The submitting actor **cannot** approve their own session. |
| D4 | Photo evidence is **optional / not required**. |
| D5 | Godown Manager and Admin only. Store Keeper has no reconciliation access. |
| D6 | Refresh expected is **draft only** and **invalidates counts and lot entries**. |
| D7 | The **entire** session must match before approval. No partial grain approval. |
| D8 | Unknown physical lot identity remains explicitly unknown / `legacy_unattributed`. No fabricated batch, manufacture, or expiry values. |
| D9 | Future lot attribution is Admin-only and cutover-gated (`stock.lots.legacy.reconcile`). |
| D10 | New permission `stock.lots.physical_reconcile` for GM + Admin. Do not reuse `stock.verify`. |
| D11 | Database-generated unique session reference (`LR-YYYYMMDD-######`). |
| D12 | Draft counting of unclassified products is allowed. **Approval** is blocked until every relevant product is classified. |
| D13 | **Defer** `apply_legacy_lot_attribution` to M1-S3. No executable stub in M1-S2.2. |
| D14 | Overlapping crate scope is blocked while a session is draft, submitted, rejected, or approved. Release via `cancelled` now, or `applied` in M1-S3. No alternative path to mark a session applied. |

---

## 13. Explicit non-goals (M1-S2)

- FEFO / FIFO allocation.
- Changing `seed_legacy_stock_lots` behaviour or signature.
- Editing migrations at or before `20261022200000`.
- Dual-write enable or `aggregate_only_blocked` flips.
- Running seed or attribution on development or production as part of S2.1–S2.4.
- Silent stock adjustments from variance.
- Fabricating batch codes or expiry dates.
- Rewriting historical `stock_ledger` to attach `lot_id`.
- Replacing daily stock verification.
- Shop-branch reconciliation.
- Damage / quarantine **module** (condition flag on a lot entry only).
- Mobile native app.
- Cloud contact in S2.1.
- Git commit / push in S2.1.

---

## 14. Stage-by-stage acceptance criteria

### M1-S2.1 (this stage)

- [x] One design document at `docs/m1-s2-physical-stock-reconciliation-contract.md`
- [x] No migrations, no UI, no cloud, no commit
- [x] Owner locked D1–D14

**Stop:** S2.2 backend follows. Do not start S2.3 until S2.2 is accepted.

### M1-S2.2 — Backend

**Deliverables:** migration `20261022210000_lot_physical_reconciliation.sql`; SQL tests; concurrency test; runbook paragraph.

**Dependencies:** S2.1 accepted; local Docker Postgres; flags off.

**Test commands (PowerShell, local only):**

```text
Get-Content supabase/tests/phase_m1_s2_physical_reconciliation.sql | docker exec -i supabase_db_sherlyos psql -U postgres -d postgres -v ON_ERROR_STOP=1
node supabase/tests/phase_m1_s2_concurrency.mjs
Get-Content supabase/tests/phase_m1_s1_cutover_flag_safety.sql | docker exec -i supabase_db_sherlyos psql -U postgres -d postgres -v ON_ERROR_STOP=1
```

**Acceptance:** RPCs listed in `docs/m1-s2-backend-implementation.md`; approve does not change `stock_balances` or flags; seed RPC unchanged; dedicated SQL + concurrency tests pass; M1-S1 tests still pass; no `apply_legacy_lot_attribution`.

**Stop if:** seed must be rewritten; invariant requires ledger rewrite; unique index collides with production-like data in local fixtures.

### M1-S2.3 — Frontend

**Deliverables:** routes, nav, three pages, api + rules modules.

**Dependencies:** S2.2 local RPCs.

**Tests:** `npx vitest run` (new tests if added), `npx eslint .`, `npx vite build`; browser pass of list → count → lot entry → submit → admin reject/approve; tablet width.

**Stop if:** RPC contract must change for the UI to work (return to S2.2, do not invent client writes).

### M1-S2.4 — Integrated QA

**Deliverables:** QA notes in chat (or a short `docs/m1-s2-qa.md` only if the owner asks). Local only.

**Acceptance:** SQL + browser + lint + build; flags still false; no seed; no cloud.

**Stop if:** conservation bug, permission bypass, or baseline-stale approve succeeds.

### M1-S2.5 — Development deployment

**Closed 2026-10-22 17:41 +05:30.** Backup `20261022T120455Z`; `npx --yes supabase@2.121.0 db push --linked --skip-vault` applied only `20261022210000` to `ypkfondrkhkydkgovwup`. Tables/RPCs/RLS verified. Flags false. Inventory 11/73 unchanged. No seed. No attribution.

---

## Appendix A — Reusable modules (quick index)

| Area | Reuse |
|---|---|
| Numbering / godown session | Daily verification create pattern |
| Frozen expected qty + unique grain | `stock_verification_lines` |
| Version + idempotency + events | `stock_adjustment_requests` |
| Approve ≠ mutate stock | Both verification close and adjustment approve |
| Advisory locks | `acquire_stock_cutover_shared_lock`, `lot_seed_lock_exclusive` |
| Audit | `app_private.write_audit` |
| Branch isolation | `app_private.can_work_at_branch` |
| Permission check | `app_private.has_permission` |
| Status UI | `StatusBadge`, `LoadingBlock`, `PageHeader` |
| Integer cases | `parseCaseCount` |
| Reserved Admin key | `stock.lots.legacy.reconcile` |
| Seed / lots | `seed_legacy_stock_lots`, `stock_legacy_lot_seeds` — call later, do not fork |

## Appendix B — Approach A vs B (summary)

| | A extend seed | B separate apply |
|---|---|---|
| Seed tests / lock order | Must re-prove | Unchanged |
| Flag side effects | Mixed into recon | Seed only |
| Ledger | Still no rewrite | Still no rewrite |
| Idempotency | Overload seed markers | New attribution markers |
| UI risk | Easy to call seed from approve | Apply not in UI |
| Migration size | Large function rewrite | New tables + one new RPC |

**Recommended: B.**
