import { describe, expect, it } from "vitest"
import {
  canDecideRefillRequest,
  canEditRefillRequest,
  canRecordRefillAcknowledgement,
  canRecordRefillDispatch,
  canCreateLinkedRefillReceipt,
  canRecordRefillSend,
  canSubmitRefillRequest,
  excessCases,
  isEditableRefillStatus,
  isTerminalRefillStatus,
  isValidDecisionReason,
  outstandingCases,
  parseRequestedCases,
  refillCreateIdempotencyKey,
  refillMutationIdempotencyKey,
  refillReceivingCompletionLabel,
  validateRefillLines,
} from "@/lib/refill/rules"

describe("refill status helpers", () => {
  it("allows edit on draft and held only", () => {
    expect(isEditableRefillStatus("draft")).toBe(true)
    expect(isEditableRefillStatus("held")).toBe(true)
    expect(isEditableRefillStatus("submitted")).toBe(false)
    expect(isEditableRefillStatus("approved")).toBe(false)
    expect(isEditableRefillStatus("rejected")).toBe(false)
  })

  it("treats rejected as terminal", () => {
    expect(isTerminalRefillStatus("rejected")).toBe(true)
    expect(isTerminalRefillStatus("approved")).toBe(false)
  })
})

describe("refill line validation", () => {
  it("requires positive whole-case quantities and unique SKUs", () => {
    expect(
      validateRefillLines([
        { product_id: "p1", requested_cases: 2 },
        { product_id: "p2", requested_cases: 1 },
      ]),
    ).toEqual([])
    expect(validateRefillLines([])).toContain("Add at least one SKU line.")
    expect(
      validateRefillLines([
        { product_id: "p1", requested_cases: 1 },
        { product_id: "p1", requested_cases: 2 },
      ]),
    ).toContain("Duplicate SKU lines are not allowed.")
    expect(
      validateRefillLines([{ product_id: "p1", requested_cases: 0 }]),
    ).not.toEqual([])
    expect(parseRequestedCases("3.5")).toBeNull()
    expect(parseRequestedCases("-1")).toBeNull()
    expect(parseRequestedCases("4")).toBe(4)
  })
})

describe("refill permission-aware actions", () => {
  it("lets the Accounts creator edit and submit draft or held requests", () => {
    const base = {
      createdBy: "acct",
      viewerId: "acct",
      canRequest: true,
    }
    expect(canEditRefillRequest({ ...base, status: "draft" })).toBe(true)
    expect(canSubmitRefillRequest({ ...base, status: "held" })).toBe(true)
    expect(canEditRefillRequest({ ...base, status: "submitted" })).toBe(false)
    expect(
      canEditRefillRequest({ ...base, viewerId: "other", status: "draft" }),
    ).toBe(false)
    expect(
      canEditRefillRequest({ ...base, canRequest: false, status: "draft" }),
    ).toBe(false)
  })

  it("lets Admin decide only submitted requests", () => {
    expect(canDecideRefillRequest({ status: "submitted", canApprove: true })).toBe(
      true,
    )
    expect(canDecideRefillRequest({ status: "draft", canApprove: true })).toBe(
      false,
    )
    expect(
      canDecideRefillRequest({ status: "submitted", canApprove: false }),
    ).toBe(false)
  })

  it("requires a hold/reject reason", () => {
    expect(isValidDecisionReason("need fewer cases")).toBe(true)
    expect(isValidDecisionReason("   ")).toBe(false)
  })
})

describe("refill supplier communication eligibility", () => {
  it("lets Accounts record send only on approved unsent active godowns", () => {
    const base = {
      canRequest: true,
      godownActive: true,
      communicationStatus: "not_sent" as const,
    }
    expect(canRecordRefillSend({ ...base, status: "approved" })).toBe(true)
    expect(canRecordRefillSend({ ...base, status: "submitted" })).toBe(false)
    expect(
      canRecordRefillSend({
        ...base,
        status: "approved",
        communicationStatus: "sent",
      }),
    ).toBe(false)
    expect(
      canRecordRefillSend({ ...base, status: "approved", canRequest: false }),
    ).toBe(false)
  })

  it("blocks dispatch after a declined supplier response", () => {
    const base = {
      status: "approved" as const,
      communicationStatus: "sent" as const,
      godownActive: true,
      canRequest: true,
    }
    expect(
      canRecordRefillDispatch({ ...base, acknowledgementStatus: "pending" }),
    ).toBe(true)
    expect(
      canRecordRefillDispatch({ ...base, acknowledgementStatus: "acknowledged" }),
    ).toBe(true)
    expect(
      canRecordRefillDispatch({ ...base, acknowledgementStatus: "declined" }),
    ).toBe(false)
    expect(
      canRecordRefillAcknowledgement({
        status: "approved",
        communicationStatus: "sent",
        godownActive: true,
        canRequest: true,
      }),
    ).toBe(true)
  })
})

describe("refill receiving reconciliation", () => {
  it("computes outstanding and excess from posted accepted only", () => {
    expect(outstandingCases(100, 70)).toBe(30)
    expect(outstandingCases(60, 45)).toBe(15)
    expect(outstandingCases(10, 12)).toBe(0)
    expect(excessCases(100, 70)).toBe(0)
    expect(excessCases(10, 12)).toBe(2)
  })

  it("excludes damaged and pending quantities from accepted stock", () => {
    const counted = 40
    const damaged = 5
    const accepted = counted - damaged
    expect(accepted).toBe(35)
    expect(outstandingCases(100, accepted)).toBe(65)
    expect(
      refillReceivingCompletionLabel({
        acceptedCases: 0,
        outstandingCases: 100,
        excessCases: 0,
        pendingReceiptCases: 12,
      }),
    ).toBe("pending_verification")
  })

  it("labels partial, complete, and excess from persisted totals", () => {
    expect(
      refillReceivingCompletionLabel({
        acceptedCases: 70,
        outstandingCases: 30,
        excessCases: 0,
        pendingReceiptCases: 0,
      }),
    ).toBe("partially_received")
    expect(
      refillReceivingCompletionLabel({
        acceptedCases: 160,
        outstandingCases: 0,
        excessCases: 0,
        pendingReceiptCases: 0,
      }),
    ).toBe("fully_received")
    expect(
      refillReceivingCompletionLabel({
        acceptedCases: 165,
        outstandingCases: 0,
        excessCases: 5,
        pendingReceiptCases: 0,
      }),
    ).toBe("excess_requires_review")
  })

  it("does not let Accounts post receiving through refill.request", () => {
    expect(
      canCreateLinkedRefillReceipt({
        canExecuteReceiving: false,
        requestStatus: "approved",
        godownActive: true,
      }),
    ).toBe(false)
    expect(
      canCreateLinkedRefillReceipt({
        canExecuteReceiving: true,
        requestStatus: "approved",
        godownActive: true,
      }),
    ).toBe(true)
    expect(
      canCreateLinkedRefillReceipt({
        canExecuteReceiving: true,
        requestStatus: "approved",
        godownActive: false,
      }),
    ).toBe(false)
  })
})

describe("refill idempotency keys", () => {
  it("reuses a stored create key and builds mutation keys without silent retry semantics", () => {
    const stored = "rf-abcdefghijkl"
    expect(refillCreateIdempotencyKey(stored)).toBe(stored)
    expect(
      refillMutationIdempotencyKey("apr", "11111111-2222-3333-4444-555555555555"),
    ).toMatch(/^apr-/)
  })
})
