# Database migration strategy

SherlysOS keeps schema changes in `supabase/migrations`. Apply them in filename order with the Supabase CLI against the linked cloud project, or against a local Supabase stack. `supabase/seed.sql` stays empty until a later phase has real reference data to load.

## Rules

- The browser may use only `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`.
- Do not put a secret or service-role key in any `VITE_` variable or in frontend source.
- Enable row level security on every application table in the same migration that creates it.
- Grant the `authenticated` role only the policies that match a person's job. Do not grant broad table writes for inventory, approvals, or financial actions.
- Stock changes, approvals, and other multi-row workflow steps go through PostgreSQL functions that run in a transaction. The client calls those functions. It does not update ledger tables directly.
- Use Edge Functions only for work that needs a secret, a document, or an external integration.
- Do not edit a migration after it has been applied. Add a new file.

## Planned order

1. Phase 1, this repository: foundation marker only. No operational tables and no stock mutations.
2. Identity and access: role catalog from the business process document, profiles, and row level security.
3. Master data: shops, products, batches, and related reference tables.
4. Inventory ledger: balances, movements, FEFO/FIFO, and batch tracking, with mutations only through transactional functions.
5. Operational modules: orders, deliveries, damage quarantine, receiving, daily verification, and refill.
6. Documents and realtime: storage policies for invoices, photos, and proofs, then live status updates.

The business process PDF is not in this workspace yet. Role names and workflow rules should be taken from that document before the identity migration is written.
