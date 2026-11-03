# M8.2E — Godown-1 UAT stock cutover (development cloud)

Owner asked to unblock Order-to-Delivery UAT on port 5173. Applied to `ypkfondrkhkydkgovwup` only. Local Playwright DB (54321) was not changed.

## Applied

- `stock.lots.dual_write_enabled=true`
- `stock.lots.aggregate_only_blocked=true` (required with dual-write)
- `damage.stock_hold_ready=false` (unchanged)
- Zone `uat_z1` / crate `uat_c1` on Godown-1
- `GOODLIFE-MILK-500ML` classified `expiry_controlled`
- Opening lot `UAT-GL500-20261102`, 20 cases, expiry 2026-12-31
- Godown Manager and Store Keeper assigned to Godown-1
- Accounts was **not** assigned

ATP for `SO-20261030-000025` as Test Accounts: `picking_operational=true`, requested 2, eligible 2, shortfall 0. Verify was not executed; Accounts still clicks Verify in the UI.

Script: `scripts/m8-2e/enable-godown1-uat-stock.sql`.

## Still blocked later in the pipeline

- Invoice notes: no selling price on this SKU
- Delivery confirmation: no Delivery Person user
- GST issuance: still disabled by design
