# Implementation progress

## Current status

- Phase 2B — committed and pushed to `origin/main`.
- Phase 2C — architecture is in `docs/phase-2c-master-data-plan.md`. Phase 2C.1 and Phase 2C.2 are applied to development Supabase `ypkfondrkhkydkgovwup`. Phase 2C.2 is committed as `01907d8aa94bbba6dc290fdf3effff6fba430731`. Phase 2C.3 development-cloud deployment is complete on development Supabase `ypkfondrkhkydkgovwup` and is committed to `main`. Phase 2C is not complete.
- Phase 3.1 — stock receiving is applied to development Supabase `ypkfondrkhkydkgovwup` through `20261015200000_stock_receiving.sql` and is committed to `main`. Phase 3.2 has not started.

The sections below are the Phase 2A and Phase 2B records. Some early paragraphs still describe the state before the development database was updated.

## Phase 2A security gate (latest)

### Static SQL / security review

| Area                           | Result                                                                                                                                  |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| Syntax and dependency order    | No issues found in manual review (foundation migration first, then access control).                                                     |
| Grants and RLS                 | All eight tables: RLS enabled + forced; `authenticated` has select-only via policies; no client insert/update/delete policies.          |
| SECURITY DEFINER               | Public RPCs and `app_private.*` helpers use `set search_path = ''`.                                                                     |
| Privilege escalation           | Self-target blocked on roles, active status, administered profile, branch assignments.                                                  |
| Bootstrap                      | `bootstrap_initial_admin` granted to `service_role` only, not `authenticated`; confirmation phrase required; fails if any Admin exists. |
| Godown Manager verification    | `stock.verify` granted only to Godown Manager.                                                                                          |
| Adjustment posting             | `stock.adjustment.post` (Godown Manager) separate from `stock.adjustment.approve_exceptional` (Admin).                                  |
| Store Keeper                   | `stock.count_assist` only — not verification owner.                                                                                     |
| Delivery Person transit damage | Documented as unresolved; `damage.record` **not** granted.                                                                              |
| 50-unit configuration seed     | Treated as **provisional placeholder**, not an approved business rule.                                                                  |

### Defects found and fixed in this gate

1. **`assign_user_branch`** — now rejects unknown or inactive operating sites before insert.

### Remaining security concerns (accepted for dev apply with review)

1. **No local migration execution** — Docker Desktop daemon was not running; `npx supabase status` failed. SQL was **not** machine-applied in this environment.
2. **`service_role` bypasses RLS** — Supabase platform behavior; mitigated by keeping the key out of the repo and browser.
3. **`has_permission` executable by any authenticated user** — returns only the caller’s own permission state; acceptable for app use, minor probing surface.
4. **`grant usage on schema app_private to authenticated`** — required for executing granted functions in that schema.
5. **RPC and RLS not smoke-tested with JWT roles** — schema apply and advisors passed locally; authenticated RPC paths were not exercised end-to-end.

### Local migration validation (Docker running, 2026-10-14)

| Command                            | Result                                                                                                            |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `npx supabase start`               | **Passed** — `20261014000000_foundation.sql` and `20261014150000_access_control.sql` applied.                     |
| `npx supabase db lint --local`     | **Passed** — no schema errors.                                                                                    |
| `npx supabase db reset --local`    | **Passed** — clean reapply.                                                                                       |
| `npx supabase db advisors --local` | **Passed** — no issues.                                                                                           |
| Stock permission spot-check        | Godown Manager has verify/post/request/report; Admin has approve_exceptional; Store Keeper has count_assist only. |

**SQL validation passed** on local Supabase. Remote project `ypkfondrkhkydkgovwup` was not modified.

### Application validation (actual)

| Command             | Result                     |
| ------------------- | -------------------------- |
| `npm run typecheck` | Passed                     |
| `npm run lint`      | Passed                     |
| `npm test`          | Passed — 6 files, 12 tests |
| `npm run build`     | Passed                     |

## Safe apply to development Supabase (when approved)

Do **not** apply until stakeholders accept `docs/access-control.md` and open items below.

```powershell
cd C:\Users\Hash\Desktop\Hashdev\sherlyos
# Optional but recommended when Docker works:
# npx supabase init   # only if config.toml is added later
# npx supabase start
# npx supabase db reset   # local dry-run only

# Link dev project (access token in environment, not in repo):
# npx supabase link --project-ref ypkfondrkhkydkgovwup

# Apply to linked development database:
# npx supabase db push

# One-time in SQL editor (postgres / dashboard), after Auth user exists:
# select app_private.bootstrap_initial_admin('<auth-user-id>'::uuid, 'create-initial-administrator');
```

After apply: assign roles and sites via `assign_user_role`, `create_branch`, `assign_user_branch`. Verify RLS manually with test JWTs in the SQL editor or a small script.

## Gate recommendation

**READY** to apply the reviewed migrations to the **development** Supabase project via `npx supabase db push` after `supabase link`. Local apply and lint succeeded.

**NOT READY** for production until dev apply, bootstrap, RPC smoke tests, and business sign-off on provisional configuration values are complete.

## Development cloud deployment attempt (2026-10-14)

- Target project from `.env.example`, docs, and code: `ypkfondrkhkydkgovwup`.
- `.env` and `.env.local` exist locally and are git-ignored. Access token is present in `.env` (presence only checked, value never printed).
- `npx supabase link --project-ref ypkfondrkhkydkgovwup` **failed** with `LinkProjectStatusError`: the token's account lacks privileges for that project endpoint.
- `npx supabase projects list` with the same token shows only project `b2bintelli` (`ivmgjtinhpyvtsogpjyt`). Target `ypkfondrkhkydkgovwup` is **not visible** to this token.
- Remote migration history could **not** be checked. `db push --dry-run` was **not** run because linking is a prerequisite.
- No remote database was modified. No Admin bootstrap was run. No role/RPC/JWT tests against cloud were run.
- Fresh app checks in this pass: typecheck passed, lint passed, Vitest 12/12 passed, production build passed (894.99 kB JS warning unchanged).

## Re-check with corrected token (2026-10-14)

- `npx supabase projects list` now shows only `sherlysos` (`ypkfondrkhkydkgovwup`, `ACTIVE_HEALTHY`, `ap-northeast-2`, created `2026-10-14`). Target confirmed.
- `npx supabase link --project-ref ypkfondrkhkydkgovwup` succeeded.
- `npx supabase migration list --linked` shows both local migrations with empty remote history: `20261014000000` and `20261014150000` are pending, nothing else.
- `npx supabase db push --linked --dry-run` would push exactly `20261014000000_foundation.sql` and `20261014150000_access_control.sql`. Remote database was **not** modified. Actual push awaits explicit approval.

## Cloud apply + JWT validation (2026-10-14, after approval)

- `npx supabase db push --linked` applied `20261014000000_foundation.sql` and `20261014150000_access_control.sql` to development. `migration list --linked` now shows both as applied.
- Created six throwaway Auth users (`phase2a.*@example.com`, email-confirmed, server-side Admin API). Trigger created one profile each with **zero** roles. The pre-existing account also has no roles: no auto-admin anywhere.
- `app_private.bootstrap_initial_admin` ran once via owner SQL (SQL-editor equivalent): succeeded. Repeat run correctly failed with `initial administrator already exists`.
- Signed in as all six users (real JWTs) — **34/34 checks passed**:
  - Admin assigned the other five roles via `assign_user_role`; self-assign rejected (`you cannot change your own roles`).
  - Salesperson granting Admin rejected (`not authorized`).
  - Admin created site `godown_main`, assigned the Godown Manager; godown sees 1 site, unassigned salesperson sees 0; unknown-branch and self-branch changes rejected.
  - Admin reads audit rows; salesperson reads zero rows; direct `user_roles` insert denied (`permission denied`).
  - Matrix confirmed: godown has `stock.verify` + report/request/post, Admin has `approve_exceptional`, store has `count_assist` only (no `stock.verify`), delivery has no `damage.record`.
  - Threshold key reads `50` (**provisional placeholder, not an approved rule**).
  - `update_own_profile` works; self-deactivation rejected.
- Cleanup: all six throwaway users deleted (profiles/roles cascaded; 8 audit rows preserved as append-only proof). Temp credentials destroyed. One test site row (`godown_main`) remains in dev `branches`; delete it or keep it as a dev fixture.
- Godown Manager verification ownership and routine-post vs exceptional-approve split hold as documented. Transit-damage grant still withheld.

## Outstanding business decisions

1. Replace provisional `stock.adjustment.exceptional_absolute_units` seed after formal approval.
2. Delivery Person + `damage.record` for transit (DMG-05) — still unresolved.
3. INR-based exceptional thresholds — deferred.
4. Real Admin provisioning: run the documented bootstrap for the actual administrator account, then assign staff and sites.

## Git

Phase 2A is committed and pushed (see log). `.env`, `.env.local`, and `dist/` stay ignored. No secrets committed.

## Phase 2B verification (2026-10-14)

Employee, operating-site, audit, and Users & role screens are wired to Phase 2A RPCs and row-level security. Navigation hides Administration until the signed-in user has the matching permission. Direct visits without that permission show an access-denied page.

New accounts are created by the deployed `create-employee` Edge Function. The browser still uses only the publishable key. The function checks that the caller is active and holds both `employees.manage` and `roles.assign`, validates the form on the server, creates a confirmed Auth user, and lets the profile trigger store name, phone, and email. The selected role is assigned with `assign_user_role`. If that assignment fails, the new Auth user is deleted. Only Admin currently holds both permissions, so a Salesperson cannot create accounts or grant Admin. An existing Admin can create another Admin. Self-role changes and self-deactivation stay rejected.

Profiles store `phone_number` and `email` (migrations `20261014180000_profile_phone.sql` and `20261014190000_profile_email.sql`, already applied to development). There is no screen or RPC to edit a phone number after creation. `update_employee_profile` still changes name and employee code only, and that editor is not on these screens.

Deactivated users can still complete Supabase sign-in. The app then stops them on an inactive-account screen and does not open the workspace. `has_permission` also ignores inactive profiles, so privileged RPCs fail for them.

Site rename is not available. The confirmed Admin account remains Jeffin Pappachan.

### Checks

| Check | Result |
| --- | --- |
| `npm run typecheck` | Passed |
| `npm run lint` (oxlint) | Passed |
| `npm test` | Passed — 6 files, 13 tests |
| `npm run build` | Passed — JS chunk about 932 kB |
| Browser, signed-in Admin | Directory, search, role filter, details dialog, mismatched passwords, duplicate email 409, invalid body 400 |
| Browser, disposable Salesperson | Sign-in works; Administration hidden; `/users-roles` access denied; create-user 403; self-assign Admin rejected |
| Browser, role and site | Store Keeper assigned and revoked; Main Godown assigned |
| Browser, deactivation | Disposable user set inactive; sign-in shows the inactive screen; Admin self-deactivation rejected; Admin session restored |

The disposable account `phase2b.verify.salesperson@example.com` was removed after these checks. The real Admin account was not deleted.

## Phase 2C (planning, then local 2C.1)

Architecture for master data and the stock ledger is in `docs/phase-2c-master-data-plan.md`. Section 13 records the Phase 2C.1 schema. The Phase 2C.2 screens and grants are in the section below. No stock table or opening-stock function was added.

### Phase 2C.1 development deployment (2026-10-15)

`20261014210000_master_data.sql` is applied on development project `ypkfondrkhkydkgovwup` (`sherlysos`). Point-in-time recovery is off and no physical backup was listed. A logical schema and data dump of `public` and `auth` was saved outside the repository before the push: `C:\Users\Hash\Desktop\Hashdev\sherlyos-recovery\`.

`npx supabase db push --linked` applied only that migration. At the close of Phase 2C.1, remote history matched local through `20261014210000`. `godown_main` remained the only operating site, and the original administrator remained the only Auth user. Phase 2C.2 later added `20261015120000`.

Cloud checks after deployment:

- Seven tables exist, with forced row-level security, the expected foreign keys, and the case-insensitive unique indexes.
- Authenticated users can select products and cannot insert them. Anonymous users cannot select products.
- The only new grant is Admin → `stock.opening.post`. No stock-posting function exists.
- Real Admin JWT: product creation and direct insert are denied, self-role change and self-deactivation are denied, profile read still works, and the create-employee function still rejects a duplicate email.
- Disposable Salesperson JWT: cannot create users or grant Admin.
- Disposable inactive Admin JWT: sign-in still returns a session, and `create_branch` is denied.
- With temporary permissions that were removed afterward, a disposable Godown Manager could create a zone and crate only in `godown_main`, duplicate zone and crate codes were rejected, and a second godown was refused. Admin product, supplier, and shop checks passed, including salesperson eligibility, duplicate active assignments, and assignment history. Removing the Salesperson role deactivated that assignment.
- Those temporary grants and every disposable row and user were removed. The grant list is back to Admin → `stock.opening.post`.

| Check | Result |
| --- | --- |
| `npm run typecheck` | Passed. |
| `npm run lint` | Passed (oxlint). |
| `npm test` | Passed. 6 files, 13 tests. |
| `npm run build` | Passed. |

At the close of the Phase 2C.1 deployment, the only new grant on the development project was Admin → `stock.opening.post`. The Phase 2C.2 grants below were applied with `20261015120000_master_data_access.sql`.

### Phase 2C.1 local schema (2026-10-14)

`supabase/migrations/20261014210000_master_data.sql` adds categories, suppliers, products, shops, shop salesperson assignments, zones, and crates. The godown remains `branches`. Stock quantities are not stored. The operational unit is a whole carton case, so there is no units table.

RLS is enabled and forced. Clients can select only when they hold the matching read permission, and location reads also require the parent godown. Mutations are security-definer functions. The new permission rows are not granted, except Admin → `stock.opening.post`. That grant has no posting function.

| Check | Result |
| --- | --- |
| `npx supabase db reset --local` | Passed. Local only. |
| `npx supabase db lint --local` | Passed. |
| `npx supabase db advisors --local` | Passed. |
| `supabase/tests/phase_2c1_master_data.sql` | Passed and rolled back. No sample rows left. |
| `npm run typecheck` | Passed. |
| `npm run lint` | Passed (oxlint). |
| `npm test` | Passed. 6 files, 13 tests. |
| `npm run build` | Passed. |

This local record preceded the development deployment above.

## Phase 2C.2 development deployment (2026-10-15)

Migration: `supabase/migrations/20261015120000_master_data_access.sql`. It is applied on development project `ypkfondrkhkydkgovwup`. No commit was made.

Approved grants:

| Role | New grants |
| --- | --- |
| Admin | `products.read`, `products.manage`, `suppliers.read`, `suppliers.manage`, `shops.read`, `shops.manage`, `shops.assign`, `locations.read`, `locations.manage`. `stock.opening.post` is unchanged. |
| Godown Manager | `products.read`, `products.manage`, `suppliers.read`, `locations.read`, `locations.manage`. `suppliers.read` is only so the product form can list suppliers. |
| Accounts | `suppliers.read`, `suppliers.manage` |
| Salesperson | `shops.read`, `shops.manage` |
| Delivery Person, Store Keeper | No new master-data grants |

`shops.assign` is provisional and granted to Admin only. A Salesperson cannot create a shop or assign or revoke another salesperson until shop ownership and delegated assignment are approved. Zone and crate updates cannot move the parent. `stock.read` was not granted. Opening-stock posting was not built.

Shop and assignment reads are scoped. An Admin with `shops.assign` sees every shop and the full assignment history. A Salesperson sees a shop, and that assignment, only while the assignment is active. Revocation hides the shop's current details from that salesperson.

Screens under Master data: Products, Categories, Suppliers, Shops, and Godown locations. Godowns stay on the existing Operating sites screen. Direct routes use `RequirePermission`.

| Check | Result |
| --- | --- |
| `npx supabase db reset --local` | Passed. Applied `20261015120000_master_data_access.sql`. |
| `npx supabase db lint --local` | Passed. |
| `npx supabase db advisors --local` | Passed. |
| `supabase/tests/phase_2c2_master_data_access.sql` | Passed and rolled back. |
| `supabase/tests/phase_2c1_master_data.sql` | Passed and rolled back after the early unauthorized checks were pointed at a Salesperson and the closing assertion stopped deleting the approved grants. |
| `npm run typecheck` | Passed. |
| `npm run lint` | Passed (oxlint). One React Compiler note remains on the product form. |
| `npm test` | Passed. 7 files, 18 tests. |
| `npm run build` | Passed. The existing bundle-size warning remains. |
| Browser, local Vite on port 5174 | Admin created and renamed a product. Accounts created a supplier and was denied Products. Godown Manager created zone `A1` and crate `C01` and saw only the assigned godown. Salesperson edited the assigned shop, did not see the other shop, and had no create or assignment controls. Locations denied that Salesperson. Delivery Person had no master-data navigation and was denied `/masters`. A 390px-wide locations view kept the sidebar collapsed and the controls stacked. |

### Cloud deployment

Before the push, the linked reference was `ypkfondrkhkydkgovwup` and the dry run listed only `20261015120000_master_data_access.sql`. `npx supabase db push --linked` applied that migration. A later read of `supabase_migrations.schema_migrations` shows exactly these versions:

`20261014000000`, `20261014150000`, `20261014180000`, `20261014190000`, `20261014210000`, `20261015120000`.

The grant check on the project confirmed Admin holds `products`, `suppliers`, `shops` (including `shops.assign`), and `locations` read and manage, and still holds `stock.opening.post`. Godown Manager holds product and location management plus `suppliers.read` only. Accounts holds supplier read and manage. Salesperson holds shop read and manage. `shops.assign` is Admin only. `stock.read` is not granted. Delivery Person and Store Keeper have no new master-data grants. No master-table insert, update, or delete policy was added. No stock-balance table, stock-movement table, or posting function was added.

Real sessions against the development database passed for Admin, Godown Manager, Accounts, Salesperson, Delivery Person, Store Keeper, and an inactive disposable Admin. Covered checks: product, category, supplier, shop, zone, and crate management; godown isolation; supplier management denied to the Godown Manager; product and location management denied to Accounts; active-shop visibility and edit; unrelated, guessed, and revoked shop denial; shop creation and assignment denied to a Salesperson; direct product insert denied; role grant denied; and product-creation audit rows. After revocation, the Salesperson saw no shops and the Admin still saw the shop and the inactive assignment.

The app on `http://localhost:5173` uses the development project. Signed-in checks:

- Admin: Products, Categories, Suppliers, Shops, and Godown locations were available, including search, deactivation, assignment, and revocation. Both test godowns appeared in the location selector. At 390px the sidebar stayed collapsed and the location controls stacked.
- Accounts: Suppliers and New supplier were available. Products, Categories, Shops, and Locations were absent from navigation. `/masters/products` showed access denied.
- Godown Manager: Products, Categories, Suppliers, and Locations were available. The location selector showed only Main Godown. Suppliers were readable and New supplier was absent. Shops was absent.
- Salesperson: only the actively assigned shop was listed. Its edit dialog opened. New shop, Assign, and Revoke were absent. The unrelated shop was absent. `/masters/products` showed access denied.
- Delivery Person: no master-data navigation. `/masters` showed access denied.
- Store Keeper: no master-data navigation. `/masters/suppliers` showed access denied.

Disposable products, categories, suppliers, shops, assignments, zones, crates, the extra godown, branch grants, role rows, and audit rows for those actors were deleted. The eight disposable Auth users were deleted. The password file for those users was deleted. One Auth user remains, the original administrator. `godown_main` is the only operating site. `shops.assign` and `stock.opening.post` remain Admin only.

| Check | Result |
| --- | --- |
| `npm run typecheck` | Passed. |
| `npm run lint` | Passed (oxlint). Warning: `ProductsPage.tsx:294` `react(incompatible-library)` for React Hook Form. |
| `npm test` | Passed. 7 files, 18 tests. |
| `npm run build` | Passed. Warning: the JS chunk is about 966 kB, above the 500 kB notice. CSS is about 83 kB. |

Phase 2C.2 implementation is complete. Cloud JWT and row-level security checks passed, and the cloud-connected browser checks passed. The unresolved business decisions in section 14.4 of `docs/phase-2c-master-data-plan.md` remain pending except the two inventory decisions recorded in Phase 2C.3. Phase 2C.3 was applied to the development project after this record; see the Phase 2C.3 section below.

Non-blocking follow-ups:

- oxlint reports `react(incompatible-library)` on the React Hook Form setup in `ProductsPage.tsx`. The lint command still exits successfully.
- The production JavaScript chunk is about 966 kB, which is above Vite's 500 kB notice. The build still succeeds.
- `npx supabase migration list --linked` later failed with password authentication for `cli_login_postgres`. Remote history was confirmed through the Management API query of `supabase_migrations.schema_migrations`.

## Phase 2C.3 inventory ledger (2026-10-15)

Migration: `supabase/migrations/20261015180000_inventory_ledger.sql`. It is applied on local Supabase and on development project `ypkfondrkhkydkgovwup`. Remote history was not forced, and the remote database was not reset.

The ledger is append-only. `stock_balances` is a projection maintained in the same transaction as the ledger. Opening stock is Admin only and once per product and crate. Transfers stay inside one authorized godown. Negative quantities are rejected. A crate may hold more than one SKU. A crate or zone with a positive balance cannot be deactivated.

`stock.read` is granted to Admin, Accounts, Godown Manager, and Store Keeper. It does not open every godown. Reads use `app_private.can_work_at_branch`. Accounts and Store Keeper see stock only after an existing site assignment. This phase does not assign them automatically. Salesperson and Delivery Person have no stock read or post grants. `stock.transfer.post` is new and is granted to Admin and Godown Manager. `stock.opening.post` stays Admin only. Existing `stock.adjustment.*` grants were not widened.

Screens: Inventory, Opening stock, Transfers, and History. Opening stock requires `stock.opening.post`. Transfers require `stock.transfer.post`.

| Check | Result |
| --- | --- |
| `npx supabase db reset --local` | Passed. Applied through `20261015180000_inventory_ledger.sql`. |
| `npx supabase db lint --local` | Passed. No schema errors. |
| `npx supabase db advisors --local` | Passed. No issues. |
| `supabase/tests/phase_2c1_master_data.sql` | Passed and rolled back. |
| `supabase/tests/phase_2c2_master_data_access.sql` | Passed and rolled back. |
| `supabase/tests/phase_2c3_inventory_ledger.sql` | Passed and rolled back. |
| Overlapping sessions | Seven races passed, including an in-flight transfer against deactivation of a stocked crate and a transfer into a crate deactivated first. |
| `npm run typecheck` | Passed. |
| `npm run lint` | Passed (oxlint). React Hook Form warnings remain on `ProductsPage.tsx:294`, `OpeningStockPage.tsx:38`, and `TransfersPage.tsx:44`. |
| `npm test` | Passed. 8 files, 21 tests. |
| `npm run build` | Passed. JS chunk about 984 kB. CSS about 84 kB. |
| Browser, local Vite | Admin opening stock and same-godown transfer. Godown Manager transfer, with opening stock denied. Accounts and Store Keeper read-only. Salesperson denied `/inventory`. A 390px inventory view kept the sidebar collapsed and the table scrolling. |

Before the disposable local rows were removed, ledger sums matched `stock_balances` with no negatives. The posted opening of 12 carton cases reconciled to balances of 6 and 6 after two transfers. Append-only triggers were re-enabled after that local cleanup.

Development-cloud deployment used `npx supabase db push --linked` and applied only `20261015180000`. Remote history now runs from `20261014000000` through `20261015180000`. `stock_transactions`, `stock_ledger`, and `stock_balances` exist, with the posting and list functions and the stock checks on crate and zone deactivation. `godown_main` and the existing administrator remained. Products and shops were already empty.

Cloud security verification passed 26 cases with real JWTs, covering opening, transfer, isolation, idempotency, direct-write, deactivation, inactive-user, and reconciliation. Successful posts ran inside one statement that raised at the end, so the ledger rows rolled back. That session reported one opening for the test product and crate, transfer entries netting to zero, source balance 4 and destination balance 6 after an opening of 10 and transfers of 4 and 2, zero mismatches, zero negatives, no stock in an inactive crate, and at least five posting audit rows. After the rollback the development ledger was empty.

The Vite app on port 5173 used `ypkfondrkhkydkgovwup`. Admin saw the inventory overview, opening form, transfer form, and empty history, and opened the opening-stock confirmation without posting. Godown Manager saw only the assigned test godown on the transfer form, and `/inventory/opening` was denied. Accounts and Store Keeper could open inventory and history and were denied both posting routes. Salesperson and Delivery Person had no inventory navigation, and `/inventory` was denied. At 390px the sidebar was hidden and the inventory filters stacked. Opening stock, a same-godown transfer, and deactivation of a stocked crate were not submitted in the browser, because those ledger rows cannot be removed without disabling the append-only triggers.

After cleanup the development project has one Auth user, `godown_main` as its only branch, no products, no shops, and no stock rows. Disposable users, assignments, sites, products, and their audit rows were removed. The temporary password file was deleted.

| Cloud check | Result |
| --- | --- |
| `npm run typecheck` | Passed. |
| `npm run lint` | Passed. The three React Hook Form warnings above remain. |
| `npm test` | Passed. 8 files, 21 tests. |
| `npm run build` | Passed. JS chunk `index-B22omsK7.js` is 983.63 kB. CSS `index--4B1rOFm.css` is 83.64 kB. |

Details, the permission matrix, and the remaining decisions are in `docs/phase-2c3-inventory-ledger-plan.md`.

## Phase 3.1 stock receiving (development cloud, 2026-10-15)

Phase 2C.3 remains deployed and committed on development Supabase `ypkfondrkhkydkgovwup`. Phase 3.1 migration `20261015200000_stock_receiving.sql` is applied to that same development project and committed to `main`. Phase 3.2 has not started.

Migration: `supabase/migrations/20261015200000_stock_receiving.sql`. It adds `stock_receipts` and `stock_receipt_lines`, extends the existing ledger with `RECEIPT`, and adds the receiving RPCs. Earlier migrations were not edited. Existing role grants were not changed. `receiving.execute` stays Store Keeper only. `receiving.verify` stays Godown Manager only. Admin keeps `operations.monitor` for read-only monitoring and was not granted receiving execute or verify.

A receipt moves draft, submitted, held, posted, or cancelled. Submit does not post stock. Verification posts accepted cases in the same transaction. Damaged cases are recorded and do not enter available stock. Posted and cancelled receipts stay closed. Corrections of posted stock are deferred.

| Check | Result |
| --- | --- |
| `npx supabase db reset --local` | Passed. Applied through `20261015200000_stock_receiving.sql`. The linked cloud project was not reset. |
| `npx supabase db lint --local` | Passed. No schema errors. |
| `npx supabase db advisors --local` | Passed. No issues. |
| `supabase/tests/phase_2c1_master_data.sql` | Passed and rolled back on the receiving schema before the disposable browser seed. |
| `supabase/tests/phase_2c2_master_data_access.sql` | Passed and rolled back on that same schema. |
| `supabase/tests/phase_2c3_inventory_ledger.sql` | Passed and rolled back. Opening stock and same-godown transfer still posted. |
| `supabase/tests/phase_3_1_stock_receiving.sql` | Passed and rolled back. |
| Overlapping sessions | Eleven receiving races passed, including verify, edit, cancel, shared crate, crate and zone deactivation, duplicate documents, and product or supplier deactivation. |
| `npm run typecheck` | Passed. |
| `npm run lint` | Passed. React Hook Form warnings remain on `ProductsPage.tsx:294`, `OpeningStockPage.tsx:38`, and `TransfersPage.tsx:44`. |
| `npm test` | Passed. 9 files, 30 tests. |
| `npm run build` | Passed. JS chunk about 1,005 kB. CSS about 84 kB. |
| Browser, local Vite on port 5175 | Store Keeper created a two-line receipt, submitted it, and cancelled a separate draft. Godown Manager held, returned, and posted the submitted receipt. Inventory showed 5 soap cases and 4 oil cases. The other godown manager, Admin create and verify, Accounts, Salesperson, and Delivery Person were denied the unauthorized actions. At 390px the sidebar stayed collapsed and the receipt table scrolled inside the page. |

After the browser post, local ledger sums matched `stock_balances`: 0 mismatches, 0 negatives, and every receipt ledger row had a receipt and line reference. Accepted cases were 9. The damaged case was not in the balance. Those rows are disposable local data. The next local reset clears them. They were not copied to the development project.

The clean local reset for this deployment removed the earlier disposable browser administrator. Phase 2C.1, 2C.2, 2C.3, and Phase 3.1 SQL then passed and rolled back from that clean database. The eleven receiving concurrency races passed, and their fixture was removed.

Development deployment used `npx supabase db push --linked` after a dry run that listed only `20261015200000_stock_receiving.sql`. The linked project was `ypkfondrkhkydkgovwup`. Remote history was not reset or repaired. Local and remote histories both end at `20261015200000`.

Real JWT checks covered Admin, two Godown Managers, Accounts, Store Keeper, Salesperson, Delivery Person, and an inactive user. Store Keeper created and submitted an assigned-godown receipt. Godown Manager verification, accepted-only posting, exact and conflicting retries, posted and cancelled immutability, opening stock, and a same-godown transfer ran inside one statement that rolled back. Direct receipt, ledger, and balance writes were denied. After that statement, `stock_transactions` and `stock_balances` were still empty.

Cloud browser checks used the Vite app on `[::1]:5173`, which reads the development project. Store Keeper saw Receiving, the submitted receipt, its lines and history, and a new-receipt form limited to the assigned godown, zone, and crates. The draft was not saved. Godown Manager saw Hold, Verify and post, and Cancel receipt, and `/receiving/new` was denied. The verify control was not activated, so the cloud browser did not post stock. Admin could read the list and detail and had no New receipt or verify action. Accounts, Salesperson, and Delivery Person had no Receiving navigation; `/receiving`, `/receiving/new`, and the receipt URL were denied. At 390px the page stayed within the viewport, filters stacked, and the receipt table scrolled inside the page.

Ledger reconciliation before and after the browser checks was the same: 0 transactions, 0 balances, 0 mismatches, 0 negatives, 0 receipt ledger rows, and both append-only triggers enabled. The original administrator and `godown_main` remained.

Disposable cloud users, roles, assignments, branches, zones, crates, products, the supplier, the unposted receipt, and related audit rows were removed. Eight disposable Auth users were deleted. One Auth user remains. No test stock remains. The temporary browser password file was deleted.

| Cloud check | Result |
| --- | --- |
| `npm run typecheck` | Passed. |
| `npm run lint` | Passed. The three React Hook Form warnings above remain. |
| `npm test` | Passed. 9 files, 30 tests. |
| `npm run build` | Passed. JS chunk `index-Bgrnsx9x.js` is 1,005.17 kB. CSS `index-DzDfXFBY.css` is 83.95 kB. |

Details are in `docs/phase-3-1-stock-receiving-plan.md`.
