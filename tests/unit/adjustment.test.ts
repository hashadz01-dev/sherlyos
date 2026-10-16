import { describe, expect, it } from "vitest"
import {
  adjustmentActions,
  reasonForQuantities,
  requestIsExceptional,
} from "@/lib/adjustment/rules"

describe("adjustment rules", () => {
  it("treats 10 cases as ordinary and 11 as exceptional", () => {
    expect(requestIsExceptional([10, -10])).toBe(false)
    expect(requestIsExceptional([11])).toBe(true)
    expect(requestIsExceptional([-11])).toBe(true)
    expect(requestIsExceptional([4, -11])).toBe(true)
  })

  it("names the reason from the line signs", () => {
    expect(reasonForQuantities([-2])).toBe("shortage")
    expect(reasonForQuantities([3])).toBe("surplus")
    expect(reasonForQuantities([-1, 2])).toBe("mixed")
  })

  it("blocks the requester from approving and lets another manager approve an ordinary request", () => {
    const requester = adjustmentActions({
      status: "submitted",
      exceptional: false,
      isRequester: true,
      canRequest: true,
      canPost: true,
      canApproveExceptional: false,
      otherManagerExists: true,
    })
    expect(requester.approve).toBe(false)
    expect(requester.submit).toBe(false)

    const otherManager = adjustmentActions({
      status: "submitted",
      exceptional: false,
      isRequester: false,
      canRequest: true,
      canPost: true,
      canApproveExceptional: false,
      otherManagerExists: true,
    })
    expect(otherManager.approve).toBe(true)
    expect(otherManager.post).toBe(false)
  })

  it("uses admin only as the ordinary fallback and always for exceptional approval", () => {
    const blockedAdmin = adjustmentActions({
      status: "submitted",
      exceptional: false,
      isRequester: false,
      canRequest: false,
      canPost: false,
      canApproveExceptional: true,
      otherManagerExists: true,
    })
    expect(blockedAdmin.approve).toBe(false)

    const fallbackAdmin = adjustmentActions({
      status: "submitted",
      exceptional: false,
      isRequester: false,
      canRequest: false,
      canPost: false,
      canApproveExceptional: true,
      otherManagerExists: false,
    })
    expect(fallbackAdmin.approve).toBe(true)

    const exceptionalAdmin = adjustmentActions({
      status: "submitted",
      exceptional: true,
      isRequester: false,
      canRequest: false,
      canPost: false,
      canApproveExceptional: true,
      otherManagerExists: true,
    })
    expect(exceptionalAdmin.approve).toBe(true)
    expect(exceptionalAdmin.post).toBe(false)
  })

  it("posts only after approval and never from a rejected request", () => {
    expect(
      adjustmentActions({
        status: "approved",
        exceptional: false,
        isRequester: true,
        canRequest: true,
        canPost: true,
        canApproveExceptional: false,
        otherManagerExists: true,
      }).post,
    ).toBe(true)
    expect(
      adjustmentActions({
        status: "rejected",
        exceptional: false,
        isRequester: false,
        canRequest: true,
        canPost: true,
        canApproveExceptional: false,
        otherManagerExists: true,
      }).reject,
    ).toBe(false)
  })
})
