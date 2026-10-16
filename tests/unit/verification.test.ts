import { describe, expect, it } from "vitest"
import { navigationItems } from "@/app/navigation"
import {
  canCloseVerification,
  countStatus,
  evidenceSatisfiesClosure,
  finalVariance,
  parseCaseCount,
  photoUploadTransition,
  reconciledExpected,
  recountRequired,
  sameIdSet,
  scopeSelectionReady,
  startVerificationIssues,
  suggestedClosureResult,
  verificationActions,
  verificationErrorMessage,
} from "@/lib/verification/rules"

describe("verification rules", () => {
  it("accepts a whole-case count, including zero", () => {
    expect(parseCaseCount("0")).toEqual({ ok: true, cases: 0 })
    expect(parseCaseCount("12")).toEqual({ ok: true, cases: 12 })
  })

  it("rejects blank, decimal, and negative counts", () => {
    expect(parseCaseCount("").ok).toBe(false)
    expect(parseCaseCount("1.5").ok).toBe(false)
    expect(parseCaseCount("-1").ok).toBe(false)
    expect(parseCaseCount("12 ").ok).toBe(true)
  })

  it("describes count status without treating a missing count as zero", () => {
    expect(
      countStatus({ countedCases: null, recountCases: null, recountRequested: false }),
    ).toBe("uncounted")
    expect(
      countStatus({ countedCases: 0, recountCases: null, recountRequested: false }),
    ).toBe("counted")
    expect(
      countStatus({ countedCases: 4, recountCases: null, recountRequested: true }),
    ).toBe("recount requested")
    expect(
      countStatus({ countedCases: 4, recountCases: 5, recountRequested: false }),
    ).toBe("recounted")
  })

  it("keeps snapshot expected separate from reconciled variance", () => {
    expect(reconciledExpected(8, -3)).toBe(5)
    expect(finalVariance(4, 5)).toBe(-1)
    expect(finalVariance(null, 5)).toBeNull()
    expect(finalVariance(5, reconciledExpected(5, 0))).toBe(0)
  })

  it("requires a recount only for an unresolved variance", () => {
    expect(recountRequired(-1, null)).toBe(true)
    expect(recountRequired(2, 4)).toBe(false)
    expect(recountRequired(0, null)).toBe(false)
    expect(recountRequired(null, null)).toBe(false)
  })

  it("limits actions by permission and status", () => {
    const keeper = verificationActions({
      canVerify: false,
      canCount: true,
      canReport: false,
      status: "counting",
    })
    expect(keeper.canStart).toBe(false)
    expect(keeper.canSaveCount).toBe(true)
    expect(keeper.canSubmit).toBe(false)
    expect(keeper.canClose).toBe(false)
    expect(keeper.readOnly).toBe(false)

    const admin = verificationActions({
      canVerify: false,
      canCount: false,
      canReport: false,
      status: "review",
    })
    expect(admin.readOnly).toBe(true)
    expect(admin.canReview).toBe(false)
    expect(admin.canUpload).toBe(false)

    const manager = verificationActions({
      canVerify: true,
      canCount: false,
      canReport: true,
      status: "submitted",
    })
    expect(manager.canReport).toBe(true)
    expect(manager.canRequestRecount).toBe(true)
    expect(manager.canClose).toBe(true)
  })

  it("blocks closure until the server blockers are clear", () => {
    expect(
      canCloseVerification({
        canVerify: true,
        status: "review",
        blockers: ["photo evidence is required"],
      }),
    ).toBe(false)
    expect(
      canCloseVerification({
        canVerify: true,
        status: "counting",
        blockers: [],
      }),
    ).toBe(false)
    expect(
      canCloseVerification({
        canVerify: false,
        status: "review",
        blockers: [],
      }),
    ).toBe(false)
    expect(
      canCloseVerification({
        canVerify: true,
        status: "review",
        blockers: [],
      }),
    ).toBe(true)
  })

  it("suggests a closure result from the remaining variance", () => {
    expect(suggestedClosureResult(0)).toBe("matched")
    expect(suggestedClosureResult(1)).toBe("variance_recorded")
  })

  it("validates the start form and scope selection", () => {
    expect(
      startVerificationIssues({
        godownId: "",
        businessDate: "today",
        zoneIds: [],
        crateIds: [],
      }),
    ).toEqual([
      "Select a godown.",
      "Enter a business date.",
      "Select at least one zone.",
      "Select at least one crate.",
    ])
    expect(
      scopeSelectionReady({
        zoneIds: ["zone-a", "zone-b"],
        crateIds: ["crate-a"],
        crates: [
          { id: "crate-a", zone_id: "zone-a" },
          { id: "crate-b", zone_id: "zone-b" },
        ],
      }),
    ).toBe(false)
    expect(
      scopeSelectionReady({
        zoneIds: ["zone-a"],
        crateIds: ["crate-a"],
        crates: [{ id: "crate-a", zone_id: "zone-a" }],
      }),
    ).toBe(true)
  })

  it("tracks photo upload state and ignores an unfinalized photo", () => {
    const selected = photoUploadTransition({ status: "idle", message: null }, { type: "select" })
    const uploading = photoUploadTransition(selected, { type: "start" })
    const failed = photoUploadTransition(uploading, { type: "fail", message: "photo content could not be verified" })
    expect(uploading.status).toBe("uploading")
    expect(failed).toEqual({
      status: "error",
      message: "photo content could not be verified",
    })
    expect(evidenceSatisfiesClosure([{ verifiedAt: null }])).toBe(false)
    expect(evidenceSatisfiesClosure([{ verifiedAt: "2026-10-15T00:00:00Z" }])).toBe(true)
  })

  it("matches movement ids without depending on order", () => {
    expect(sameIdSet(["b", "a"], ["a", "b"])).toBe(true)
    expect(sameIdSet(["a"], ["a", "b"])).toBe(false)
  })

  it("returns the database message for an API error", () => {
    expect(verificationErrorMessage(new Error("recount is required"))).toBe("recount is required")
    expect(verificationErrorMessage("no")).toBe("The verification could not be saved.")
  })

  it("shows verification only to counting and monitoring roles", () => {
    expect(navigationItems.find((item) => item.to === "/stock-verification")?.anyPermissions).toEqual([
      "stock.verify",
      "stock.count_assist",
      "operations.monitor",
    ])
  })
})
