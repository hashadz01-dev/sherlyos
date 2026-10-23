# SherlysOS

Internal operations workspace for Sherlys. Phase 1 is the Vite + React foundation: application shell, route map, Supabase Auth, and shared UI. Operational modules are registered and intentionally empty.

## Stack

- React, Vite, and TypeScript
- Tailwind CSS and shadcn/ui
- React Router, TanStack Query, Zustand, TanStack Table, React Hook Form, and Zod
- Supabase Auth, with PostgreSQL, Storage, Realtime, and Edge Functions planned for later phases

## Local development

1. Install dependencies with `npm install`.
2. Copy `.env.example` to `.env.local` and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`. Vite gives `.env.local` priority for the browser client.
3. Keep `SUPABASE_SERVICE_ROLE_KEY` and `SUPABASE_ACCESS_TOKEN` in `.env` for server tools only. Do not prefix them with `VITE_` and do not commit either file.
4. Start the app with `npm run dev`.

MCP servers are configured in `.cursor/mcp.json`. In Cursor, open Settings → Tools & MCP, enable **supabase** (project `ypkfondrkhkydkgovwup`) and **context7**, then sign in when asked. Context7 supplies current library docs (Playwright, Vitest, Supabase, React) to the agent; it does not replace `npm test` or `npm run test:e2e`.

Without those two variables the login page stays on a configuration notice and does not create a session. Accounts are created in Supabase by an administrator. This phase does not include self-service signup.

The original Sherlys logo is `public/branding/sherlys-logo.png`. The business blueprint is `reference/Sherlys_Distribution_Agents_BPM.pdf`.

## Scripts

- `npm run dev` starts the Vite dev server.
- `npm run typecheck` runs the TypeScript project build.
- `npm run lint` runs oxlint.
- `npm run format` writes Prettier formatting.
- `npm test` runs Vitest.
- `npm run test:e2e` runs Playwright. Install the browser once with `npx playwright install chromium`.
- `npm run build` typechecks and creates the production bundle.

## Database

Phase 1 does not create operational tables. Read `docs/database-migration-strategy.md` before adding schema. The first migration is `supabase/migrations/20261014000000_foundation.sql`.
