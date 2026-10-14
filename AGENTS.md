# SherlysOS agent notes

SherlysOS is an internal operations application: Vite, React, TypeScript, and Supabase. Do not add Next.js, Astro, or a second backend framework unless a later phase has a concrete integration that Supabase cannot host.

## Boundaries

- Phase 1 is the foundation only. Do not add stock mutations, approvals, or live dashboard figures.
- Unimplemented screens stay empty. Do not fill them with sample orders or sample counts.
- Authentication comes from Supabase Auth. Do not invent a signed-in session.
- The frontend may read `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` only.
- Inventory and approval changes, when they are built, go through PostgreSQL functions or Edge Functions protected by row level security.

## Layout

Feature screens live under `src/features`. Shared UI lives under `src/components`. Supabase access lives under `src/lib/supabase`. Schema changes live under `supabase/migrations`.
