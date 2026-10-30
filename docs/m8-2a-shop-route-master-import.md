# M8.2A — Shop master and sales-route import

Branch 1 Order-to-Delivery UAT preparation. Extract the 14 route-area shop lists, import eligible shop names locally, and preserve visit order without assigning salespersons.

**Verdict: `M8.2A BLOCKED — SCHEMA OR IMPORT CONSTRAINT`**

The four source screenshots were not attached to the agent turn and were not found under `data/imports/shops/source/`. Shop names were not invented. No `create_shop` calls ran. No salesperson assignments were written. No route tables were created.

Place the images in `data/imports/shops/source/` and continue extraction.

Starting HEAD: `61d912de865a9b153a1114c04d1da508e13897fe`  
`products data added` on `main`. Working tree already dirty from earlier uncommitted work. This phase did not commit, push, or deploy.

Flags (unchanged): `damage.stock_hold_ready=false`, `stock.lots.dual_write_enabled=false`, `stock.lots.aggregate_only_blocked=false`, `SHORT_SHIPMENT_OPERATIONAL=false`.

Stock writers were not modified.

---

## 1. Existing architecture (inspected)

### Shops

Table `public.shops` (`20261014210000_master_data.sql`): `name` (required, 1–160), optional `phone`, optional `address`, `is_active`. **No `branch_id`.** Comment on the table: shop-to-site ownership is unresolved.

RPCs: `create_shop(name, phone, address)`, `update_shop`, `set_shop_active`. Permission `shops.assign` (Admin) for create/update/deactivate. Phone and address may be null, so a name-only import is schema-legal. Do not invent phone, GSTIN, address, GPS, credit, or owner.

There is **no unique index on shop name**. `PRIME` in two areas can be two rows.

### Salesperson assignment

`shop_salesperson_assignments` is many salespersons per shop and many shops per salesperson. Active pair unique. This phase must not call `assign_shop_salesperson`.

### RLS

`shops_select_authorized`: Admin (`shops.assign`) sees all shops. Accounts (`shops.read_all`) sees active shops. A salesperson sees only shops with an active assignment to `auth.uid()`.

Order capture (`app_private.assert_order_shop`): Admin/Accounts can order for any active shop they can read. A salesperson can order only for an assigned shop. Until assignments exist, salespeople will not see imported shops. Admin will.

`loadOrderShops` reads `shops` through RLS. New-order UI is a shop `<select>` of those rows.

### Routes / visit schedule

**Not implemented.** No `sales_routes`, route areas, weekday schedule, visit sequence, or route-shop membership table. `zones` are godown pick-face zones (`branch_id` required), not sales routes. Do not reuse zones for Thevara/Kaloor lists.

### Branch 1

Shops are not owned by a godown. Orders still require `branch_id` at capture time.

Development cloud godowns: Godown-1 … Godown-7 (`gd_1` … `gd_7`). There is no row named “Branch 1”. Local container currently has **0** `branches` and **0** `shops` (67 catalogue products and 11 fleet vehicles remain). Cloud shops: **0**.

Do not assign every shop to Godown-1.

---

## 2. Source status

The owner brief states **574** listed entries. The 14 published area counts add to **575**. Extraction must confirm which figure is correct. Counts below are the published area totals:

| Collection | Day | Area | Expected |
|---|---|---|---:|
| SHEET_A | Monday | THEVARA | 42 |
| SHEET_A | Tuesday | VYTTILA TOC H | 31 |
| SHEET_A | Wednesday | NETTOOR, PANANGAD | 56 |
| SHEET_A | Thursday | MANJUMMEL VENNALA | 38 |
| SHEET_A | Friday | KARUKAPPALLY | 52 |
| SHEET_A | Saturday | THRIPUNITHURA | 42 |
| SHEET_B | Monday | PALARIVATTOM | 56 |
| SHEET_B | Tuesday | KADAVANTHRA | 41 |
| SHEET_B | Wednesday | KALOOR | 49 |
| SHEET_B | Thursday | KALAMASSERY | 31 |
| SHEET_B | Friday | KKD-1 | 25 |
| SHEET_B | Saturday | ERNAKULAM | 33 |
| SHEET_B | Saturday | MARKET | 39 |
| SHEET_C | unassigned | CHULLIKKAL | 40 |

Tom / Liju / Arun were **not** mapped. Temporary collections are `SHEET_A` / `SHEET_B` / `SHEET_C`. Chullikkal has no weekday.

Extracted rows: **0**. Distinct proposed shops: **0**. Count gap 574 vs 575 is unresolved.

---

## 3. Smallest later schema (proposal only — not applied)

To keep visit order without assigning people:

- `sales_routes` — name, source_collection, optional notes. No salesperson FK.
- `sales_route_days` — route_id, weekday nullable, area_name.
- `sales_route_shops` — day_id, shop_id, visit_sequence. A shop may appear on multiple days/routes.

This is a sales-visit sequence, not a delivery vehicle run. **No migration was written.** Owner approval is required before any DDL.

Until then, memberships live only in `data/imports/shops/*.csv`.

---

## 4. Intended local import (not executed)

When names exist: `create_shop(original_name, null, null)` as local admin on `supabase_db_sherlyos` only. Match key = `route_area::normalized_name` (case-insensitive, spaces collapsed, abbreviations kept). Same name in two areas → two shops. Same key twice → one shop, extra membership row in CSV. Ambiguous existing matches → review, no silent merge.

`--apply` currently refuses until extraction is complete.

---

## 5. Tests

| Layer | Result |
|---|---|
| Vitest `tests/unit/m8-2a-shops.test.ts` | 574 expected; abbreviations preserved; PRIME not merged across areas |
| SQL / HTTP / Playwright shop import | not run (no rows) |
| Typecheck of new TS | included in `npx tsc -b` when run |

---

## 6. Owner decisions required

1. Drop the four screenshots into `data/imports/shops/source/` so names can be extracted without guessing.
2. Confirm SHEET_A / SHEET_B / SHEET_C → Tom / Liju / Arun (or leave unmapped).
3. Confirm Chullikkal visit day.
4. Approve or reject the three-table sales-route schema. Do not improvise on `zones`.
5. Confirm shop-to-godown ownership for orders (shops have no branch column). Do not default every shop to Godown-1.
6. After shop master is verified, assign salespersons (multiple per shop allowed).
7. Authorize local `--apply`. Cloud/UAT import is a separate authorization.

**STOP FOR OWNER REVIEW.**
