# M5.2 — Damage management database and security foundation

Local implementation only. **Do not apply** `20261026140000_damage_management_foundation.sql` to development cloud `ypkfondrkhkydkgovwup`. This work does not post stock, create holds, flip lot cutover flags, or implement the M5.4 frontend.

M5.3 will add atomic on-hand isolation and tagged `ADJUSTMENT` posting. M5.4 will replace the empty `/damage` placeholder.

## Implemented tables

| Table | Purpose |
|---|---|
| `damage_reports` | Header. Unique `report_number` (`DMG-YYYYMMDD-######`) and `idempotency_key`. Optimistic `version`. Source document FKs. |
| `damage_report_lines` | Positive carton cases. Optional `lot_id` (cutover is off). Optional `crate_id` where the scenario allows it. Optional `receipt_line_id` for inbound. Unique grain per report/product/crate/lot/receipt line. |
| `damage_report_events` | Append-only lifecycle history. |
| `damage_evidence` | Private photo metadata. `verified_at` marks finalized magic-byte validation. Path `{report_id}/{evidence_id}`. |

Trusted writer GUC: `app.damage_write`. Direct authenticated DML is denied. `FORCE ROW LEVEL SECURITY` is on for all four tables. Clients have `SELECT` only.

Partial unique indexes block a second open transit report per dispatch and a second open loading report per picking or preparing dispatch. Inbound overlap is enforced as remaining `damaged_cases` on the receipt line (cancelled/rejected excluded). Storage/shop-return quantity overlap is **not** enforced until M5.3 inventory integration; those scenarios cannot submit because `apply_damage_stock_isolation` is still a fail-closed stub.

## Permissions

Existing `damage.record` is unchanged (Godown Manager + Store Keeper).

| Code | Grants | Use in M5.2 |
|---|---|---|
| `damage.read` | Admin, Godown Manager, Store Keeper | View authorized reports |
| `damage.verify` | Godown Manager | Return, verify, reject |
| `damage.dispose` | Admin | Catalog only. No RPC. Exceptional M5.3 approval. |
| `damage.record` | Godown Manager, Store Keeper (existing) | Ordinary create except transit driver path |

Admin does **not** receive `damage.record` or `damage.verify`. Admin historical read uses `operations.monitor`. Admin `branches.access_all` cannot skip `assert_operational_active_branch` on non-transit writes.

Accounts and Salesperson receive no new write grants.

Assigned Delivery Person does **not** receive `damage.record`. Transit create is `deliveries.execute` **and** `stock_dispatch_requests.assigned_to = auth.uid()` **and** consumed eligible status **and** the report `dispatch_id` is that dispatch.

## RPC inventory

All public RPCs are `SECURITY DEFINER`, `search_path = ''`, `GRANT EXECUTE` to `authenticated` only.

| RPC | Actor |
|---|---|
| `create_damage_report` | Scenario-scoped recorder (see below) |
| `update_damage_report` | Reporter, `draft` / `returned` |
| `submit_damage_report` | Reporter, `draft` / `returned` |
| `return_damage_report` | Godown Manager `damage.verify` |
| `verify_damage_report` | Godown Manager `damage.verify` |
| `cancel_damage_report` | Reporter or Godown Manager, `draft` / `returned` |
| `reject_damage_report` | Godown Manager `damage.verify`, `submitted` |
| `get_damage_report` / `list_damage_reports` | `can_view_damage_report` |
| `create_damage_photo_upload` | Reporter or Godown Manager on non-terminal reports |
| `finalize_damage_photo_upload` | Uploader; magic bytes on payload; Storage catalog must exist and be owned; metadata rewritten from payload |
| `get_damage_photo_url` | Viewer of a **finalized** photo for that report |

No disposition or stock-posting RPCs.

Private helpers are revoked from `public`, `anon`, `authenticated`, and `service_role`, except storage-policy helpers `can_view_damage_report`, `can_store_damage_photo`, and `can_read_damage_photo` (authenticated execute, as with verification photos).

## State machine

```
create → draft
draft → submitted
submitted → returned
returned → submitted
submitted → verified
draft | returned → cancelled
submitted → rejected
```

Verified / cancelled / rejected are terminal. Verified quantities and evidence cannot be changed. Stale `version` raises `PT409`. Transitions take `FOR UPDATE` on the report row.

Reserved future labels (not operational): `approved_writeoff`, `approved_return_supplier`, `approved_destroy`, `disposed`.

## Submission readiness gate

Hold-required submit **always** calls `app_private.apply_damage_stock_isolation(report_id)`. The M5.2 stub always raises `23514` `damage stock isolation is not ready`. Config `damage.stock_hold_ready` is a future M5.3 kill-switch only:

- Authenticated clients cannot DML `app_configuration`.
- A BEFORE trigger rejects `value = true` until `app_private.damage_stock_isolation_installed()` returns true.
- M5.2 `damage_stock_isolation_installed()` is immutable `false`. Replica can write the flag (triggers skipped) but submit still calls the stub.

| Scenario | Submit in M5.2 |
|---|---|
| `refill_supply` / `unloading` | Allowed. Receipt `damaged_cases` were never posted as accepted `RECEIPT` stock. |
| `transit` | Allowed. Dispatch already consumed. No new `DISPATCH` row and no available-stock hold. |
| `storage` / `loading` / `shop_return` | **Blocked** by the isolation stub. Draft/create may exist for source validation. |

Postgres cannot read Storage object bytes. Finalize requires a `storage.objects` row owned by the uploader, validates magic bytes on the supplied payload, and **rewrites** catalog size/MIME/eTag from that payload. Client-supplied metadata cannot mark evidence finalized.

## DMG-01 through DMG-06 validation

| Code | Scenario | Source rule |
|---|---|---|
| DMG-01 | `refill_supply` | Posted receipt + receipt line. Quantity ≤ remaining `damaged_cases`. Same godown. |
| DMG-02 | `unloading` | Same inbound rule. Reporter chooses scenario; remaining qty is shared per receipt line across inbound scenarios. |
| DMG-03 | `storage` | Crate in the report godown. Product required. `lot_id` optional. Submit gated. |
| DMG-04 | `loading` | Picking in `allocated`/`picking`/`picked`/`ready_for_dispatch` and/or preparing unconsumed dispatch. Lines must match reservation grain. Consumed dispatch rejected. Submit gated. |
| DMG-05 | `transit` | Consumed dispatch in `dispatched`/`in_transit`/`delivered`/`exception`. Assigned driver or Godown Manager in consumed-delivery scope. Quantity ≤ reserved cases on that picking. No new `DISPATCH` transaction. |
| DMG-06 | `shop_return` | Active shop. Optional order must match shop + godown. Does not create inbound available inventory. Submit gated. |

## Assigned-driver security

- Create/submit DMG-05 only for the assigned consumed dispatch.
- View own eligible transit reports.
- Cannot verify, reject, dispose, or post stock.
- Unassigned drivers on the same godown are denied before duplicate-source detection.
- Cross-dispatch and cross-branch reporting are denied.

Godown Manager may report transit in consumed-delivery assignment scope (including an inactive godown, matching M4.1 post-consume delivery). Other scenarios still use `assert_operational_active_branch`.

## Evidence security

Private bucket `stock-damage-evidence` (10 MB, jpeg/png/webp). No public read. No update/delete storage policies.

Path is `{report_id}/{evidence_id}`. Cross-report uploads fail because the pending metadata row owns the path. Finalize requires matching size, MIME, MD5 etag, and magic bytes (`app_private.detected_image_mime`). Verification requires ≥1 finalized photo **for that report**. Another report's photo cannot satisfy the check.

## Idempotency and concurrency

- Create replays an identical `idempotency_key` + fingerprint; a different body raises `23505`.
- Submit replays the same submit key while already `submitted`.
- Stale `expected_version` raises `PT409`.
- Concurrent verify: document `FOR UPDATE`; one session verifies, the other sees verified or stale version.
- Duplicate open transit/loading sources fail unique indexes.
- Inbound remaining quantity is summed across non-terminal reports. Overlap is not silently merged.

Pending M5.3: storage/shop-return quantity overlap against on-hand/reserved stock cannot be determined safely while hold integration is absent, so submit stays gated.

## M4.1 inactive-godown integration

Non-transit creates, updates, submits, returns, verifies, rejects, and manager cancels call `assert_operational_active_branch`. Admin `access_all` cannot skip `is_active`. Historical Admin list/get still uses `operations.monitor` / `can_work_at_branch` (unchanged). Transit create uses `can_complete_consumed_delivery_at_branch` so an assigned driver or GM can document already-consumed goods after deactivation, without new stock writes.

## No stock mutation

M5.2 RPCs do not insert or update `stock_balances`, `stock_ledger`, `stock_transactions`, or `stock_reservations`. They do not add `DAMAGE_*` ledger types. Cutover flags are not changed by the migration. `damage.stock_hold_ready` is inserted as `false` and cannot be enabled until M5.3 replaces the isolation stub.

## Driver-specific and historical reads

`can_view_damage_report`: `operations.monitor` **or** (`damage.read` and `can_work_at_branch`) **or** (transit + `deliveries.execute` + reporter is caller + dispatch `assigned_to` is caller).

## Test results

Local Docker `supabase_db_sherlyos`, API `http://127.0.0.1:54321`. Cloud `ypkfondrkhkydkgovwup` was not written. Cutover flags restored to `false` / `false`. `damage.stock_hold_ready` remains `false`.

| Suite | Result |
|---|---|
| M5.2 SQL | passed (rollback) |
| M5.2 HTTP | passed (9 checks) |
| M5.2 concurrency | passed (one verify win, one conflict, no extra ledger) |
| M1-S1 SQL | passed |
| M1 posting SQL | passed |
| M1-S2 SQL | passed |
| M1-S3 SQL | passed |
| M2 SQL | passed |
| M3 SQL | passed |
| M4 SQL | passed |
| M4.1 SQL | passed |
| 4.1D security SQL | passed |
| M2 HTTP | passed (5) |
| M3 HTTP | passed (9) |
| M4 HTTP | passed (13) |
| M4.1 HTTP | passed (6) |
| M2 concurrency | passed |
| M3 concurrency | passed |
| M4.1 concurrency | passed |
| Playwright | **30 passed** |
| Vitest | 107 passed / 21 files |
| typecheck | passed |
| lint | passed (existing react-compiler warnings on Transfers / Opening / Products) |
| build | passed |

## Known limitations

1. Hold/quarantine is not implemented. On-hand scenarios cannot submit.
2. `damage.dispose` has no RPC.
3. Storage/shop-return duplicate-quantity detection is deferred.
4. Lot attribution is optional and unused while cutover is off.
5. `/damage` remains an empty placeholder; nav/route is permission-gated only.
6. Inbound DMG-01 vs DMG-02 is a reporter-chosen label on the same receipt-line damaged pool.

## Migration deployment prerequisites (do not execute now)

1. Separate owner authorization naming project `ypkfondrkhkydkgovwup` and this file only.
2. Confirm cloud tip is still `20261026120000` and inventory/cutover unchanged.
3. Operational write freeze, verified backup, dry-run showing only `20261026140000`.
4. Do not enable lot cutover. Do not set `damage.stock_hold_ready`; M5.2 rejects that write until isolation is installed.
