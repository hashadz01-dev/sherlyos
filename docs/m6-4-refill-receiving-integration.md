# M6.4 — Stock refill receiving integration

Local-only implementation of PDF Branch 05 **REF-07**. Approved supplier replenishment requests may have **multiple physical deliveries** and **multiple linked stock receipts**. Each receipt is counted, verified, and posted through existing Branch 03 receiving. **`verify_stock_receipt` is the sole accepted-stock posting authority.**

Owner-approved multi-partial receiving (D9–D12) is implemented. No automatic procurement closure policy was invented. Over-delivery is **refused on linked create/update/submit** using a cumulative reservation of non-cancelled accepted cases. It is not silently posted against the refill request and does not change original requested quantities. `verify_stock_receipt` is unchanged.

## 1. Approved multi-partial receiving decision

One approved refill request → many `stock_receipts`. Each `stock_receipt` → zero or one refill request (`stock_receipts.refill_request_id` nullable). Unlinked Branch 03 receiving continues to work.

Example persisted reconciliation after two verified receipts:

| SKU | Requested | Accepted | Outstanding |
| --- | ---: | ---: | ---: |
| Product A | 100 | 70 | 30 |
| Product B | 60 | 45 | 15 |

The request stays `approved` until an owner-approved completion policy exists.

## 2. REF-07 traceability

| Step | Blueprint | M6.4 behavior |
| --- | --- | --- |
| REF-07 | Connect approved supplier replenishment to Branch 03 receiving | Optional `refill_request_id` on create/update. Store Keeper counts. GM verifies. Existing `verify_stock_receipt` posts accepted cases. Read-only per-SKU reconciliation. |

Approval, supplier communication, supplier dispatch, and receipt linkage post **zero** stock.

## 3. Existing receiving contracts reused

Unchanged stock-posting RPC: `verify_stock_receipt`. Unchanged lifecycle RPCs except reservation re-check: `hold_stock_receipt`, `release_stock_receipt`, `cancel_stock_receipt`, `get_stock_receipt`.

Extended: `create_stock_receipt`, `update_stock_receipt` (optional `target_refill_request uuid default null`), `submit_stock_receipt` (re-asserts linked reservation, still zero stock), `list_stock_receipts`, `list_receiving_options`, `app_private.stock_receipt_payload`.

Accepted cases remain the generated column `counted_cases - damaged_cases`. Damaged cases do not enter saleable inventory. DMG-01 / DMG-02 readiness is unchanged.

## 4. Schema changes

Forward-only local Docker migrations:

- `20261027170000_stock_refill_receiving_integration.sql` — linkage column, optional refill arg, read-only reconciliation.
- `20261027180000_stock_refill_receiving_cumulative_limit.sql` — cumulative reservation. Does **not** rewrite 170000.

- `stock_receipts.refill_request_id uuid null references stock_refill_requests(id) on delete restrict`
- Partial index on non-null `refill_request_id`
- No new stock writers, no status `receiving_complete`, no auto-close

Live `pg_get_functiondef` for `assert_refill_receipt_header` matches 180000 (`FOR UPDATE`). Shared local database was not reset. Isolated empty-DB replay was not run.

## 5. RPC signatures

| RPC | Arguments |
| --- | --- |
| `create_stock_receipt` | existing six args + `target_refill_request uuid default null` |
| `update_stock_receipt` | existing seven args + `target_refill_request uuid default null` |
| `get_stock_refill_receiving_reconciliation` | `target_request uuid` |

`get_stock_refill_request` payload now includes `receiving` (same snapshot as the dedicated RPC). Keepers cannot call `get_stock_refill_request`; they use the reconciliation RPC and `list_receiving_options.refill_requests`.

All new/replaced functions: `SECURITY DEFINER`, `search_path = ''`, schema-qualified, execute granted to `authenticated` only.

## 6. Receipt linkage rules

- Linked request must exist, be `approved`, match supplier, match destination godown, and be operationally active.
- Linked lines must be SKUs on the request.
- Linked create/update/submit refuse this receipt’s accepted + **all other non-cancelled** linked accepted > requested (`23514`). Draft, submitted, held, and posted rows reserve capacity. Cancelled rows free it.
- Linked create/update take `FOR UPDATE` on the refill request **before** location locks, so concurrent creates serialize.
- Link is set on create; changeable only while `draft`. Immutable after submit/verify. No silent historical attach. Posted receipts cannot be reassigned.
- Unlinked receipts omit `target_refill_request` and skip reservation.

## 7. Per-SKU reconciliation definitions

Server-authoritative `app_private.stock_refill_receiving_snapshot`. Frontend does not aggregate raw tables.

| Field | SQL |
| --- | --- |
| `requested_cases` | `sum(stock_refill_request_lines.requested_cases)` |
| `accepted_cases` | `sum(accepted_cases)` on **posted** linked receipts only |
| `outstanding_cases` | `greatest(requested - accepted, 0)` |
| `excess_cases` | `greatest(accepted - requested, 0)` |
| `damaged_cases` | `sum(damaged_cases)` on **posted** linked receipts |
| `pending_receipt_cases` | `sum(counted_cases)` on **submitted** or **held** linked receipts |

Draft and cancelled quantities never count as accepted or pending. Header `completion_label`: `not_started` / `pending_verification` / `partially_received` / `fully_received` / `excess_requires_review` (excess wins).

## 8. Damaged case accounting

`accepted_cases = counted_cases - damaged_cases` per existing receiving rules. Damaged cartons are not accepted refill quantity. No new quarantine or damage posting. M5 readiness stays false.

## 9. Partial / under / over delivery

Under-delivery keeps outstanding visible and allows further receipts.

Over-delivery is **not** auto-accepted and does **not** increase requested quantities. Linked create/update/submit reserve `accepted_cases` from every non-cancelled linked receipt. Concurrent independent sessions that each request 8 against a remaining 10 produce one winner; the winner posts 8 through existing `verify_stock_receipt` (one ledger row). `verify_stock_receipt` is **not** modified.

Read-model `excess_cases` remains for historical display if older data ever exceeded the request. New linked writes cannot create that state.

## 10. Exact-once posting proof

Duplicate `verify_stock_receipt` with the same idempotency key returns the posted payload. SQL and HTTP recovered a second verify without a second ledger row. Concurrent dual-verify of two receipts posted two transactions and accepted 5+6=11.

## 11. Lock ordering

`verify_stock_receipt` is unchanged: receipt `FOR UPDATE` → supplier → products → `prepare_stock_locations` (cutover shared, zones, crates, branch) → balances. **No refill-header lock inside verify.**

Linked create/update: `assert_refill_receipt_header` `FOR UPDATE` on the request **before** `replace_receipt_lines` location locks. Quantity checks after lines do not take a second header lock. Submit locks the receipt first, then re-asserts quantities **without** locking the refill header.

This does not invert verify’s grain order. Two over-limit linked creates serialize on the request row.

## 12. Role and godown security

| Action | Accounts `refill.request` | Admin `refill.approve` | Store Keeper `receiving.execute` | GM `receiving.verify` |
| --- | --- | --- | --- | --- |
| Approve refill | No | Yes | No | No |
| Create/update linked receipt | No | No | Yes, assigned active godown | No |
| Verify / post | No | No | No | Yes, existing Branch 03 |
| Read refill reconciliation | Assigned (historical inactive OK) | access_all or assignment | Assigned active godown | Assigned active godown |

FORCE RLS unchanged on `stock_receipts`. Authenticated has SELECT only. Inactive godowns refuse new linkage; authorized historical refill recon remains readable.

## 13. SQL results

`supabase/tests/phase_m6_4_refill_receiving_integration.sql` — passed and rolled back after 180000 (includes sequential second-draft refusal). Earlier helper `sku` shadow / short verify key failures were test-only.

Regressions (all ROLLBACK, passed): M6.3 supplier communication, M6.2 request lifecycle, `phase_3_1_stock_receiving.sql`, `phase_m5_3_damage_stock_isolation.sql`.

## 14. HTTP results

`supabase/tests/phase_m6_4_http_integration.mjs` — **10/10** including sequential over-limit create denial after the first draft.

M6.3 HTTP 12/12. M6.2 HTTP 16/16.

Posted inventory is only on disposable `m64%` SKUs via existing `verify_stock_receipt`.

## 15. Concurrency results

`supabase/tests/phase_m6_4_concurrency.mjs`

| Race | Result |
| --- | --- |
| Two in-limit linked creates | PASS |
| Two over-limit creates (8+8 vs 10) | PASS — one winner, posted accepted 8, one stock tx |
| Two in-limit partial verifies | PASS — accepted 11, two txs |
| Same receipt verify twice | PASS — one tx |
| Verify vs cancel | PASS — one winner |
| Link vs approve | PASS |
| Verify vs godown deactivate | PASS |
| Verify vs supplier deactivate | PASS |
| Verify vs recon read | PASS |
| Duplicate document create | PASS — one winner |
| Linked vs unlinked verify same crate | PASS — refill accepted excludes unlinked |

**Final: 12/12.** Skipped races were not reported as passing.

## 16. Vitest / Playwright results

Vitest: **207 passed** (33 files).

Playwright full suite after the locator fix: **84 passed / 84**. M6.4 spec 6/6.

## 17. Known limitations

- No owner-approved over-delivery *acceptance* or request auto-completion policy. Excess is refused, not approved as extra stock.
- An uncancelled draft still reserves requested quantity until it is cancelled.
- Accounts see receipt numbers on the refill page but cannot open `/receiving/:id`. Keepers cannot open `/refill/:id`.
- Linked receiving does not require REF-05/REF-06 send or dispatch records.
- Disposable `m64%` posted balances remain in the local database (not operational SKUs).
- Isolated empty-database migration replay was not run; shared local Docker was not reset.

## 18. M6.5 handoff

Out of scope: automated supplier messaging, financial settlement, supplier credits, request auto-close, over-delivery approval workflow, and any second stock writer.

Suggested M6.5 questions: whether Accounts should see receipt detail read-only; whether send/dispatch should be required before linkage; whether an authorized person may accept over-delivery; when a request may be marked complete.
