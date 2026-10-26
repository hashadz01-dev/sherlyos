# Netlify development frontend release

Date: 2026-10-26  
Repository: `C:\Users\Hash\Desktop\Hashdev\sherlyos`  
Approved host: Netlify (development frontend only)  
Development Supabase project: `ypkfondrkhkydkgovwup`  
Development API: `https://ypkfondrkhkydkgovwup.supabase.co`

This document prepares a **development-only** static frontend on Netlify. It does not authorize site creation, Git push, Netlify deploy, production hosting, cloud schema changes, or operational lot cutover.

## Netlify build configuration

Checked into `netlify.toml`:

| Setting | Value |
|---|---|
| Build command | `npm run build` |
| Publish directory | `dist` |
| Node | `22` |
| Release target | `SHERLYS_RELEASE_TARGET=development` |
| SPA fallback | `/*` → `/index.html` status `200` |
| Functions | none |

The rewrite does not use `force = true`, so real files in `dist` (JS, CSS, images) are served first. Direct refresh of `/orders`, `/reports/inventory`, and other client routes returns the SPA shell.

SherlysOS continues to use Supabase as the only backend. Do not add Netlify Functions or a second API.

## Development Supabase identity

| Item | Value |
|---|---|
| Project ref | `ypkfondrkhkydkgovwup` |
| API URL | `https://ypkfondrkhkydkgovwup.supabase.co` |
| Browser URL variable | `VITE_SUPABASE_URL` |
| Browser key variable | `VITE_SUPABASE_PUBLISHABLE_KEY` |

Vite exposes only `VITE_` names to the browser. Never place the following in Netlify or in any `VITE_` variable:

- Supabase `service_role` key
- Supabase secret key
- Database password
- Supabase access token
- Git provider token
- Any private server credential

The publishable/anon key is the only browser credential. Enter it in **Netlify → Site configuration → Environment variables**. Do not invent a key value and do not commit `.env`, `.env.local`, or `.env.*.local`.

`.env.example` names the development URL and leaves the publishable key blank.

## Deployment environment guard

`src/lib/supabase/release-env.ts` is invoked from `vite.config.ts` on `vite build`.

For Netlify (`NETLIFY=true`) or `SHERLYS_RELEASE_TARGET=development` the build fails if:

- `VITE_SUPABASE_URL` is missing
- `VITE_SUPABASE_PUBLISHABLE_KEY` is missing
- the URL is not project `ypkfondrkhkydkgovwup`
- `VITE_SUPABASE_SERVICE_ROLE_KEY` is set
- the publishable value is a JWT whose `role` is `service_role` or `supabase_admin`

The guard never prints keys. Local Playwright builds against `127.0.0.1` remain allowed. A local production build that points at a different hosted Supabase project also fails.

## Authentication and redirects

The application uses **email + password** only (`signInWithPassword` on `/login`). It does not implement magic links, OAuth, or a password-recovery screen. The browser client still sets `persistSession`, `autoRefreshToken`, and `detectSessionInUrl` so a future recovery hash would not be dropped, but operators sign in with the issued password.

Do not invent a Netlify URL before the site exists. After the owner creates the development site, configure Supabase Auth **without changing settings until authorized**:

1. Copy the Netlify site URL (for example `https://<site>.netlify.app`).
2. In the development project: Authentication → URL configuration.
3. Set **Site URL** to that Netlify origin.
4. Add the same origin to **Redirect URLs**, plus `https://<site>.netlify.app/**` if recovery or email links are later enabled.
5. Keep local origins (`http://127.0.0.1:5173`, `http://localhost:5173`, `http://127.0.0.1:4173`) if local development still needs them.

SPA fallback is required so a signed-in refresh of a protected route does not 404. Authorization still comes from the persisted Supabase session and RLS, not from Netlify.

## Git synchronization

Before this checkpoint, `main` matched `origin/main` at `f08304a`. The Netlify preparation commit is local until the owner authorizes `git push`.

**A Git-connected Netlify site cannot see this checkpoint until the owner authorizes and performs `git push`.** This procedure does not push.

If the owner wants to publish without pushing Git, use a manual deploy of the local `dist` folder (Netlify CLI `netlify deploy --dir=dist` or a drag-and-drop of `dist`). Manual deploy does not require Git push. Git-connected continuous deploy does.

## Deployment procedure (do not execute until authorized)

1. Owner creates a **dedicated Netlify development site**. Do not reuse a production site. Do not create the site from this task.
2. Connect the GitHub/Git remote **or** choose a manual/CLI deploy of `dist`. Connecting Git implies a later authorized push.
3. If using Git: select branch `main` only after the checkpoint is pushed. If using CLI: build locally from the checkpoint SHA.
4. Confirm build command `npm run build` and publish directory `dist` (already in `netlify.toml`).
5. Add environment variables:
   - `VITE_SUPABASE_URL=https://ypkfondrkhkydkgovwup.supabase.co`
   - `VITE_SUPABASE_PUBLISHABLE_KEY=<development publishable/anon key>`
   - Do not add `SHERLYS_RELEASE_TARGET`; `netlify.toml` already sets `development`.
6. Confirm the SPA rewrite is present (`/*` → `/index.html` `200`).
7. Run a Netlify deploy preview or local `npm run build` and confirm the guard accepts the development URL. Inspect the deploy log: it must not print keys. Confirm `dist` has no `.env` files.
8. Deploy **only after owner authorization**.
9. Browser smoke tests (development Auth, no stock mutations):
   - Sign in with a development operator password account.
   - Refresh `/` and a protected URL such as `/reports/inventory`.
   - Overview shows available-to-pick as not applicable while cutover is off.
   - Inactive godowns appear under Inactive / Historical and in overall totals; they are labeled Inactive (historical).
   - Opening stock / new order godown lists omit inactive sites.
   - Sign out, sign in as another user, confirm the previous user's figures are gone.
   - Delivery person is denied `/reports/inventory`.
10. Record the Netlify deploy ID and the Git SHA that produced `dist`.
11. If the deploy is wrong, restore the previous Netlify deploy (Deploys → previous unique deploy → Publish). Do not roll back database migrations. Do not toggle cutover flags.

## Smoke-test checklist

- [ ] HTTPS Netlify origin loads `/login`
- [ ] Password sign-in against `ypkfondrkhkydkgovwup`
- [ ] Refresh of `/` and `/reports/inventory` stays in-app
- [ ] Query cache clears on sign-out / user switch
- [ ] Admin overall cartons include inactive godowns
- [ ] Inactive / Historical optgroup is labeled
- [ ] Opening stock cannot select an inactive godown
- [ ] CSV export still downloads
- [ ] Cutover flags remain false / false
- [ ] No picking confirm or dispatch confirm against development cloud

## Rollback

Netlify keeps prior unique deploys. Restore the last known-good deploy for this site. If nothing has been published yet, rollback is “do not publish.”

Do not reverse `20261023200000_operational_intelligence` or any other cloud migration as part of a frontend rollback. Do not change stock quantities.

## Inactive godown reporting policy

Owner decision: inactive godowns remain visible in authorized reporting, including overall stock totals, under a labeled **Inactive / Historical** filter. They are not selectable for new operational transactions.

Frontend:

- Dashboard, inventory, lots, movements, orders/picking, dispatch, and exceptions reports use the RLS branch list and group inactive sites.
- “All authorized branches” does not drop inactive stock. Totals are unchanged.
- Opening stock, transfers, new orders, and new lot reconciliation selectors list active godowns only.
- Receiving and verification option lists already come from active-only RPCs.

Backend (no migration in this release):

- New opening, transfer, receiving, verification start, and new orders reject inactive godowns (`branches.is_active` or crate location lock).
- Admin `branches.access_all` still makes `can_work_at_branch` true for inactive sites. Picking, dispatch, and adjustment writers that only call `can_work_at_branch` can continue **existing** work at an inactive godown. That gap needs a separate authorized migration. See the integration review.

## Security notes

- Frontend hosting is not a substitute for RLS or RPC `assert_permission`.
- Query keys are hashed by signed-in user id; identity change clears the cache.
- Playwright refuses to start unless the effective Vite URL is localhost.
- Do not enable source maps in Netlify if a later production site is created; the development build may include them for debugging, but must never embed secrets.

## Remaining authorization gates

1. Owner creates the Netlify development site and records its URL.
2. Owner sets the two `VITE_` variables in Netlify.
3. Owner authorizes Git push if the site is Git-connected.
4. Owner authorizes the first deploy.
5. Owner authorizes Supabase Auth Site URL / Redirect URL updates to that Netlify origin.
6. Owner must separately authorize any migration that adds `branches.is_active` checks to picking, dispatch, and adjustment writers.
7. Operational lot cutover stays inactive (`stock.lots.dual_write_enabled` and `stock.lots.aggregate_only_blocked` both false).
