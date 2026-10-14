-- SherlysOS Phase 1 foundation.
-- This migration records the start of the schema history.
-- It does not create inventory, order, approval, or stock-movement objects.

comment on schema public is
  'SherlysOS. Phase 1 has no operational tables. Later migrations add master data, the inventory ledger, and module tables. Stock changes belong in transactional database functions with row level security, not in direct client writes.';
