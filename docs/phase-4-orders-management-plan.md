# Phase 4 orders management

PHASE 4.1A–4.1D: LOCAL READY. PHASE 4.1C — AVAILABILITY RULE A APPROVED. PHASE 4.1E — DEVELOPMENT DEPLOYED AND VERIFIED on `ypkfondrkhkydkgovwup`. Production not deployed. Committed on `main` at `9bcbcbb8eca6c44c9ce4d7f1316e291db4e3c681`.

**Phase 4.2A — LOCAL COMPLETE.** Schema/RLS/read RPCs in `20261018120000_delivery_notes.sql`.  
**Phase 4.2B — LOCAL COMPLETE.** Mutations/print/cancel guard in `20261018130000_delivery_note_mutations.sql` plus Accounts UI.  
**Phase 4.2C — LOCAL IMPLEMENTATION ONLY.** Send/acknowledge in `20261018140000_delivery_note_handover.sql` plus Accounts Send and Godown Manager inbox. Cloud unchanged. Plan: `docs/phase-4-2-delivery-note-plan.md`.

Migration `supabase/migrations/20261017120000_shop_orders.sql` holds Phase 4.1A–4.1C in one file and is applied on development. Availability Rule A is approved.

The Phase 4.1 implementation contract is `docs/phase-4-1-implementation-spec.md`. This file records approved Phase 4 decisions and the BPM boundary. It does not authorize Phase 4.2 code, migrations, or deployment.

## Approved decisions (Phase 4.1)

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

- ORD-01 and ORD-02 are Phase 4.1 (deployed on development).
- ORD-03 and ORD-04 are Phase 4.2 (4.2A–4.2C local: create/generate/void/print/send/acknowledge; 4.2D QA / 4.2E cloud remain).
- ORD-05 through ORD-09 remain later dependencies (picking, vehicle/delivery assignment, invoice note, final invoice, shop delivery).
- The document sequence remains delivery note, then invoice note, then signed invoice.
- Phase 4.1 does not create those documents. Phase 4.2 plans the delivery note only; it does not invent unapproved picking or invoicing rules.

## Phase 4.2 approved decisions

Documented in `docs/phase-4-2-delivery-note-plan.md`:

1. At most one non-voided delivery note per verified order.
2. `delivery_notes.acknowledge` granted only to Godown Manager (create/generate/send/void remain Accounts via `delivery_notes.issue`).
3. Creation begins in persisted `draft`; explicit later `generate_delivery_note` → `generated` → `sent` → `acknowledged`.
4. Cancellation: active DN must be voided before cancel; acknowledged DN blocks cancel and cannot be voided; no silent auto-void. Forward-only `cancel_order` guard is a blocking prerequisite for 4.2B/4.2C.
5. Official printing requires configured company identity; no fictional placeholders.
6. Order status machine unchanged (`verified` / `cancelled`); no inventory reservation or deduction in 4.2.

## Readiness

- Phase 4.1: DEVELOPMENT DEPLOYED AND VERIFIED; Availability Rule A approved.
- Phase 4.2A–4.2C: LOCAL COMPLETE. Phase 4.2D: LOCAL QA COMPLETE — READY FOR DEVELOPMENT DEPLOYMENT (4.2E authorization pending).
