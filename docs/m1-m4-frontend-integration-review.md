# M1–M4 frontend integration review

Date: 2026-10-23  
Repository: `C:\Users\Hash\Desktop\Hashdev\sherlyos`  
Git HEAD: `202eb8a4c468e22a22e85ed082a4d2c7b000ab39` (`main`, ahead of `origin/main` by 4)  
Development project: `ypkfondrkhkydkgovwup`  
Development API: `https://ypkfondrkhkydkgovwup.supabase.co`  
This review did **not** commit, push, deploy frontend, apply cloud migrations, or mutate development-cloud business data.

## Verdict

**M1–M4 FRONTEND INTEGRATION PARTIAL — CORRECTIONS REQUIRED**

The integrated Vite frontend matches the deployed M1–M4 RPC contracts. Local journeys A–J pass against a disposable database, including SQL assertions for reservation-versus-DISPATCH. Cache isolation, Playwright local-target guarding, and inactive-godown reporting copy are in the working tree (uncommitted).

Release authorization is not complete because:

1. No development frontend host, CI deploy pipeline, or rollback artifact exists in the repository.
2. Inactive-godown reporting policy remains an unresolved product decision (totals unchanged; UI now explains the split).
3. The production JS entry chunk is still above Vite’s 500 kB warning after route splitting.

## Application route map

All routes below sit behind `RequireAuth` except `/login`. Feature pages are lazy-loaded from `src/app/lazy-pages.ts`.

| Path | Component | Guard | RPC / data | State |
|---|---|---|---|---|
| `/login` | `LoginPage` | public | Supabase Auth | Fully integrated |
| `/` | `DashboardPage` | session; KPIs gated by report permissions | `get_operations_dashboard` | Fully integrated |
| `/orders` | `OrdersPage` | `orders.capture` \| `orders.verify` \| `operations.monitor` | `list_orders` | Fully integrated |
| `/orders/new`, `/orders/:id/edit` | `OrderEditorPage` | `orders.capture` | `create_order`, `update_order` | Fully integrated |
| `/orders/:id` | `OrderDetailPage` | same as list | submit/hold/verify/cancel + availability | Fully integrated |
| `/picking` | `PickingPage` | allocate/manage/execute/monitor | `list_picking_requests` | Fully integrated; fails closed when cutover off |
| `/picking/exceptions` | `PickingExceptionsPage` | manage/allocate/monitor | `list_picking_exceptions` | Fully integrated |
| `/picking/allocate/:orderId` | `PickingAllocatePage` | `picking.allocate` | `preview_order_allocation`, `reserve_order_allocation` | Fully integrated; preview is not a deduction |
| `/picking/:requestId` | `PickingDetailPage` | allocate/manage/execute/monitor | assign/start/confirm/shortage/complete/handoff/cancel | Fully integrated; handoff is not DISPATCH |
| `/dispatch` | `DispatchPage` | `dispatch.view` \| `dispatch.confirm` \| `operations.monitor` | `list_dispatch_queue` | Fully integrated |
| `/dispatch/prepare/:orderId` | `DispatchPreparePage` | view/confirm/monitor | `preview_dispatch`, `prepare_dispatch`, `confirm_dispatch` | Fully integrated; confirm is the consume boundary |
| `/dispatch/:dispatchId` | `DispatchDetailPage` | view/confirm/deliveries.execute/assign/monitor | confirm/cancel/assign/start/ack/exception | Fully integrated |
| `/delivery-runs` | `DeliveryRunsPage` | execute/assign/view/monitor | `list_assigned_deliveries` | Fully integrated |
| `/deliveries` | `DeliveriesPage` | issue/acknowledge/monitor | `list_delivery_notes` | Fully integrated; DN ack ≠ POD |
| `/deliveries/new` | `NewDeliveryNotePage` | `delivery_notes.issue` | create from verified order | Fully integrated |
| `/deliveries/:noteId` | `DeliveryNoteDetailPage` | issue/acknowledge/monitor | generate/send/acknowledge/void | Fully integrated |
| `/deliveries/:noteId/print` | `DeliveryNotePrintPage` | same | print payload | Fully integrated |
| `/damage` | `DamagePage` | session only | none | **Placeholder** |
| `/refill` | `RefillPage` | session only | none | **Placeholder** |
| `/receiving` and children | receiving pages | execute/verify/monitor | receipt RPCs | Fully integrated; lot attribution requires dual-write |
| `/stock-verification` and children | verification pages | verify/count_assist/monitor | verification RPCs | Fully integrated |
| `/stock-lot-reconciliation` and children | lot recon pages | physical/legacy/monitor | recon RPCs | Fully integrated; cloud cutover remains off |
| `/stock-adjustments` and children | adjustment pages | request/post/approve/monitor/read | adjustment RPCs | Fully integrated |
| `/inventory` | `InventoryPage` | `stock.read` | `list_stock_balances` | Fully integrated; on-hand, not available-to-pick |
| `/inventory/opening` | `OpeningStockPage` | `stock.opening.post` | `post_opening_stock`, cutover state | Fully integrated |
| `/inventory/transfers` | `TransfersPage` | `stock.transfer.post` | `post_crate_transfer`, lot balances | Fully integrated |
| `/inventory/history` | `HistoryPage` | `stock.read` | `list_stock_transactions` | Fully integrated; includes DISPATCH |
| `/masters` | `MastersPage` | products/suppliers/shops/locations read | hub only | Fully integrated |
| `/masters/*` | catalog pages | matching `*.read` | master RPCs / tables | Fully integrated |
| `/reports` | `ReportsPage` | union of report permissions | hub | Fully integrated; delivery person can open hub |
| `/reports/inventory` | `InventoryReportPage` | `stock.read` \| `operations.monitor` | `list_inventory_report`, export | Fully integrated |
| `/reports/lots` | `LotStockReportPage` | same | `list_lot_stock_report` | Fully integrated; empty while no lots |
| `/reports/movements` | `MovementReportPage` | same | `list_stock_movement_report` | Fully integrated |
| `/reports/orders-picking` | `OrderPickingReportPage` | order/picking/monitor | `list_order_picking_report` | Fully integrated |
| `/reports/dispatch` | `DispatchReportPage` | dispatch/delivery/monitor | `list_dispatch_delivery_report` | Fully integrated |
| `/reports/exceptions` | `ExceptionsReportPage` | operations report union | `list_operations_exceptions` | Fully integrated |
| `/settings` | `SettingsPage` | session | public env presence only | Partial: no account admin |
| `/employees`, `/branches`, `/users-roles` | admin pages | `employees.read` | assign/revoke RPCs | Fully integrated |
| `/audit` | `AuditPage` | `audit.read` | `audit_logs` | Fully integrated |

Screens requiring cutover prerequisites: picking allocation/reservation, dispatch confirm, lot-aware opening/receiving attribution. With both flags false these paths fail closed.

## Role / permission matrix

Roles are loaded from `user_roles` → `roles.code` and `role_permissions`. This review did not invent roles. Observed in fixtures and seed: `admin`, `godown_manager`, `store_keeper`, `delivery_person`, `accounts`, `salesperson`.

Frontend navigation is not the security boundary. Direct URL access uses `RequirePermission` / `RequireAnyPermission`. Backend RPCs still call `app_private.assert_permission`.

| Surface | Admin | Godown manager | Store keeper | Delivery person | Accounts |
|---|---|---|---|---|---|
| Overview KPIs | yes | inventory/ops as granted | limited | assigned deliveries | orders as granted |
| Orders | yes | monitor if granted | no | no | capture/verify |
| Picking allocate | yes | yes | no | no | no |
| Picking execute | yes | manage | yes | no | no |
| Confirm dispatch | yes | yes | no | no | no |
| Delivery runs / POD | yes | assign | no | assigned only | no |
| Inventory / reports inventory | yes | yes | read if granted | no | no |
| Reports hub | yes | yes | if any ops perm | yes (`deliveries.execute`) | if order perms |

Store Keeper cannot confirm dispatch (Playwright + M3 HTTP). Delivery person cannot open `/inventory`, `/orders`, `/picking`, `/dispatch` list, `/reports/inventory`, or `/masters`.

## Branch behavior

Operational selectors (opening stock, dashboard dropdown from `authorized_branches`) list **active** godowns.

M4 admin totals and `stock_by_godown` **include inactive godowns**. The dashboard dropdown does not. Inventory report now groups inactive sites as “Inactive (historical reporting)” without activating them.

**Unresolved product decision:** whether “All authorized branches” should continue to include inactive stock, or whether reports should default to active-only. This review did not change totals.

## Frontend-to-RPC contract map

Argument names were compared to local migrations and the live development catalog. No missing RPCs were invented. No deployed functions were changed.

M4: `get_operations_dashboard`, `list_inventory_report`, `list_lot_stock_report`, `list_stock_movement_report`, `list_order_picking_report`, `list_dispatch_delivery_report`, `list_operations_exceptions`, `export_operations_report`.

M2: `list_picking_requests`, `get_picking_request`, `preview_order_allocation`, `reserve_order_allocation`, `assign_picking_request`, `start_picking`, `confirm_picking_quantity`, `report_picking_shortage`, `complete_picking`, `confirm_picking_handoff`, `cancel_picking_request`, `get_picking_handoff`, `list_picking_exceptions`.

M3: `list_dispatch_queue`, `preview_dispatch`, `get_dispatch_request`, `prepare_dispatch`, `confirm_dispatch`, `cancel_dispatch`, `assign_dispatch_delivery`, `start_dispatch_delivery`, `acknowledge_dispatch_delivery`, `report_dispatch_delivery_exception`, `list_assigned_deliveries`, `list_dispatch_assignees`.

M1 inventory: `list_stock_balances`, `list_stock_lot_balances`, `list_stock_transactions`, `post_opening_stock`, `post_crate_transfer`, `get_stock_lot_cutover_state`.

Orders / DN use existing `list_orders`, `create_order`, `submit_order`, `verify_order`, `hold_order`, `cancel_order`, and delivery-note RPCs.

Error mapping: PostgREST `42501` / JWT expiry / `PT409` become operator messages. SQL `details`/`hint` are not shown. Stock-consuming mutations are not auto-retried. Double-submit is blocked with `isPending` on confirm/reserve/dispatch/POD.

## M1 inventory

Inventory shows crate on-hand cases, not available-to-pick. Lot identities are linked to `/reports/lots`. History labels `DISPATCH` and `ADJUSTMENT`. Opening/transfer remain permission-gated. Aggregate stock is not presented as pickable while cutover is inactive.

## M2 picking

Allocation preview does not write reservations until confirm. Handoff leaves reservations `active` and writes **zero** `DISPATCH` rows (Playwright SQL). Cutover-off preview shows the dual-write blocker and disables confirm (journey I).

## M3 dispatch / delivery

Confirm dispatch is the consume boundary. Playwright after UI confirm: two `DISPATCH` rows / three cartons / two consumed reservations for the disposable SKU (one SQL-prepared fail fixture + one UI confirm). Failed delivery leaves DISPATCH count unchanged and creates no `RECEIPT`. Driver POD uses recipient name. Store keeper is denied prepare.

## M4 reporting

Eight live RPCs match the client. Available-to-pick is `not_applicable` while cutover is off. Lot report empty state is honest. CSV export uses the existing sanitizer. Query keys already included user id; session hashing now covers every module.

Development-cloud read-only baseline (this review): on-hand **73** cartons across **11** balances, **0** lots, **0** dispatch requests, **0** reservations. `sum(stock_transactions.quantity)` is **104** across **20** rows (transfer and other positive document quantities; not a second on-hand figure). Do not hardcode these into the UI.

## Orders and delivery notes

Status set remains `draft | submitted | held | verified | cancelled` with hold/verify/cancel as allowed transitions, not a single forced line. DN: `draft → generated → sent → acknowledged`, plus void. Order detail links into picking allocate and dispatch prepare. DN acknowledgement is paperwork and does not inflate delivered KPIs.

## Cross-module journeys (local disposable DB)

| ID | Result |
|---|---|
| A Auth login/refresh/logout | Pass |
| B Branch scope | Covered by M4 HTTP cross-branch denial + report branch filters |
| C Order → picking → ready_for_dispatch | Pass (`picking.spec.ts`) with SQL: 0 DISPATCH, active reservations |
| D Picking → confirm dispatch | Pass (`dispatch.spec.ts`) with SQL: DISPATCH once per UI confirm |
| E Assign → start → POD | Pass |
| F Delivery exception, no restock | Pass; RECEIPT count 0 |
| G Reporting after local dispatch | Pass (`reports.spec.ts` + movement type DISPATCH in UI) |
| H Account switch cache isolation | Pass |
| I Cutover inactive fail-closed | Pass; flags `false|false`; 0 reservations / 0 DISPATCH |
| J Unauthorized direct URLs | Pass for inventory/orders/picking/dispatch list/inventory report/masters |

## Cache / session isolation

`QueryClient` previously lived for the app lifetime and was never cleared. Protected keys outside M4 omitted user id.

Fix:

- `setQueryScopeUserId` during `AuthProvider` render
- `queryKeyHashFn` prefixes the current user
- `QueryCacheIsolation` cancels and `clear()`s on identity change, including logout

Unit test: user A `stock-balances` is not readable as user B.

## Responsive / accessibility

Login fits 390×844. Inventory report and lot-reconciliation create form fit tablet 768. Sidebar remains `md:flex`; `MobileNav` covers smaller viewports. Tables use `overflow-x-auto`. Permission loading uses `LoadingScreen`. Access denied uses a heading plus back link. Alerts use `role="alert"`.

## Performance

After route-level `React.lazy`:

- Entry `dist/assets/index-*.js`: **781.27 kB** (gzip **229.59 kB**)
- Vite still warns above 500 kB because React, Supabase, and the shell remain eager
- Feature pages are separate chunks (dashboard 8.4 kB, dispatch detail 12 kB, lot recon detail 26 kB)

No new large dependencies were added.

## Test results

| Suite | Result |
|---|---|
| `npm run typecheck` | Pass |
| `npm run lint` | Pass (existing React Compiler warnings on `watch()`) |
| `npm test` | 18 files, **95** tests pass |
| `npm run build` | Pass, 500 kB entry warning remains |
| Playwright Chromium | **29** pass |
| M4 SQL | Pass (clean local reset) |
| M2 SQL | Pass |
| M3 SQL | Pass |
| M1 lot-aware posting + S1 flags + S2 recon + S3 attribution | Pass |
| 4.1a/b/c orders, 4.1d security | Pass |
| 4.2a/b/c DN, 4.2f stale version | Pass |
| 4.3e2b1 / 4.3e2b2 ledger/writer | Pass |
| M4 HTTP | 13 pass |
| M2 HTTP | 5 pass |
| M3 HTTP | 9 pass |

Skipped (documented, not weakened):

- `phase_m1_concurrency.mjs` — unsafe on the working local database
- Other concurrency `.mjs` suites — no trusted-writer or lock-order change in this frontend task
- M1 S2/S3 HTTP — not re-executed this pass after M2/M3/M4 HTTP passed

A polluted local database caused M4 SQL `opening summary` to fail before reset. `npx supabase db reset --local --yes` was used (disposable local only).

## Development-cloud read-only verification

- Linked URL: `https://ypkfondrkhkydkgovwup.supabase.co`
- 29 migrations, tip `20261023200000_operational_intelligence`
- Eight M4 RPCs present; sampled M1/M2/M3 RPCs present
- Cutover flags **false / false**
- On-hand 73, lots 0, dispatch requests 0, reservations 0
- No cloud DDL/DML from this task

## Deployment target

No Vercel, Netlify, Cloudflare, GitHub Actions, or Pages config exists. Scripts are `dev`, `build`, `preview`, `test`, `test:e2e`. Frontend env is only `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`. `.env.example` already names `ypkfondrkhkydkgovwup`. Default `npm run dev` uses `.env.local` (development cloud). Playwright uses `--mode m1s2` and now refuses to start unless the effective Vite URL host is `127.0.0.1` or `localhost`.

There is no prior frontend deployment artifact to roll back.

## Release checklist (do not execute until owner authorizes)

1. Owner names a **development-only** frontend host. Do not create production.
2. Confirm the host’s env is `VITE_SUPABASE_URL=https://ypkfondrkhkydkgovwup.supabase.co` and the development publishable key — never production.
3. Confirm cutover flags remain false/false.
4. Build from this working tree (or the proposed checkpoint) with `npm run typecheck && npm run lint && npm test && npm run build`.
5. Smoke login against development Auth; open overview; confirm available-to-pick is not applicable; confirm 0 lots / 0 dispatch.
6. Do not run picking confirm or dispatch confirm against development cloud.
7. Keep a copy of the previous static build if the host retains one.

## Rollback plan

Because no frontend is deployed, rollback is “do not publish.” After a future deploy: restore the previous static artifact on the same host, or point the host back to the last known `202eb8a` build, without changing database migrations. Do not reverse `20261023200000` on development cloud as part of a frontend rollback.

## Outstanding blockers

1. Owner must designate the development frontend host and env.
2. Owner should confirm inactive-godown reporting policy.
3. Entry bundle still large; further splitting of the shell is optional follow-up.
4. `/damage` and `/refill` remain empty by design.
5. Settings does not administer accounts.

## Proposed Git checkpoint (DO NOT COMMIT)

Preserve unrelated: `.cursor/mcp.json`, `README.md`, `.cursor/rules/`.

Include:

```
playwright.config.ts
src/app/lazy-pages.ts
src/app/layouts/AppShell.tsx
src/app/providers.tsx
src/app/router.tsx
src/features/administration/branches/BranchesPage.tsx
src/features/inventory/HistoryPage.tsx
src/features/inventory/InventoryLinks.tsx
src/features/inventory/InventoryPage.tsx
src/features/reports/BranchFilterNote.tsx
src/features/reports/InventoryReportPage.tsx
src/lib/auth/AuthProvider.tsx
src/lib/delivery-notes/api.ts
src/lib/dispatch/api.ts
src/lib/inventory/api.ts
src/lib/inventory/labels.ts
src/lib/lot-reconciliation/api.ts
src/lib/masters/api.ts
src/lib/orders/api.ts
src/lib/picking/api.ts
src/lib/query/QueryCacheIsolation.tsx
src/lib/query/session-scope.ts
src/lib/rpc/user-error.ts
src/pages/dashboard/DashboardPage.tsx
tests/e2e/assert-local-target.ts
tests/e2e/dispatch.spec.ts
tests/e2e/journeys.spec.ts
tests/e2e/picking.spec.ts
tests/e2e/reports.spec.ts
tests/integration/dashboard.test.tsx
tests/unit/inventory.test.ts
tests/unit/query-session-scope.test.ts
tests/unit/rpc-user-error.test.ts
docs/m1-m4-frontend-integration-review.md
```

Proposed message:

```
fix(frontend): isolate session cache and harden M1-M4 development release

Clear and hash TanStack Query by signed-in user, fail closed if Playwright would target a non-local API, and explain inactive-godown reporting without changing stock totals.
```
