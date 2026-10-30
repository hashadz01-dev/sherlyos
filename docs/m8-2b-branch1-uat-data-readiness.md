# M8.2B — Branch 1 UAT data readiness and gap closure

**Verdict: `M8.2B BLOCKED — DATA OR SCHEMA ISSUE`**

Live SQL was run on **30 Oct 2026** against development cloud `ypkfondrkhkydkgovwup` (the target of `npm run dev` on port **5173**) and, separately, local Docker `supabase_db_sherlyos`. Isolated `sherlyos_m81c` was not queried or modified.

This phase did **not** commit, push, deploy, reset a database, activate cutover flags, create prices, assign staff, write stock, or change owner/production data.

No silent operational writes were applied. Existing RPCs and screens can perform the needed master-data steps **after owner approval**. There is no confirmed application-code defect that should be patched before that approval.

---

## 1. Preflight

| Item | Result |
|---|---|
| Git branch | `main` |
| HEAD | `234cbaededafec5c21ecafc2d239406089dfcb13` — `shop data added and sales statement option added` |
| Working tree | Clean |
| Port 5173 | `VITE_SUPABASE_URL` host `ypkfondrkhkydkgovwup.supabase.co` (`.env` and `.env.local`) |
| Local Playwright / 4173 | `.env.m1s2.local` host `127.0.0.1` (local GoTrue/PostgREST on 54321) |
| Isolated cutover replica | `supabase_db_sherlyos_m81c` ports 56321/56322 — **not used** |
| Owner/production | No separate production project was identified in this workspace. Treat `ypkfondrkhkydkgovwup` as **development cloud only**. |

Cloud migration names include `sales_routes` (`20261030110239`) and `shop_sales_statement` (`20261030112536`). Local files use `20261030180000` / `20261030190000`. Functions exist on both. Do not `db reset` to “align” timestamps.

Cutover flags on **both** cloud and local Docker:

| Flag | Cloud | Local | Source |
|---|---|---|---|
| `damage.stock_hold_ready` | `false` | `false` | `app_configuration` |
| `stock.lots.dual_write_enabled` | `false` | `false` | `app_configuration` |
| `stock.lots.aggregate_only_blocked` | `false` | `false` | `app_configuration` |
| `SHORT_SHIPMENT_OPERATIONAL` | `false` | `false` | `src/lib/picking/rules.ts` |

---

## 2. Live master-data counts

### Development cloud (5173 UAT target)

| Entity | Total | Active | Reconstructed guess | Live vs guess |
|---|---:|---:|---:|---|
| Auth users / profiles | 5 | 5 | Jeffin only | **More:** four Test* users exist |
| Godowns (`branches`) | **7** | 7 | unknown | **Godown-1 … Godown-7**, all active |
| Zones | **0** | 0 | unknown | **Missing** |
| Crates | **0** | 0 | unknown | **Missing** |
| Categories | 13 | 13 | 13 | Match |
| Suppliers | 6 | **0** | 6 inactive | Match (all inactive) |
| Products | **102** | 102 | 67, “potentially more” | **Sunpure extras applied** (67 + 35) |
| Shops | 565 | 565 | 565 | Match |
| Sales routes | 14 | 14 | 14 | Match |
| Shop–route memberships | 565 | — | 565 | Match; 0 shops without a route |
| Shop–salesperson assignments | **0** | 0 | 0 | Match |
| Vehicles | 11 | **11** | 11 total, Bolero inactive | **Bolero is active** on cloud |
| Selling prices | **0** | 0 | 0 | Match |
| Stock lots / lot balances | **0** / **0** | — | 0 | Match |
| Aggregate balances / ledger / transactions | **0** / **0** / **0** | — | 0 | Match |
| Opening stock (`OPENING_STOCK`) | **0** | — | 0 | Match |
| Orders / delivery notes / invoice notes | 0 / 0 / 0 | — | — | Empty |

### Cloud staff (all profiles active; **zero** `user_branch_assignments`)

| Email | Name | Role |
|---|---|---|
| jeffinpappachan110@gmail.com | Jeffin Pappachan | admin |
| testaccounts@gmail.com | Test Accounts | accounts |
| testgodownmanager@gmail.com | Test Godownmanager | godown_manager |
| testsalesperson@gmail.com | Test Salesperson | salesperson |
| teststorekeeper@gmail.com | Test Storekeeper | store_keeper |

**Delivery Person: 0 users.** There is no Auth account to sign in as. Employees UI can assign a role to an existing profile; it cannot create a Supabase Auth user.

### Local Docker (`supabase_db_sherlyos`) — do not use as 5173 UAT data

| Entity | Live |
|---|---|
| Users | 2: Jeffin (admin), `admin.m1s2qa@example.com` (admin, e2e seed) |
| Godowns / zones / crates | **0 / 0 / 0** |
| Products | **67** (Sunpure extras **not** applied locally) |
| Shops / routes / assignments | 565 / 14 / 0 |
| Vehicles | 11 total, **10 active** (Bolero inactive, as imported) |
| Prices / lots / balances | 0 / 0 / 0 |
| Delivery person | 0 |

Local Docker is **not** a copy of development cloud.

---

## 3. Missing relationship report (cloud)

### Products

| Gap | Count |
|---|---:|
| No `supplier_id` | **65** |
| Linked to Sunpure (MK Agrotech; invoicing pending) | **37** (supplier still **inactive**) |
| No category | 0 |
| Billing conversion present | 67 |
| Billing conversion missing | **35** (the Sunpure extra SKUs) |
| `expiry_policy` unclassified | **102** |
| Default or shop selling price | **0** |

Empty categories: **Rice & Grains (0)**, **Spices & Masalas (0)**. MattaNaad rice and spice SKUs remain staged, not inserted.

`create_product` / `update_product` reject an inactive supplier. Linking AVT / Kera / Parry’s / Nandini products requires owner-approved supplier activation first.

Pilot SKU facts:

| SKU | Category | Supplier | Billing |
|---|---|---|---|
| `AVT-PREM-DUST-100G` | Tea & Tea Bags | none | nos × 240 |
| `KERA-COIL-500ML-PCH` | Edible Oils | none | nos × 40 |
| `PARRY-WHITE-1KG` | Sugar & Sweeteners | none | nos × 20 |
| `SUN-SFO-500ML-PCH` | Edible Oils | Sunpure (inactive) | nos × 20 |
| `SUN-SFO-1L-PCH` | Edible Oils | Sunpure (inactive) | nos × 10 (catalogue value, not invented) |

### Shops

- 565 / 565 have a geographic route membership.
- 565 / 565 have **no** salesperson.
- 565 / 565 have **no** phone and **no** address (name-only import).
- Shops have **no** godown column by design.
- Route weekday: Chullikkal `null`. Heading gaps not invented: Thevara 41/42, Kadavanthra 40/41, Kalamassery 30/31, Chullikkal 39/40.

Thevara visit 1–5 (proposed UAT shops): Family supermarket, Idukki Spice, Krishna Stores, Family Mini mart, S T M.

### Sites and stock

- Seven godowns exist; **none** have a zone or crate. Opening stock and picking require crate → zone → godown.
- No opening transactions, no lots, no balances.
- `post_opening_stock` with dual-write **off** writes **aggregate-only** stock (no lot identity).
- `create_picking_request` **fails closed** when `stock.lots.dual_write_enabled` is false: *“Lot-aware picking requires dual-write to be enabled. Aggregate-only stock has no valid lot identities.”*
- Therefore a complete Order-to-Delivery UAT **cannot** run on development cloud without either enabling dual-write there (not recommended) or using an **isolated UAT database**.

### Vehicles

All 11 fleet plates exist, `branch_id` null (shared fleet, intended), type `other`, capacity null. Cloud: Bolero **active**. Local: Bolero **inactive**. Do not invent capacities.

### Payments / GST

Customer receipts are not implemented (M8.2B.1). Statutory GST invoice and credit-note issuance remain blocked. UAT invoice path stops at **invoice-note review** and **internal credit-adjustment preview**.

---

## 4. Branch 1 pilot dataset manifest

**Site:** Godown-1 (`gd_1`, id `798bacf9-2212-43fc-9cbb-2fe1e7367a93`). Active. No zone/crate yet.

Do **not** invent a real warehouse map. If the owner approves UAT labels, Admin can create them in `/masters/locations`:

| Record | Status | Proposed if owner agrees |
|---|---|---|
| Zone | missing | code `uat_z1`, name `UAT Zone 1` under Godown-1 |
| Crate | missing | code `uat_c1`, name `UAT Crate 1` in that zone |

**People (exist except driver):**

| Role | Record | Godown assignment | Action |
|---|---|---|---|
| Admin | Jeffin | none (Admin has `branches.access_all`) | Keep |
| Accounts | testaccounts@gmail.com | none | Assign Godown-1 if Accounts work is site-scoped; otherwise leave |
| Godown Manager | testgodownmanager@gmail.com | **none** | Assign Godown-1 |
| Salesperson | testsalesperson@gmail.com | **none** | Assign Godown-1 **and** shops |
| Store Keeper | teststorekeeper@gmail.com | **none** | Assign Godown-1 |
| Delivery Person | **does not exist** | — | Create Auth user, profile, role `delivery_person`, assign Godown-1 |

**Shops (exist, Thevara Monday):**

1. Family supermarket `8f84fabb-c550-45dc-afeb-60f59a730f52`
2. Idukki Spice `47403fdf-7cf3-429c-94ab-609fde05440e`
3. Krishna Stores `8a212668-7d4c-4a95-a6dc-b0eed8a570c9`
4. Family Mini mart `9b8ead31-652e-4ba0-8ee4-017ba11254ca`
5. S T M `f6520e5b-9071-40e4-8c02-efc32108e01a`

Assign `testsalesperson@gmail.com` via existing `assign_shop_salesperson` (Shops detail / list). No invented phone/GSTIN.

**Products (exist). Owner must still approve supplier, expiry, and price:**

| SKU | Use if |
|---|---|
| AVT-PREM-DUST-100G | Owner classifies expiry and names a **test** default INR price |
| KERA-COIL-500ML-PCH | same |
| PARRY-WHITE-1KG | same |
| SUN-SFO-500ML-PCH | already linked to inactive Sunpure; needs billing already present |
| Optional 5th | `SUN-SFO-1L-PCH` only if owner accepts nos × 10 |

Do not activate AVT/Kera/Parry’s/Nandini until invoicing identity is confirmed. UAT can still order a product with `supplier_id` null; receiving later will need a supplier.

**Vehicle:** Benz (B) `KL-43-F-948` (active, shared fleet). Confirm Bolero should remain active on cloud.

**Selling prices / stock quantities / expiry dates:** **owner input required.** No amounts or quantities are proposed here.

---

## 5. Owner approvals needed before any data writes

RPCs/screens already exist. None of the following has been applied.

1. **Create a Delivery Person Auth user** (email/password chosen by owner). Then Admin: Employees → role `delivery_person` → assign Godown-1.
2. **Assign Godown-1** to Test Godownmanager, Test Salesperson, Test Storekeeper (and Delivery Person). RPC: `assign_user_branch`.
3. **Assign the five Thevara shops** to Test Salesperson. RPC: `assign_shop_salesperson`.
4. **Create UAT zone + crate** on Godown-1, or supply the owner’s real zone/crate names. RPCs: `create_zone`, `create_crate` (`/masters/locations`).
5. **Classify expiry** on the pilot SKUs (`expiry_controlled` vs `non_expiring`). RPC: `set_product_expiry_policy`. Do not invent dates.
6. **Test default selling prices** (INR, `shop_id` null) for those SKUs. RPC: `upsert_product_selling_price` (`/masters/prices`). Owner must state each unit amount and `effective_from`.
7. **Billing conversion** for the 35 Sunpure extra SKUs if any of those enter UAT. UI already calls `set_product_billing_conversion`.
8. **Supplier activation / product link** only if owner confirms the invoicing party. `set_supplier_active` then `update_product`. Pending GSTIN/phone stay empty unless owner supplies them.
9. **Bolero** active on cloud vs inactive locally — confirm intended status.
10. **Stock path (choose one):**
    - **A. Isolated UAT database** (recommended): copy schema, seed only the pilot rows, enable dual-write **there**, post opening lots, run picking → dispatch → POD. Do **not** flip flags on `ypkfondrkhkydkgovwup`.
    - **B. Enable `stock.lots.dual_write_enabled` on development cloud** — owner-only, high risk; still no production.
11. **Opening stock quantities** per pilot SKU in the UAT crate. Owner must state carton cases. `post_opening_stock` after dual-write on the chosen database, with lot metadata for expiry-controlled SKUs.
12. **Do not** enable `damage.stock_hold_ready`, `stock.lots.aggregate_only_blocked`, or `SHORT_SHIPMENT_OPERATIONAL` for this UAT unless separately approved.

Statutory GST invoice issuance and legal credit notes stay blocked.

---

## 6. Role-access gap report

Live `role_permissions` on development cloud (workflow subset). Hidden navigation is **not** treated as security.

| Capability | Admin | Accounts | GM | Sales | Store keeper | Delivery |
|---|---|---|---|---|---|---|
| `orders.capture` | no (`operations.monitor` only) | **yes** | no | **yes** | no | no |
| `orders.verify` | no | **yes** | no | no | no | no |
| Picking allocate/manage | **yes** | no | **yes** | no | execute only | no |
| Dispatch view/confirm | **yes** | no | **yes** | no | no | no |
| `deliveries.assign` | no | no | **yes** | no | no | no |
| `deliveries.execute` | no | no | no | no | no | **yes** (role exists; **user missing**) |
| DN issue | no | **yes** | no | no | no | no |
| Invoice-note prepare | no | no | **yes** | no | no | no |
| Invoice review | **yes** | **yes** | no | no | no | no |
| `shops.statement.read` | **yes** | **yes** | no | no | no | no |
| `stock.opening.post` | **yes** | no | no | no | no | no |
| Prices manage | **yes** | **yes** | no | no | no | no |
| Locations manage | **yes** | no | **yes** | no | no | no |

**Unnecessary-module notes (by design, not patched here):**

- Admin with `operations.monitor` sees almost the whole Operations nav. That is the monitor grant, not a leak of salesperson-only capture.
- Accounts has `suppliers.manage` and price manage; they cannot pick, dispatch, or assign vehicles.
- Godown Manager has `vehicles.manage` and `products.manage`. They cannot capture/verify orders or read shop statements.
- Salesperson is correctly narrow (capture + shop/product read). They cannot see statements or stock.
- Store Keeper is correctly narrow (receive execute, pick execute, stock read).
- Delivery Person grant is only `deliveries.execute`. RLS/RPC for other modules stay denied. The gap is **missing user**, not extra grants.

Employees screen: Admin can assign roles and godowns to **existing** profiles. There is no in-app Auth signup for a new Delivery Person.

---

## 7. Stock and lot readiness verdict

**Not ready on development cloud.**

Reasons:

1. No zones/crates under Godown-1.
2. No opening stock, lots, or balances.
3. Dual-write is false, so picking allocation is blocked even if aggregate opening were posted.
4. Enabling dual-write on the shared development cloud would affect every later operational write. That is an owner decision, not a UAT default.

### Isolated UAT setup plan (reproducible, not executed)

1. Leave `ypkfondrkhkydkgovwup` flags false.
2. Do **not** reuse `sherlyos_m81c` unless the owner explicitly retires that cutover replica.
3. Create a new local Postgres/PostgREST pair (new ports, new DB name, e.g. `sherlyos_uat_b1`).
4. Apply `supabase/migrations` in version order (or restore a schema-only dump of development cloud).
5. Seed **only** the pilot: Godown-1, one zone, one crate, five shops, five SKUs, six role users, one vehicle, owner-stated prices and opening lots.
6. Enable `stock.lots.dual_write_enabled` **only** on that database.
7. Point a Vite `--mode` file at that URL (not `.env` used by 5173).
8. Run the UAT sequence below. Tear down the database when UAT ends. Do not merge lots back onto development cloud.

Opening stock on cloud with dual-write off would create aggregate rows that **cannot** be picked and must not be backfilled into lots later.

---

## 8. Exact next UAT execution steps (after approvals)

Existing screens, in order. GST issuance stays off.

1. **Admin setup** (`/employees`, `/masters/locations`, `/masters/shops`, `/masters/prices`, `/inventory/opening` on the **approved** database)
   - Delivery Person Auth user + role + Godown-1
   - Branch assignments for GM, salesperson, store keeper, driver
   - Zone + crate
   - Shop assignments
   - Expiry classification
   - Default test prices (owner amounts)
   - Opening lots (owner quantities; dual-write on)
2. **Salesperson** `/orders/new` — capture against an assigned Thevara shop and classified products.
3. **Accounts** `/orders/:id` — verify. Inventory unchanged.
4. **Godown Manager** — delivery note if used, then `/picking` allocate FEFO/FIFO, store keeper execute pick.
5. **Godown Manager** `/dispatch` — confirm consume-once.
6. **Godown Manager** delivery-run assign vehicle Benz (B) + Delivery Person.
7. **Delivery Person** `/delivery-runs` — proof of delivery (or failed-delivery path). No stock restock except the existing return workflow.
8. **Godown Manager** `/invoices` — prepare invoice-note draft (not a tax invoice).
9. **Accounts** invoice-note review. Credit-adjustment preview only if a verified return exists.
10. **Payments tab** remains pending. Do not post receipts.

If any step is run on 5173 **before** dual-write and opening lots exist, stop at order verification: picking will fail closed.

---

## 9. Application functions available (no writes performed)

| Need | RPC / screen |
|---|---|
| Supplier on/off | `set_supplier_active` — `/masters/suppliers` |
| Product–supplier / category | `update_product` — `/masters/products` |
| Expiry | `set_product_expiry_policy` — Products classify dialog |
| Billing conversion | `set_product_billing_conversion` — Products billing dialog |
| Shop assignment | `assign_shop_salesperson` — Shops list/detail |
| Zone / crate | `create_zone`, `create_crate` — `/masters/locations` |
| Prices | `upsert_product_selling_price` — `/masters/prices` |
| Vehicle list | `list_assignable_vehicles` (shared fleet; active, not in-run) |
| Role / site | `assign_user_role`, `assign_user_branch` — `/employees` |
| Opening stock | `post_opening_stock` — `/inventory/opening` |

No code change is required for those entry points. The blocker is **missing approved data** plus **lot dual-write policy**.

---

**M8.2B BLOCKED — DATA OR SCHEMA ISSUE**

STOP FOR OWNER REVIEW.
