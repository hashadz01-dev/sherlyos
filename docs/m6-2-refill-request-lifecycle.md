# M6.2 — Stock refill request lifecycle and Admin approval

Local-only implementation of PDF Branch 05 REF-01–REF-04. Supplier replenishment request and Admin decision. **Approval is not a stock receipt.** No Git commit, push, cloud migration, Netlify deploy, flag flip, or M6.3 work.

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

Lock order: request header `FOR UPDATE`, then optional branch lock via `assert_operational_active_branch`. **No** product/location/stock grain locks.

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

Nav label **Refill**. Copy states that Admin approval is not a stock receipt. Accounts never sees Approve/Hold/Reject. Admin never sees New request / Edit / Submit.

## 6. Tests

| Suite | File |
| --- | --- |
| SQL | `supabase/tests/phase_m6_2_refill_request_lifecycle.sql` |
| HTTP | `supabase/tests/phase_m6_2_http_integration.mjs` |
| Concurrency | `supabase/tests/phase_m6_2_concurrency.mjs` |
| Vitest | `tests/unit/refill.test.ts`, `tests/unit/refill-pages.test.tsx` |
| Playwright | `tests/e2e/refill-request-lifecycle.spec.ts` |

Disposable SKU prefix `m62%`.

## 7. M6.3 handoff

Out of scope here:

- REF-05 send approved request to the FMCG supplier (`sent_to_supplier` / `mark_stock_refill_sent`)
- REF-06 supplier dispatch tracking
- REF-07 linkage from an approved request to Branch 03 receiving (`stock_receipts.refill_request_id` remains an owner decision)
- Any stock writer, hold, reservation, or ledger type

Do not begin M6.3 without owner approval. Do not treat approval as receiving.
