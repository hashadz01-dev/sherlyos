# Phase 2C.3 inventory ledger

Migration `supabase/migrations/20261015180000_inventory_ledger.sql` is applied on local Supabase and on development project `ypkfondrkhkydkgovwup`. This phase is committed to `main`. Production was not changed.

Earlier migrations were not edited. `stock.opening.post` was already granted to Admin and was left in place.

## Approved inventory rules

- The unit is a whole carton case. Quantities are integers from 1 to 1,000,000.
- Several SKUs may occupy one crate. Crate capacity is not enforced.
- Negative stock is prohibited.
- Opening stock is posted by Admin only, once per product and crate.
- Balances are not edited directly. They change only inside a posting function.
- A crate or zone with a positive balance cannot be deactivated. There is no Admin override.
- A transfer is a ledger transaction. Both crates must belong to the same godown.
- Cross-godown transfers are prohibited.
- Posted history is append-only.

Piece conversion, pricing, valuation, receiving, dispatch, damage posting, refill, verification posting, and generic stock adjustments are not in this phase.

## Permission matrix

| Role | `stock.read` | `stock.opening.post` | `stock.transfer.post` |
| --- | --- | --- | --- |
| Admin | Yes | Yes, already granted | Yes |
| Accounts | Yes | No | No |
| Godown Manager | Yes | No | Yes |
| Store Keeper | Yes | No | No |
| Salesperson | No | No | No |
| Delivery Person | No | No | No |

`stock.transfer.post` is the only new permission. Existing adjustment grants stay as they were: Godown Manager holds `stock.adjustment.post`, `stock.adjustment.request`, `stock.discrepancy.report`, and `stock.verify`; Admin holds `stock.adjustment.approve_exceptional`; Store Keeper holds `stock.count_assist`. No `stock.adjustment.*` grant was added or removed.

## Site-scoped reads

`stock.read` does not open every godown. List functions and row-level policies call `app_private.can_work_at_branch`, which is true for `branches.access_all` or an active assignment to an active branch. Admin has `branches.access_all`. A Godown Manager sees only assigned active godowns.

Accounts and Store Keeper have no site model of their own. They receive `stock.read`, and they see a godown only when an administrator has already assigned it with `assign_user_branch`. This migration does not assign them and does not treat the grant as global. A filter or guessed crate outside that scope returns no rows. The browser filters are not the security boundary.

The list functions are security definer and return godown, zone, crate, product, and actor labels. Accounts and Store Keeper do not have `products.read` or `locations.read`, so they cannot be required to join those tables under row-level security. The underlying tables still hide rows outside `can_work_at_branch`.

## Posting

`post_opening_stock` requires an active profile and `stock.opening.post`. It checks the product, godown, zone, and crate are active, the caller can work at that godown, and the quantity is a positive whole number. It writes one positive ledger entry and the balance projection. A second distinct opening for the same product and crate is rejected. There is no correction or unrestricted adjustment.

`post_crate_transfer` requires `stock.transfer.post`. Admin and Godown Manager hold it. The source and destination crates must differ, both must be active, and both must belong to the same godown the caller can work at. A Godown Manager targeting another godown is not authorized. An Admin transferring across godowns is rejected as a business rule. The function writes a negative source entry and a positive destination entry, updates both balances, and rolls back together if either side fails. Insufficient stock is rejected.

The caller cannot supply the actor or the timestamp. Both functions audit a successful post. Ledger writes, balance updates, and the audit row commit or roll back together.

## Idempotency and concurrency

Every post requires an idempotency key of 8 to 80 letters, digits, underscores, or hyphens. The request fingerprint is the type, product, crates, quantity, and notes. An exact retry returns the original transaction. The same key with a different payload fails.

The posting functions lock zones, then crates, then balance rows, in identifier order. The idempotency replay is checked again after those locks, so a concurrent retry waits and then returns the original transaction instead of raising a duplicate-opening error.

Balance updates run only after the ledger rows exist. A trigger rejects a balance that does not equal the ledger sum for that crate and product. A deferred constraint checks that an opening has one positive entry and that a transfer nets to zero.

## Reconciliation

Compare the ledger with the projection:

```sql
select count(*) filter (
         where coalesce(ledger.qty, 0) is distinct from coalesce(balances.quantity, 0)
       ) as mismatches,
       count(*) filter (where balances.quantity < 0) as negatives
from (
  select crate_id, product_id, sum(quantity) as qty
  from public.stock_ledger
  group by crate_id, product_id
) ledger
full join public.stock_balances balances using (crate_id, product_id);
```

`list_stock_balances` hides zero rows. A zero projection row can remain after a crate is emptied. Transfer ledger quantities for one transaction sum to zero. Opening quantities remain in the ledger total.

## Stock-aware deactivation

`set_crate_active` and `set_zone_active` are replaced in this migration. Existing execute grants are preserved. Deactivation locks the zone, then its crates, then the balance rows, and rechecks status. A crate with any positive balance raises `crate still holds stock`. A zone whose crates hold stock raises `zone still holds stock`. An empty crate or zone can still be deactivated. Posting into an inactive product, godown, zone, or crate is rejected. Reactivating a crate still requires an active zone.

## Screens

- `/inventory` — balances for authorized godowns, with search and a godown filter built from the returned rows. Requires `stock.read`.
- `/inventory/opening` — Admin form. Confirmation, then `post_opening_stock`. The idempotency key is kept until the post succeeds.
- `/inventory/transfers` — Admin and Godown Manager. Destination crates are limited to the selected godown and exclude the source crate. The form shows the source balance and blocks a quantity above it. The server still enforces the rule.
- `/inventory/history` — read-only references, type, product, crates, quantity, actor, and timestamp.

Navigation hides a screen the caller cannot use. Direct visits without the permission show the access-denied page.

## Tests that ran

SQL, in authenticated role contexts, each rolled back:

- `supabase/tests/phase_2c1_master_data.sql` — passed. The suite still rejects unapproved stock tables and functions, and it allows the three ledger tables and the approved stock grants.
- `supabase/tests/phase_2c2_master_data_access.sql` — passed. `stock.read` is no longer treated as an Admin-only grant. `stock.opening.post` and `shops.assign` stay Admin only.
- `supabase/tests/phase_2c3_inventory_ledger.sql` — passed. It covers the six roles, inactive users, site isolation, guessed identifiers, ledger shape, idempotency, duplicate opening, insufficient stock, cross-godown rejection, direct writes, deactivation, audit rows, and ledger-to-balance reconciliation.

`npx supabase db reset --local`, `npx supabase db lint --local`, and `npx supabase db advisors --local` passed after the replay-after-lock change. Lint had previously warned that the list functions were marked stable while calling a volatile permission check. They are volatile now.

Overlapping database sessions, started from separate `psql` processes:

- Two transfers drawing the same balance. Passed. The source finished at 1, with no negative balance.
- Two opening posts with the same idempotency key. Passed. The quantity stayed 1.
- Two distinct opening posts for one crate and product. Passed. Exactly one transaction remained.
- Opening stock posted against deactivation of an empty crate. Passed. The post was blocked, the crate ended inactive, and it held no positive stock.
- An in-flight partial transfer against deactivation of the still-stocked source. Passed. Deactivation was rejected, the source stayed active, and its remaining quantity was unchanged.
- An in-flight transfer that emptied the source against deactivation of that crate. Passed. The crate ended inactive with no positive balance, and the destination held the full quantity.
- A transfer into a crate whose deactivation was already in flight. Passed. The transfer was rejected, the crate stayed inactive, and it received no stock.

Application checks:

- `npm run typecheck` passed.
- `npm run lint` passed. oxlint still reports `react(incompatible-library)` on React Hook Form in `ProductsPage.tsx:294`, `OpeningStockPage.tsx:38`, and `TransfersPage.tsx:44`.
- `npm test` passed: 8 files, 21 tests.
- `npm run build` passed. The JavaScript chunk is about 984 kB, above Vite's 500 kB notice. CSS is about 84 kB.

Browser checks used a second Vite process on port 5175 against local Supabase. Port 5174 was already taken. The development app on port 5173 was left pointed at the cloud project. Disposable local users were removed afterward.

- Admin posted opening stock `OS-20261015-000011` for 12 carton cases into crate `lc1`. The overview showed that balance. History showed the opening row.
- Admin transferred 4 cases from `lc1` to `lc2` in the same godown. The destination list offered only the other crate in that godown. The reference was `TR-20261015-000012`.
- Godown Manager saw Inventory, Transfers, and History, and did not see Opening stock. `/inventory/opening` showed access denied. The form showed a source balance of 8. A transfer of 2 posted as `TR-20261015-000013`.
- Accounts saw Inventory and History only, including both balances of 6. Searching for a missing SKU showed the empty state. `/inventory/opening` and `/inventory/transfers` showed access denied. The godown filter listed only the assigned godown.
- Store Keeper saw the same read-only navigation and the balances. Opening stock and transfers showed access denied.
- Salesperson had no inventory navigation. `/inventory` showed access denied.
- At 390px the sidebar was hidden, the menu button was present, the search and godown filter stacked, and the balance table scrolled horizontally.

Delivery Person was denied in the SQL suite and was not signed in during the browser pass.

Before cleanup, the reconciliation query reported 0 mismatches and 0 negatives. The ledger total was 12, matching balances of 6 in `lc1` and 6 in `lc2`. Cleanup disabled the append-only triggers, deleted the disposable stock, audit, site, product, and Auth rows, and re-enabled the triggers. They were confirmed enabled, and those rows were gone.

Reference numbers in the browser pass started above 1 because the sequence is not rolled back with the SQL tests. That does not duplicate stock.

## Development-cloud verification

`npx supabase db push --linked` applied only `20261015180000`. Remote migration history is `20261014000000`, `20261014150000`, `20261014180000`, `20261014190000`, `20261014210000`, `20261015120000`, and `20261015180000`.

The three stock tables, `post_opening_stock`, `post_crate_transfer`, `list_stock_balances`, and `list_stock_transactions` are present. Crate and zone deactivation still reject a positive balance. Append-only triggers remain enabled. Authenticated clients can select stock rows only through the stock-read policies. Direct inserts into the ledger and balances were denied with a user JWT.

Stock grants on the development project match the matrix above. Existing adjustment grants were not widened. Salesperson and Delivery Person have no stock grants. Master-data grants were not changed by this migration. `shops.develop` was already present before the push.

Cloud security verification passed 26 cases with real JWTs for disposable users. Denials were committed HTTP calls and left no stock. The successful opening, same-godown transfer, isolation, idempotency, deactivation, and reconciliation assertions ran in one database statement that ended by raising, so PostgreSQL rolled the stock back. The statement confirmed:

- one opening remained for the retried product and crate
- a conflicting idempotency key and a second opening were rejected
- Admin and Godown Manager same-godown transfers left 4 at the source and 6 at the destination after an opening of 10
- cross-godown transfers were rejected for both roles
- an insufficient transfer was rejected and no negative balance existed
- a stocked crate and its zone could not be deactivated
- posting into an inactive crate was rejected
- an inactive user could not post
- Accounts and Store Keeper saw no rows until assigned, then saw only the assigned godown
- Salesperson could not read stock
- transfer ledger entries netted to zero
- ledger sums matched balances
- posting wrote audit rows

After that rollback, and again after fixture cleanup, the development database had 0 stock rows, 0 mismatches, 0 negatives, 0 duplicate openings, a transfer net of 0, and no stock in an inactive crate.

Browser checks used the existing Vite process on port 5173, whose Supabase host is `ypkfondrkhkydkgovwup`. The local app on port 5175 was not used. The posting confirmation was opened and cancelled. No browser action called `post_opening_stock` or `post_crate_transfer`. Deactivating empty disposable crate `ca3` succeeded; a stocked-crate denial was not exercised in the browser.

Cleanup removed the seven disposable Auth users, their roles and assignments, the two test godowns, their zones and crates, the two test products, and audit rows for those actors. One Auth user and `godown_main` remain. The password file for the disposable users was deleted.

## Remaining decisions

These are not approved by this phase:

- Whether category is mandatory on a product.
- Whether supplier is mandatory on a product.
- Shop-to-godown ownership.
- Cross-godown salesperson assignment.
- Salesperson authority to assign or revoke other salespersons.
- A safe owner for a newly created shop.
- Crate capacity.
- Moving a zone or crate, or changing its parent, after stock exists. Parent moves stay blocked. Deactivation with stock is now blocked.
- Informational pieces per carton.
- Product pricing and valuation.
- Batch, expiry, and serial tracking.
- Delivery Person transit-damage authorization.
- The exceptional adjustment threshold. 50 remains a provisional placeholder.
- An INR exceptional-adjustment threshold.
- Cross-godown stock transfers. They are prohibited, not approved for later implementation.
- Opening-stock correction and generic balance adjustments. They are not implemented. One opening per product and crate is a provisional safety constraint.
- A default godown for Accounts or Store Keeper. None is assigned until an administrator uses the existing site-assignment function.
