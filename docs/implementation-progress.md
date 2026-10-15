# Implementation progress

## Current status

- Phase 2B — committed and pushed to `origin/main`.
- Phase 2C — architecture is in `docs/phase-2c-master-data-plan.md`. Phase 2C.1 is applied to development Supabase `ypkfondrkhkydkgovwup`. Phase 2C.2 has not started. Phase 2C is not complete.

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

Architecture for master data and the stock ledger is in `docs/phase-2c-master-data-plan.md`. Section 13 records the Phase 2C.1 schema. Phase 2C.2 has not started. No master-data screen, stock table, or opening-stock function was added.

### Phase 2C.1 development deployment (2026-10-15)

`20261014210000_master_data.sql` is applied on development project `ypkfondrkhkydkgovwup` (`sherlysos`). Point-in-time recovery is off and no physical backup was listed. A logical schema and data dump of `public` and `auth` was saved outside the repository before the push: `C:\Users\Hash\Desktop\Hashdev\sherlyos-recovery\`.

`npx supabase db push --linked` applied only that migration. Remote history now matches local through `20261014210000`. `godown_main` remains the only operating site. The original administrator remains the only Auth user.

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

Phase 2C.2 has not started. No master-data management permission is granted except Admin → `stock.opening.post`.

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

This local record preceded the development deployment above. Phase 2C.2 has not started.
