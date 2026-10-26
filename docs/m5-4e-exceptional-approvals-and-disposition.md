# M5.4E — Exceptional Damage Approvals & Disposition

Local-only operational frontend over the trusted M5.2/M5.3 exceptional RPCs, plus a server-paged Admin queue read and completed-identification for request/approve/reject/post. This work does **not** flip `damage.stock_hold_ready`, lot cutover flags, or post stock from React.

## 1. Feature overview

Exceptional disposition is three separate trusted operations:

1. **Request** — a Godown Manager records return-to-supplier or destroy against remaining isolated quantity.
2. **Admin decision** — Admin approves or rejects. Approval is an authorization event and does not post stock.
3. **Execution** — a Godown Manager posts the approved disposition. The trusted RPC consumes remaining holds exactly once as `ADJUSTMENT` / `exceptional_writeoff`.

Requested, approved, and posted remain visually distinct. Approved-but-not-posted is labeled **Approved — pending execution**. Posted is labeled **Posted — ledger complete**. Physical destruction or supplier handover is not independently recorded.

## 2. Actual RPC contracts

Audited in repository. `20261026180900` replaces request/approve/reject/post bodies for unlocked godown snapshot, remaining-hold gates, ordinary-write-off exclusion, and completed identification before stale-version rejection. It also adds `list_exceptional_damage_requests`.

| RPC | Arguments | Auth | Version of | Idempotency | Stock |
| --- | --- | --- | --- | --- | --- |
| `request_exceptional_damage_disposition` | `target_report uuid`, `expected_version integer`, `disposition_kind text`, `request_reason text`, `idempotency_key text` | `damage.verify` | report | `request_idempotency_key` unique; 80900 replays the same key before version | none |
| `approve_exceptional_damage_disposition` | `target_request uuid`, `expected_version integer` | `damage.dispose` | request | 80900 returns payload if already `approved` or `posted` | none |
| `reject_exceptional_damage_disposition` | `target_request uuid`, `expected_version integer`, `decision_reason text` | `damage.dispose` | request | 80900 returns payload if already `rejected`; reason 1–500 | none |
| `post_exceptional_damage_disposition` | `target_request uuid`, `expected_version integer`, `idempotency_key text` | `damage.verify` | request | 80900 returns payload if `posted` (any key); new posts still need current version | consume remaining holds |
| `list_exceptional_damage_requests` | page, page_size (cap 100), godown, status, kind, scenario, search, dates | `damage.dispose` **or** `operations.monitor` **or** `damage.verify` | n/a | n/a | none; rows still pass `can_view_damage_report` |
| `post_ordinary_damage_writeoff` | existing | `damage.verify` | report | existing completed identification | blocked while an exceptional request is `requested`/`approved` |
| `get_damage_report` / `list_damage_reports` / `get_damage_dashboard` / `list_damage_quarantine_inventory` | existing | existing | n/a | n/a | none |

Private helpers used, not invented: `lock_damage_report`, `assert_damage_version`, `assert_damage_godown_active_unlocked`, `assert_damage_disposition_ready`, `consume_damage_holds`, `post_damage_adjustment`, `lock_damage_stock_grains`, `can_view_damage_report`, `can_work_at_branch`.

Kinds accepted by the backend: `return_supplier`, `destroy`. Quantity is always remaining active/transferred holds. Partial quantity controls are not offered.

## 3. Request / approval / execution state machine

```
verified storage/loading
  OR rejected shop-return
        │
        ▼
   requested  ──reject──► rejected (holds stay)
        │
        ▼
   approved   (authorization only; stock unchanged)
        │
        ▼
   posted     (holds written_off or returned_supplier; exceptional_writeoff txn)
```

- Unique open request per report (`requested` or `approved`).
- Ordinary write-off is blocked while a request is open.
- Exceptional request is blocked if an ordinary write-off transaction already exists.
- Execution is denied until status is `approved`.
- Report status does not change at request/approve/post.

## 4. Permission matrix

| Role | Queue `/damage/exceptional` | Request | Approve / reject | Execute | Notes |
| --- | --- | --- | --- | --- | --- |
| Admin | Yes (`damage.dispose` / `operations.monitor`) | No | Yes | No | Does not inherit `damage.verify` |
| Godown Manager | RPC list allowed via `damage.verify`; UI route is Admin/monitor only | Assigned godowns | No | Assigned godowns after approval | Cannot approve own request unless the same user also has `damage.dispose` (roles are split; not changed) |
| Store Keeper | No | No | No | No | Report/view in scope |
| Delivery Person | No | No | No | No | Assigned transit only |
| Accounts / Sales | No | No | No | No | Unauthorized |

Backend authorization is authoritative. Hidden buttons are not the control. Direct RPC tests cover every relevant role.

## 5. Supplier-return behavior

`return_supplier` is not a restock. `consume_damage_holds(..., 'returned_supplier', 'exceptional_writeoff')` posts a trusted `ADJUSTMENT`. Holds become `returned_supplier`. Saleable on-hand is decremented, not restored. No supplier shipment or credit note is created.

## 6. Destruction behavior

`destroy` consumes remaining holds as `written_off` with the same `exceptional_writeoff` posting kind. Exact-once per report via `stock_transactions_damage_kind_once`. Ledger posting is not a physical-destruction certificate. The backend does not store a later physical-completion event.

## 7. Rejected shop-return handling

Rejected shop-return reports remain eligible because `assert_damage_disposition_ready` allows `scenario = shop_return` and `status = rejected`. Quarantine intake stays until an authorized exceptional (or ordinary) posting consumes it. Rejection is not supplier-return approval. There is no restock-to-saleable path.

## 8. Hold and ledger effects

| Operation | Holds | Ledger |
| --- | --- | --- |
| Request | unchanged | none |
| Approve / reject | unchanged | none |
| Post `destroy` | `written_off` | one `ADJUSTMENT` / `exceptional_writeoff` |
| Post `return_supplier` | `returned_supplier` | one `ADJUSTMENT` / `exceptional_writeoff` |
| Ordinary write-off | `written_off` | one `ADJUSTMENT` / `ordinary_writeoff` |

Preview is informational. The trusted RPC recalculates remaining holds at posting time.

## 9. Idempotency and recovery

M5.4D identified completed ordinary write-offs before stale-version rejection. Exceptional posting had the same class of gap because post bumps **request** version.

80900:

- Request, approve, reject, and post all assert the current permission and `can_view_damage_report` before completed identification. A reused request key must belong to the same report.
- Request: same `request_idempotency_key` on the same report returns payload before version.
- Unique open-request index surfaces as `an exceptional disposition is already open`.
- Approve: already `approved`/`posted` returns payload.
- Reject: already `rejected` returns payload. Reason is validated only for a new rejection.
- Post: already `posted` returns payload for any key, including a stale `expected_version`. A **new** posting still requires the current request version, an active assigned godown, and `approved` status. Identification does not re-consume holds.

The frontend keeps one idempotency key until success, maps network errors to “refresh before retrying”, and identifies completion from the persisted payload (`reportHasCompletedExceptionalDisposition`). It does not treat a network error as proof of failure and does not silently retry.

## 10. Lock ordering

Request snapshots godown activity with `assert_damage_godown_active_unlocked` (no branch `FOR UPDATE`). Approve/reject lock the request row, then `lock_damage_report`. Post locks the request row, then the report, snapshots godown activity, then `consume_damage_holds` → `lock_damage_stock_grains` (products → locations). That matches confirm_dispatch / ordinary write-off.

## 11. Readiness restrictions

Current flags remain false:

- `damage.stock_hold_ready=false`
- `stock.lots.dual_write_enabled=false`
- `stock.lots.aggregate_only_blocked=false`

Exceptional RPCs do not consult readiness. If isolation never created holds, posting fails closed with `no isolated damage quantity remains`. Tests that enable lot dual-write for dispatch races restore the flags.

Approval is allowed on an inactive godown (authorization event). Request and execution still require an active assigned godown. `can_work_at_branch` requires `branches.is_active`, so inactive-godown request may fail `42501` at `lock_damage_report` before the `23514` inactive snapshot.

## 12. Routes and UI components

| Path | Screen | Guard |
| --- | --- | --- |
| `/damage` | Dashboard + exceptional queue link | `damageNavPermissions` |
| `/damage/exceptional` | Admin approval queue | `damage.dispose` or `operations.monitor` |
| `/damage/:reportId` | Request / review / execute panels | `damageNavPermissions` |

`/damage/exceptional` is registered before `/damage/:reportId`.

Components:

- `DamageExceptionalApprovalsPage`
- `DamageExceptionalRequestPanel` / `DamageExceptionalRequestDialog`
- `DamageExceptionalReviewPanel` / `DamageExceptionalApprovalDialog` / `DamageExceptionalRejectionDialog`
- `DamageExceptionalExecutionPanel` / `DamageExceptionalExecutionDialog`
- `DamageDispositionEligibility`
- Extended `DamageLifecycleTimeline`, `DamageActivityTimeline`, `DamageReportDetailPage`, `DamagePage`

## 13. Security controls

- FORCE RLS remains on `damage_exceptional_requests`. Authenticated clients have SELECT only through `can_view_damage_report`.
- Queue reads use the new security-definer list RPC. No privileged table queries from React.
- Admin does not inherit GM operational posting.
- GM does not inherit Admin approval.
- Historical inactive godowns remain visible for authorized reporting; new request/post still fail closed.

## 14. Test isolation

SQL, HTTP, and concurrency suites share local Docker `app_configuration`. Run M5.2–M5.4E SQL/HTTP/concurrency **one at a time**. Do not parallelize them.

4E SQL, HTTP, and concurrency take `pg_advisory_lock(hashtext('sherlyos.m5.stock_flag_tests'))` for the suite duration. HTTP and concurrency hold that lock with `psql -c` + `pg_sleep` so later `docker exec` calls cannot drop it. Dual-write is enabled only for the dispatch pairing seed and restored in `finally`, including after failures. Persistent local baseline flags stay false.

## 15. Test results

Recorded in the M5.4E implementation report after the local regression run.

| Suite | Path |
| --- | --- |
| SQL | `supabase/tests/phase_m5_4e_exceptional_disposition.sql` |
| HTTP | `supabase/tests/phase_m5_4e_http_integration.mjs` |
| Concurrency | `supabase/tests/phase_m5_4e_concurrency.mjs` |
| Unit | `tests/unit/damage-exceptional.test.ts`, `tests/unit/damage-exceptional-pages.test.tsx` |
| Playwright | `tests/e2e/damage-exceptional.spec.ts` |

## 16. Remaining limitations

- Physical destruction certificates, supplier shipments, and supplier credit notes are not in the backend contract. Do not invent those workflows here.
- Persisted states are `requested` → `approved`/`rejected` → `posted`. `posted` means the trusted inventory/ledger adjustment completed. Physical destruction or supplier handover is **not** independently recorded and must not be labeled as independently verified.
- After branch deactivation, a Godown Manager loses `can_view` (`can_work_at_branch` requires `is_active`), so completed post replay is denied without a second ledger row. New posting fails closed.
- Self-approve is possible only if one Auth user holds both `damage.dispose` and `damage.verify`. Current roles do not combine those grants.
- Isolation-required live reports still cannot be submitted while `damage.stock_hold_ready=false`. Tests use isolated fixtures.

## 17. M5.4F handoff

M5.4F should close remaining Damage Management operational gaps that are still out of this slice: any additional exceptional kinds the business later adds, physical-completion evidence if product requires it, and cross-module reporting that consumes posted exceptional ledger rows. Do not enable readiness or lot cutover here. Do not treat ordinary write-off as covering destroy or supplier-return.
