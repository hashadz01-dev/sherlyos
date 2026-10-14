# Implementation progress

Phase 1 is verified. The active application is `c:\Users\Hash\Desktop\Hashdev\sherlyos`. The sibling folder `bpm-sherlys-distribution-agents` is a separate Vite app and was not changed. Operational modules stay empty. There are no stock mutations and no sample dashboard figures. Phase 2 has not started.

## Checks

| Check                  | Result                    |
| ---------------------- | ------------------------- |
| `npm run typecheck`    | Passed                    |
| `npm run lint`         | Passed                    |
| `npm test`             | Passed, 6 files, 12 tests |
| `npm run test:e2e`     | Passed, 4 Chromium tests  |
| `npm run build`        | Passed                    |
| `npm run format:check` | Passed                    |

## Supabase

The browser reads `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` from `.env.local`. Both values point at development project `ypkfondrkhkydkgovwup`. Vite gives `.env.local` priority over `.env`. The dev server was restarted after `.env.local` was added so that file is the one in use.

`SUPABASE_SERVICE_ROLE_KEY` and `SUPABASE_ACCESS_TOKEN` remain in `.env` only, without a `VITE_` prefix. They are not in source, tests, the production bundle, or `.env.example`. `.env` and `.env.local` are gitignored. The publishable key is present in the production bundle because the browser client needs it. `dist/` is gitignored.

## Authentication

Checked in the browser at `http://127.0.0.1:5173` against the real project:

- Signing out returns to `/login`.
- Visiting `/orders` while signed out redirects to `/login`.
- A wrong password stays on `/login` and shows “Invalid login credentials”.
- The provisioned account signs in and opens Operations Overview.
- Reloading `/` keeps the session. The stored key is `sb-ypkfondrkhkydkgovwup-auth-token`.
- Signing out again clears that session.
- The login page does not show the missing-configuration notice.
- Overview metrics say “Not connected”, and recent orders stay empty.

Playwright covers the signed-out redirect, invalid credentials, the phone layout, and the logo response. Vitest still covers the unconfigured login path with the Supabase client mocked, so that check does not depend on local secrets.

## Assets

- `public/branding/sherlys-logo.png` is the original Sherlys script mark, saved as PNG. The signed-in shell loads it from `/branding/sherlys-logo.png`.
- `reference/Sherlys_Distribution_Agents_BPM.pdf` is a readable PDF. Its title text is “Sherlys Distribution & Agents OS - Business Process and Automation Blueprint v1.”

## Production bundle

`npm run build` emits one JavaScript file, `dist/assets/index-aIfr18OX.js`, at 894.99 kB minified and 269.24 kB gzipped. Vite warns because that chunk is over 500 kB.

The size comes from one eager entry. `src/app/router.tsx` statically imports every page, and the entry also includes React, React Router, the Supabase client, TanStack Query, TanStack Table, and the Radix-based shell. Nothing is deferred.

Recommended change, not applied in this phase: load each route element with `React.lazy` and render it through `Suspense` in the shell. Login and the overview can stay in the first chunk. Orders, deliveries, damage, receiving, verification, refill, inventory, masters, reports, and settings should each become their own chunk. That is route-based splitting, and it does not require a second bundler.

## Git

This folder is not a Git repository, so the verified foundation was not committed. `git init` was not run.

## Remaining blockers

1. Initialize Git and commit the Phase 1 foundation before treating the history as saved. Do not commit `.env`, `.env.local`, or `dist/`.
2. `npm audit` reports 7 high findings. They come through `shadcn` from `braces` and the packages around it. The offered fix downgrades `shadcn` to 1.0.0, so it was left unchanged.
3. The foundation migration does not create operational tables. Apply schema only when that later phase starts.
