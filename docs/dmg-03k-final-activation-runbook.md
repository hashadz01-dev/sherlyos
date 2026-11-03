# DMG-03K — Final cloud activation runbook (awaiting owner authorization)

**Project:** `ypkfondrkhkydkgovwup`  
**Status:** STOPPED at approval checkpoint — no migrations, flag flips, or stock writes executed.

## Preflight (read-only, 2026-11-03)

| Check | Result |
|-------|--------|
| `damage.stock_hold_ready` | false |
| `stock.lots.dual_write_enabled` | true |
| `stock.lots.aggregate_only_blocked` | true |
| Aggregate/lot mismatched | 0 (35/35) |
| Active/transferred damage holds | 0 |
| Negative lot avail | 0 (min avail 8) |
| Picking subtracts holds | yes |
| Lot catalog / unreserved / dual-write guard | **missing** (pending migrations) |
| Tip | `20261102125515` |
| Branches | none |
| Draft `DMG-20261103-000013` | draft v5, storage, AVT@uat_c1 qty 1, evidence 1, **lot_id null**, 2 positive lots on grain |

## Approval checkpoint (A–F) — do not proceed until owner replies

### A. Backup evidence
Agent **cannot** see Dashboard backups. Fastest owner action:

1. Open [Database → Backups](https://supabase.com/dashboard/project/ypkfondrkhkydkgovwup/database/backups/scheduled)
2. If **Pro+**: confirm at least one **Daily backup** is listed; note **timestamp / recovery point**; reply with that evidence.
3. Optional stronger: enable PITR add-on, or use **Restore to a new project** only if needed later (cost/downtime).
4. If **Free** (no automatic backups): run off-site dump **before** cutover:
   ```bash
   npx supabase db dump --project-ref ypkfondrkhkydkgovwup -f backups/ypkfondrkhkydkgovwup-pre-dmg03k.sql
   ```
   **Limitation:** logical dump ≠ full platform restore (Auth/Storage/extensions/roles may need separate handling); slower RTO; not a tested physical restore.

Do **not** treat empty branching (`list_branches=[]`) or `create_branch` as a data-preserving backup.

### B. Exact migrations and commands (ordered)

```text
1. supabase/migrations/20261102190000_damage_inbound_receipt_line_lock.sql
2. supabase/migrations/20261103100000_damage_evidence_drop_followlocation.sql
3. supabase/migrations/20261103120000_damage_storage_store_keeper_draft.sql
4. supabase/migrations/20261103130000_damage_hold_ready_requires_lot_dual_write.sql
5. supabase/migrations/20261103140000_transfer_adjustment_honor_damage_holds.sql
6. supabase/migrations/20261103160000_damage_storage_lot_catalog.sql
EXCLUDE: 20261103170000_damage_evidence_disposable_kong_hosts.sql
```

```bash
# After backup attestation + explicit approval only:
npx supabase db push --project-ref ypkfondrkhkydkgovwup
# Or apply the six files above in order via Dashboard SQL / MCP apply_migration
```

### C. Stock integrity preflight (must still hold)

- mismatched = 0  
- dual_write = true  
- aggregate_only_blocked = true  
- hold_ready = false until step 6  
- active/transferred holds = 0  
- no negative `picking_available_cases`

### D. Pilot inventory (TEST ONLY — after approval)

Prefer **not** AVT/GOODLIFE. After migrations + approval:

1. Create product via trusted `create_product` (SKU e.g. `TEST-DMG03K-ONLY`, name marked TEST ONLY).  
2. Ensure gd_1 has an active non-quarantine crate (or create via masters).  
3. Post **1–2 cases** opening stock with a distinct manufacturer lot code `TEST-LOT-DMG03K` via trusted opening/receiving path (lot dual-write on).  
4. Confirm catalog/picking avail ≥ 1 on that lot only.

### E. Rollback / recovery

- `damage.stock_hold_ready=false` does **not** undo holds, quarantine moves, or write-offs.  
- Bad draft/hold before disposition: manager return/reject (releases logical holds).  
- Posted quarantine/write-off: compensating trusted adjustments under owner authority only.  
- Catastrophic: Dashboard restore from attested daily backup / PITR (project downtime).

### F. Exact owner authorization required

Reply authorizing **each** of: (1) backup attestation accepted, (2) apply six migrations, (3) create TEST-ONLY pilot stock, (4) set `damage.stock_hold_ready=true`, (5) browser pilot on 5173. Optional: abandon `DMG-20261103-000013` and use a new draft.

## Ordered runbook (execute only after F)

1. Confirm recoverable backup (A).  
2. Confirm maintenance window (freeze gd_1 transfers/adjustments/picking if needed).  
3. Apply approved migrations (B).  
4. Verify helpers + recon (lot catalog, unreserved, dual-write guard present; mismatched 0; flags unchanged).  
5. Create approved TEST-ONLY inventory (D).  
6. `update app_configuration set value='true'::jsonb where key='damage.stock_hold_ready';`  
7. Refresh 5173; RPC `damage_stock_hold_ready_status` → true; readiness banner green.  
8. **New** Storage Damage report (do not silent-fix 000013): godown gd_1, TEST product/crate/lot, qty 1, finalize evidence.  
9. Review and Submit.  
10. Confirm exactly one active hold for that report.  
11. Confirm `picking_available_cases` reduced; physical unchanged.  
12. Godown Manager (not reporter) verifies.  
13. Reconcile physical / held / available.  
14. Spot-check unrelated ops (transfer candidate list, open picking) still function.

**Draft 000013:** After lot catalog, UI can select one of the two AVT lots on `uat_c1` if owner chooses commercial pilot — **prefer replacement draft on TEST stock**. Do not SQL-patch `lot_id`.

## Expected 5173 result after approved cutover

Store Keeper: Save Draft → **Review and Submit enabled** → submit isolates 1 TEST case → Godown Manager verifies. Success only after that browser path passes; do not claim success while hold_ready is false.
