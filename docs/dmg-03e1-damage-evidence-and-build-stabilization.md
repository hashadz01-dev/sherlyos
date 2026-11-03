# DMG-03E.1 — Damage Evidence and Build Stabilization

**Verdict: PASS**

Disposable stack only (`supabase_db_sherlyos_m82c`, API `57321`, app `5174`). Cloud and owner DB unchanged. `DMG-20261103-000013` not modified. No commit/push/deploy.

## Root causes

### 1. TypeScript / build (`ReceivingPage.tsx`)

`FilterSelect` types `onChange` as `(value: string) => void`. Receiving status state was inferred as `ReceiptStatus | "all"` because `RECEIPT_VERIFICATION_DEFAULT_STATUS` is annotated that way, so React’s `Dispatch<SetStateAction<…>>` was not assignable to `(value: string) => void`.

This predates DMG-03D lot work; it blocked `tsc -b` / production build for the whole tree. Orders filters avoid the issue because their default status constant is a plain `string`.

### 2. Evidence finalization / SQL fallback

Trusted lifecycle was already correct:

1. `create_damage_photo_upload` → catalog row + private path  
2. Browser `storage.upload` to `stock-damage-evidence`  
3. `finalize_damage_photo_upload` → server reads Storage bytes via `damage_storage_object_bytes`, compares to client payload, sets `verified_at`, records `evidence_attached`

DMG-03C/D Playwright still wrapped upload in a **SQL stamp catch** when submit stayed disabled. That made browser-only finalize inconclusive even when recent runs had already succeeded (`mime_type=image/png`, `file_size=70`, `evidence_attached` events).

Disposable risk: byte fetch allowlist sometimes missed isolated Kong hostnames. Harden with explicit m82c/m81c hosts; do not trust client bytes alone.

## Files changed

| Path | Change |
|------|--------|
| `src/features/receiving/ReceivingPage.tsx` | Narrow status state + string→union `onChange` adapter |
| `src/features/damage/components/DamageEvidencePanel.tsx` | Stable alt `Finalized damage evidence` after trusted finalize |
| `supabase/migrations/20261103170000_damage_evidence_disposable_kong_hosts.sql` | Allowlist disposable Kong hosts for byte fetch |
| `tests/e2e/dmg03c-isolation-uat.spec.ts` | Remove SQL evidence stamp; assert browser finalize |
| `tests/e2e/dmg03d-lot-aware-storage-uat.spec.ts` | Same + prove `evidence_attached` |
| `playwright.dmg03e1.config.ts` | New disposable UAT config |
| `tests/e2e/dmg03e1-evidence-browser-only.spec.ts` | Browser-only evidence UAT |

## Evidence lifecycle (unchanged contract)

- Private bucket `stock-damage-evidence` (JPEG/PNG/WebP, 10 MB)
- Storage RLS insert/select for authenticated path owners
- Finalize is SECURITY DEFINER, ownership-checked, compares Storage bytes ≠ client-claimed metadata alone
- Browser never receives service-role keys
- Unfinalized rows cannot satisfy submit UX or GM verify

## Browser UAT results

Environment: m82c disposable, isolation flags already true from DMG-03C/D.

| Suite | Result |
|-------|--------|
| DMG-03E.1 Playwright | **4/4 PASS** |
| DMG-03D Playwright (no SQL evidence) | **6/6 PASS** |
| DMG-03C Playwright (no SQL evidence) | **5/5 PASS** |

E.1 covered: invalid MIME rejected; lot select; browser upload+finalize; reload keeps evidence+lot; submit isolation; one hold; other lot unchanged; physical 17; no new ledger rows from isolation; duplicate submit; SK self-verify blocked; GM verify; audit includes `evidence_attached,submitted,verified`.

Representative report: **`DMG-20261103-000024`** (verified). Audit: `created,evidence_attached,submitted,verified`. Proof of browser finalize: `image/png` size 70 + `evidence_attached` event (SQL stamp path used jpeg/4-byte marker and skipped the event).

## Stock reconciliation

- Aggregate physical for `m82c-stable` @ `m82c_c1`: **17** unchanged by isolation  
- Selected lot hold +1; other lot holds unchanged by that report  
- Stock ledger count unchanged across isolation submit  

## Typecheck / build / lint

| Check | Result |
|-------|--------|
| `npm run typecheck` | **PASS** |
| `npm run build` | **PASS** |
| `npm run lint` | **PASS** (existing warnings only) |
| Vitest receiving + damage (+ evidence viewer/fetch) | **47/47 PASS** |

## Regression notes

| Suite | Result |
|-------|--------|
| DMG-03A SQL on m82c | **Not applicable while cutover flags are true** (script requires flags false at start) |
| DMG-03B SQL on m82c | Executed transfer pre-check path; completed with test `ROLLBACK` |
| M5.3 isolation / concurrency full matrix | Not re-run this pass beyond E.1 hold/ledger checks |

## Security review

- No service-role in browser  
- Private bucket + path ownership preserved  
- Finalize still fail-closed on byte mismatch  
- Allowlist only adds known disposable Kong hostnames + existing cloud host  
- No RLS weakening, no GST/legal changes  

## Remaining blockers

- Cloud migrations / `damage.stock_hold_ready` still owner-gated  
- DMG-03A disposable SQL expects pre-cutover flags (restore script if re-running A on a fresh stack)  
- Owner app on 5173 untouched  

## Readiness for DMG-03E.2

UI-only lot + evidence + build gate are green on disposable m82c. E.2 can focus on remaining operational cutover packaging / cloud prerequisites without rediscovering evidence SQL workarounds.

## Final verdict

**PASS** — TypeScript/build green; evidence finalize proven browser-only with no SQL lot or evidence repair.
