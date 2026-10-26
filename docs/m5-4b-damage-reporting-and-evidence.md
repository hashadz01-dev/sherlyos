# M5.4B — Damage Reporting Forms, Draft Management, Photo Evidence

Local-only create/edit/submit UI over M5.2/M5.3 damage RPCs. Stock postings, holds, quarantine, and lot cutover stay in trusted PostgreSQL functions. This work does **not** flip `damage.stock_hold_ready`.

## Routes and components

| Path                     | Screen                                             | Guard                                   |
| ------------------------ | -------------------------------------------------- | --------------------------------------- |
| `/damage`                | Dashboard (now includes New report when permitted) | `damageNavPermissions`                  |
| `/damage/reports`        | Report list                                        | `damageNavPermissions`                  |
| `/damage/new`            | Create draft                                       | `damage.record` or `deliveries.execute` |
| `/damage/:reportId/edit` | Edit draft/returned                                | `damage.record` or `deliveries.execute` |
| `/damage/:reportId`      | Detail (Edit draft when reporter + editable)       | `damageNavPermissions`                  |

`/damage/new` and `/damage/:reportId/edit` are registered before `/damage/:reportId`.

Components:

- `src/features/damage/DamageReportEditorPage.tsx` — create and edit
- `src/features/damage/components/DamageScenarioPicker.tsx`
- `src/features/damage/components/DamageSourcePicker.tsx`
- `src/features/damage/components/DamageLineEditor.tsx`
- `src/features/damage/components/DamageEvidenceUploader.tsx`
- `src/features/damage/components/DamageSubmitReview.tsx`
- Helpers: `src/features/damage/utils/draft.ts`, `submit.ts`

Admin monitor-only accounts can open the dashboard/list/detail routes and cannot open create/edit.

## Scenario / source mapping

Database enum values, not invented identifiers:

| Code            | Blueprint | Source picker                                                                     | Create extras                                    |
| --------------- | --------- | --------------------------------------------------------------------------------- | ------------------------------------------------ |
| `refill_supply` | DMG-01    | Posted receipt + remaining `damaged_cases`                                        | `receiving.execute` or `damage.verify`           |
| `unloading`     | DMG-02    | Same inbound receipt contract                                                     | `receiving.execute` or `damage.verify`           |
| `storage`       | DMG-03    | Authorized godown crates/products with on-hand                                    | `damage.verify`                                  |
| `loading`       | DMG-04    | Picking `allocated`/`picking`/`picked`/`ready_for_dispatch` + active reservations | `loading.assist` or `damage.verify`              |
| `transit`       | DMG-05    | Consumed dispatch; GM all at branch, driver assigned only                         | `damage.record` or assigned `deliveries.execute` |
| `shop_return`   | DMG-06    | Active shops + godown crate/product catalog                                       | `damage.verify`                                  |

All six require `damage.record` except the assigned-driver transit path.

## Exact RPC contracts

Existing writes (unchanged signatures):

| RPC                            | Arguments                                                                                                                       | Notes                                                                                                                                          |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `create_damage_report`         | `scenario, target_godown, report_lines, idempotency_key, notes, receipt_id, picking_request_id, dispatch_id, order_id, shop_id` | Returns payload. Idempotent replay on same fingerprint.                                                                                        |
| `update_damage_report`         | `target_report, expected_version, report_lines, notes, receipt_id, picking_request_id, dispatch_id, order_id, shop_id`          | Reporter only. `draft`/`returned`. `PT409` on stale version. `20261026180100` qualifies SET columns so PostgREST named args are not ambiguous. |
| `submit_damage_report`         | `target_report, expected_version, idempotency_key`                                                                              | Reporter only. Isolation always invoked for hold scenarios.                                                                                    |
| `create_damage_photo_upload`   | `target_report, photo_note`                                                                                                     | Returns `{ id, bucket, path }`. Private bucket `stock-damage-evidence`.                                                                        |
| `finalize_damage_photo_upload` | `target_evidence, image_base64`                                                                                                 | Fetches private Storage bytes and requires exact equality with the payload. Catalog metadata is not proof.                                     |
| `get_damage_photo_url`         | `target_evidence`                                                                                                               | Finalized only. Bucket + path, never a public URL.                                                                                             |
| `get_damage_report`            | `target_report`                                                                                                                 | Payload via `app_private.damage_report_payload`.                                                                                               |

New local read-only RPC:

| RPC                          | Arguments                                                                             | Notes                                                                                                                                                     |
| ---------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `list_damage_report_sources` | `scenario, target_godown, search_text, page, page_size, catalog_search, catalog_page` | SECURITY DEFINER, `search_path=''`, **not STABLE**. Page size cap 50. Shop-return products are searched/paginated (no 200 cap). Authenticated grant only. |

Payload change in `20261026180000_damage_reporting_source_pickers.sql`: evidence metadata includes unfinalized rows (`finalized=false`) **without** `storage_path`. Preview still requires `verified_at`.

Frontend `sourceRefsForScenario` posts only the document ids `validate_damage_sources` accepts (transit = dispatch only; inbound = receipt only; storage = none; loading = picking + optional preparing dispatch; shop_return = shop + optional order).

## Draft lifecycle

```
create → draft
update (reporter, expected_version) → draft | returned
submit → submitted (or isolation/custody/validation failure)
```

Frontend:

- Create uses a user-scoped localStorage idempotency key so repeated Save clicks, refresh, and extra tabs replay the same backend key. `create_damage_report` idempotency_key + fingerprint remain authoritative.
- Submit uses a per-report sessionStorage key. After an ambiguous network failure the UI refreshes and does not auto-retry.
- Unsaved changes use `beforeunload`.
- Stale `version` maps to a refresh message.
- Expired JWT maps to sign-in again.
- Locked statuses are not editable in the UI.

## Evidence upload flow

1. Validate JPEG/PNG/WebP and 10 MB (bucket limits).
2. `create_damage_photo_upload` inserts catalog row and returns private path `{reportId}/{evidenceId}`.
3. Browser uploads to private Storage. This is **not** finalization.
4. `finalize_damage_photo_upload` decodes the submitted payload, checks magic bytes, requires a Storage catalog row owned by the uploader, then **GETs the private object through the in-cluster Storage API using the caller JWT** and requires byte-for-byte equality with the payload. Missing object, mismatched stored bytes, wrong uploader, or replay fails closed. Catalog eTag/size/MIME are never treated as stored content and are not rewritten from the client.
5. Preview uses `get_damage_photo_url` + 60s signed URL. Signed URLs are not logged.

## Photo security boundary

Trusted path in `20261026180300` (`app_private.damage_storage_object_bytes`):

- Private bucket only. No public URLs. No service-role key in the frontend.
- Client-supplied paths, base64, hashes, MIME types, and file sizes are not treated as proof of stored bytes.
- A `storage.objects` metadata row is ownership corroboration only. Matching eTag/size/MIME without a fetchable object fails closed.
- Finalize allowlists `http://kong:8000` and `http://supabase_kong_sherlyos:8000`, forwards the caller `Authorization`/`apikey` headers, and compares `text_to_bytea(response)` to the decoded payload.
- SQL sessions that only set JWT claim GUCs cannot fetch Storage bytes; those tests fail closed unless they are explicit fixtures that stamp `verified_at`.
- The uploader may SELECT their own unfinalized object so the JWT GET can read pending bytes. Other users cannot read unfinalized objects. `get_damage_photo_url` still requires `verified_at`.
- Residual trust boundary: Postgres must reach the allowlisted in-cluster Storage API (`http://kong:8000`, `http://supabase_kong_sherlyos:8000`). If Kong is unreachable, finalization fails closed. Cloud/project URLs are not allowlisted; remote finalize stays fail-closed until a later allowlisted base URL is added and tested. `extensions.text_to_bytea` is the binary-safe converter (NUL and high bytes included). JSON/text Storage error bodies are rejected.

## Photo requirement policy

`submit_damage_report` does **not** require evidence. `verify_damage_report` does. The create/edit UI still requires at least one finalized photo before Submit as an operational UX policy so warehouse users do not send incomplete reports. SQL/HTTP callers may still submit without photos. Submitted reports accept additional uploads from the reporter or a verifier on the detail page.

## Submission readiness

Frontend gates (backend remains authoritative):

- Isolation scenarios (`storage`, `loading`, `shop_return`) stay blocked while `damage.stock_hold_ready=false`.
- Inbound (`refill_supply`, `unloading`) and `transit` may submit; submit RPC does not call isolation for those scenarios.
- Shop-return also blocks on missing physical custody. Custody confirmation is **not** implemented here (M5.4C).
- UI requires at least one finalized photo before Submit even though `submit_damage_report` itself does not. Verify still requires evidence.

No frontend stock deduction, reservation conversion, or ledger posting.

## Role permissions

| Role             | Create/edit UX                                   | Backend authority                                        |
| ---------------- | ------------------------------------------------ | -------------------------------------------------------- |
| Godown Manager   | All six scenarios in assigned godowns            | `damage.record` + `damage.verify`                        |
| Store Keeper     | Inbound + loading (+ transit if `damage.record`) | `receiving.execute` / `loading.assist` extras            |
| Delivery Person  | Transit on assigned consumed dispatches only     | `deliveries.execute` + assignment                        |
| Admin            | Read/history only. No create/edit routes         | `operations.monitor` / `damage.read`. No `damage.record` |
| Accounts / Sales | Routes denied                                    | No grants                                                |

Frontend flags are UX-only.

## Test results

Local, this session. Flags confirmed `false` after the suites.

| Suite                                   | Result                                                                       |
| --------------------------------------- | ---------------------------------------------------------------------------- |
| Vitest                                  | 24 files, 139 tests passed                                                   |
| Typecheck                               | passed                                                                       |
| Lint                                    | passed (existing warnings; editor hydrate `set-state-in-effect`)             |
| Build                                   | passed                                                                       |
| `phase_m5_4b_damage_reporting.sql`      | passed (catalog-only finalize fails closed; shop search reaches product 205) |
| `phase_m5_4a_damage_frontend_reads.sql` | passed                                                                       |
| `phase_m5_2_damage_foundation.sql`      | passed (serial)                                                              |
| `phase_m5_3_damage_stock_isolation.sql` | passed (serial after M5.2)                                                   |
| M5.4B HTTP                              | 14 passed (includes NUL/high-byte stored-byte finalize)                      |
| M5.2 HTTP                               | 8 passed                                                                     |
| M5.3 HTTP                               | 4 passed                                                                     |
| M5.2 concurrency                        | passed (single verified report)                                              |
| M5.3 race C                             | 20/20 independent concurrent runs, fail-fast, no retries                     |
| M5.3 concurrency                        | 9/9 passed on the first full matrix after the lock-order fix                 |
| Playwright `damage-reporting.spec.ts`   | 10 passed                                                                    |
| Playwright `damage.spec.ts`             | 7 passed                                                                     |
| Full Playwright                         | 47 passed                                                                    |

`tests/e2e/reports.spec.ts` KPI locator now uses `{ exact: true }` so a godown option whose code contains `7` cannot steal `getByText("7")`. No reports product change.

## Known blockers / limitations

- Stock isolation remains fail-closed. Storage/loading/shop-return cannot submit until operations enables readiness (not done here).
- Shop-return custody confirmation is M5.4C. Submit stays blocked.
- Cloud Storage hosts are not in the local Kong allowlist. Remote finalize stays fail-closed until a later allowlisted base URL is added.
- Shop-return product catalog is searched and paginated (page size cap 50); the previous 200-row cap is removed.
- Lot remains optional per `assert_optional_damage_lot`. Cutover flags stay false.
- `list_damage_report_sources` is not STABLE so PostgREST uses POST, not a read-only GET.

## M5.4C handoff

1. Authorized physical-custody confirmation UI calling `confirm_shop_return_custody`.
2. Only then can shop-return submit succeed after isolation is also ready.
3. Do not add a client-side custody checkbox that writes the timestamp.
4. Keep shop-return intake on the trusted isolation function.

## Safety

`damage.stock_hold_ready`, `stock.lots.dual_write_enabled`, and `stock.lots.aggregate_only_blocked` remain `false`. No commit, push, cloud migration, Netlify deploy, or cutover.
