# Phase 4.1 shop orders specification

PHASE 4.1A–4.1D: LOCAL READY.

PHASE 4.1E — DEVELOPMENT DEPLOYED AND VERIFIED on `ypkfondrkhkydkgovwup` (2026-10-17). Production not deployed. Cloud test users/orders retained. Adjustment-versus-verify race unverified. Git commit/push checkpoint pending user approval.

PHASE 4.1C — AVAILABILITY RULE A APPROVED.

When `verify_order` detects `shortfall_cases > 0` for any order line: reject verification; keep status `submitted`; do not increment version; do not write a verification-success event or accepted verification snapshot; do not change inventory; return actionable shortage details; allow Accounts to invoke `hold_order` separately. Do not auto-hold. Do not verify with shortages.

This is the implementation contract for Phase 4.1. It does not authorize a migration, a screen, a commit, or a deployment by itself. The next implementation task must follow the stages in section 10.

Repository `main` at `af754f9a9ec463e4f343cbb85994be968c7b851e`. Development project `ypkfondrkhkydkgovwup`. Latest development migration `20261016200000_stock_adjustment_approval.sql`.

Labels used below:

- **BPM** — stated in `reference/Sherlys_Distribution_Agents_BPM.pdf` v1.0.
- **Approved** — one of the twelve decisions. Do not reopen it.
- **Engineering** — a technical choice made so the approved rules can be built. It is not a new business policy.

## 1. Scope

**Approved.** Phase 4.1 includes order capture, submission, Accounts verification, hold, correction, and cancellation.

Included:

- Draft create and edit.
- Submit, hold, creator correction, and resubmit.
- Accounts verification of a submitted order.
- Creator cancellation of a draft or held order.
- Accounts cancellation of a submitted or verified order.
- An availability read used during verification.
- Append-only order events.

Excluded:

- Delivery notes, invoice notes, and signed invoices (ORD-03, ORD-07, ORD-08).
- Picking, crate allocation, vehicles, and delivery assignment (ORD-04 through ORD-06).
- Shop delivery outcome and failed delivery (ORD-09).
- Short picks and partial fulfilment.
- Prices, discounts, taxes, and invoice totals.
- Batch and expiry tracking.
- Damage and returns.
- Any insert into `stock_transactions`, `stock_ledger`, or `stock_balances`.
- Any change to receiving, daily verification, adjustment, transfer, or opening-stock functions.

## 2. BPM mapping

| Flow | BPM statement | Phase 4.1 |
| --- | --- | --- |
| ORD-01 | Receive a product order from a shop through a Salesperson, Accounts, telecalling, or enquiry. | In scope. |
| ORD-02 | Accounts verifies the shop request and availability, and holds an invalid request for correction. | In scope, except the unresolved short-stock outcome in section 6. |
| ORD-03 | Accounts generates a delivery note for approved requested products. | Future. Permission `delivery_notes.issue` already exists and is unused. |
| ORD-04 | Pass the delivery note to the Godown Manager. | Future. |
| ORD-05 | Pick by expiry and first-in receipt sequence. | Future. Blocked until batch and expiry data exist. **Approved.** |
| ORD-06 | Assign a vehicle and a Delivery Person. | Future. No vehicle master exists. |
| ORD-07 | Invoice note from goods actually loaded. | Future. This is where a short load would surface. **Approved** to defer. |
| ORD-08 | Accounts signs or seals the final invoice and hands it to the Delivery Person. | Future. No amounts in 4.1. |
| ORD-09 | Deliver to the shop and record the outcome. | Future delivery-outcome workflow. |

**BPM.** The later document sequence stays delivery note, then invoice note, then signed or sealed final invoice. Phase 4.1 stores none of those documents.

**BPM.** If verification fails, Accounts returns the request for correction. In this model that return is `submitted` to `held`, not a second order.

## 3. Order state machine

Statuses: `draft`, `submitted`, `held`, `verified`, `cancelled`.

`cancelled` is terminal. No function may leave it.

A `held` order cannot become `verified`. The creator resubmits it to `submitted` first. **Engineering**, matching the approved correction flow. A later approval would be required to skip that resubmit.

The original creator is `orders.created_by`, set on insert and never updated. Line edits, resubmit, and creator cancellation must use that column. `order_events.actor_id` records who performed each later action. Those actors do not replace `created_by`.

Every mutation takes `expected_version` and an idempotency key. The key shape is the existing `app_private.clean_idempotency_key` rule: 8 to 80 letters, numbers, underscores, or hyphens.

Replay of a key already stored for the same order and the same action returns the current order payload and writes nothing. A key reused for a different order, or the same key with a different action fingerprint, raises `idempotency key does not match the original request` (`23514`).

A version mismatch raises `order was changed by someone else` (`40001`). The client refetches.

Unauthorized callers raise `not authorized` (`42501`), including an inactive profile, because `has_permission` already requires `profiles.is_active`.

| Action | Actor | Permission | From | To | Required fields | Event |
| --- | --- | --- | --- | --- | --- | --- |
| `create_order` | Salesperson or Accounts | `orders.capture` | none | `draft` | active shop, authorized active godown, source, at least one active product line, idempotency key | `created` |
| `set_order` | `created_by` | `orders.capture` | `draft` or `held` | same status | `expected_version`, shop, godown, source, lines | `lines_revised` |
| `submit_order` | `created_by` | `orders.capture` | `draft` or `held` | `submitted` | `expected_version`, at least one line, shop, products, and godown still valid | `submitted` |
| `hold_order` | Accounts | `orders.verify` | `submitted` | `held` | `expected_version`, non-empty hold note | `held` |
| `verify_order` | Accounts, including `created_by` | `orders.verify` | `submitted` | `verified` | `expected_version`. Availability Rule A: any shortfall rejects and leaves `submitted`. | `verified` |
| `cancel_order` by creator | `created_by` | `orders.capture` | `draft` or `held` | `cancelled` | `expected_version`. Note optional. | `cancelled` |
| `cancel_order` by Accounts | Accounts | `orders.verify` | `submitted` or `verified` | `cancelled` | `expected_version`, non-empty reason | `cancelled` |

Invalid transitions raise `order cannot change from <status> to <target>` (`23514`). Examples: verify a draft, held, verified, or cancelled order; hold a draft; creator cancel of a submitted or verified order; Accounts cancel of a draft or held order; any change after `cancelled`; a second verify.

Hold note and the Accounts cancellation reason are trimmed and must be 1 to 500 characters. **Engineering** for the hold note, so correction has a recorded reason. **Approved** for the Accounts cancellation reason.

`submit_order` does not read stock. Availability is an Accounts action at verification. **Engineering**, because ORD-02 assigns availability to Accounts.

### Required flows

1. Create draft. `created_by` is the caller. `version` is 1.
2. Edit draft through `set_order`. Status stays `draft`. `version` increases by 1.
3. Submit draft. Status becomes `submitted`. `submitted_at` and `submitted_by` are set.
4. Accounts holds that submitted order. Status becomes `held`. `held_at` and `held_by` are set. The hold note is the event note.
5. Creator corrects the held order through `set_order`. Status stays `held`.
6. Creator resubmits. Status becomes `submitted` again. `submitted_at` and `submitted_by` update. `held_at` remains historical. The event history keeps the hold.
7. Accounts verifies a submitted order. Status becomes `verified`. `verified_at` and `verified_by` are set. Self-verification is allowed. **Approved.**
8. Creator cancels a draft or a held order.
9. Accounts cancels a submitted or verified order with a reason.

Each successful call inserts one `order_events` row in the same transaction as the status or line change, then increments `version`.

## 4. Database design

Proposed migration name, not created by this document: `supabase/migrations/20261017120000_shop_orders.sql`. It is written only when Phase 4.1A is authorized. It is not pushed until Phase 4.1E.

No allocation table. No reservation table. No price or tax column. No change to `stock_transactions_type_check`.

### `orders`

| Column | Type | Null | Default | Rules |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | no | `gen_random_uuid()` | Primary key. |
| `order_number` | `text` | no | none | Unique. Database-issued. Format `SO-YYYYMMDD-` plus 6 digits from `shop_order_seq`. **Engineering.** |
| `shop_id` | `uuid` | no | none | FK `shops(id)` `on delete restrict`. |
| `branch_id` | `uuid` | no | none | FK `branches(id)` `on delete restrict`. Fulfilling godown. |
| `source` | `text` | no | none | Check: `salesperson`, `accounts`, `telecalling`, `enquiry`. |
| `source_reference` | `text` | yes | null | Optional. Trimmed, 1–80 characters when present. |
| `notes` | `text` | yes | null | Optional order notes. Trimmed, 1–500 characters when present. |
| `created_by` | `uuid` | no | none | FK `profiles(id)` `on delete restrict`. Immutable. |
| `status` | `text` | no | `'draft'` | Check: `draft`, `submitted`, `held`, `verified`, `cancelled`. |
| `version` | `integer` | no | `1` | Check `version >= 1`. |
| `idempotency_key` | `text` | no | none | Unique. Create-request key. |
| `submitted_at` | `timestamptz` | yes | null | Set when status becomes `submitted`. |
| `submitted_by` | `uuid` | yes | null | FK `profiles(id)` `on delete restrict`. |
| `verified_at` | `timestamptz` | yes | null | Set only by `verify_order`. |
| `verified_by` | `uuid` | yes | null | FK `profiles(id)` `on delete restrict`. |
| `held_at` | `timestamptz` | yes | null | Set by `hold_order`. Kept after resubmit. |
| `held_by` | `uuid` | yes | null | FK `profiles(id)` `on delete restrict`. |
| `cancelled_at` | `timestamptz` | yes | null | Required when status is `cancelled`. |
| `cancelled_by` | `uuid` | yes | null | FK `profiles(id)` `on delete restrict`. Required when cancelled. |
| `cancellation_reason` | `text` | yes | null | Required for an Accounts cancellation. Optional for a creator cancellation. |
| `created_at` | `timestamptz` | no | `pg_catalog.now()` | |
| `updated_at` | `timestamptz` | no | `pg_catalog.now()` | Trigger `set_updated_at` on update. |

Checks:

- `submitted` requires `submitted_at` and `submitted_by`.
- `verified` requires `verified_at` and `verified_by`.
- `cancelled` requires `cancelled_at` and `cancelled_by`.
- `draft` that has never been submitted has null submission columns. A row that was held and not yet resubmitted may still hold the previous `submitted_at`.
- Same shop may place many orders on the same day. Uniqueness is `order_number` and `idempotency_key` only.

Indexes: unique `order_number`, unique `idempotency_key`, `(status, created_at desc)`, `shop_id`, `branch_id`, `created_by`.

`created_by` has no update path. `set_order` updates shop, godown, source, reference, notes, and lines only.

### `order_lines`

| Column | Type | Null | Default | Rules |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | no | `gen_random_uuid()` | Primary key. |
| `order_id` | `uuid` | no | none | FK `orders(id)` `on delete restrict`. |
| `product_id` | `uuid` | no | none | FK `products(id)` `on delete restrict`. |
| `requested_cases` | `integer` | no | none | Check `requested_cases between 1 and 1000000`. Whole carton cases. |
| `created_at` | `timestamptz` | no | `pg_catalog.now()` | Replaced rows receive a new id. |

Unique `(order_id, product_id)`. Index on `order_id`.

`set_order` deletes and reinserts that order’s lines inside the locked transaction. Line delete is allowed only through that function, by a security-definer owner, not by a client grant. The event row preserves the prior line list in `line_snapshot`.

### `order_events`

| Column | Type | Null | Default | Rules |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | no | `gen_random_uuid()` | Primary key. |
| `order_id` | `uuid` | no | none | FK `orders(id)` `on delete restrict`. |
| `event_type` | `text` | no | none | Check: `created`, `lines_revised`, `submitted`, `held`, `verified`, `cancelled`. |
| `from_status` | `text` | yes | null | Null on `created`. |
| `to_status` | `text` | no | none | Status after the action. |
| `actor_id` | `uuid` | no | none | Caller. Not a foreign key, matching `audit_logs`, so a later profile delete cannot rewrite history. |
| `note` | `text` | yes | null | Hold note, cancellation reason, or optional creator note. |
| `version` | `integer` | no | none | Order version after the action. |
| `idempotency_key` | `text` | no | none | Unique across all events. |
| `line_snapshot` | `jsonb` | no | `'[]'` | Product id and requested cases after the action. |
| `availability_snapshot` | `jsonb` | yes | null | Set only on `verified`. Product id, requested cases, on-hand cases. |
| `created_at` | `timestamptz` | no | `clock_timestamp()` | |

Before update or delete, trigger `order_events_append_only` raises `order history is append-only` (`42501`).

Index `(order_id, created_at)`.

### Number sequence

`shop_order_seq` is an owned sequence. `nextval` is not rolled back. A failed insert may skip a number. That matches adjustment numbers and is not reused.

## 5. Security and authorization

Inspected grants and helpers:

- `orders.capture` is already granted to Accounts and Salesperson.
- `orders.verify` is already granted to Accounts only.
- `operations.monitor` is already granted to Admin only.
- `shops.read` is Admin and Salesperson. The live policy `shops_select_authorized` in `20261015120000_master_data_access.sql` shows a shop only when the caller has `shops.read` and either `shops.assign` or an active `shop_salesperson_assignments` row. Granting `shops.read` to Accounts would not show all shops.
- `shops.assign` is Admin only. Do not grant it to Accounts. It also assigns salespeople.
- `products.read` and `products.manage` are Admin and Godown Manager. `products_select_readers` returns every product, including inactive, to anyone with `products.read`.
- `product_categories` select also uses `products.read`.
- `stock.read` is already Admin, Accounts, Godown Manager, and Store Keeper. Balance selects are limited to crates in a godown where `can_work_at_branch` is true. Salesperson and Delivery Person do not have `stock.read`.
- `can_work_at_branch` is true for `branches.access_all` or an assignment to that active branch. Accounts and Salesperson do not have `branches.access_all`.
- `has_permission` requires an active profile.

### Permission changes

| Change | Who | Why |
| --- | --- | --- |
| Grant existing `products.read` | Accounts, Salesperson | **Approved** active catalog read. |
| Add `shops.read_all` | Accounts | **Approved** all active shops. Description: view every active shop, without shop assignment rights. |
| Grant existing `shops.read` | Accounts | Required by the current shop policy shape together with `shops.read_all`. |
| No grant | Salesperson `stock.read` | **Approved.** |
| No new `stock.read` grant | Accounts | Already held. Do not widen the stock policies. |
| No order grant | Admin, Godown Manager, Store Keeper, Delivery Person | Admin uses `operations.monitor` to read. |

### Policy changes

Shops, replace the `shops.assign` branch with an additional branch, and keep the assignment branch:

- `shops.read` and `shops.assign`: existing Admin path, including inactive shops.
- `shops.read` and an active assignment: existing Salesperson path.
- `shops.read` and `shops.read_all` and `shops.is_active`: Accounts path.

Products, replace `products_select_readers`:

- `products.manage`: Admin and Godown Manager still see inactive products.
- `products.read` and `products.is_active`: Accounts and Salesperson see the active catalog.

Do not change the category policy in this phase. Granting `products.read` also reveals category rows. That is existing coupling, not stock visibility.

### Order RLS

Enable and force RLS on `orders`, `order_lines`, and `order_events`. `authenticated` receives select only. No insert, update, or delete policies. Revoke table writes from `anon` and `authenticated`.

`orders` select when any of these is true:

- `operations.monitor`.
- `orders.verify` and `can_work_at_branch(branch_id)`.
- `orders.capture` and `created_by = auth.uid()`.

Lines and events are visible when the parent order is visible.

### RPC boundary

All functions are `SECURITY DEFINER`, `search_path = ''`, granted to `authenticated` only after `revoke all` from `public` and `anon`.

| Function | Rule |
| --- | --- |
| `create_order` | `orders.capture`. Salesperson: active assignment on the shop. Accounts: active shop through `shops.read_all`. Both: `can_work_at_branch`. Active products. |
| `set_order` | Caller is `created_by` and still has `orders.capture`. Same shop and godown checks. |
| `submit_order` | Caller is `created_by`. Re-checks shop, products, and godown. Does not read balances. |
| `hold_order` | `orders.verify` and `can_work_at_branch`. |
| `verify_order` | `orders.verify` and `can_work_at_branch`. Caller may be `created_by`. |
| `cancel_order` | Creator path or Accounts path from the matrix. |
| `list_orders` / `get_order` | Same visibility as the select policy. |
| `check_order_availability` | Section 6. |

Inactive shop, inactive product, inactive godown, missing assignment, and a salesperson naming an unassigned shop raise `not authorized` or `shop is not active`, `product is not active`, `godown is not authorized` (`23514` for the data checks, `42501` for permission).

Direct inserts into the three tables raise permission denied.

Admin can read orders and cannot create, hold, verify, or cancel them.

## 6. Availability

**Approved.** Verification checks current availability and does not reserve or deduct inventory.

**Engineering.** On-hand cases for a product at a godown are the sum of `stock_balances.quantity` for that product in crates whose zone belongs to `orders.branch_id`. Missing balance rows count as zero. Other products and other godowns are not returned.

`check_order_availability(target_order uuid)` returns one row per current line:

- `product_id`
- `requested_cases`
- `on_hand_cases`
- `shortfall_cases` as `greatest(requested_cases - on_hand_cases, 0)`

It requires `orders.verify` and `can_work_at_branch` for that order. It validates the shop is active and each line product is active. It writes nothing. It does not lock `stock_balances`, so a receipt, transfer, or adjustment can commit beside it.

`verify_order` repeats that read after `select … for update` on the order row and stores it in `availability_snapshot`. It still does not lock stock rows and does not insert a ledger row.

A zero-stock product returns `on_hand_cases = 0` and a shortfall equal to the request. Concurrent verified orders can each see the same on-hand quantity. Stock can change immediately after verification. That is the approved no-reservation rule.

Receiving, transfers, and adjustments continue to change on-hand through their existing functions. Phase 4.1 does not call or edit them.

### Availability Rule A — APPROVED

When `verify_order` runs and any line has `shortfall_cases > 0`:

1. Reject verification.
2. Keep order status as `submitted`.
3. Do not increment the order version.
4. Do not write a verification-success event.
5. Do not write a verification snapshot as an accepted verification.
6. Do not change inventory.
7. Return actionable shortage information to Accounts.
8. Allow Accounts to separately invoke `hold_order`.

Do not automatically hold the order. Do not allow verification with shortages.

Options B and C are rejected.

## 7. Frontend

No screen is created by this specification. Follow the current React, TypeScript, Tailwind, shadcn, TanStack Query, React Hook Form, and Zod patterns used by adjustments.

Gate `/orders` with `orders.capture`, `orders.verify`, or `operations.monitor`. Hide the nav item unless one of those is held. A direct visit without them shows the existing access-denied page.

| Route | Behavior |
| --- | --- |
| `/orders` | List from `list_orders`. Search by order number and shop name. Filters for status, shop, and godown. Accounts sees a submitted queue by choosing status `submitted`. Empty copy states that orders appear after one is captured. |
| `/orders/new` | `orders.capture` only. Shop, godown, source, optional reference, optional notes, and lines of active products with whole cases. Salesperson shop list is assigned shops. Accounts shop list is active shops. Godown list is sites where `can_work_at_branch` is true. |
| `/orders/:orderId` | Header, lines, address, source, creator, and the event timeline. Draft and held orders show edit for `created_by`. Submitted orders show hold and verify for Accounts, and cancel for Accounts. Draft and held orders show cancel for the creator. Verified orders show Accounts cancel only. |

Edit and correction use the same form as create, bound to `set_order`, and only while status is `draft` or `held`.

Verification shows the availability rows from `check_order_availability` before confirm. The confirm button’s enabled state waits for section 6. Do not treat a shortfall as success or failure in the UI until that decision lands.

Cancellation uses a confirm step. Accounts must enter a reason before the button enables. Creator cancellation may omit a reason.

Loading uses `LoadingBlock`. Failures use `role="alert"` and the server message. Do not invent sample orders.

At 390px the list is cards, the line editor stacks, and hold, verify, and cancel remain on the page without a horizontal scroll.

The overview metrics stay “Not connected”. This phase does not fill them.

## 8. Concurrency and idempotency

Transaction order for every mutation:

1. Resolve the idempotency key. Return the existing result when the replay matches.
2. Lock the order row with `for update` when it already exists.
3. Compare `version` to `expected_version`.
4. Re-read shop, product, and branch activity.
5. Apply the single allowed transition.
6. Insert one event.
7. Commit.

Do not lock `stock_balances`, `stock_ledger`, or receipt, verification, or adjustment rows.

| Race | Result |
| --- | --- |
| Two creates with one key | One insert. The other replay returns that order when the body matches. |
| Two submits | The lock serializes them. The second sees `submitted` and raises the transition error unless it is the same key replay. |
| Two edits | The stale `expected_version` loses with `order was changed by someone else`. |
| Submit versus creator cancel | One lock winner. The loser reads the new status and is rejected. |
| Hold versus verify | Same serialization. Only one of `held` or `verified` commits. |
| Verify versus Accounts cancel | Same serialization. |
| Two Accounts users verify | One `verified` event. The other is a transition error or an idempotent replay. |
| Stock movement during verify | The snapshot is whatever balances are committed at the read. No stock lock. A later receipt can raise on-hand after `verified`. |
| Shop, product, or godown deactivated before submit or verify | The re-check rejects the call. An already verified order is not reopened. |

Phase 3 functions are not modified.

## 9. Test plan

Use disposable development users and a dedicated godown. Do not disable append-only stock triggers. Do not delete posted ledger, receipt, verification, or adjustment history. Deactivate and ban disposable users after a cloud run. Keep order rows that the event trail references.

| Area | Proves |
| --- | --- |
| Role, JWT, RLS | Salesperson and Accounts can call their functions. Godown Manager, Store Keeper, Delivery Person, and Admin cannot create or verify. Admin with `operations.monitor` can read. Direct inserts are denied. Inactive users are denied. |
| Cross-branch | A caller cannot select or save a godown they are not assigned to. |
| Assigned shop | Salesperson cannot order for an unassigned shop. Revocation hides that shop. Historical orders they created remain readable. |
| Catalog | Accounts and Salesperson select active products and do not select inactive products. They do not gain `stock.read`. |
| Accounts shops | Accounts selects every active shop and does not gain `shops.assign`. |
| Transitions | The nine required flows. Held cannot be verified. Cancelled accepts no further action. |
| Self-verification | Accounts verifies an order where `created_by` is themselves. |
| Hold and resubmit | Note required. Correction keeps `held` until submit. |
| Cancellation | Creator blocked on submitted and verified. Accounts blocked on draft and held. Accounts reason required. |
| Idempotency | Same create and submit keys replay. A mismatched body is rejected. |
| Concurrency | Two verifies, hold versus verify, submit versus cancel. |
| Availability | The RPC returns on-hand and shortfall for the order’s godown only. |
| No reservation | After verify, `stock_balances` and `stock_ledger` row counts and quantities are unchanged. |
| Events | Update and delete of `order_events` are rejected. |
| Browser | Each role’s allowed and denied path, server error alert, cancellation confirm. |
| 390px | List, editor, and detail actions fit the viewport. |
| Development cloud | Backup, dry run of the single new migration, then the same role and ledger checks on `ypkfondrkhkydkgovwup`. Production is not a target. |

The short-stock verify cases are written only after section 6 is decided.

## 10. Stages

Do not `db push` until stage 4.1E. One new migration file is completed across 4.1A–4.1C and is not edited after it is applied.

### 4.1A — Database schema and security

Files: the new migration only.

Depends on development history still ending at `20261016200000`, and on this specification.

Acceptance: tables, checks, grants, shop and product policy changes, select policies, `list_orders`, `get_order`, and `check_order_availability`. No stock type change. Local SQL tests for RLS and the availability read.

Stop if the migration needs to alter a Phase 3 function, or if `shops.read` alone is treated as enough for Accounts to see every shop.

### 4.1B — Order capture and editing

Files: the same migration (`create_order`, `set_order`) and `src/features/orders/` list, create, and edit. Router and navigation gates.

Depends on 4.1A.

Acceptance: creator can draft and edit draft or held orders for an authorized shop and godown. Other roles cannot. No status reaches `verified`.

Stop if the UI writes tables directly or queries `stock_balances` for a salesperson.

### 4.1C — Submission, hold, and verification

Files: the same migration (`submit_order`, `hold_order`, `verify_order`, `cancel_order`) and the detail actions.

Depends on 4.1B and on a recorded choice of section 6 option A, B, or C.

Acceptance: the nine flows, terminal cancel, self-verify, and zero ledger writes.

Stop if section 6 is still open. Do not pick A, B, or C inside the migration.

### 4.1D — Browser, concurrency, and regression

Files: `supabase/tests/` order SQL and concurrency scripts, plus targeted UI tests if the repo’s current test style needs them.

Depends on 4.1C.

Acceptance: section 9 matrix passes locally, including an existing Phase 3 SQL suite so ledger behavior is unchanged.

Stop on any ledger row written by an order function, or on a failed append-only trigger test.

### 4.1E — Development deployment and cloud verification

Files: none in the repository unless a cloud defect requires a new forward migration. Do not edit the applied order migration.

Depends on 4.1D, a development backup, and a dry run that lists only the order migration.

Acceptance: remote history ends at the new version, role checks pass, ledger counts match the pre-deploy snapshot plus any unrelated legitimate postings, disposable users are inactive and banned.

Stop on a push error. Do not retry automatically, repair history, or reset the database.

## 11. Readiness

Phase 4.1A–4.1D are LOCAL READY. Phase 4.1C Availability Rule A is approved. Phase 4.1E development deployment and cloud verification completed on `ypkfondrkhkydkgovwup` (migration `20261017120000` applied; JWT/RLS/workflow/Rule A/order concurrency/browser smoke passed). Production deployment has not been performed. Adjustment-versus-verify inventory race remains unverified by design.
