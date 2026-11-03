# DMG-03C — Controlled local damage isolation UAT

## Verdict

**LOCAL DMG-03 END-TO-END UAT PASSED** on the disposable M8.2C Docker stack.

This is **not** approval to enable isolation on the owner local DB (`supabase_db_sherlyos`) or cloud `ypkfondrkhkydkgovwup`. Port **5173** remains on cloud with `damage.stock_hold_ready=false`.

## Environment identification

| Item | Value |
|------|-------|
| Isolated app URL | `http://127.0.0.1:5174` |
| Vite mode / env file | `dmg03c` / `.env.dmg03c.local` (gitignored) |
| API | `http://127.0.0.1:57321` (Kong on m82c) |
| Postgres container | `supabase_db_sherlyos_m82c` |
| DB host port | `57322` |
| System identifier | `7702447407569928229` |
| Forbidden owner sysid | `7699785797738577957` (different — disposable proof) |
| Playwright config | `playwright.dmg03c.config.ts` |

Owner / cloud not modified:

- Owner `supabase_db_sherlyos`: `damage.stock_hold_ready=false`
- Cloud project: not migrated / flag not flipped
- Existing cloud draft `DMG-20261103-000013`: untouched

## Proof database is disposable

1. Separate Docker project `sherlyos_m82c` with dedicated API/DB ports.
2. System identifier ≠ owner container.
3. Playwright assert refuses ports `54321` / `56321` when `SHERLYOS_DMG03C=1`.
4. Fixture emails/SKUs are `*.m82c@example.test` / `m82c-*` only.

## Migrations applied (m82c only)

1. `20261103120000_damage_storage_store_keeper_draft.sql`
2. `20261103130000_damage_hold_ready_requires_lot_dual_write.sql`
3. `20261103140000_transfer_adjustment_honor_damage_holds.sql`

FORCE RLS on `damage_reports` confirmed.

## Flags

| Key | Before (m82c) | After cutover (m82c) | Owner DB |
|-----|---------------|----------------------|----------|
| `stock.lots.dual_write_enabled` | true | true (unchanged) | false |
| `stock.lots.aggregate_only_blocked` | true | true (**not** flipped by this milestone; already true) | false |
| `damage.stock_hold_ready` | false | **true** | false |

`SHORT_SHIPMENT_OPERATIONAL` not enabled.

Restore hold-ready on disposable stack:

```powershell
Get-Content scripts/dmg03c/restore-m82c-hold-ready-false.sql -Raw |
  docker exec -i supabase_db_sherlyos_m82c psql -U postgres -d postgres -v ON_ERROR_STOP=1
```

## Fixtures

| Role | Email | Password |
|------|-------|----------|
| Store Keeper | `keeper.m82c@example.test` | `local-only-m82c` |
| Godown Manager | `gm.m82c@example.test` | `local-only-m82c` |

| Master | Value |
|--------|-------|
| Godown | `m82c_gd1` / TEST ONLY Godown-1 |
| Zone / crate | `m82c_z1` / `m82c_c1` |
| Product | `m82c-stable` |
| Physical before | 17 cases |
| Reconcile | aggregate ↔ lot mismatched = 0 |

## Browser UAT results

Playwright: `npx playwright test -c playwright.dmg03c.config.ts` → **5 passed**.

Latest successful report from the final green run:

- **Damage ID:** `DMG-20261103-000006`
- Status after SK submit: Submitted → hold 1 case
- Physical on-hand: **17** (unchanged)
- Available = physical − active holds (decreased by 1 for this report)
- GM verify → **Verified**; holds still 1; physical still 17
- SK cannot verify own report
- Duplicate submit did not add holds

### Known disposable workarounds (documented gaps)

1. **Lot picker missing in storage UI** while dual-write is on. E2E attributes `lot_id` via SQL (`session_replication_role=replica`) after draft save, then continues in the browser.
2. If private photo finalize is flaky on the stack, evidence can be stamped via SQL (M5.3 pattern). Final green run enabled submit after browser upload path.

## Security / negative checks covered

- Isolated env sysid guard
- SK self-verify UI absent / blocked
- Duplicate submit hold count stable
- Backend readiness RPC reports `stock_hold_ready: true` for keeper JWT
- Owner DB flag remains false

## Other tests this pass

| Suite | Result |
|-------|--------|
| Playwright DMG-03C | **5/5 passed** |
| Vitest damage-editor + damage | **29 passed** |
| Cloud / owner flag flip | **NOT RUN** (forbidden) |

## Owner manual retest

```powershell
# Terminal 1 — isolated app (does not change 5173)
npm run dev -- --mode dmg03c --host 127.0.0.1 --port 5174 --strictPort

# Terminal 2 — automated suite
npx playwright test -c playwright.dmg03c.config.ts
```

Manual:

1. Open `http://127.0.0.1:5174/login`
2. Sign in as `keeper.m82c@example.test` / `local-only-m82c`
3. Operations → Damage → New → Storage → TEST ONLY Godown-1
4. Add line: `m82c-stable`, crate `m82c_c1`, qty 1, Packaging Damage
5. Save draft; if submit requires lot and UI has no lot field, use the SQL lot attribution from the e2e (or ask for a follow-up lot-picker story)
6. Attach photo → Review and submit → confirm
7. Sign in as `gm.m82c@example.test` → open report → Verify → Verify report
8. Confirm physical still 17; hold present; status Verified

## Remaining blockers / cloud cutover prerequisites

1. Add **storage lot picker** (or trusted auto-lot) before dual-write production cutover UX is complete.
2. Apply migrations `1200/1300/1400` to cloud only with owner approval.
3. Separate owner approval to set cloud `damage.stock_hold_ready=true`.
4. Do not confuse 5174 (disposable) with 5173 (cloud).
5. Optionally restore m82c hold-ready to false after UAT via restore script.

## Artifacts

- `.env.dmg03c.local`
- `playwright.dmg03c.config.ts`
- `tests/e2e/dmg03c-isolation-uat.spec.ts`
- `scripts/dmg03c/prepare-m82c-cutover.sql`
- `scripts/dmg03c/restore-m82c-hold-ready-false.sql`
