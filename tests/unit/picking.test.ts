import { describe, expect, it } from "vitest"
import {
  SHORT_SHIPMENT_OPERATIONAL,
  cutoverBlocksPicking,
  isStalePickingVersion,
  nextOrderPickingAction,
  parsePickingFulfilment,
  pickingHasShortage,
  remainingCases,
  shortShipmentNotOperationalMessage,
} from "@/lib/picking/rules"

describe("picking rules", () => {
  it("keeps remaining cases from going negative", () => {
    expect(remainingCases(10, 4)).toBe(6)
    expect(remainingCases(4, 4)).toBe(0)
    expect(remainingCases(4, 9)).toBe(0)
  })

  it("blocks allocation while dual-write is off", () => {
    expect(
      cutoverBlocksPicking({ dual_write_enabled: false, aggregate_only_blocked: false }),
    ).toMatch(/dual-write/)
    expect(
      cutoverBlocksPicking({ dual_write_enabled: true, aggregate_only_blocked: true }),
    ).toBeNull()
  })

  it("treats PT409 as a stale picking version", () => {
    expect(isStalePickingVersion({ message: "nope", code: "PT409" })).toBe(true)
    expect(isStalePickingVersion({ message: "picking was changed by someone else" })).toBe(true)
    expect(isStalePickingVersion({ message: "insufficient eligible stock" })).toBe(false)
  })

  it("does not treat short-shipment as operational", () => {
    expect(SHORT_SHIPMENT_OPERATIONAL).toBe(false)
    expect(parsePickingFulfilment({ short_shipment_operational: true }).short_shipment_operational).toBe(
      false,
    )
    expect(pickingHasShortage([{ exception_type: "shortage" }])).toBe(true)
    expect(pickingHasShortage([{ exception_type: "stale" }])).toBe(false)
  })

  it("does not imply verified orders reserve stock", () => {
    expect(
      nextOrderPickingAction({
        orderStatus: "submitted",
        dnStatus: null,
        pickingStatus: null,
        hasShortage: false,
        cutoverBlocked: false,
      }),
    ).toMatch(/does not reserve/)
    expect(
      nextOrderPickingAction({
        orderStatus: "verified",
        dnStatus: "acknowledged",
        pickingStatus: null,
        hasShortage: false,
        cutoverBlocked: false,
      }),
    ).toMatch(/does not guarantee reserved/)
    expect(
      nextOrderPickingAction({
        orderStatus: "verified",
        dnStatus: "sent",
        pickingStatus: null,
        hasShortage: false,
        cutoverBlocked: false,
      }),
    ).toMatch(/acknowledgement/)
    expect(
      nextOrderPickingAction({
        orderStatus: "verified",
        dnStatus: "acknowledged",
        pickingStatus: "picked",
        hasShortage: true,
        cutoverBlocked: false,
      }),
    ).toBe(shortShipmentNotOperationalMessage)
    expect(
      nextOrderPickingAction({
        orderStatus: "verified",
        dnStatus: "acknowledged",
        pickingStatus: "picked",
        hasShortage: true,
        cutoverBlocked: false,
        shipmentStatus: "gm_confirmed",
      }),
    ).toMatch(/Accounts must approve/)
    expect(
      nextOrderPickingAction({
        orderStatus: "verified",
        dnStatus: "acknowledged",
        pickingStatus: "picked",
        hasShortage: true,
        cutoverBlocked: true,
        shipmentStatus: "approved",
      }),
    ).toMatch(/lot cutover/)
  })
})
