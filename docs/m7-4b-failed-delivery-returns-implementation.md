# M7.4B — Failed-delivery returns and stock reconciliation

Local-only implementation after M7.4A and the committed M7.4B design. This phase adds one return wave per failed or partial dispatch, driver handback, Store Keeper lot-level count, GM approval, and **one** new stock-credit writer: `post_delivery_return`.

It does **not** change `confirm_dispatch` or `verify_stock_receipt` posting, supplier receiving, invoices, payments, TallyPrime, backorder mutation, M5 report auto-create/close, cloud migration, Netlify deploy, Git commit, or feature-flag activation.

**Development completion is not operational activation.** All operational flags stay false. No production return posting is authorized.

Starting HEAD: `aa5eb0d305bba44e4c81b8eb4d75d39da827c33d`  
`docs(m7.4b): define failed-delivery return stock contract` on `main`.

Working tree was clean at start. M7.4A and the M7.4B design document were committed.

Migration applied locally (Docker only): `20261027240000_failed_delivery_returns_and_stock_reconciliation.sql`.

Flags at start and end (operational values):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`

BPM source: `reference/Sherlys_Distribution_Agents_BPM.pdf` is **not present in this workspace**. BPM statements reuse the committed M7.1 extraction. No missing BPM requirements were invented.

---

## 1. Approved R1–R10 mapping

| Decision | Implementation |
|---|---|
| R1 Original godown only | Receiving crate must belong to `dispatch.branch_id`. Cross-godown crate is `23514`. No transfer workflow. |
| R2 Authorized receiving crate | Saleable → active `storage` crate chosen by Store Keeper. Damaged / uncertain / expired → godown quarantine crate via `ensure_godown_quarantine_crate`. Missing credits nothing. |
| R3 Physical lot allocation | `stock_delivery_return_lots` snapshot original `(order_line, product, lot, source_crate, dispatched_cases)` from shipment lots or consumed reservations, full-joined to the DISPATCH ledger. Keeper counts those grains. Order-line totals are never inferred. |
| R4 Transit-damage overlap | Open transit reports with null `lot_id`, overlapping physical qty on the same lot, or existing damage stock transactions block approval/post. Reports are not closed. |
| R5 Expired lots | `expiry_date < today` (or blocked lot status) cannot be classified saleable. Physical expired/damaged/uncertain credit quarantine only. Product expiry policy unchanged. |
| R6 Separation of duties | Permissions split: `return_handback` (driver), `return_count` (keeper), `return_approve`/`return_post` (GM). Posted/closed-missing shape requires `counted_by is distinct from approved_by/closed_by`. GM cannot count. |
| R7 Single return wave | Unique `stock_delivery_returns.dispatch_id`. Second insert fails. Unresolved qty blocks posting. Missing is explicit, never silent receipt. |
| R8 Backorder independence | Writer does not create, cancel, reserve, or modify backorders. |
| R9 Dedicated stock transaction | Type `DELIVERY_RETURN`, FK `delivery_return_id`, unique `stock_transactions_delivery_return_once`. `dispatch_request_id` stays null on the return txn. |
| R10 Quarantine-only damage credit | Damaged/uncertain increase quarantine on-hand only. No M5 report create/approve/close. `damage.stock_hold_ready` stays false. Related report ids are stored, not acted on. |

---

## 2. Schema changes

Additive local migration after tip `20261027230000`.

- Permissions: `deliveries.return_view|handback|count|approve|post`
- `stock_delivery_returns` (unique dispatch, FORCE RLS, write guard `app.delivery_return_write`)
- `stock_delivery_return_lots` (original grain + keeper allocation + optional `posted_crate_id`)
- `stock_delivery_return_events` (immutable inserts)
- `stock_transactions.delivery_return_id` + type `DELIVERY_RETURN` + shape check + unique once index
- `assert_stock_transaction_complete` accepts positive `DELIVERY_RETURN` ledger (`entry_sum = header_qty > 0`)
- Dispatch `physical_return_status` widened; exception shape no longer frozen at `pending_verification`
- Dispatch events: `return_posted`, `return_closed_missing`
- AFTER UPDATE trigger opens a return when `return_required` + `exception` + `stock_consumed`

Client has SELECT only. Stock-posting fields are RPC-owned.

---

## 3. Return lifecycle

```
Posted DISPATCH debit
  → failed/partial exception (M7.4A, inventory unchanged)
  → stock_delivery_returns awaiting_handback (trigger)
  → driver handback
  → Store Keeper lot/condition/crate count
  → GM approval (fingerprint)
  → post_delivery_return  OR  close_delivery_return_missing
  → posted | closed_missing
```

Failed/partial delivery does not restore stock. Original DISPATCH and outcome lines remain historically posted/readable. Stages cannot be skipped: count requires handback; approval requires count by a different actor; posting requires valid approval and unresolved = 0.

---

## 4. Lot reconciliation

`app_private.dispatch_return_source_grains` prefers `order_shipment_lots.shipped_cases`, else consumed `stock_reservations`. `assert_return_grains_match_ledger` full-joins that grain to negative DISPATCH ledger lines. Mismatch fails closed.

The consumed-reservation fallback no longer uses `(array_agg(id order by id))[1]` plus `sum()`. That expression kept lot/crate identity (those columns were grouped) but discarded extra reservation IDs on the same grain. Duplicate rows per `(order_line, product, lot, crate)` now raise `23514`. Each remaining reservation is returned as its own `id` + `reserved_cases`. Historical `confirm_dispatch` posting is unchanged.

Per grain:

`delivered + saleable + damaged + uncertain + missing + unresolved = dispatched`

All nonnegative integers. Physical returned qty cannot exceed driver handback or original undelivered. Line-level outcome delivered/undelivered must match lot sums. Browser quantities are re-verified server-side.

---

## 5. Physical count and GM approval

- Driver: assigned executor only. Declares returned case count. Cannot classify saleable, choose lots beyond the snapshot, approve, or post.
- Store Keeper: `deliveries.return_count` at originating godown. Allocates each original lot. Saleable requires a storage crate in that godown. Count from `handed_back` or `counted` clears approval.
- GM: `deliveries.return_approve` then `deliveries.return_post`. Cannot count. Cannot certify own count. Approval stores `return_lot_fingerprint`. Any later count change invalidates it (`approval is no longer valid` / version `PT409`).

---

## 6. Saleable / quarantine / missing

| Class | Ledger |
|---|---|
| Saleable | Positive `DELIVERY_RETURN` on original lot into keeper storage crate |
| Damaged / uncertain | Positive credit of original lot into quarantine crate (`app.damage_stock_write` for location prep only) |
| Missing | No ledger line |
| Unresolved | Blocks posting |

Quarantine goods are not picking-eligible through this writer. UI copy does not call them stocked until `posted_transaction_id` exists.

---

## 7. `post_delivery_return` writer

- `SECURITY DEFINER`, `search_path = ''`
- GM `deliveries.return_post` + `can_work_at_branch` + active godown
- Dual-write required; **no aggregate-only fallback**
- Original lot identity only; no new supplier lots; does not call `verify_stock_receipt`; does not reverse DISPATCH
- Idempotency key `delivery-return:<return_id>`; unique `delivery_return_id`
- Replay of a posted return returns the original payload
- Unique-violation is treated as success only when the return is already `posted` with a transaction; other uniques re-raise
- Header quantity = physically returned cases only

---

## 8. Ledger and stock integrity

Positive `DELIVERY_RETURN` lines use `apply_lot_aware_stock_deltas`. Existing DISPATCH uniqueness is untouched. Missing does not credit. Damaged does not credit storage. Direct ledger/return-table writes remain denied (`42501`).

---

## 9. Transit-damage overlap

`assert_transit_damage_overlap` collects open transit reports for the dispatch. Null line `lot_id` fails closed (cannot map to dispatched lots). Overlap of physical return qty on the same product/lot fails closed. Prior damage `stock_transactions` fail closed. Report ids are stored on the return header. No M5 auto-close.

---

## 10. Lock order

Shared cutover lock → dispatch `FOR UPDATE` → return header `FOR UPDATE` → return lots → products → `prepare_stock_locations` (receiving + quarantine) → lots → lot_balances → stock_balances → transaction insert → ledger → lot-aware apply.

This matches M2/M3/M5 (cutover, then products/locations/lots/balances) and holds dispatch before products so it cannot deadlock with `confirm_dispatch`.

---

## 11. Idempotency

One return per dispatch. One `DELIVERY_RETURN` transaction per return. Concurrent posters serialize on the return row; one transaction wins; the waiter sees `posted` or a stale version. Replay does not add ledger lines.

---

## 12. Security / RLS

FORCE RLS on return tables. SELECT-only grants. Write guard GUC. Trusted RPCs.

Proven denials (SQL + HTTP):

- Driver approve / count / post
- GM count
- Store Keeper post / approve
- Cross-godown GM
- Cross-godown crate
- Direct return insert / direct ledger insert
- Unauthorized close-all-missing (driver)
- Stale approval after count correction
- Dual-write off posting
- Transit-damage overlap
- Unassigned driver cannot `get_dispatch_request` an origin-godown exception (M3 regression). `return_view` is not a godown-wide leak. Keepers reach return documents through `return_count`; assigned drivers through `deliveries.execute`. The dispatch list route does not include `return_view`.

---

## 13. Concurrency and failure injection

| Race | Result |
|---|---|
| Two concurrent `post_delivery_return` | Exactly one `DELIVERY_RETURN` transaction |
| Replay after success | Same transaction, no extra ledger |
| Second return document | Unique `dispatch_id` rejected |
| Injected ledger failure on an already-posted return | No additional ledger lines |
| SQL function abort | Statement rolls back (no partial credit) |

A dedicated unposted two-lot inject is executed in `phase_m7_4b_hardening.mjs`: an AFTER INSERT constraint trigger on `stock_ledger` fails when a `DELIVERY_RETURN` already has `count(*) >= 2` (first credit stays in-txn, second aborts). No `DELIVERY_RETURN` header, no positive ledger, no lot/crate increase, return stays `approved` / unposted, `posted_by` remains null. After dropping the trigger, retry posts exactly one transaction with two positive lines; a second retry does not add another.

---

Hardening concurrency actually executed in `phase_m7_4b_hardening.mjs` (7/7):

| Race | Result |
|---|---|
| Unposted two-lot inject after first ledger credit | Rolled back; balances unchanged |
| Retry after removing inject | Exactly one `DELIVERY_RETURN`, two positive lines |
| GM approve versus Store Keeper count correction | One version winner; no stale fingerprint |
| `close_delivery_return_missing` versus `post_delivery_return` | One terminal state; posted ⇒ one txn, closed_missing ⇒ zero |
| Receiving crate deactivation versus posting | Post wins with one txn, or inactive crate `23514` with zero credit |
| Lot expiry change versus posting | Post wins with one txn, or expired `23514` with zero saleable credit |
| Permission revocation versus posting | Sequential revoke then post; `42501`, zero txn |

`lock_delivery_return` unused `dispatch` rowtype was replaced with `PERFORM … FOR UPDATE OF stock_dispatch_requests`.

---

## 14. Test results

Recorded after the local hardening pass. Skipped tests are not counted as passing. Suites are not marked PASS unless executed in this pass.

| Suite | Result |
|---|---|
| SQL `phase_m7_4b_delivery.sql` | PASS, rolled back (includes two-lot grains vs DISPATCH ledger, duplicate reservation fail-closed) |
| HTTP `phase_m7_4b_http_integration.mjs` | 7/7 PASS |
| Concurrency `phase_m7_4b_concurrency.mjs` | 4/4 PASS |
| Hardening `phase_m7_4b_hardening.mjs` | 7/7 PASS |
| Vitest | 224 passed / 36 files / 0 failed / 0 skipped |
| Playwright full Chromium | 91 passed / 2 failed / 5 did not run (serial dependents). `delivery-returns.spec.ts` passed. Isolated `damage-exceptional.spec.ts` 9/9 (stale-version was a serial flake). Isolated `lot-reconciliation` unexpected-product select still fails: local catalog has 1026 products vs PostgREST default 1000-row cap, so `m1s2qa-found` is omitted from the dropdown. Not a return-writer defect. |
| Typecheck | PASS |
| Lint | 4 oxlint warnings, all pre-existing non-M7.4B files |
| Production build | PASS (`DispatchDetailPage-Dfw5V48C.js` 28.21 kB includes return panel) |
| Local `db lint --local` | **No new M7.4B extras.** Unused `dispatch` in `lock_delivery_return` is gone. Remaining: pre-existing lot-aware temp-table errors, `update_vehicle` ambiguous `vehicle_type`, STABLE/VOLATILE and text→array warnings on older functions. |

Disposable SKU prefix `m74b%` covers `m74b-`, `m74bc_`, `m74bh_`.

Regressions executed in this hardening pass:

- M2 SQL ROLLBACK + HTTP 5/5 + concurrency (competing reserve; reserve vs transfer)
- M3 SQL ROLLBACK + HTTP 9/9 + concurrency (confirm once, transfer lock, adjustment races)
- M5 SQL all listed files ROLLBACK; HTTP M5.2 8, M5.3 4, M5.4B 14, M5.4C 5, M5.4D 13, M5.4E 20, M5.4F 4
- M5.2 concurrency 1/1; M5.3 concurrency 9/9
- M5.4C/D/E concurrency: executed races passed (3, 5, and 6 respectively). Later picking-vs-dispatch seeds were **not** marked PASS: pre-existing undeclared `payload` in those DO blocks, then after a declare-only experiment `verify_order` fail-closed because dual-write was off. Those files were left unchanged.
- M7.3B SQL ROLLBACK + HTTP 5/5 + concurrency 6/6
- M7.4A SQL ROLLBACK + HTTP 9/9 + concurrency 5/5

This is **not** a claim of clean-database replay of every historical migration. Only the additive M7.4B migration was applied on the existing local Docker database. Grain/lock/post function replacements were re-applied with `CREATE OR REPLACE` so Docker matches the file.

---

## 15. Known limitations

- One verified return wave per dispatch. Additional physical waves are not supported.
- Vehicle capacity, external scheduling, and POD photo/signature bytes remain out of scope (M7.4A).
- Dual-write must be enabled for posting. The operational flag remains **false**; tests replica-enable it and restore.
- Quarantine disposition / M5 write-off of returned damaged goods is later work.
- Backorders are independent; returns do not reopen fulfilment.
- BPM PDF was unavailable; M7.1 extraction only.
- Permission revocation versus posting was executed sequentially (revoke, then post). A same-instant GM-session race is not claimed.
- M5.4C/D/E later picking-vs-dispatch concurrency seeds remain pre-existing harness gaps and were not counted as passing.
- Local Playwright unexpected-product picker can miss `m1s2qa-found` once leftover HTTP products exceed PostgREST’s 1000-row default. `delivery-returns` e2e passed in the full run.

---

## 16. M7.5 handoff

M7.5 (and later) still owns invoices, payment collection, TallyPrime, production lot cutover, and enabling `stock.lots.dual_write_enabled` / `aggregate_only_blocked` / `SHORT_SHIPMENT_OPERATIONAL` / `damage.stock_hold_ready`.

Return posting in production is blocked until trusted lot-attributed dual-write is operationally permitted by the owner.

---

## 17. Production cutover blockers

1. Operational flags still false.
2. No cloud migration applied.
3. No production dual-write cutover.
4. Owner Git commit not performed in this phase.
5. Unresolved M5 transit-damage cases still block overlapping returns by design.
