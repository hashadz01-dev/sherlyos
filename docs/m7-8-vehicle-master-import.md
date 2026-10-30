# M7.8 — Vehicle master data import (shared fleet)

Import of the 11 vehicles extracted from Sherlys Distributors' Vehicle.docx into the M7.4A vehicle master, after the owner confirmed vehicles are **not** bound to a godown. A vehicle is assigned when a delivery to shops is about to start, from the available fleet.

This phase does **not** post stock, change existing delivery runs, or flip operational flags.

Starting HEAD: `61d912de865a9b153a1114c04d1da508e13897fe`  
`products data added`

Branch `main`. New migration `20261030150000_shared_vehicle_fleet.sql`. No git commit, push, or deploy unless the owner asks.

Flags at start and end (unchanged):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false`

Authoritative stock writers were not modified. `verify_stock_receipt`, `confirm_dispatch`, and `post_delivery_return` were not touched. `lock_vehicle_for_dispatch` no longer rejects a vehicle for belonging to another godown.

---

## 1. Owner decision

Vehicles are a shared delivery fleet. There is no home godown on the master. At dispatch time the godown manager picks an **available** vehicle (active, not already on a `dispatched` / `in_transit` run). The previous product model required `vehicles.branch_id` and filtered `list_assignable_vehicles` to that godown, which would have hidden the fleet from other sites.

Vehicle.docx did not classify type. Rows are stored as `other`. Capacity, insurance, fitness, and ownership were not invented.

Bolero (`KL-43-R-6725`) was marked optional in the source. It is created **inactive** so it appears on the master but is not offered on a delivery run until the owner activates it.

---

## 2. Schema change

Migration `20261030150000_shared_vehicle_fleet.sql`:

- `vehicles.branch_id` is nullable
- `create_vehicle` accepts a null godown
- `list_assignable_vehicles` returns every **active** fleet vehicle; `in_use` stays global
- `lock_vehicle_for_dispatch` no longer raises `vehicle belongs to another godown`
- Select RLS is `vehicles.view` only (no godown filter)

The Vehicles page lists the whole fleet. The delivery selector still requires `deliveries.assign` at the dispatch godown.

---

## 3. Source plates

| Name | Display | Normalized | Status after import |
|---|---|---|---|
| Benz (B) | KL-43-F-948 | kl43f948 | active |
| Benz (S) | KL-43-K-3458 | kl43k3458 | active |
| New SML | KL-43-T-5764 | kl43t5764 | active |
| Mahindra | KL-43-N-3241 | kl43n3241 | active |
| Bada Dost (Malayalam Motors) | KL-43-P-0012 | kl43p0012 | active |
| Tata | KL-43-P-7981 | kl43p7981 | active |
| Mahindra New | KL-43-Q-1561 | kl43q1561 | active |
| SML | KL-43-R-1543 | kl43r1543 | active |
| Big Benz | KL-43-R-5470 | kl43r5470 | active |
| Veero | KL-43-S-7528 | kl43s7528 | active |
| Bolero (optional) | KL-43-R-6725 | kl43r6725 | inactive |

Type for all rows: `other`. Godown: null. Capacity: null.

---

## 4. Apply

Local importer: `npm run m7-8:dry-run` then `npm run m7-8:apply` against `supabase_db_sherlyos` only.

Local apply: vehicles 106 → 117 (11 fleet rows). Active 101 → 111 (Bolero inactive). Dispatch-with-vehicle, assignments, ledger, balances, lots, prices, invoice notes, and flags unchanged.

Development-cloud import (same pattern as M7.7 so the 5173 session can see the fleet): migration `shared_vehicle_fleet` plus `docs/m7-8/development-cloud-apply.sql`. Cloud now has 11 vehicles, 10 active, Bolero inactive, no home godown.

Isolated M8.1C ports 56321/56322 were not used. No git commit, push, or deploy.

---

## 5. Tests

| Layer | Command | Result |
|---|---|---|
| Vitest | `npx vitest run tests/unit/m7-8-vehicles.test.ts tests/unit/masters.test.ts` | 10 passed |
| SQL | `phase_m7_8_vehicles.sql` BEGIN/ROLLBACK | passed: null-godown create, lock for any dispatch site, duplicate plate, invalid type, salesperson denied |
| HTTP | `phase_m7_8_http_integration.mjs` | 6 passed: 11 plates present, Bolero inactive, GM selector includes Benz (B) and omits Bolero |
| Playwright | `tests/e2e/m7-8-vehicles.spec.ts` | 1 passed on `--mode m1s2` port 4173 |
| Typecheck | `npx tsc -b` | passed |
| Browser | 5173 `/masters/vehicles` as Jeffin | 11 fleet rows; search `KL-43-F-948` shows Benz (B); Bolero Inactive |

---

## 6. Still open

- Confirm whether Bolero should be activated for shop deliveries
- Confirm per-plate type (`truck` / `van` / `two_wheeler` / `other`) if the owner wants a tighter label than `other`
- Capacity cases, if any (informational only)
