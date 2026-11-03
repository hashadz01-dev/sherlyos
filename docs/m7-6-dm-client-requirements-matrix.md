# M7.6-DM — Client requirements matrix

Baseline: Sherlys Distributors and Agents — Pipeline 2 Damage Management — Excel System User Manual & Operating Guide — Version 1.0 — 23 September 2026.

Implemented values: **Yes** / **Partial** / **No**. Gated operational work is Partial with severity GATED, not Yes.

Evidence is code or local database unless noted. Automated tests are the suites actually executed in this audit.

---

## A. Categories and navigation

| Requirement ID | Client requirement | Implemented | Actual evidence | Automated test | Manual UAT required | Severity | Recommended action |
|---|---|---|---|---|---|---|---|
| CR-01 | Three user-facing categories: Receiving, Warehouse, Transit | Partial | Six internal scenarios. UI now shows client category via `formatClientDamageCategory`. Loading remains extra. | `tests/unit/damage.test.ts` mapping | Yes — confirm staff understand extra Loading card | P2 | Keep six codes. Do not collapse DB statuses. |
| CR-02 | Loading may exist internally but three client categories stay understandable | Yes | Scenario picker subtitle + reports list | unit + e2e reporting | Yes | — | None |
| CR-03 | Operations → Damage is the entry | Yes | `src/app/navigation.ts` label `Damage`, route `/damage` | `tests/e2e/damage.spec.ts` | Yes | — | Use this path in UAT, not guessed Excel tab names |

---

## B. Common fields

| Requirement ID | Client requirement | Implemented | Actual evidence | Automated test | Manual UAT required | Severity | Recommended action |
|---|---|---|---|---|---|---|---|
| CR-10 | Damage ID | Yes | `report_number` unique | SQL unique + e2e list | Yes | — | — |
| CR-11 | Damage identification date | Partial | `created_at` / `submitted_at`. No separate “identified on” field | list date filters e2e | Optional | P2 | Use created date unless owner wants a new column |
| CR-12 | Damage source | Yes | Scenario + source document picker | e2e reporting source picker | Yes | — | — |
| CR-13 | Godown | Yes | `godown_id` required | SQL + e2e | Yes | — | — |
| CR-14 | Zone and crate where applicable | Partial | Storage/loading/shop-return require crate. Zone via crate join on quarantine list | SQL 4c, e2e custody | Yes for warehouse/loading drafts | P2 | — |
| CR-15 | SKU and auto-populated product details | Yes | Catalogs fill SKU/name | e2e reporting | Yes | — | — |
| CR-16 | Damaged cases | Yes | Integer ≥ 1 | CHECK + `parseCartonQuantity` | Yes — try 0, -1, 1.5 | — | — |
| CR-17 | Cost per case | No | No product cost column | none | No until CLIENT DECISION | CLIENT DECISION | Do not invent live costs |
| CR-18 | Damage value | No | Formula not stored or displayed | none | No | CLIENT DECISION | Same |
| CR-19 | Damage type | Partial | Free-text `damage_reason` 1–80 with client classification datalist | unit classifications | Yes — pick Leakage etc. | P2 | Not a constrained enum |
| CR-20 | Damage description | Partial | Line `notes` 1–500 and header `notes` | SQL checks | Optional | P2 | — |
| CR-21 | Action required | Partial | Client list is Hold / Supplier Return / Write-off / Repacking / Inspection / Other. Software has hold (gated), exceptional return/destroy, ordinary write-off. No Repacking/Inspection/Other | HTTP 4e | Disposition UAT only if holds exist (gated) | GATED / CLIENT DECISION | Do not add new kinds without owner |
| CR-22 | Recorded by | Yes | `reporter_user_id` / `reporter_name` | SQL 4d payload | Yes | — | — |
| CR-23 | Verified by | Yes | `verifier_user_id`, `verified_at` | SQL 4d | Yes | — | — |
| CR-24 | Status Open / Verified / Closed | Partial | Mapped Open/Verified in UI. Closed is not a header status | unit `clientWorkflowStatus` | Yes — explain Closed | CLIENT DECISION | Keep internal state machine |
| CR-25 | Stock deduction readiness | Yes | Banner + `damage.stock_hold_ready=false` | HTTP 4f, e2e reporting | Yes — read the amber banner | GATED | Do not flip the flag |
| CR-26 | Photo evidence | Partial | Private bucket, JPEG/PNG/WebP, 10 MB, multiple rows, repeatable single-file picker. UI submit requires photo; RPC submit does not; verify does | HTTP 4b, e2e reporting | Yes | P2 | Multi-select control is a gap, not a fake upload |

---

## C. Classifications and dispositions

| Requirement ID | Client requirement | Implemented | Actual evidence | Automated test | Manual UAT required | Severity | Recommended action |
|---|---|---|---|---|---|---|---|
| CR-30 | Types: Leakage, Box/Packaging, Crushed, Torn, Moisture, Handling, Breakage, Contamination, Transit Damage, Other | Partial | Datalist suggestions. User may still type other text | unit array | Yes | P2 | Enum only if owner wants hard constraint |
| CR-31 | Dispositions: Supplier Return, Hold, Write-off, Repacking, Inspection, Other | Partial | Hold + write-off + supplier return exist. Repacking, Inspection, Other missing | HTTP 4e | Gated posting | GATED / MISSING | Owner policy |

---

## D. Status and stock eligibility

| Requirement ID | Client requirement | Implemented | Actual evidence | Automated test | Manual UAT required | Severity | Recommended action |
|---|---|---|---|---|---|---|---|
| CR-40 | Open must not become eligible for deduction | Yes | Draft/submitted inbound does not post. Isolation submit fails while flag false | HTTP 4f, SQL 4d verify-no-stock | Yes | — | — |
| CR-41 | Verified/Closed = eligible for approved adjustment, not already deducted | Yes | `verify_damage_report` inserts 0 `stock_transactions`. Write-off is a later RPC | SQL 4d | Yes — verify then confirm stock unchanged | — | — |
| CR-42 | Do not force only three DB statuses | Yes | Six statuses retained; UI maps | unit | Yes | — | — |

---

## E. Scenario-specific

| Requirement ID | Client requirement | Implemented | Actual evidence | Automated test | Manual UAT required | Severity | Recommended action |
|---|---|---|---|---|---|---|---|
| CR-50 | Receiving links Stock-In, supplier, vehicle, driver, godown, SKU, received vs damaged | Partial | Receipt + supplier on receipt. No vehicle/driver on `stock_receipts` | SQL M5.2 | Yes receiving; skip vehicle/driver | P2 gap | Do not invent |
| CR-51 | Damaged cases ≤ received remaining | Yes | `23514` exceeds receipt line | SQL M5.2 | Yes | — | — |
| CR-52 | Warehouse Godown → Zone → Crate → SKU | Partial | Create path exists for GM. Submit gated | e2e storage draft | Draft only | GATED | — |
| CR-53 | One crate one SKU | No | `stock_balances` PK `(crate_id, product_id)` | phase_2c3 allows multiple SKUs | No | CLIENT DECISION | Do not add unique SKU constraint without owner |
| CR-54 | Crate max 50 cases | No | No crate capacity. Vehicle `capacity_cases` only | none | No | CLIENT DECISION | — |
| CR-55 | Current cases from stock, not user | Yes | Catalogs `on_hand_cases` / balances | SQL isolation | Yes on draft | — | — |
| CR-56 | Loading distinguishable from warehouse | Yes | Scenario `loading` | e2e + SQL | Draft only | GATED submit | — |
| CR-57 | Loading not counted as successfully loaded | Yes while gated | Submit never posts | HTTP 4f | Confirm blocked submit | GATED | Do not enable short-shipment |
| CR-58 | Transit links order, invoice, customer, route, vehicle, delivery person, loaded/damaged/undamaged | Partial | Dispatch/order/shop/assignee. No invoice number on damage header. Undamaged is not a stored column | e2e transit draft | Yes transit | P2 | Calculate undamaged off loaded − damaged if needed in a later report |
| CR-59 | Transit does not count as delivered | Yes | Separate from delivery complete / returns | delivery-return architecture untouched | Yes | — | Do not backfill lots |

---

## F. Roles

| Requirement ID | Client requirement | Implemented | Actual evidence | Automated test | Manual UAT required | Severity | Recommended action |
|---|---|---|---|---|---|---|---|
| CR-70 | Store Keeper records receiving and warehouse | Partial | SK records receiving (and loading/transit). Warehouse storage requires `damage.verify` → GM | e2e reporting SK inbound; storage picker disabled for driver; SK has no storage in `scenariosAvailableForPermissions` | SK receiving yes; SK warehouse no | CLIENT DECISION | UAT warehouse as GM unless owner grants SK storage create |
| CR-71 | Loading Assistant records loading | Partial | No such role. SK `loading.assist` | SQL create auth | SK loading draft | P2 | Document as Store Keeper |
| CR-72 | Delivery person records transit for assignments | Yes | Assignment-only `can_complete_consumed_delivery_at_branch` | HTTP 4b/M5.2, e2e | Yes | — | — |
| CR-73 | Godown Manager verifies | Yes | `damage.verify` | HTTP 4d, e2e verification | Yes inbound/transit | — | Cannot self-verify |
| CR-74 | Accounts sees financial summaries, not physical stock ops | No | Accounts has no `damage.*`. e2e access denied | `damage.spec.ts` accounts denied | No on `/damage` | CLIENT DECISION | Grant `damage.read` only with owner approval |
| CR-75 | Admin oversight still respects gates | Yes | Admin cannot create ordinary reports; dispose is approval-only | HTTP 4e | Optional | — | — |

---

## G. Integrity

| Requirement ID | Client requirement | Implemented | Actual evidence | Automated test | Manual UAT required | Severity | Recommended action |
|---|---|---|---|---|---|---|---|
| CR-80 | Duplicate submissions cannot double-adjust | Yes | Unique keys + completed replay identification | HTTP 4d/4e, concurrency | Optional | — | — |
| CR-81 | Concurrent verify/post | Yes | Serialized exact-once | concurrency 4d/4e | No (automated) | — | — |
| CR-82 | Unauthorized status transitions | Yes | Verify only submitted; re-verify denied | SQL 4d | Yes | — | — |
| CR-83 | Historical records not silently rewritten | Yes | Events append; posting identification-only | HTTP 4e replay | Optional | — | — |
| CR-84 | Damage value does not change when current cost changes | No | No snapshot | none | No | CLIENT DECISION | — |

---

## Counts

| Status | Count |
|---|---|
| Fully implemented (Yes) | 25 |
| Partially implemented | 15 |
| Missing / No | 6 |
| Gated (called out inside Partial) | Hold, isolation submit, write-off posting, supplier-return posting |
