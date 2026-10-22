import { describe, expect, it } from "vitest"
import { navigationItems } from "@/app/navigation"
import { LotReconciliationRpcError } from "@/lib/lot-reconciliation/api"
import {
  actorLabel,
  canSubmitFromSummary,
  cratesBelongToGodown,
  createSessionIssues,
  emptyLotDraft,
  eventLabel,
  isStaleVersionError,
  lineCountState,
  lotBreakdownState,
  lotEntryIssues,
  lotReconciliationActions,
  lotsToRpc,
  reconciliationErrorMessage,
  sessionListAction,
  submitSummary,
  unknownIdentityDraft,
} from "@/lib/lot-reconciliation/rules"
import { parseCaseCount } from "@/lib/verification/rules"

describe("lot reconciliation rules", () => {
  it("requires a godown and at least one unique crate", () => {
    expect(createSessionIssues({ godownId: "", crateIds: [] })).toEqual([
      "Select a godown.",
      "Select at least one crate.",
    ])
    expect(createSessionIssues({ godownId: "g1", crateIds: ["c1", "c1"] })).toEqual([
      "Remove duplicate crate selections.",
    ])
  })

  it("rejects crates that belong to another godown", () => {
    expect(
      cratesBelongToGodown({
        crateIds: ["crate-a", "crate-b"],
        crates: [
          { id: "crate-a", zone_id: "zone-a" },
          { id: "crate-b", zone_id: "zone-b" },
        ],
        zones: [
          { id: "zone-a", branch_id: "godown-a" },
          { id: "zone-b", branch_id: "godown-b" },
        ],
        godownId: "godown-a",
      }),
    ).toBe(false)
    expect(
      cratesBelongToGodown({
        crateIds: ["crate-a"],
        crates: [{ id: "crate-a", zone_id: "zone-a" }],
        zones: [{ id: "zone-a", branch_id: "godown-a" }],
        godownId: "godown-a",
      }),
    ).toBe(true)
  })

  it("accepts whole carton counts and rejects decimals", () => {
    expect(parseCaseCount("0")).toEqual({ ok: true, cases: 0 })
    expect(parseCaseCount("12")).toEqual({ ok: true, cases: 12 })
    expect(parseCaseCount("1.5").ok).toBe(false)
    expect(parseCaseCount("-1").ok).toBe(false)
  })

  it("classifies counted lines without treating missing as zero", () => {
    expect(lineCountState(4, null)).toBe("not_counted")
    expect(lineCountState(4, 4)).toBe("matched")
    expect(lineCountState(4, 2)).toBe("shortage")
    expect(lineCountState(4, 5)).toBe("excess")
  })

  it("requires lot quantities to equal counted cases", () => {
    expect(lotBreakdownState(null, [])).toBe("waiting")
    expect(lotBreakdownState(0, [])).toBe("complete")
    expect(lotBreakdownState(4, [])).toBe("missing")
    expect(lotBreakdownState(4, [{ quantity: 3 }])).toBe("invalid")
    expect(lotBreakdownState(4, [{ quantity: 2 }, { quantity: 2 }])).toBe("complete")
  })

  it("keeps unknown identity without a fabricated batch or expiry", () => {
    const unknown = unknownIdentityDraft("4")
    expect(lotEntryIssues(unknown, "expiry_controlled")).toEqual([])
    expect(lotsToRpc([unknown])[0]).toMatchObject({
      manufacturer_lot_code: null,
      expiry_date: null,
      identity_unknown: true,
      expiry_unknown: true,
      quantity: 4,
    })
    expect(
      lotEntryIssues({ ...unknown, manufacturer_lot_code: "FAKE-1" }, "expiry_controlled"),
    ).toContain("Unknown identity cannot include a manufacturer lot code.")
  })

  it("does not invent a manufacturer code on an empty identified lot", () => {
    expect(lotEntryIssues(emptyLotDraft(), "expiry_controlled")).toContain(
      "Enter a manufacturer lot code, or mark identity as unknown.",
    )
    expect(lotsToRpc([{ ...emptyLotDraft(), quantity: "2" }])[0]?.manufacturer_lot_code).toBeNull()
  })

  it("lets submission proceed with quantity differences and blocks only incomplete counts", () => {
    const summary = submitSummary([
      {
        product_id: "p1",
        expected_quantity: 4,
        counted_quantity: 5,
        is_found_product: false,
        expiry_policy: "expiry_controlled",
        lots: [{ quantity: 5 }],
      },
      {
        product_id: "p2",
        expected_quantity: 0,
        counted_quantity: 1,
        is_found_product: true,
        expiry_policy: null,
        lots: [{ quantity: 1 }],
      },
    ])
    expect(summary.unmatchedLines).toBe(2)
    expect(summary.unclassifiedProducts).toBe(1)
    expect(summary.foundProductLines).toBe(1)
    expect(canSubmitFromSummary(summary)).toBe(true)
    expect(
      canSubmitFromSummary(
        submitSummary([
          {
            product_id: "p1",
            expected_quantity: 4,
            counted_quantity: null,
            is_found_product: false,
            expiry_policy: "expiry_controlled",
            lots: [],
          },
        ]),
      ),
    ).toBe(false)
  })

  it("hides approval for the submitter and locks approved sessions", () => {
    const submitter = lotReconciliationActions({
      status: "submitted",
      isSubmitter: true,
      canPhysical: true,
      canAdmin: true,
    })
    expect(submitter.approve).toBe(false)
    expect(submitter.reject).toBe(true)
    expect(submitter.saveCount).toBe(false)

    const reviewer = lotReconciliationActions({
      status: "submitted",
      isSubmitter: false,
      canPhysical: true,
      canAdmin: true,
    })
    expect(reviewer.approve).toBe(true)

    const approved = lotReconciliationActions({
      status: "approved",
      isSubmitter: false,
      canPhysical: true,
      canAdmin: true,
    })
    expect(approved.cancel).toBe(false)
    expect(approved.saveCount).toBe(false)
    expect(approved.immutable).toBe(true)

    const rejected = lotReconciliationActions({
      status: "rejected",
      isSubmitter: false,
      canPhysical: true,
      canAdmin: true,
    })
    expect(rejected.reopen).toBe(true)
    expect(rejected.cancel).toBe(true)
  })

  it("explains PT409 and overlapping crate errors without inventing codes", () => {
    const stale = new LotReconciliationRpcError(
      "lot reconciliation was changed by someone else",
      "PT409",
    )
    expect(isStaleVersionError(stale)).toBe(true)
    expect(reconciliationErrorMessage(stale)).toMatch(/changed by someone else/i)
    expect(
      reconciliationErrorMessage(
        new Error("an overlapping lot reconciliation already holds these crates"),
      ),
    ).toMatch(/overlapping reconciliation/i)
  })

  it("labels events from backend types", () => {
    expect(eventLabel("expected_refreshed")).toBe("Expected stock refreshed")
    expect(actorLabel("aaaaaaaa-bbbb", "aaaaaaaa-bbbb")).toBe("You")
    expect(sessionListAction({ status: "draft", canPhysical: true, canAdmin: false })).toBe("Count")
  })

  it("registers a permission-aware lot reconciliation nav item", () => {
    const item = navigationItems.find((entry) => entry.to === "/stock-lot-reconciliation")
    expect(item?.label).toBe("Lot reconciliation")
    expect(item?.anyPermissions).toEqual([
      "stock.lots.physical_reconcile",
      "stock.lots.legacy.reconcile",
      "operations.monitor",
    ])
    expect(item?.anyPermissions).not.toContain("stock.verify")
    expect(item?.anyPermissions).not.toContain("stock.count_assist")
  })
})
