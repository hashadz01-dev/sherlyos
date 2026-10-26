# M5.4A — Damage Management Frontend Foundation

Local-only read UI over M5.2/M5.3 damage RPCs. Mutation workflows belong to M5.4B–E.

## Routes

| Path                | Screen                | Guard                  |
| ------------------- | --------------------- | ---------------------- |
| `/damage`           | Operational dashboard | `damageNavPermissions` |
| `/damage/reports`   | Paginated report list | `damageNavPermissions` |
| `/damage/:reportId` | Report detail         | `damageNavPermissions` |

`damageNavPermissions` = `damage.read`, `damage.record`, `damage.verify`, `operations.monitor`, `deliveries.execute`.

## Components

- `src/features/damage/DamagePage.tsx` — summary cards, readiness banner, queues
- `src/features/damage/DamageReportsPage.tsx` — filters, pagination, table/cards
- `src/features/damage/DamageReportDetailPage.tsx` — header, sources, lines, holds, evidence, activity
- `src/features/damage/components/*` — readiness, queues, filters, holds, evidence, timeline
- `src/features/damage/hooks/use-damage-access.ts` — UX-only capability flags
- `src/features/damage/utils/labels.ts` / `quantities.ts` — display helpers

API transport stays in `src/lib/damage/api.ts`.

## API contracts

### Existing

- `list_damage_reports` — authorized summaries + total (extended below)
- `get_damage_report` — full payload via `app_private.damage_report_payload`
- `get_damage_photo_url` — bucket/path for finalized evidence only; client signs via Storage

### Local read-only addition (`20261026170000_damage_frontend_read_contracts.sql`)

- `damage_stock_hold_ready_status()` — boolean readiness for damage-nav roles
- `get_damage_dashboard(target_godown)` — authorized totals + bounded queues
- `list_damage_reports(..., status_filter, scenario_filter, search_text, from_date, to_date)` — server filters including calendar-day range (UTC, inclusive) that applies to both `items` and `total`
- Payload enrichment: `updated_at`, hold `crate_code` / `location_role` / `posted_transaction_id`, exceptional `request_reason`

Does **not** flip `damage.stock_hold_ready` or lot cutover flags.

## Permission behavior

| Role                                         | Expected UX                                                                 |
| -------------------------------------------- | --------------------------------------------------------------------------- |
| Admin (`damage.read` / `operations.monitor`) | Dashboard + history; exceptional queue; no GM verify/post controls in M5.4A |
| Godown Manager                               | Godown reports; verification + disposition queues                           |
| Store Keeper                                 | Authorized reports and evidence                                             |
| Delivery Person                              | Transit reports for assigned dispatches only (`deliveries.execute`)         |
| Accounts / Sales                             | Route denied                                                                |

Backend `can_view_damage_report` remains authoritative.

## Readiness states

When `stock_hold_ready` is false, the dashboard banner states that stock-affecting damage submission is unavailable. The UI does not show the configuration key name or imply that held stock is active in development cloud.

## Evidence display

`get_damage_report` returns finalized evidence metadata only (id, mime, uploaded_at). Storage paths are omitted. Preview calls `get_damage_photo_url` (finalized + `can_view_damage_report`) then Storage `createSignedUrl` (60s) against the private `stock-damage-evidence` bucket. Expired/broken previews offer refresh. Signed URLs are not logged. Draft evidence cannot be located.

## Hold / quarantine visibility

Detail distinguishes:

- Reported quantity (lines)
- Logical hold (active non-quarantine holds)
- Quarantined quantity (quarantine intake / quarantine crate)
- Written-off quantity

Logical holds are never labeled as physical quarantine transfers.

## Backend read gaps

- List does not return verifier name (not in list payload).
- Mutation RPCs exist in the API module for later phases but are not wired to UI actions in M5.4A.

## Test coverage

- Unit: scenario/status labels, quantities, readiness copy, nav permissions
- Component: dashboard readiness, empty/error list, detail sections
- SQL (`supabase/tests/phase_m5_4a_damage_frontend_reads.sql`): date pagination totals, driver transit-only dashboard, FORCE RLS, photo locator ACL
- Playwright (`tests/e2e/damage.spec.ts`): admin/GM/keeper/driver/accounts plus server-side date pagination

## Known limitations

- No create/submit/verify/disposition/upload actions (M5.4B–E)
- Stock hold readiness remains false locally and on development cloud
- Driver transit visibility depends on assigned dispatch linkage

## Handoff for M5.4B–E

1. Create/edit draft forms and photo upload
2. Custody confirmation, submit, verify/reject/return
3. Ordinary write-off and exceptional disposition posting
4. Quarantine transfer action
5. Enable mutation buttons only when RPCs and readiness allow
