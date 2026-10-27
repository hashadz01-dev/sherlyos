import { describe, expect, it } from "vitest"
import {
  canDecideRefillRequest,
  canEditRefillRequest,
  canSubmitRefillRequest,
  isEditableRefillStatus,
  isTerminalRefillStatus,
  isValidDecisionReason,
  parseRequestedCases,
  refillCreateIdempotencyKey,
  refillMutationIdempotencyKey,
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

describe("refill idempotency keys", () => {
  it("reuses a stored create key and builds mutation keys without silent retry semantics", () => {
    const stored = "rf-abcdefghijkl"
    expect(refillCreateIdempotencyKey(stored)).toBe(stored)
    expect(
      refillMutationIdempotencyKey("apr", "11111111-2222-3333-4444-555555555555"),
    ).toMatch(/^apr-/)
  })
})
