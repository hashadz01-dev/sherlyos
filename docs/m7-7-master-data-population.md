# M7.7 — Master data population (Sherlys catalogues)

Master-data import of Categories, Suppliers, and Products from Sherlys Distributors / MattaNaad / SUNPURE catalogues. This phase does **not** post opening stock, lots, receipts, dispatches, selling prices, purchase prices, or financial transactions. It does **not** flip operational flags.

Local apply ran first on `supabase_db_sherlyos`. Jeffin then authorized the same INSERT rows on the development cloud (`ypkfondrkhkydkgovwup`) so `npm run dev` on port 5173 can show them. Staged rows were not inserted.

Starting HEAD: `d5c56bb16e083c2636326a8b51ceee5302b11e53`  
`minor correction done`

Working tree is uncommitted. Branch `main`. No new migrations. No git commit, push, or deploy.

Flags at start and end (unchanged):

`damage.stock_hold_ready=false`  
`stock.lots.dual_write_enabled=false`  
`stock.lots.aggregate_only_blocked=false`  
`SHORT_SHIPMENT_OPERATIONAL=false` (hardcoded in `src/lib/picking/rules.ts`)

Authoritative stock writers were not modified. `verify_stock_receipt`, `confirm_dispatch`, and `post_delivery_return` were not touched.

---

## 1. Architecture

Catalogue rows live in `scripts/m7-7-catalog.mjs`. The local importer, CSV manifests, Vitest, and HTTP checks consume that file. `src/lib/masters/m7-7-catalog.ts` holds insertability invariants (SKU length, no invented case pack of 1).

Import path:

```
scripts/m7-7-catalog.mjs
  → npm run m7-7:dry-run   (classify only; writes docs/m7-7/*.csv + dry-run-report.json)
  → npm run m7-7:apply     (local RPCs only; writes docs/m7-7/local-apply-report.json)
```

RPCs used (existing, authenticated admin):

- `create_product_category`
- `create_supplier` then `set_supplier_active(..., false)`
- `create_product` with `next_supplier: null`
- `set_product_billing_conversion` (invoice billed qty per carton case; inventory unit stays one carton case)

Guards in `scripts/m7-7-import-local.mjs`:

- Refuses any API other than `http://127.0.0.1:54321`
- Requires container `supabase_db_sherlyos`
- Refuses the isolated M8.1C database
- Aborts if any of the three operational flags is true
- After apply, aborts if ledger / balances / lots / selling prices / invoice notes drifted
- Default mode is dry-run; `--apply` is explicit
- Writes gitignored `.env.m1s2.local` with the local URL and anon key only (no service_role)

Schema constraints that shaped the catalogue:

- Product `sku` unique on `lower(sku)`, max 40 characters
- Category unique on `lower(name)`; no category-code column (codes exist only in the catalogue file)
- Supplier has name / phone / email; no unique name, no address, no GSTIN
- `create_product` rejects an inactive supplier (`42501`); pending invoicing suppliers are therefore stored inactive and products keep `supplier_id` null
- Duplicate SKU is `23505`

Units-per-case from the source catalogues are stored only as `billed_units_per_case`. They are **not** a second inventory unit. Tea bags: outer carton = stock case; billed unit is `box`.

Expiry policy is left unclassified. No selling-price rows were created for catalogue SKUs.

### Source classes

| Class | Meaning | Disposition |
|---|---|---|
| `CONFIRMED_DISTRIBUTION` | Sherlys distributes this SKU and the case pack is in the source list | `INSERT` |
| `CONFIRMED_PRODUCT` | Product exists (MattaNaad packs) but carton quantity is unknown | `STAGE` |
| `MANUFACTURER_CATALOGUE_ONLY` | Present on a manufacturer list (SUNPURE extras, spices) without a Sherlys stockist confirmation | `STAGE` |

### Outcomes

`CREATED` · `ALREADY_EXISTS` · `SKIPPED_PENDING_VERIFICATION` · `CONFLICT_REQUIRES_REVIEW`

---

## 2. Manifests

Written by every importer run to `docs/m7-7/`:

- `categories.csv` — 13 rows. Catalogue codes (TEA, COFFEE, …) are documentation only.
- `suppliers.csv` — 6 pending inactive placeholders. Phone and email empty.
- `products.csv` — 125 rows (67 INSERT, 58 STAGE).

Category names:

Tea & Tea Bags · Coffee · Edible Oils · Rice & Grains · Sugar & Sweeteners · Jaggery · Dairy & Milk Products · Ghee · Dairy Whitener · Coconut Products · Spices & Masalas · Wheat Flour & Atta · Desserts & Mixes

Pending suppliers (all inactive, no contacts):

- AVT (pending invoicing confirmation)
- Kera (pending invoicing confirmation)
- MK Agrotech Pvt Ltd (manufacturer; invoicing pending)
- Parry's (pending invoicing confirmation)
- Nandini (pending invoicing confirmation) — supplier of GoodLife products; the GoodLife brand is not a supplier
- MattaNaad (pending invoicing confirmation)

TPF Bharat Private Limited is named on MattaNaad material and is **not** stored as the invoicing supplier. MK Agrotech is identified as manufacturer/marketer from the SUNPURE catalogue and is **not** treated as a proven Sherlys invoicing supplier.

Insertable SKUs (67) include AVT tea / coffee / ghee / whitener / Dairy Sure, Kera coconut oil and powders, Parry's sugar and jaggery, GoodLife milk and cream, and Sunpure sunflower oil 500 ml / 1 L pouch.

---

## 3. Dry-run (local)

`npm run m7-7:dry-run` against `supabase_db_sherlyos` before the first apply:

| Area | CREATED | ALREADY_EXISTS | SKIPPED | CONFLICT |
|---|---:|---:|---:|---:|
| Categories | 13 | 0 | — | 0 |
| Suppliers | 6 | 0 | — | 0 |
| Products | 67 | 0 | 58 | 0 |

Local snapshot before first apply:

products 1636 · categories 0 · suppliers 313 · ledger 1054 · balances 140 · lots 141 · prices 140 · invoice_notes 80 · true_flags 0

Proposed SKUs did not collide with existing local test products. Report: `docs/m7-7/dry-run-report.json`. `ownerDatabaseModified: false`.

---

## 4. Local apply

First `--apply`: products **1636 → 1703** (+67 catalogue SKUs), categories **0 → 13**, suppliers **313 → 319**. Ledger, balances, lots, selling prices, invoice notes, and flags unchanged.

Second `--apply` (idempotency): all rows `ALREADY_EXISTS` or `SKIPPED_PENDING_VERIFICATION`. Counts stayed 1703 / 13 / 319. Integrity snapshot unchanged. Report: `docs/m7-7/local-apply-report.json`.

Sample billing conversion after import (`supplier_id` null on every catalogue product):

| SKU | billing_unit | billed_units_per_case |
|---|---|---|
| AVT-PREM-DUST-100G | nos | 240 |
| AVT-TEABAG-25 | box | 36 |
| KERA-COIL-500ML-PCH | nos | 40 |
| SUN-SFO-500ML-PCH | nos | 20 |

Prior local test products (~1636) were **not** truncated.

---

## 5. Pending-verification list (staged, not inserted)

58 STAGE rows. Full list is `docs/m7-7/products.csv` where `disposition=STAGE`.

**MattaNaad rice** (`CONFIRMED_PRODUCT`, carton unknown; 2 kg is not listed):

- MATTA-VADI-1KG, 5KG, 10KG, 30KG, 50KG

**SUNPURE manufacturer extras** (sunflower PET/bucket/tin, groundnut, ricebran, mustard, vanaspati, Palmpure, soya, atta, sugar, khandsari, jaggery powder, gulab jamun mix). Includes an ₹10 pouch with unspecified volume and no SKU.

**Spices** — six families only, no SKU, no size matrix:

Coriander · Chilli · Turmeric · Sambar · Rasam · Puliyogare

Do not explode spice families into unsupported pouch sizes.

---

## 6. Conflict / review flags

No `CONFLICT_REQUIRES_REVIEW` rows on local apply.

Review flags kept on inserted or staged rows (values not averaged or “corrected”):

| Flag | Where |
|---|---|
| `TEA_BAG_PACKING_MODEL` | AVT tea bags and green tea bags (small boxes per outer carton) |
| `AMBIGUOUS_CASE_PACK` | Green tea leaf 100 g = 30 vs 250 g = 48; whitener 10 g = 38; green tea bags 30 @ 30 |
| `AMBIGUOUS_PACK_SIZE` | SUNPURE 15 L / 15 kg tins |

---

## 7. Tests

| Layer | Command | Result |
|---|---|---|
| Vitest catalogue | `npx vitest run tests/unit/m7-7-catalog.test.ts` | 6 passed |
| SQL RPC guards | `Get-Content supabase/tests/phase_m7_7_master_data.sql \| docker exec -i supabase_db_sherlyos psql …` | BEGIN / ROLLBACK; duplicate category, inactive supplier rejected, duplicate SKU, salesperson denied, stock/prices/flags unchanged |
| HTTP | `node supabase/tests/phase_m7_7_http_integration.mjs` | 5 passed: flags false, `AVT-PREM-DUST-100G` searchable, salesperson cannot create, duplicate SKU rejected |
| Playwright | `npx playwright test tests/e2e/m7-7-master-data.spec.ts` | admin.m1s2qa on `--mode m1s2` port 4173: Categories Tea & Tea Bags; inactive AVT pending supplier; product AVT-PREM-DUST-100G |
| Typecheck / build | `npm run typecheck` · `npm run build` | passed before this wrap-up |

Playwright uses gitignored `.env.m1s2.local` (`http://127.0.0.1:54321`). After owner authorization, the same INSERT rows were applied on the development cloud so `npm run dev` on 5173 shows them.

---

## 8. Development-cloud apply (authorized)

Jeffin asked for Products, Categories, and Suppliers to appear on port 5173 (development cloud, previously empty after the dummy-master wipe).

Applied through existing RPCs as Jeffin (`cdc087c0-0295-425d-8dbe-9a91030bf012`): `docs/m7-7/development-cloud-apply.sql`.

Cloud after apply: products **67**, categories **13**, suppliers **6** (all inactive), ledger/balances/lots/prices/invoice notes **0**, flags still false. `supplier_id` null on catalogue products. Staged MattaNaad / SUNPURE extras / spices were not inserted.

The local importer still refuses non-local APIs. Staged rows stay staged until the decisions in section 9.

---

## 9. Owner decisions still required

- Actual invoicing supplier / GSTIN for AVT, Kera, Parry's, Nandini (GoodLife brand), MattaNaad, SUNPURE
- MattaNaad case/sack representation
- SUNPURE extras: stockist vs manufacturer-only
- Spice size matrix
- Tea-bag billed unit (`box`) vs other packing
- Green tea / whitener case-pack anomalies
- 15 L vs 15 kg tins
- Expiry policy per SKU
- Whether to activate pending suppliers after GST/contact verification
- Whether catalogue products should later link `supplier_id` once a supplier is active
- Opening stock is a later phase; not part of M7.7

---

## 10. What this phase did not do

- No git commit, push, or Netlify deploy
- No flag flips
- No stock, lot, receipt, dispatch, or invoice-note writes
- No selling/purchase price rows for catalogue SKUs
- No fabricated GSTIN, phone, email, or carton quantity of 1
- Staged MattaNaad / SUNPURE extras / spices were not inserted
- Isolated M8.1C (`56321`) was not used
