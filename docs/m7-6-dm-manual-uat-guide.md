# M7.6-DM — Manual UAT guide

Use **local** Playwright mode, not cloud 5173.

```text
App:  npm run dev -- --mode m1s2 --host 127.0.0.1 --port 4173
API:  http://127.0.0.1:54321
Nav:  Operations → Damage
```

Do **not** sign in as `jeffinpappachan110@gmail.com` for operational damage writes.

Do **not** flip `damage.stock_hold_ready`, lot dual-write, aggregate-only-blocked, or `SHORT_SHIPMENT_OPERATIONAL`.

Do **not** verify, write off, quarantine, or close any real owner damage (local count is currently 0).

Do **not** treat a passing click as production cutover.

---

## 0. Test-data reality check

Local Docker **does not** currently have persistent named employees:

| Needed role | Local persistent account | Result |
|---|---|---|
| Test Storekeeper | Missing | Must create a disposable Store Keeper **or** use Playwright disposable emails from `tests/e2e/damage*.spec.ts` |
| Test Godown Manager | Missing | Same |
| Test Delivery Person | Missing | Same |
| Accounts | Missing (only leftover M82* emails) | `/damage` is denied by design |
| Admin | `admin.m1s2qa@example.com` | Oversight only |
| Owner | `jeffinpappachan110@gmail.com` | Do not use |

Local masters: 87 active products (AVT* SKUs exist). Active godowns/crates are leftover M7.2/M8.2 disposable names, not a clean Godown-1. `suppliers = 0`. `damage_reports = 0`. `product_selling_prices = 0`.

### Suggested disposable quantities (when a source document exists)

| Scenario | Product | Quantity | Who |
|---|---|---|---|
| Receiving | Any receipt SKU (client “Product A”) | 2 cases | Store Keeper |
| Warehouse | Crate SKU (client “Product B”) | 3 cases | Godown Manager — **draft only** |
| Loading | Packed SKU | 1 case | Store Keeper — **draft only** |
| Transit | Loaded SKU | 1 case | Delivery Person |
| Hold / Inspection | Existing test damage | No posting | Confirm banner + blocked submit |
| Supplier Return / Write-off | Disposable verified+held fixture | Gated | SQL/HTTP already proved; skip live post |

If there is **no posted receipt** or **no assigned consumed dispatch**, the create form cannot select a source. Set those documents up in a disposable local flow first, or rely on Playwright e2e which seeds its own receipt/dispatch.

Recommended first login for a human pass: **disposable Store Keeper** on 4173, then Godown Manager, then Delivery Person.

---

## 1. Store Keeper — Receiving Damage

Operations → Damage

1. Sign in as the disposable Test Storekeeper.
2. Confirm the amber banner **Damage stock isolation not ready**.
3. Open **New report**.
4. Select scenario **Unloading** or **Refill supply**. Under the title you should see **Receiving / Stock-In Damage**.
5. **Storage** and **Shop return** should show **Not permitted for this account**.
6. Choose an authorized godown and a posted stock-in / receipt.
7. Add a line. SKU and product name fill from the receipt line. Enter **2** damaged cases. Pick **Leakage** from the Damage reason suggestions (or type it).
8. Upload at least one JPEG/PNG/WebP under 10 MB. Finalize it. You may add another photo by choosing a file again.
9. Save draft, then Submit.

Expected result

- Report number assigned. Status **Draft** then **Submitted**. Client workflow **Open**.
- Stock on the receipt’s accepted quantity does not change.
- Verify / Write-off / Exceptional controls are absent.
- Direct URL `/damage/verification` is denied.

Negative checks

- Quantity `0`, `-1`, or `1.5` cannot save.
- Damaged cases above remaining receipt damaged cases fail with a quantity error.
- Double-click Save does not create two report numbers.

---

## 2. Store Keeper — Warehouse Damage

Operations → Damage → New report

1. Still signed in as Store Keeper.
2. Look at **Storage**.

Expected result

- Storage is disabled: **Not permitted for this account**.
- This is current architecture (CD-01), not a broken button. Warehouse recording for UAT is section 5 (Godown Manager), **draft only**, because submit is gated.

---

## 3. Loading Assistant — Loading Damage

There is no Loading Assistant role. Use Store Keeper (`loading.assist`).

Operations → Damage → New report

1. Select **Loading**. Subtitle **Loading Damage**.
2. Pick an eligible packing/allocation source if one exists.
3. Enter **1** damaged case. Save draft. Attempt Submit.

Expected result

- Draft can save.
- Submit is **blocked** while isolation is not ready. Read the banner and the submit error. Stock and packing reservations must not change.
- Do not enable short-shipment to force a pass.

If no packing allocation exists, record **setup missing** and stop. Do not post fake stock.

---

## 4. Delivery Person — Transit Damage

Operations → Damage

1. Sign in as the disposable Delivery Person.
2. Open **New report**. **Transit** is available. Storage is not.
3. Select the assigned consumed dispatch only.
4. Enter **1** damaged case. Reason **Transit Damage** or **Crushed**.
5. Attach evidence. Submit.

Expected result

- Status **Submitted**, client workflow **Open**. Linked dispatch/order visible on detail.
- Another dispatch (not assigned) is refused.
- `/damage/quarantine` and `/damage/verification` show **You do not have access to this page**.
- Goods are not marked delivered by this report.
- Undamaged cases are not a stored field; do not fail UAT for a missing undamaged column.

---

## 5. Godown Manager — Verification

Operations → Damage → Verification queue  
or open the submitted report from **All reports**.

1. Sign in as a **different** Godown Manager than the reporter (self-verify is blocked).
2. Open a **Submitted** receiving or transit report.
3. Confirm header **Client category** and **Client workflow = Open**.
4. If evidence is missing, **Verify** stays blocked: **Finalized photographic evidence is required.**
5. Verify.

Expected result

- Status **Verified**. Client workflow **Verified**. `verified by` / timestamp set.
- Activity timeline records the decision.
- Inventory ledger does **not** drop by the damaged cases.
- Verify again is blocked.

Store Keeper and Delivery Person must not see the Verify button.

---

## 6. Godown Manager — Disposition and Closure

Operations → Damage → report detail

1. On a **Verified** inbound/transit report with **no holds**, inspect Write-off / Exceptional panels.

Expected result

- Ordinary write-off requires remaining isolated holds. With the flag false, inbound/transit never created holds. The UI should explain the blocker, not post stock.
- Exceptional **Return to supplier** / **Destroy** need Admin approval and holds. Do not approve live owner data (there is none). Do not run posting on leftover HTTP fixtures unless they are clearly disposable and you accept they are test leftovers.
- There is no **Closed** header status. Do not try to close the record as Excel Closed.
- **Repacking** and **Inspection** are not in the product. Record as missing (CD-08).
- Cancel/reject paths: reject needs a reason; rejected reports stay traceable.

Warehouse **Storage** draft (optional):

1. New report → **Storage** → Warehouse Damage.
2. Godown → crate → SKU. Quantity **3**. Save.
3. Submit.

Expected result: submit **fails closed**. On-hand crate quantity unchanged.

---

## 7. Accounts — Damage Value and Reporting

1. Sign in as Accounts (if a disposable Accounts user exists).
2. Open `/damage`.

Expected result

- **You do not have access to this page.**
- No Damage Value = cases × cost. No cost master. Do not treat this as a failed calculation; it is not implemented (CD-02, CD-07).

Admin or Godown Manager reporting instead:

Operations → Damage dashboard and **All reports**.

- Filter godown, scenario, status, dates, report number.
- Totals are **cases**, not rupees.
- Open ≈ submitted/draft/returned; Verified ≈ verified count. Closed is not a dashboard status.

---

## 8. Admin — Audit and Stock Reconciliation

1. Sign in as `admin.m1s2qa@example.com` (or a disposable Admin).
2. Operations → Damage. Dashboard loads (monitor). **New report** should not create ordinary operational reports.
3. Open **Exceptional approvals** (Admin dispose). Do not approve production-like leftover requests unless they are known disposable prefixes (`m54e`, `m54c`, `m54a`, `m82*`).
4. Open a report **Activity** / verification history.
5. Confirm settings/flags still:

```text
damage.stock_hold_ready=false
stock.lots.dual_write_enabled=false
stock.lots.aggregate_only_blocked=false
```

6. Confirm stock screens (Inventory / History) were not changed by a damage verify.

Expected result: oversight without operational posting; gates still on.

---

## Role matrix (what to tick)

| Role | Ready now | Blocked / gated |
|---|---|---|
| Store Keeper receiving | Yes | Vehicle/driver fields |
| Store Keeper warehouse | No (permission) | CD-01 |
| Store Keeper loading | Draft only | Submit gated |
| Delivery Person transit | Yes | Invoice number, undamaged column |
| Godown Manager verify inbound/transit | Yes | Self-verify |
| Godown Manager warehouse submit | No | Isolation flag |
| Godown Manager write-off / return | No on live data | Needs holds |
| Accounts value/report | No | No damage permission, no cost |
| Admin audit | Yes | Must not flip flags |

---

## Stop conditions

Stop and call owner review if:

- Any Open report reduces stock.
- Verify posts a stock transaction.
- A Store Keeper or Delivery Person can Verify or Write-off.
- Isolation submit **succeeds** while the flag is false.
- Dual-write or legal-issuance flags turn on.
- Existing owner rows are deleted or rewritten (local damage count should stay 0 unless you created disposable reports you own).
