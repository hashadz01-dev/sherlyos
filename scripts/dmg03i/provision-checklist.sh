#!/usr/bin/env bash
# DMG-03I owner provisioning checklist (manual). Does not create projects or write cloud.
set -euo pipefail

cat <<'EOF'
DMG-03I — Isolated cloud UAT provisioning (OWNER ACTIONS)

[ ] 1. Create a NEW Supabase project (separate from ypkfondrkhkydkgovwup).
[ ] 2. Record project ref + URL; store publishable/anon key in gitignored .env.dmg03i.local.
[ ] 3. Link CLI: supabase link --project-ref <NEW_REF>
[ ] 4. Push migrations from repo tip through 20261103160000 (exclude 20261103170000 unless required).
[ ] 5. Create Auth users: admin/keeper/gm @example.test (TEST ONLY).
[ ] 6. Seed masters + opening stock via trusted RPCs (see fixture-contract.md).
[ ] 7. Set dual_write=true, recon mismatched=0, then damage.stock_hold_ready=true.
[ ] 8. Start UI: npm run dev -- --mode dmg03i --host 127.0.0.1 --port 5175 --strictPort
[ ] 9. Confirm 5173 still uses ypkfondrkhkydkgovwup and hold_ready=false.
[ ] 10. Run Storage Damage browser UAT on 5175 only.

This script prints the checklist only. It does not mutate any database.
EOF
