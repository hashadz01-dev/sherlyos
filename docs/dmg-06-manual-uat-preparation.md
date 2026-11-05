# DMG-06 — Shop Return Damage manual UAT preparation

**Verdict: READY FOR BROWSER UAT — do not create the report until you choose to start it**

The accepted workflow is the deployed one. The Salesperson creates and submits. The Godown Manager confirms custody on the submitted report, then verifies it. Verification posts the quarantine intake. The Store Keeper is unchanged.

Do not apply `docs/rejected-migrations/20261105140000_shop_return_store_keeper_report.sql`. Do not create a new user.

---

## 1. Fixture status (created)

| Field | Value |
|-------|--------|
| Product | `TEST-DMG06-ONLY` (`5f1c1730-fc91-4be0-bc3f-92cbc925184c`) |
| Lot | `TEST-LOT-DMG06` (`ddc2aace-6102-429e-94e6-aa4b9ae16075`) |
| Opening | `OS-20261103-000057` — **2** cases @ Godown-1 / `uat_c1` |
| Aggregate = lot | **2 = 2** |
| Shop source | **SHOPPE FRESH** (active; selectable in transit-style shop picker for `shop_return`) |
| Product selectable | **Yes** (`list_damage_report_sources` shop_return catalog) |
| Order / dispatch / delivery return | **None** |
| Shop-return damage reports | **0** |

### Baselines after fixture (unchanged except TEST-DMG06)

| SKU | Qty |
|-----|-----|
| AVT-CATER-BLEND-1KG | 17 |
| GOODLIFE-MILK-500ML | 18 |
| TEST-DMG03M-ONLY | 2 |
| TEST-DMG04-ONLY | 3 |
| TEST-DMG05-ONLY | 1 |
| TEST-DMG06-ONLY | **2** |

Script: `scripts/dmg06/prepare-shop-return-fixture-cloud.mjs`.

---

## 2. Live cloud workflow — do not execute

The applied cloud comments define this sequence:

1. Salesperson, with `damage.shop_return.record` and an active shop assignment, creates and submits the report.
2. Submit does not post stock.
3. Godown Manager confirms custody only after status is `submitted`. Custody posts no stock.
4. A different user with `damage.verify` verifies. Verification posts one quarantine intake. The reporter cannot verify.

The Store Keeper is not a step in that sequence. The local screen now offers Shop return to `damage.shop_return.record` without `damage.verify`. Shop choices come from `list_damage_report_sources`, which returns only assigned shops for that permission. Receiving godowns come from `list_shop_return_receive_godowns`.

## 3. Stock effect on the development database

For a later 1-case report, submit and custody leave saleable stock at 2 and quarantine at 0. Verification adds 1 quarantine case and 1 hold. Saleable stock stays 2. This differs from the older local submit-time intake.

---

## 4. Browser UAT — start only when you intend to create the report

App: `http://127.0.0.1:5173`. Use the existing accounts. Do not create a user.

1. Sign in as Test Salesperson. Open **Damage**. **New report** must be available. Shop return is the only scenario. Store Keeper, Delivery Person, and Admin still do not get that scenario from their own permissions.
2. Godown: **Godown-1**. The list comes from `list_shop_return_receive_godowns`.
3. Scenario: **Shop return**.
4. Search the shop list for **SHOPPE FRESH** and select it. The list is the salesperson's assigned shops, not every shop in the company.
5. Product: `TEST-DMG06-ONLY`. Quantity **1**. Save the draft. Attach and finalize one photo. **Review and submit**.
6. Expect status **Submitted**. Saleable `uat_c1` stays **2**. Quarantine stays **0**. The Salesperson must not see **Confirm physical custody**, verification, or disposition actions.
7. Sign out. Sign in as Test Godownmanager. Open the submitted report. **Shop-return custody** shows **Confirm physical custody**. Confirm it. Stock is still unchanged.
8. On **Godown verification**, verify. The Godown Manager is not the reporter. Expect status **Verified**.
9. Expect `QRN-01` **+1**, one active quarantine hold, saleable stock still **2**, and available-to-pick still **2**. A second verify must not post again.

