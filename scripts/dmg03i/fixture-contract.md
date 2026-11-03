# DMG-03I disposable fixture contract

Use only on an **isolated** Supabase project or disposable Docker DB.  
Never run against `ypkfondrkhkydkgovwup`.

## Identifiers (TEST ONLY)

| Entity | Code / value |
|--------|----------------|
| Godown | `dmg03i_gd1` / name `TEST ONLY DMG03I Godown-1` |
| Zone | `dmg03i_z1` / `TEST ONLY DMG03I Zone 1` |
| Crate | `dmg03i_c1` / `TEST ONLY DMG03I Crate 1` |
| Product A | sku `dmg03i-stable-a` |
| Product B | sku `dmg03i-stable-b` |
| Lot A | `TEST-LOT-DMG03I-A` (optional expiry `2099-12-31`) |
| Lot B | `TEST-LOT-DMG03I-B` (optional expiry `2099-06-30`) |
| Opening qty | 20 cases each product on `dmg03i_c1` |
| Store Keeper | `keeper.dmg03i@example.test` |
| Godown Manager | `gm.dmg03i@example.test` |
| Admin (seed) | `admin.dmg03i@example.test` |
| Password (local/UAT only) | set at provision time; never reuse production passwords |

## Trusted provisioning sequence (no direct balance SQL)

1. Create branch/godown/zone/crate masters via existing masters RPCs or approved seed scripts patterned on `scripts/m8-2c/http-seed.mjs`.
2. Create products with expiry policy compatible with dual-write opening.
3. Assign roles/permissions (`damage.record`, `damage.verify`, `damage.read`, `stock.opening.post`, etc.).
4. Enable `stock.lots.dual_write_enabled=true` only after lot foundation migrations.
5. `post_opening_stock` for Product A/B with lot metadata + idempotency keys `dmg03i-open-a` / `dmg03i-open-b`.
6. Confirm aggregate = lot sum; avail = physical.
7. Apply DMG-03H pending migrations (see activation doc).
8. Set `damage.stock_hold_ready=true` via trusted admin SQL.
9. Browser UAT on port **5175** only.

## Forbidden

- `INSERT`/`UPDATE` on `stock_balances` / `stock_lot_balances` outside trusted writers  
- Copying commercial customers, suppliers, employees, or ledgers from `ypkfondrkhkydkgovwup`  
- Pointing `.env.local` (5173) at the new project without owner change control  
