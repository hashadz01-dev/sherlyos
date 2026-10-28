import { describe, expect, it } from "vitest"
import {
  canReassignDelivery,
  canStartDelivery,
  cutoverBlocksDeliveryReturn,
  cutoverBlocksDispatch,
  isStaleDispatchVersion,
  lotClassificationTotal,
} from "@/lib/dispatch/rules"

describe("dispatch rules", () => {
  it("blocks dispatch while dual-write is off", () => {
    expect(
      cutoverBlocksDispatch({ dual_write_enabled: false, aggregate_only_blocked: false }),
    ).toMatch(/dual-write/)
    expect(
      cutoverBlocksDispatch({ dual_write_enabled: true, aggregate_only_blocked: true }),
    ).toBeNull()
  })

  it("treats PT409 as a stale dispatch version", () => {
    expect(isStaleDispatchVersion({ message: "nope", code: "PT409" })).toBe(true)
    expect(isStaleDispatchVersion({ message: "dispatch was changed by someone else" })).toBe(true)
    expect(isStaleDispatchVersion({ message: "insufficient unreserved stock" })).toBe(false)
  })

  it("blocks delivery-return posting while dual-write is off", () => {
    expect(cutoverBlocksDeliveryReturn(false)).toMatch(/dual-write/)
    expect(cutoverBlocksDeliveryReturn(true)).toBeNull()
  })

  it("requires lot classification to consume the dispatched grain", () => {
    expect(
      lotClassificationTotal({
        delivered_cases: 1,
        saleable_cases: 2,
        damaged_cases: 1,
        uncertain_cases: 0,
        missing_cases: 1,
      }),
    ).toBe(5)
  })

  it("allows assignment only before transit and requires vehicle to start", () => {
    expect(canReassignDelivery("dispatched", true)).toBe(true)
    expect(canReassignDelivery("in_transit", true)).toBe(false)
    expect(
      canStartDelivery({
        status: "dispatched",
        assignedTo: "driver",
        vehicleId: "vehicle",
      }),
    ).toBe(true)
    expect(
      canStartDelivery({
        status: "dispatched",
        assignedTo: "driver",
        vehicleId: null,
      }),
    ).toBe(false)
  })
})
