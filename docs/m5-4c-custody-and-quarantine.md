# M5.4C — Shop-Return Custody & Quarantine Management

Local-only frontend over existing M5.2/M5.3 damage RPCs, plus a read-only quarantine inventory RPC and a lock-order alignment on `transfer_verified_damage_to_quarantine`. This work does **not** flip `damage.stock_hold_ready`, lot cutover flags, or post stock from React.

## Routes

| Path                 | Screen                               | Guard                                                                 |
| -------------------- | ------------------------------------ | --------------------------------------------------------------------- |
| `/damage`            | Dashboard + awaiting-custody         | `damageNavPermissions`                                                |
| `/damage/reports`    | Report list                          | `damageNavPermissions`                                                |
| `/damage/quarantine` | Quarantine / hold inventory          | `damage.read`, `damage.record`, `damage.verify`, `operations.monitor` |
| `/damage/:reportId`  | Detail, custody, transfer, lifecycle | `damageNavPermissions`                                                |

`/damage/quarantine` is registered before `/damage/:reportId`. Delivery Person is excluded from the quarantine route.

Components:

- `DamageCustodyPanel` / `DamageCustodyConfirmDialog`
- `DamageQuarantinePage` / `DamageQuarantineTable`
- `DamageHoldDetails` (used by `DamageHoldsPanel`)
- `DamageQuarantineTransferDialog`
- `DamageLifecycleTimeline`
- Helpers: `utils/lifecycle.ts`, eligibility in `src/lib/damage/rules.ts`

## Exact RPC contracts

Existing mutations (signatures unchanged):

| RPC                                      | Arguments                                                                | Authorization                                                                                         | Effect                                                                                                                                                                                                                                                                               |
| ---------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `confirm_shop_return_custody`            | `target_report uuid`, `expected_version integer`                         | `assert_damage_create_auth` for `shop_return` = `damage.record` **and** `damage.verify` at the godown | Eligible `draft`/`returned` shop-return only. Stamps `physical_custody_confirmed_at/by`. Writes `custody_confirmed` event. Does **not** submit, isolate, or post stock. Does **not** consult `damage.stock_hold_ready`.                                                              |
| `transfer_verified_damage_to_quarantine` | `target_report uuid`, `expected_version integer`, `idempotency_key text` | `damage.verify` + `can_work_at_branch`                                                                | `status = verified` **and** `scenario = storage` only. Moves **all** active `on_hand_deduction` holds onto `ensure_godown_quarantine_crate`. Full quantity; destination crate is not selectable. Inactive godown → `23514`. Lot dual-write still follows current flags (both false). |

New / replaced reads (local `20261026180500`):

| RPC                                 | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `app_private.damage_report_payload` | Adds `physical_custody_confirmed_at/by/by_name`, `shop_name`, hold `source_reservation_id`, zone, product sku/name, `created_at`.                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `list_damage_reports`               | Adds `physical_custody_confirmed`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `get_damage_dashboard`              | Adds `queues.awaiting_custody` (shop-return `draft`/`returned` with null custody timestamp).                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `list_damage_quarantine_inventory`  | Paginated holds (page size cap 50). Filters: godown, product, product search, scenario, hold kind, hold status, date range. Gate: damage read/record/verify or `operations.monitor` — **not** `deliveries.execute`. Rows still pass `can_view_damage_report`. Computed `isolation_class` distinguishes logical hold, reservation conversion, shop-return intake, transferred quarantine, written-off. `totals` are filter-wide class sums; `current_unavailable_cases` excludes written-off / returned / released. Page items are never summed into those totals. |

Frontend never writes `physical_custody_confirmed_at` and never queries `damage_stock_holds` with a privileged credential.

## Custody workflow

1. Open an eligible shop-return (`draft` or `returned`).
2. Review product, returned cases, receiving godown.
3. Confirm in the dialog (explicit operational copy: does not submit, does not post stock).
4. Call `confirmShopReturnCustody` → refresh `get_damage_report`.
5. UI shows actor + timestamp from the payload.

Store Keepers have `damage.record` but not `damage.verify`, so they cannot confirm. Delivery Persons cannot confirm. Admin monitor-only accounts cannot confirm. Backend remains authoritative.

Repeated confirmation is idempotent: if `physical_custody_confirmed_at` is already set, the RPC returns the payload and does not insert a second `custody_confirmed` event.

Shop-return submit remains blocked while `damage.stock_hold_ready=false`. Custody confirmation is independent of that flag.

## Quarantine inventory semantics

The quarantine page lists **holds**, not the stock ledger. Categories are not summed into a single physical-stock figure. The summary strip uses server `totals` for the current filter, not cartons visible on this page:

| `isolation_class`                                | Meaning                                                                                              |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| `logical_hold`                                   | Active on-hand deduction on a non-quarantine crate. Unavailable logical stock.                       |
| `reservation_converted`                          | Loading reservation converted to a damage hold.                                                      |
| `shop_return_intake`                             | Shop-return quarantine intake (physical unavailable stock posted at submit when isolation is ready). |
| `transferred_quarantine`                         | Verified storage hold moved by `CRATE_TRANSFER`.                                                     |
| `written_off` / `returned_supplier` / `released` | Terminal or released hold states.                                                                    |

Inactive godowns remain visible to authorized historical readers (`operations.monitor`). They stay excluded from new operational transfers.

## Hold lifecycle (detail)

`DamageHoldsPanel` shows reported / held / quarantined / written-off carton cases from authorized payload holds. Hold rows are not editable. There is no manual release control.

Terminology:

- **Held** — unavailable logical stock (`active` non-quarantine hold).
- **Quarantined** — physically segregated unavailable stock.
- **Reservation converted** — previously allocated loading stock now held.
- **Written off** — quantity removed by an authorized ledger posting.

## Transfer eligibility

Shown only when:

- caller has `damage.verify`
- report `scenario = storage` and `status = verified`
- at least one active `on_hand_deduction` hold remains

UI does not offer partial quantity. Idempotency key is generated per dialog open and is **not** reused after an ambiguous failure (user must refresh; backend unique `(damage_report_id, damage_posting_kind)` plus key replay prevent double posting).

Shop-return verified reports are not transferable (backend `23514`).

## Lock-order review

M5.4B aligned `lock_damage_stock_grains` to products → `prepare_stock_locations` (zones → crates → branch). `transfer_verified_damage_to_quarantine` still called `assert_operational_active_branch` (branch `FOR UPDATE`) **before** grain locks.

`20261026180500` changes only that order:

1. Lock report + version + eligibility.
2. Snapshot `branches.is_active` **without** locking the branch row; `can_work_at_branch`.
3. Idempotency lookup.
4. `ensure_godown_quarantine_crate`.
5. `lock_damage_stock_grains` (products → locations including branch).
6. Post `CRATE_TRANSFER`, move holds to `transferred`.

Stock posting, hold updates, and event insert remain the same trusted path. This is not a mutation redesign.

`20261026180600` aligns stock-posting write-off the same way:

1. `post_ordinary_damage_writeoff` / `post_exceptional_damage_disposition` snapshot `is_active` without locking the branch.
2. `consume_damage_holds` locks products → locations, re-reads `is_active` under that lock, then locks hold rows.
3. Exact-once posting, hold consumption, events, and audit are unchanged.

Authorization for `confirm_shop_return_custody` remains `assert_damage_create_auth` for `shop_return` (`damage.record` **and** `damage.verify`). That is the live RPC rule. M5.3 prose that named only `damage.record` is incomplete. Permissions were not broadened.

## Lifecycle tracking

`damageLifecycleStages` maps persisted status, events, custody columns, evidence `verified_at`, and holds. Stages are conceptual. Rejected shop-return with remaining quarantine holds shows that stock stays quarantined until authorized disposition (M5.4E).

## Permission matrix

| Role                                               | View reports     | Confirm custody           | Quarantine list  | Transfer to quarantine |
| -------------------------------------------------- | ---------------- | ------------------------- | ---------------- | ---------------------- |
| Admin (`operations.monitor`, `damage.read`)        | Yes (historical) | No                        | Yes              | No                     |
| Godown Manager (`damage.record` + `damage.verify`) | Assigned godowns | Yes, eligible shop-return | Assigned godowns | Yes, verified storage  |
| Store Keeper (`damage.record`, `damage.read`)      | Assigned godowns | No                        | Assigned godowns | No                     |
| Delivery Person (`deliveries.execute`)             | Own transit only | No                        | No (route + RPC) | No                     |
| Accounts / Sales                                   | No               | No                        | No               | No                     |

Frontend route guards are UX only.

## Security controls

- SECURITY DEFINER reads keep `search_path = ''` and `can_view_damage_report`.
- Quarantine list rejects delivery-only callers before any hold rows are built.
- No browser write to hold quantities, custody timestamps, or stock ledger.
- Transfer and custody network failures tell the operator to refresh; they do not auto-retry.
- Flags left false. No synthetic production holds.

## Test evidence

| Suite       | File                                                                            |
| ----------- | ------------------------------------------------------------------------------- |
| SQL         | `supabase/tests/phase_m5_4c_custody_quarantine.sql`                             |
| HTTP        | `supabase/tests/phase_m5_4c_http_integration.mjs`                               |
| Concurrency | `supabase/tests/phase_m5_4c_concurrency.mjs`                                    |
| Vitest      | `tests/unit/damage-custody.test.ts`, `tests/unit/damage-custody-pages.test.tsx` |
| Playwright  | `tests/e2e/damage-custody.spec.ts` plus existing damage/reporting specs         |

## Known limitations

- Shop-return submit and isolation remain fail-closed while `damage.stock_hold_ready=false`.
- Transfer is storage + verified + full hold quantity only. No partials, no shop-return transfer.
- Destination quarantine crate is backend-selected.
- Lot-aware transfer is untested under current flags (both false).
- Write-off / exceptional disposition UI remains M5.4E. Trusted write-off lock order is now products → locations.
- Transfer vs `confirm_dispatch` and write-off vs `confirm_dispatch` are first-pass two-session races in `phase_m5_4c_concurrency.mjs`.

## M5.4D handoff

1. Verification UI for submitted reports (`verify_damage_report`), including evidence completeness.
2. Do not treat custody confirmation as verification.
3. Align any new verify-path locks with products → locations; do not reintroduce early `assert_operational_active_branch` before grain locks.
4. Keep `damage.stock_hold_ready` false until an explicit cutover.
5. After verify, storage reports with active on-hand holds may use the existing transfer RPC; do not add a second transfer writer.
6. Rejected shop-return quarantine remaining after reject is a disposition problem for M5.4E, not a verify-path move back to saleable stock.
