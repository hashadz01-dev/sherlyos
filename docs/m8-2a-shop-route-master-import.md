# M8.2A — Central shop master and route grouping

Populate the existing Shops master from owner route lists. Organize by geographic sales route, not by salesperson. Tom / Liju / Arun are not assigned in this phase.

**Verdict: `M8.2A APPLIED ON DEVELOPMENT CLOUD`**

Shops are name-only. No phone, GSTIN, address, GPS, credit, salesperson, or godown. Matching key is `route_code::normalized_name`. PRIME on Thevara and PRIME on Thripunithura are two shops.

Flags unchanged: `damage.stock_hold_ready=false`, `stock.lots.dual_write_enabled=false`, `stock.lots.aggregate_only_blocked=false`, `SHORT_SHIPMENT_OPERATIONAL=false`.

This phase did not commit, push, or deploy.

---

## 1. Counts

| Metric | Value |
|---|---|
| Listed heading sum | 575 |
| Owner brief | 574 |
| Extracted visit rows | 571 |
| Distinct shops imported | 565 |
| Salesperson assignments | 0 |
| Unreadable names invented | 0 |

Four heading gaps were not invented: Thevara 41/42, Kadavanthra 40/41, Kalamassery 30/31, Chullikkal 39/40.

Six same-route name repeats stayed one shop (first sequence): Thripunithura AJ STORES; Palarivattom WE MART, SIDDIQE, ORANGE; Kaloor SHANKAR; Ernakulam Jacob/JACOB.

## 2. Schema

`supabase/migrations/20261030180000_sales_routes.sql` is applied on the development cloud. Fourteen `sales_routes` rows. `set_shop_sales_route` requires `shops.assign`.

## 3. Review file

`data/imports/shops/shop_import_review.csv` lists OCR-uncertain spellings and same-route duplicates. Sheet B names stay flagged until a clearer scan is provided.

## 4. Shops UI

`/masters/shops` groups by geographic route with visit sequence. Admin sees all 565. Route assignment is available now that the tables exist. Salesperson assignment is still a separate admin action and was not run.
