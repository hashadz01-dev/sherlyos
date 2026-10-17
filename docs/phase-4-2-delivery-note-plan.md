# Phase 4.2 delivery note generation and godown handover

**Phase 4.2A — LOCAL COMPLETE (verified).** Migration `20261018120000_delivery_notes.sql`.  
**Phase 4.2B — LOCAL COMPLETE (verified).** Migration `20261018130000_delivery_note_mutations.sql` (create/generate/void, print, cancel guard).  
**Phase 4.2C — LOCAL COMPLETE (verified).** Migration `20261018140000_delivery_note_handover.sql` (send/acknowledge + GM inbox).  
**Phase 4.2D — LOCAL QA COMPLETE — READY FOR DEVELOPMENT DEPLOYMENT.**  
**Phase 4.2E — DEVELOPMENT DEPLOYED AND VERIFIED** on `ypkfondrkhkydkgovwup` (2026-10-17). Applied: `20261018120000`, `20261018130000`, `20261018140000`. Production not deployed. No git commit/push for this gate.

Phase 4.1 Orders Management remains DEVELOPMENT DEPLOYED AND VERIFIED on `ypkfondrkhkydkgovwup` and committed on `main` at `9bcbcbb8eca6c44c9ce4d7f1316e291db4e3c681`. Latest **deployed** development migration: `20261018140000_delivery_note_handover.sql`. Do not edit applied migrations.

Labels used below:

- **BPM** — stated in `reference/Sherlys_Distribution_Agents_BPM.pdf` v1.0.
- **Approved** — owner-signed decision that supersedes earlier planning defaults.
- **Engineering** — a technical choice so the locked rules can be built. Not a new business policy.
- **Blocking for 4.2B/4.2C** — must be resolved or implemented via a forward-only migration before mutation RPCs ship.

## 1. Purpose

This document is the Phase 4.2 business and technical plan for ORD-03 and ORD-04 only:

1. Accounts generates a delivery note for a verified order’s approved requested products.
2. Accounts sends that delivery note to the Godown Manager.
3. The Godown Manager acknowledges receipt for an authorized fulfilling godown.

It does not authorize code. Implementation must follow the stages in section 12 after owner sign-off on section 13.

## 2. BPM mapping

| Flow | BPM statement | Phase 4.2 |
| --- | --- | --- |
| ORD-01 | Receive shop product order. | Prerequisite (Phase 4.1). |
| ORD-02 | Accounts verifies request and availability; hold for correction. | Prerequisite. Source order must be `verified`. |
| ORD-03 | Accounts generates delivery note for approved requested products. | **In scope.** |
| ORD-04 | Pass / send delivery note to Godown Manager. | **In scope** (send + Godown acknowledgement). |
| ORD-05 | Expiry-aware / FEFO picking. | Out of scope. Blocked until batch and expiry data exist. |
| ORD-06 | Assign vehicle and Delivery Person. | Out of scope. No vehicle master. |
| ORD-07 | Invoice note from goods actually loaded. | Out of scope. |
| ORD-08 | Accounts signs/seals final invoice. | Out of scope. |
| ORD-09 | Shop delivery and outcome. | Out of scope. |

**BPM.** Document sequence remains delivery note → invoice note → signed/sealed final invoice. Phase 4.2 creates only the delivery note document and its handover acknowledgement.

**BPM.** ORD-05 through ORD-09 remain later phases. Short picks and partial fulfilment wait for picking and delivery (Phase 4.1 approved decision 9).

## 3. Approved decisions (owner)

| # | Decision | Status |
| --- | --- | --- |
| 1 | At most **one non-voided** delivery note per verified order. A voided DN remains in audit history; a replacement may be created only when business constraints permit. | **Approved** — enforced by partial unique index `delivery_notes_open_order_key`. |
| 2 | Add `delivery_notes.acknowledge` and grant it **only** to Godown Manager. Do not grant create/generate/send/void to Godown Manager. | **Approved** — seeded in 4.2A. |
| 3 | Creation must begin in **`draft`**. Lifecycle is `draft → generated → sent → acknowledged`. Generation is an explicit later transition (`generate_delivery_note` in a future stage). Draft is a persisted status. | **Approved** — supersedes the earlier “create lands at generated” proposal. Schema default and shape checks support draft. Mutation RPCs are **not** in 4.2A. |
| 4 | Cancellation consistency: verified order may cancel with no DN; with draft/generated DN cancel is allowed only when the DN is voided as part of an **approved** cancellation workflow; once `sent`, void before cancel; once `acknowledged`, cancel blocked and DN cannot be voided. | **Approved** — see §3.1. Conservative 4.2A rule: any **active** (non-voided) DN must be voided before cancel. No silent auto-void. `cancel_order` is **not** replaced in 4.2A. |
| 5 | Official DN printing requires configured company identity. Do not invent legal names, addresses, tax IDs, logos, signatures, or seals. Do not use an unapproved placeholder as official print identity. | **Approved** — see §9. No print UI in 4.2A. |

Engineering defaults that remain locked:

| # | Default | Rationale |
| --- | --- | --- |
| A | Phase 4.1 **order status machine unchanged**. Order stays `verified` or `cancelled`. | Delivery note is a separate document. |
| B | **No inventory side effects.** No reservation, deduction, batch/expiry, vehicles, invoice notes, or dispatch. | Matches Phase 4.1 no-reservation rule and BPM deferral of ORD-05+. |
| C | **No `delivery_note_handoffs` table.** Send and acknowledge are status transitions plus append-only events. | Same pattern as `order_events`. |

### 3.1 Order cancellation integration (design only — blocking for 4.2B/4.2C)

Phase 4.1 `public.cancel_order` (in deployed `20261017120000_shop_orders.sql`) does not know about delivery notes. **Do not edit that migration.**

Future forward-only migration must replace or wrap `cancel_order` with guards:

| Order + DN state | Cancel allowed? |
| --- | --- |
| `verified`, no DN or only voided DNs | Yes (Phase 4.1 behavior) |
| `verified`, open DN in `draft` / `generated` / `sent` | **No** until the open DN is voided first (conservative; owner has not authorized automatic void of draft/generated) |
| `verified`, DN `acknowledged` | **No** — acknowledged DN cannot be voided; cancel blocked |

**Ambiguity for owner approval before mutation stages:** Decision 4 wording allows cancel when DN is draft/generated *if* the related DN is voided as part of the approved cancellation workflow. That could mean (a) a single combined RPC that voids then cancels, or (b) operator voids first, then cancels. Phase 4.2A records the conservative separable rule (void first). A combined workflow must be explicitly authorized later.

**Lock order (future mutations):** always `SELECT … FOR UPDATE` on the **order** row first, then on the **delivery_note** row. Same order for create, generate, send, acknowledge, void, and cancel guards — avoids deadlock inversions with concurrent cancel.

**Race:** Creating a DN and cancelling the source order must serialize on the order row lock so an open DN cannot exist against a cancelled order, and cancel cannot succeed past an open DN without the void step.

## 4. Scope stages

| Stage | Content |
| --- | --- |
| **4.2A** | Schema, constraints, indexes, forced RLS, permission seed, number sequence, events, read RPCs |
| **4.2B** | Accounts create DN from verified order (full line snapshot), void before acknowledgement, print payload |
| **4.2C** | Accounts send to godown; Godown Manager inbox and acknowledge (branch-scoped) |
| **4.2D** | Local SQL, JWT, concurrency, browser QA |
| **4.2E** | Development-only `db push` and cloud verification (separate authorization) |

### Included

- Delivery note header and lines copied from a verified order.
- Unique delivery note number (`DN-YYYYMMDD-######` via `delivery_note_seq`; intentional gaps possible after rollbacks).
- Document statuses: **`draft`**, `generated`, `sent`, `acknowledged`, `voided`.
- Append-only delivery note events.
- Accounts create (draft), generate, send, and void (with rules below) — mutation RPCs from 4.2B onward.
- Godown Manager acknowledge for the fulfilling godown (4.2C).
- Print-friendly HTML view (CSS print) only after company identity is configured — no PDF service in 4.2.
- Version checks and idempotency on mutations.

### Excluded

- Physical stock deduction or any ledger write.
- Inventory reservation or allocation tables.
- Batch / expiry-aware picking (ORD-05).
- Vehicle or Delivery Person assignment (ORD-06).
- Invoice note or final invoice (ORD-07, ORD-08).
- Dispatch, shop delivery outcomes, returns, damage.
- Widening `orders.capture` or `orders.verify`.
- Editing deployed `20261017120000_shop_orders.sql`.
- Production deployment.

## 5. Data model

Local migration (4.2A): `supabase/migrations/20261018120000_delivery_notes.sql`. Not pushed until 4.2E.

### `delivery_notes`

| Column | Notes |
| --- | --- |
| `id` | uuid PK |
| `delivery_note_number` | text, unique, assigned by trigger; pattern `DN-YYYYMMDD-######` |
| `order_id` | FK → `orders`, restrict |
| `shop_id` | Copied from order at create |
| `branch_id` | Copied from order (fulfilling godown = `orders.branch_id`) |
| `status` | `draft` \| `generated` \| `sent` \| `acknowledged` \| `voided` (default `draft`) |
| `version` | integer, optimistic concurrency |
| `idempotency_key` | create key; shape matches `app_private.clean_idempotency_key` |
| `created_by` / `created_at` | Accounts actor; creator never updated |
| `generated_at` / `generated_by` | Set on explicit generate transition |
| `sent_at` / `sent_by` | Set on send |
| `acknowledged_at` / `acknowledged_by` | Set on acknowledge |
| `voided_at` / `voided_by` / `void_reason` | Set on void |
| `updated_at` | Touch on mutation |

Constraints:

- Partial unique index: one row with `status <> 'voided'` per `order_id`.
- Shape checks for status vs timestamp/actor columns (mirror orders).
- Order must remain `verified` at create time.

### `delivery_note_lines`

| Column | Notes |
| --- | --- |
| `id` | uuid PK |
| `delivery_note_id` | FK → `delivery_notes` |
| `product_id` | FK → `products` |
| `requested_cases` | integer ≥ 1; copied from order lines |
| `created_at` | set on insert |

Lines are immutable after create. No price, tax, or batch columns.

### `delivery_note_events`

Append-only. Event types: `created`, `sent`, `acknowledged`, `voided`.

Columns: `id`, `delivery_note_id`, `event_type`, `from_status`, `to_status`, `actor_id`, `version`, `note`, `idempotency_key`, `line_snapshot` (jsonb, optional), `created_at`.

Triggers reject update and delete on event rows (same engineering pattern as `order_events`).

### Omitted in 4.2

`delivery_note_handoffs` — redundant with status timestamps and events.

## 6. Document state machine

Statuses: `generated` → `sent` → `acknowledged`. Terminal: `acknowledged`, `voided`.

| Action | Actor | Permission | From | To | Required | Event | Stage |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `create_delivery_note` | Accounts | `delivery_notes.issue` | none | **`draft`** | Verified order; no open DN; `can_work_at_branch`; full line copy; idempotency key | `created` | **4.2B** |
| `generate_delivery_note` | Accounts | `delivery_notes.issue` | `draft` | `generated` | `expected_version`; ≥1 lines; idempotency key | `generated` | **4.2B** |
| `void_delivery_note` | Accounts | `delivery_notes.issue` | `draft` / `generated` / `sent` | `voided` | `expected_version`; reason always required (1–500) | `voided` | **4.2B** |
| `send_delivery_note` | Accounts | `delivery_notes.issue` | `generated` | `sent` | `expected_version`; idempotency key | `sent` | 4.2C |
| `acknowledge_delivery_note` | Godown Manager | `delivery_notes.acknowledge` | `sent` | `acknowledged` | `expected_version`; `can_work_at_branch(dn.branch_id)`; idempotency key | `acknowledged` | 4.2C |

Invalid transitions raise `delivery note cannot change from <status> to <target>` (`23514`). Unauthorized callers raise `not authorized` (`42501`). Version mismatch raises `delivery note was changed by someone else` (`40001`).

**Engineering.** Idempotency replay returns the current DN payload and writes nothing when the key and action fingerprint match.

### Interaction with Phase 4.1 orders

- Create requires `orders.status = 'verified'`.
- Order status is **not** updated by DN RPCs.
- If the order is `cancelled` before create, create is rejected.
- **4.2B `cancel_order` guard (forward-only replace):** any active (non-voided) DN must be voided first (separate action; no auto-void). Acknowledged DN blocks cancel with a distinct error. Lock order: order `FOR UPDATE`, then open DN `FOR UPDATE`.

## 7. Role permissions

Existing catalog (do not invent grants that contradict `docs/access-control.md`):

| Permission | Admin | Accounts | Godown Mgr | Sales | Delivery | Store Keeper |
| --- | --- | --- | --- | --- | --- | --- |
| `delivery_notes.issue` | | yes (existing) | | | | |
| `delivery_notes.acknowledge` | | | **add** | | | |
| Read via list/get RPCs + RLS | `operations.monitor` | issue | acknowledge + branch | no DN mutations | no | no |

Rules:

- Accounts generates and sends delivery notes.
- Godown Manager receives and acknowledges authorized godown handovers only (`can_work_at_branch`).
- Admin with `operations.monitor` may read; Admin does **not** gain DN mutation permissions in 4.2 unless separately approved.
- Do not grant `picking.execute`, `deliveries.assign`, stock write, or expand `orders.*` mutations for this phase.
- Salesperson, Store Keeper, Delivery Person: no DN create/send/ack/void.

## 8. Frontend specification

**4.2B implemented locally.** Reuses shell, StatusBadge, cards, LoadingBlock, and access gates.

Nav `/deliveries` gated with:

`anyPermissions: ["delivery_notes.issue", "delivery_notes.acknowledge", "operations.monitor"]`

| Route | Behavior |
| --- | --- |
| `/deliveries` | Accounts: verified-order queue + DN list filters + Send. Godown Manager: sent inbox default + Acknowledge (4.2C). |
| `/deliveries/new?orderId=` | Accounts create draft (full line copy; no quantity edit). Also linked from verified order detail. |
| `/deliveries/:noteId` | Header, shop, godown, order ref, lines, totals, timeline. Actions: Generate (draft), Send (generated), Acknowledge (sent, GM), Void (draft/generated/sent), Open print (generated+). |
| `/deliveries/:noteId/print` | Print-friendly layout; `@media print`. Blocks official print when company identity is incomplete. |

At **390px**: card lists, stacked full-width actions.

Do not fill overview metrics. Do not invent sample delivery notes on empty screens.

## 9. Printable delivery note

### Required content

- Company identity (see gaps)
- Delivery note number and date
- Shop name, phone, address
- Order number reference
- Fulfilling godown name
- Product SKU, description, requested carton cases
- Total cartons
- Prepared by (Accounts profile name) and generation time
- Sent and acknowledged actors/timestamps when present

### Available from masters today

- `shops.name`, `shops.phone`, `shops.address`
- `branches.name` (godown)
- `products.sku`, `products.name`
- `profiles.full_name`
- Order and delivery note numbers

### Missing (decisions — do not invent)

- Legal company name and registered address
- Tax / GST identifier
- Logo asset
- Signature or seal image fields

**Approved:** official printing requires configured company identity. Do **not** invent values or use an unapproved placeholder as official identity.

### Company identity configuration contract (4.2A findings)

`public.app_configuration` exists and currently stores **only** stock-adjustment keys:

- `stock.adjustment.exceptional_absolute_units`
- `stock.adjustment.exceptional_requires_admin`

There are **no** `company.*` keys today. Select policy is limited to adjustment/monitor roles — a future print path that needs identity may require a dedicated read grant or SECURITY DEFINER helper (propose before expanding RLS).

**Proposed keys (not seeded in 4.2A — propose before expanding schema silently):**

| Key | Purpose | Mandatory for official print? |
| --- | --- | --- |
| `company.legal_name` | Legal / display name on DN header | Yes |
| `company.registered_address` | Registered address block | Yes |
| `company.tax_id` | Tax / GST identifier where applicable | Yes if jurisdiction requires it on DN |
| `company.logo_storage_path` | Logo asset reference | Optional until design requires logo |
| `company.signatory_storage_path` | Authorized signatory / seal reference | Optional until BPM invoice stage |

**Print readiness check (future route):** refuse official print and surface a clear “company identity not configured” error when any mandatory key is missing or empty. Do not fall back to a fictional brand string.

## 10. Database and API design

### Security

- RLS enabled and forced on `delivery_notes`, `delivery_note_lines`, `delivery_note_events`.
- `authenticated`: select-only where policies allow. No client insert/update/delete policies.
- Mutations only through `SECURITY DEFINER` RPCs with `set search_path = ''`.
- Revoke execute from `anon` / `public` as with order RPCs.

### RPCs

| RPC | Stage | Purpose |
| --- | --- | --- |
| `list_delivery_notes(status, shop, branch)` | **4.2A** | Filtered list with branch visibility |
| `get_delivery_note(id)` | **4.2A** | Header, lines, order ref, shop, godown, events |
| `list_verified_orders_without_dn()` | **4.2A** | Accounts queue of verified orders with no open DN |
| `create_delivery_note(order, key)` | **4.2B** | Snapshot lines; status **`draft`** |
| `generate_delivery_note(note, version, key)` | **4.2B** | `draft` → `generated` |
| `void_delivery_note(note, version, reason, key)` | **4.2B** | draft/generated/sent → `voided` |
| `get_company_print_identity()` | **4.2B** | Non-secret company identity; `ready` flag |
| `get_delivery_note_print(note)` | **4.2B** | Print payload; `print_ready` requires identity |
| `cancel_order(...)` | **4.2B guard** | Forward-only replace; active DN blocks cancel |
| `send_delivery_note` | 4.2C | `generated` → `sent` |
| `acknowledge_delivery_note` | 4.2C | `sent` → `acknowledged` |

### Transaction / lock order

1. Resolve idempotency key; return replay if matched.
2. `SELECT … FOR UPDATE` on the order row; assert `verified`.
3. Assert no open (non-voided) DN when creating.
4. `SELECT … FOR UPDATE` on the DN row when mutating.
5. Compare `expected_version`.
6. Apply one allowed transition; insert one event; bump version.
7. Commit.

Do **not** lock `stock_balances`, `stock_ledger`, or Phase 3 tables. Do **not** insert ledger rows.

### Indexes

- `delivery_notes (status, created_at desc)`
- `delivery_notes (branch_id, status)` for GM inbox
- `delivery_notes (order_id)` plus partial unique for open DN
- `delivery_note_events (delivery_note_id, created_at)`

## 11. Test plan (4.2D)

### Authorization

- Accounts: create, send, void allowed; acknowledge denied.
- Godown Manager: acknowledge on assigned godown allowed; create/send denied; cross-godown acknowledge denied.
- Salesperson, Store Keeper, Delivery Person, Admin (without monitor-only read): mutations denied.
- Direct table insert/update/delete denied for `authenticated`.

### Business rules

- Create rejected unless order `verified`.
- Second open DN for same order rejected.
- Void of `acknowledged` rejected.
- Void of `sent` requires reason.
- Create after order cancel rejected.

### Concurrency and idempotency

- Duplicate create with same key: one insert, replay returns same DN.
- Dual send / dual acknowledge: one winner; loser transition or version error.
- Send versus void: serialized; one outcome.
- Create versus Accounts order cancel: lock order determines winner; loser consistent with signed cancel policy.

### Integrity

- Append-only events (update/delete fail).
- Ledger row count unchanged across DN RPCs.
- Forced RLS remains on.

### Browser

- Accounts: verified queue → generate → print → send → timeline.
- Godown Manager: sent inbox → acknowledge.
- Unauthorized route access denied.
- Session refresh.
- Mobile viewport 390px.

## 12. Implementation stages and stop conditions

1. **4.2A** — migration local only; SQL tests for schema/RLS/grants. Stop: any stock write or order status mutation from DN code.
2. **4.2B** — create/void/print path. Stop: editable quantities or partial lines without approval.
3. **4.2C** — send and acknowledge. Stop: godown acknowledgement without branch check.
4. **4.2D** — full local QA matrix in section 11.
5. **4.2E** — development deploy and cloud verify only after explicit authorization. No production. No edit of applied migration.

This plan does not authorize any stage by itself.

## 13. Owner decisions (signed for 4.2A)

| # | Decision | Outcome |
| --- | --- | --- |
| 1 | One non-voided DN per order; voided retained for audit. | **Approved** — implemented in schema |
| 2 | `delivery_notes.acknowledge` for Godown Manager only. | **Approved** — implemented |
| 3 | Mandatory `draft`; explicit later `generate_delivery_note`. | **Approved** — schema ready; mutation RPCs deferred |
| 4 | Cancellation consistency (void before cancel for active DN; acknowledged blocks cancel; no silent auto-void). | **Approved** — documented; `cancel_order` guard is a **blocking prerequisite** for 4.2B/4.2C |
| 5 | No official print without configured company identity; no fictional placeholders. | **Approved** — contract documented; no print UI in 4.2A |

**Remaining ambiguity (owner):** whether draft/generated void+cancel may be a single combined workflow RPC, or must stay as separate void-then-cancel steps. Until decided, implement conservative void-first guards only.

## 14. Readiness

**Phase 4.2A–4.2D — LOCAL COMPLETE (verified).**  
**Phase 4.2E — DEVELOPMENT DEPLOYED AND VERIFIED** on `ypkfondrkhkydkgovwup` (2026-10-17).

### State machine (complete for 4.2)

- Happy path: `draft` → `generated` → `sent` → `acknowledged`
- Void: `draft` | `generated` | `sent` → `voided`
- Terminal: `acknowledged`, `voided`
- No inventory movement on send or acknowledge

### Permissions

| Action | Actor | Permission |
| --- | --- | --- |
| Create / generate / send / void | Accounts | `delivery_notes.issue` |
| Acknowledge | Godown Manager (assigned fulfilling godown) | `delivery_notes.acknowledge` |
| Admin | Monitor read only | `operations.monitor` — no mutations |
| Salesperson / Store Keeper / Delivery Person / inactive | Denied | — |

### Phase 4.2D QA summary (2026-10-17)

| Area | Result |
| --- | --- |
| Schema/RLS/FORCE RLS / SELECT-only grants | PASS |
| SECURITY DEFINER + empty `search_path`; PUBLIC/anon EXECUTE revoked | PASS |
| Cancel guard (void-first; ack blocks cancel/void) | PASS |
| Idempotency + concurrency (4.2B/4.2C + prior suites) | PASS |
| Inventory unchanged by DN RPCs; append-only triggers on | PASS |
| Phase 2C–4.2 SQL regressions | PASS |
| typecheck / lint / test / build; local db lint / advisors | PASS |
| Authenticated browser (create→generate→print→send→ack; voids; gates) | PASS |
| Print identity gating + void/draft not printable | PASS |
| 390px no horizontal overflow | PASS |
| SPA soft-nav lag / access-loading flicker | NON-BLOCKING (documented) |

### SPA navigation findings (4.2D)

- **Reproduction:** click sidebar `NavLink` (e.g. Overview → Deliveries). URL updates immediately; page content can lag briefly (~1–2s) before settling.
- **Hard reload:** briefly shows only unpermissioned nav items while `useAccess` is loading (`loading` hides permissioned links), then full nav appears.
- **Pre-existing:** yes — access loading filter in `SidebarNav` / `useAccess`; not introduced by DN feature code.
- **Stale auth/DN:** does **not** leave incorrect authorization once access query completes. Hard refresh resolves intermediate UI. Fixture reseed with an old JWT shows empty permissions until re-login (QA hygiene, not a product defect).
- **Classification:** not a Phase 4.2 deployment blocker. Proposed polish (authorization required before coding): keep prior nav visible while access loads; invalidate DN queries on window focus.

### Remaining risks before/after 4.2E

- Company print identity must be configured on development (`company.legal_name`, `company.registered_address`); optional `company.tax_id`.
- Forward-only `cancel_order` replace ships with 4.2B migration — irreversible in the sense that cloud apply advances history; backup before push.
- Phase 4.1E adjustment-versus-verify inventory race remains an acknowledged unverified gap (unchanged by 4.2).

### Cloud (Phase 4.2E)

- Development `ypkfondrkhkydkgovwup` ends at `20261018140000_delivery_note_handover.sql` (also `20261018120000`, `20261018130000`).
- Pre-deploy backup: `C:\Users\Hash\Desktop\Hashdev\sherlyos-recovery\phase-4-2e\` (logical dumps; restore not drill-tested).
- Cloud JWT + browser verification passed; ledger row count remained 23; company print identity still unconfigured (`print_ready=false`).
- Labeled `phase42e.cloud.*` fixtures retained. Production not touched. No git commit/push.
