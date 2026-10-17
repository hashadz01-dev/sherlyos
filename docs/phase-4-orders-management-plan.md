# Phase 4 orders management

PHASE 4.1A–4.1D: LOCAL READY. PHASE 4.1C — AVAILABILITY RULE A APPROVED. PHASE 4.1E — DEVELOPMENT DEPLOYED AND VERIFIED on `ypkfondrkhkydkgovwup`. Production not deployed. Cloud fixtures retained. Adjustment-versus-verify race unverified. Git checkpoint pending.

Migration `supabase/migrations/20261017120000_shop_orders.sql` holds Phase 4.1A–4.1C in one file (tables, grants, read RPCs, capture/edit, submit/hold/verify/cancel) and is applied on development. Availability Rule A is approved.

The implementation-ready specification is `docs/phase-4-1-implementation-spec.md`. This file records the approved decisions and the BPM boundary. It does not authorize code, migrations, or deployment.

Repository `main` at `af754f9a9ec463e4f343cbb85994be968c7b851e`. Development Supabase `ypkfondrkhkydkgovwup` ends at `20261016200000_stock_adjustment_approval.sql`.

## Approved decisions

1. Phase 4.1 is order capture, submission, Accounts verification, hold, correction, and cancellation.
2. Verification checks current availability and does not reserve or deduct inventory.
3. Each order has an authorized fulfilling godown.
4. Accounts can view all active shops.
5. Accounts and Salesperson can read the active product catalog. `stock.read` is not expanded.
6. Accounts may verify an order they created.
7. Telecalling and enquiry are order-source values, with an optional reference and notes.
8. The original creator may cancel a draft or held order. Accounts may cancel a submitted or verified order, and that reason is mandatory.
9. Short picks and partial fulfilment wait for the picking and delivery phase.
10. Batch and expiry tracking must exist before expiry-aware picking is released.
11. Phase 4.1 is quantity-only. No prices, discounts, taxes, or invoice totals.
12. Delivery failure belongs to a future delivery-outcome workflow. Damaged or returned stock belongs to separate workflows.

## BPM boundary

Confirmed in `reference/Sherlys_Distribution_Agents_BPM.pdf` v1.0:

- ORD-01 and ORD-02 are Phase 4.1.
- ORD-03 through ORD-09 are future dependencies.
- The later document sequence remains delivery note, then invoice note, then signed invoice.
- Phase 4.1 does not create those documents.

## Readiness

Availability Rule A is approved: shortfall rejects verification, leaves the order `submitted`, and does not auto-hold. Phase 4.1C local implementation follows that rule.
