# DMG-06 — Salesperson shop-return damage (local implementation)

**Status: LOCAL IMPLEMENTATION + LOCAL TESTS COMPLETE — request separate approval before development-cloud rollout.**

No commit, push, deploy, Auth user create, operational flag flip, or development-cloud migration in this phase.

## Lifecycle

| Step | Actor | Stock effect |
|------|--------|--------------|
| Create/edit draft + evidence | Salesperson (`damage.shop_return.record`) | None |
| Submit | Salesperson (own draft/returned) | **None** |
| Confirm physical custody | GM (`damage.record` + `damage.verify`) on **submitted** | **None** |
| Verify | Independent `damage.verify` (not reporter) | Quarantine intake **once** |
| Disposition | Existing disposition / Admin flows | Unchanged |

Historical reports (including `DMG-20261103-000018`) are not modified. `apply_damage_stock_isolation` short-circuits when holds already exist.

## Permission matrix

| Permission | Salesperson before | Salesperson after | Godown Manager |
|------------|--------------------|-------------------|----------------|
| `damage.shop_return.record` | — | **Yes (new)** | No |
| `damage.read` | No | No (own shop_return via create grant + `can_view`) | Yes |
| `damage.record` | No | No | Yes |
| `damage.verify` | No | No | Yes |
| `damage.disposition` / `damage.dispose` | No | No | Existing |
| DMG-01–05 create / custody / verify | No | No | Existing |

## Migration

`supabase/migrations/20261104120000_dmg06_salesperson_shop_return.sql`

## Local ports note

On this Windows host, Hyper-V excluded TCP `54302–54401`, so local Supabase API/DB ports in `supabase/config.toml` were remapped to `55421` / `55422` for testing only.
