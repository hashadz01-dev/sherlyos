# M6.3 — Supplier communication and dispatch tracking

Local-only implementation of PDF Branch 05 **REF-05** and **REF-06**. Manual recording of supplier communication and supplier-reported dispatch. **Not independently verified delivery.** **Not a stock receipt.**

Owner-approved model: Accounts attests that an approved refill request was communicated outside SherlysOS (phone, WhatsApp, email, or other). SherlysOS does not send messages and does not integrate Meta, SMTP, SMS, or webhooks.

Admin approval remains an authorization event only. Supplier dispatch remains informational. Accepted inventory is posted only by existing Branch 03 `verify_stock_receipt`. REF-07 is out of scope.

## 1. Traceability

| Step | Blueprint | M6.3 behavior |
| --- | --- | --- |
| REF-05 | Accounts sends the approved request to the FMCG company | Accounts records channel, communication time, optional reference/notes. Actor is `auth.uid()`. `recorded_at` is server-generated. |
| REF-06 | FMCG supplier dispatches products to the godown | Accounts records supplier-reported dispatch details. No in-transit balance, reservation, or receipt. |
| REF-07 | Branch 03 receiving | Not implemented. UI states “Awaiting physical receiving” after dispatch is recorded. |

Manual recording means Accounts attests that communication or dispatch information was received. It does not prove the supplier accepted, dispatched, or delivered goods.

## 2. State model

Approval status is unchanged from M6.2:

```
draft → submitted → approved
                 ↘ held → submitted
                 ↘ rejected (terminal)
```

Supplier fulfilment is stored separately:

| Axis | Values |
| --- | --- |
| Communication | `not_sent` / `sent` |
| Acknowledgement | `none` / `pending` / `acknowledged` / `declined` |
| Dispatch | `not_recorded` / `recorded` |

Conceptual operator view:

1. Approved, not sent
2. Sent, awaiting supplier response (`pending`)
3. Supplier acknowledged
4. Supplier declined (Admin approval stays `approved`; dispatch blocked until an audited acknowledgement correction)
5. Supplier dispatch recorded
6. Awaiting physical receiving

Approved requests are not reopened for line edits because a supplier response is pending. Send fields are immutable. Acknowledgement and dispatch may be corrected with a new event; the original event remains.

## 3. Schema

Forward-only `20261027150000_stock_refill_supplier_communication.sql`.

- `stock_refill_supplier_communications` — one first-send per request (`unique refill_request_id`). Send fingerprint + idempotency key. Acknowledgement columns default to `pending`.
- `stock_refill_supplier_dispatches` — one current dispatch row per request. Corrections update the row and write `supplier_dispatch_corrected`.
- Event actions added: `sent_to_supplier`, `supplier_acknowledged`, `supplier_declined`, `supplier_acknowledgement_corrected`, `supplier_dispatch_recorded`, `supplier_dispatch_corrected`.
- FORCE RLS, authenticated SELECT only, write guard GUC `app.refill_write`.
- Supplier and godown on child rows are copied from the approved request. Clients cannot substitute another supplier.

Channel / date / reference corrections of the original send are **not** implemented. Keep the send immutable; that correction is a future requirement.

## 4. RPC signatures

Trusted `SECURITY DEFINER`, `search_path = ''`, execute granted to `authenticated` only.

| RPC | Arguments |
| --- | --- |
| `record_stock_refill_supplier_communication` | `target_request uuid, expected_version integer, communication_channel text, communicated_at timestamptz, idempotency_key text, external_reference text default null, notes text default null` |
| `record_stock_refill_supplier_acknowledgement` | `target_request uuid, expected_version integer, acknowledgement_status text, response_at timestamptz, idempotency_key text, acknowledgement_reference text default null, notes text default null, decline_reason text default null` |
| `record_stock_refill_supplier_dispatch` | `target_request uuid, expected_version integer, dispatched_on date, idempotency_key text, supplier_dispatch_reference text default null, expected_arrival_on date default null, transport_provider text default null, vehicle_reference text default null, tracking_reference text default null, notes text default null` |

`get_stock_refill_request` / `list_stock_refill_requests` now include communication, acknowledgement, dispatch status, expected arrival, and nested communication/dispatch objects. History is the existing events array.

Lock order: request header `FOR UPDATE`, then optional `assert_operational_active_branch`, then send-key `pg_advisory_xact_lock(88106305, hashtext(key))`. **No** product, location, or stock grain locks.

## 5. Authorization

| Action | Accounts `refill.request` | Admin `refill.approve` | GM / Keeper / Delivery / Sales / monitor-only |
| --- | --- | --- | --- |
| View authorized request and history | Yes | Yes | No |
| Record send / ack / dispatch | Assigned active godown | No (approve is not send) | No |
| Direct table write | No | No | No |

New operational writes fail closed on inactive godowns. Historical GET remains. Permission and assignment revocation take effect on the next statement, including completed-operation replay. Replay authorizes the original recorder plus current `refill.request` and `can_view_refill_at_godown` before comparing fingerprints.

## 6. Idempotency and lost-response recovery

- Client-generated keys, 8–80 `[A-Za-z0-9_-]`.
- Identical completed send/ack/dispatch returns the persisted payload after current authorization.
- Conflicting payload with the same key → `23505`.
- Foreign actor or other request → `42501` with no payload.
- Concurrent identical sends produce one communication row and one `sent_to_supplier` event.
- Frontend mutations use `retry: false` and keep the key in sessionStorage until success is identified. Ambiguous network errors ask the user to refresh first.

## 7. UI

`/refill` shows approval, communication, acknowledgement, dispatch, and expected arrival. `/refill/:requestId` adds **Supplier communication & dispatch** with explicit labels:

- Mark as sent — manually recorded
- Supplier acknowledged — manually recorded
- Supplier dispatch recorded
- Awaiting physical receiving
- Admin approval does not add inventory
- Supplier dispatch does not add inventory

Admin never sees send/ack/dispatch actions. Accounts actions are hidden unless backend-derived eligibility is true; RPCs remain authoritative.

## 8. Tests

| Suite | File |
| --- | --- |
| SQL | `supabase/tests/phase_m6_3_supplier_communication.sql` |
| HTTP | `supabase/tests/phase_m6_3_http_integration.mjs` |
| Concurrency | `supabase/tests/phase_m6_3_concurrency.mjs` |
| Vitest | `tests/unit/refill.test.ts`, `tests/unit/refill-pages.test.tsx` |
| Playwright | `tests/e2e/refill-supplier-communication.spec.ts` |

Disposable SKU prefix `m63%`. M6.2 suites remain the approval-lifecycle regression.

### Test evidence (this implementation)

| Suite | First pass | Final |
| --- | --- | --- |
| M6.3 SQL | Failed: `current_date` under `search_path = ''`; dispatch UPDATE shadowed `fingerprint` | Passed after those two function fixes in `20261027150000` (still uncommitted; local function replaced) |
| M6.3 HTTP | 12 passed | 12 passed |
| M6.3 concurrency | 12 passed | 12 passed |
| M6.2 SQL / HTTP / concurrency | Passed | Passed |
| M5.3 isolation SQL | Passed (ROLLBACK) | Passed |
| `phase_3_1_stock_receiving.sql` | Passed (ROLLBACK) | Passed |
| Vitest | 32 files / 197 tests passed | 197 passed |
| Playwright | 77 passed, 1 failed (`getByLabel('Supplier response')` matched the dialog) | 78 passed after unique acknowledgement label |
| Typecheck / lint / production build | Passed (pre-existing oxlint warnings plus two unused concurrency vars, then fixed) | Passed |

Flags after all runs remain false.

## 9. Known limitations

- Manual recording is not proof of supplier delivery.
- Original send channel/date/reference cannot be rewritten; document a future audited send correction if needed.
- No email/WhatsApp/SMS integration.
- No `stock_receipts.refill_request_id` (M6.4 / REF-07).
- Development cloud and production are not migrated.

## 10. M6.4 handoff

Evaluate REF-07 separately: optional receipt-to-request linkage, partial/over/under delivery, and reuse of `verify_stock_receipt` only. Do not create a second stock writer. Do not treat supplier dispatch as goods received.
