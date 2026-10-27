# M6.2 — Stock refill request lifecycle and Admin approval

Local-only implementation of PDF Branch 05 REF-01–REF-04. Supplier replenishment request and Admin decision. **Approval is not a stock receipt.** No Git push, cloud migration, Netlify deploy, flag flip, or M6.3 work.

Owner-approved decisions applied here:

1. FMCG supplier replenishment, not internal transfer/picking/dispatch.
2. Brand identity is existing `supplier_id`.
3. Destination godown is mandatory on each request.
4. Accounts identifies demand manually. No reorder-level schema.
5. Held requests may be edited and resubmitted. Rejected requests are terminal.
6. Queue access is Accounts (`refill.request`) and Admin (`refill.approve`) only. `operations.monitor` is not a refill grant.

## 1. State machine

```
draft → submitted → approved
                 ↘ held → submitted
                 ↘ rejected (terminal)
```

| From | To | Actor | RPC |
| --- | --- | --- | --- |
| (none) | `draft` | Accounts creator | `create_stock_refill_request` |
| `draft` / `held` | same | Accounts creator | `update_stock_refill_request` |
| `draft` | `submitted` | Accounts creator | `submit_stock_refill_request` |
| `held` | `submitted` | Accounts creator | `submit_stock_refill_request` (event `resubmitted`) |
| `submitted` | `approved` | Admin | `approve_stock_refill_request` |
| `submitted` | `held` | Admin | `hold_stock_refill_request` (reason required) |
| `submitted` | `rejected` | Admin | `reject_stock_refill_request` (reason required) |

Illegal in M6.2: `approved` → any; `rejected` → any; `submitted` → `draft`; Admin create/edit/submit; non-creator edit/submit; `sent_to_supplier` (M6.3).

Approved is immutable. It does not create a supplier order, receipt, reservation, hold, or ledger row.

## 2. Permission matrix

| Action | Accounts `refill.request` | Admin `refill.approve` | Godown / Sales / monitor-only |
| --- | --- | --- | --- |
| List / get assigned godown | Yes, assignment including inactive | Yes, `branches.access_all` or assignment | No |
| Create / edit / submit / resubmit | Creator only; destination must be an assigned **active** godown | No | No |
| Approve | No | Yes; destination must be active | No |
| Hold / reject | No | Yes; reason required; active godown not required | No |
| Direct table write | No | No | No |

Historical SELECT keeps `user_branch_assignments` even after a godown is deactivated. Operational create/update/submit/approve still call `assert_operational_active_branch` (row lock + `can_work_at_branch` + `is_active`).

## 3. RPC signatures

Trusted `SECURITY DEFINER`, `search_path = ''`, execute granted to `authenticated` only.

| RPC | Arguments | Result |
| --- | --- | --- |
| `create_stock_refill_request` | `target_supplier uuid, target_godown uuid, request_lines jsonb, idempotency_key text, notes text default null` | request payload jsonb |
| `update_stock_refill_request` | `target_request uuid, expected_version integer, target_supplier uuid, target_godown uuid, request_lines jsonb, notes text default null` | payload |
| `submit_stock_refill_request` | `target_request uuid, expected_version integer, idempotency_key text` | payload |
| `approve_stock_refill_request` | `target_request uuid, expected_version integer, idempotency_key text, decision_reason text default null` | payload |
| `hold_stock_refill_request` | `target_request uuid, expected_version integer, decision_reason text, idempotency_key text` | payload |
| `reject_stock_refill_request` | `target_request uuid, expected_version integer, decision_reason text, idempotency_key text` | payload |
| `get_stock_refill_request` | `target_request uuid` | payload |
| `list_stock_refill_requests` | `page integer default 1, page_size integer default 25, status_filter text default null, target_godown uuid default null, target_supplier uuid default null, search_text text default null` | `{ total, page, page_size, items }` |
| `list_stock_refill_options` | none | `{ godowns, suppliers, products }` |

Idempotency: create key + fingerprint; submit/decision key replay of the completed operation. Stale `expected_version` raises `PT409`. Lines must be unique active SKUs of the selected supplier, whole cases 1–1_000_000. Numbering `RF-YYYYMMDD-######`.

Write guard GUC `app.refill_write` (transaction-local). FORCE RLS on header, lines, events. Authenticated SELECT only.

Lock order: request header `FOR UPDATE`, then optional branch lock via `assert_operational_active_branch`. Create also takes `pg_advisory_xact_lock(88106220, hashtext(key))`. **No** product/location/stock grain locks.

## 4. Stock contract

Every M6.2 mutation has **zero** stock effects:

- no `stock_balances` / `stock_ledger` / `stock_transactions` writes
- no `stock_lots` / `stock_lot_balances`
- no `stock_reservations` or `damage_stock_holds`
- no receiving, picking, or dispatch postings

Accepted inventory is posted only by the existing Branch 03 `verify_stock_receipt` path. M6.3 may later mark an approved request as sent to the supplier. M6.2 does not.

Flags remain false:

- `damage.stock_hold_ready=false`
- `stock.lots.dual_write_enabled=false`
- `stock.lots.aggregate_only_blocked=false`

## 5. Frontend

| Route | Guard | Screen |
| --- | --- | --- |
| `/refill` | `refill.request` or `refill.approve` | Queue |
| `/refill/new` | `refill.request` | Create draft |
| `/refill/:requestId/edit` | `refill.request` | Edit draft/held (creator) |
| `/refill/:requestId` | `refill.request` or `refill.approve` | Detail, submit/resubmit, Admin decide |

Nav label **Refill**. Copy states that Admin approval is not a stock receipt. Accounts never sees Approve/Hold/Reject. Admin never sees New request / Edit / Submit. Mutations set `retry: false`. Create keeps a sessionStorage idempotency key until success so a lost HTTP response can be retried by the same actor without opening a second tab.

## 6. Tests

| Suite | File |
| --- | --- |
| SQL | `supabase/tests/phase_m6_2_refill_request_lifecycle.sql` |
| HTTP | `supabase/tests/phase_m6_2_http_integration.mjs` |
| Concurrency | `supabase/tests/phase_m6_2_concurrency.mjs` |
| Vitest | `tests/unit/refill.test.ts`, `tests/unit/refill-pages.test.tsx` |
| Playwright | `tests/e2e/refill-request-lifecycle.spec.ts` |

Disposable SKU prefix `m62%`.

## 7. Final security review

### RLS helper

`app_private.can_view_refill_at_godown(uuid)` is `SECURITY DEFINER` with `search_path = ''`. It returns a boolean from `auth.uid()`, `refill.request` / `refill.approve`, `branches.access_all`, and `user_branch_assignments`. It does not read request lines or notes.

`GRANT EXECUTE` to `authenticated` is required so FORCE RLS `USING` expressions can evaluate, matching `can_view_damage_report` / `can_view_order`. `anon`, `public`, and `service_role` stay revoked. Direct callers only learn whether *they* may view refill at a godown UUID; they cannot impersonate another user. Private mutation helpers (`enable_refill_write`, `replace_refill_lines`, `record_refill_event`) remain revoked.

Permission and assignment changes take effect on the next statement. `operations.monitor` granted to salesperson still cannot list. Cross-godown Accounts cannot `GET`. Inactive godown historical `GET` remains; submit/approve fail closed.

### Concurrent create idempotency

Original create selected by key then inserted. Concurrent identical-key inserts could unique-violate without completed-operation recovery, and a second Accounts user on the same godown could replay a key and receive the original payload.

Forward-only `20261027133000_stock_refill_create_idempotency.sql` (local Docker applied):

- Same-key creates take a transaction advisory lock.
- Unique-violation recovery re-selects the row and runs the same completed-operation path.
- Replay authorizes **creator + current view** before comparing fingerprints, so a foreign actor always gets `42501` and cannot distinguish a fingerprint mismatch.
- Same actor, matching fingerprint, returns the original payload (lost-response recovery).
- Same actor, conflicting fingerprint, `23505`.
- Unique `(idempotency_key)` remains the persistence safety net.
- Submit replay also requires `created_by = auth.uid()`.

Proven: one persisted request, one `created` event, no duplicate numbers, no cross-actor disclosure, no silent conflicting payload, current auth on replay, zero stock.

### Receiving harness

`phase_3_1_stock_receiving.sql` assumed an empty database (`bootstrap_initial_admin` fails when an admin already exists) and a globally matching balance/ledger pair. Later disposable suites seed replica balances for zero-stock proofs.

Test-only changes, no bootstrap or receiving writer edits:

1. Repeatable admin fixture (same `42501` handler as M5 SQL).
2. Ledger mismatch / negative checks scoped to this file’s `refs` crates and products.

After those harness fixes the suite rolls back successfully. M5.3 isolation SQL, which posts through `verify_stock_receipt`, also passed. Production bootstrap authorization was not changed.

### Zero-stock-effect proofs

SQL, HTTP, concurrency, and Playwright snapshots of `stock_transactions`, `stock_ledger`, `stock_balances`, lots, reservations, holds, and receipts were unchanged across create, update, submit, hold, resubmit, approve, and reject.

## 8. Final test evidence (this review)

| Suite | First pass | Final |
| --- | --- | --- |
| M6.2 SQL | Passed after review SQL additions | Passed |
| M6.2 HTTP | 16 passed | 16 passed |
| M6.2 concurrency | 16 passed (create races included) | 16 passed |
| `phase_3_1_stock_receiving.sql` | Failed: existing admin, then global ledger mismatch from leftover disposable replica balances | Passed after test-only harness scoping |
| M5.3 damage stock isolation | Passed | Passed |
| Vitest | 32 files / 194 tests passed | 194 passed |
| Playwright | 75 passed | 75 passed |
| Typecheck / lint / production build | Passed (pre-existing oxlint warnings only) | Passed |

Flags after all runs remain false.

## 9. Remaining limitations

- Development cloud and production are not migrated.
- Replica-seeded disposable balances can still exist on the shared local Docker database; they are not operational stock.
- Advisory-lock hash collisions could serialize unrelated creates; uniqueness still prevents duplicate keys.
- M6.2 does not send a supplier order or link receipts.

## 10. M6.3 handoff

Out of scope and not started:

- REF-05 send approved request to the FMCG supplier
- REF-06 supplier dispatch tracking
- REF-07 optional `stock_receipts.refill_request_id`
- Any stock writer, hold, reservation, or new ledger type

Do not begin M6.3 without owner approval. Do not treat Admin approval as receiving.
