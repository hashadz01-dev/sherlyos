import { describe, expect, it } from "vitest"
import {
  parseShipmentSummary,
  shortShipmentNextAction,
} from "@/lib/shipments/rules"

describe("shipment rules", () => {
  it("parses an approved shipment summary", () => {
    const parsed = parseShipmentSummary({
      id: "11111111-1111-1111-1111-111111111111",
      shipment_number: "SH-20261027-000001",
      status: "approved",
      revision: 1,
      version: 3,
      approved_cases: 1,
    })
    expect(parsed?.status).toBe("approved")
    expect(parsed?.approved_cases).toBe(1)
  })

  it("rejects unknown shipment statuses", () => {
    expect(parseShipmentSummary({ id: "x", status: "invoiced" })).toBeNull()
  })

  it("does not claim live warehouse movement while cutover is blocked", () => {
    expect(
      shortShipmentNextAction({
        hasShortage: true,
        shipmentStatus: "approved",
        pickingStatus: "ready_for_dispatch",
        cutoverBlocked: true,
      }),
    ).toMatch(/lot cutover/)
  })
})
