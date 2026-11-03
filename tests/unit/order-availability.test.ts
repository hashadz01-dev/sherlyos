import { describe, expect, it } from "vitest"
import {
  deliveryNoteHandoverLabel,
  describeAtpLine,
  isAcknowledgedDeliveryNote,
  parseAvailabilitySnapshot,
  shortageLinesFromErrorDetails,
} from "@/lib/orders/availability"

describe("order availability snapshot", () => {
  it("parses the M7.2 object and treats pre-cutover lines as ineligible", () => {
    const snapshot = parseAvailabilitySnapshot({
      reserves_stock: false,
      picking_operational: false,
      cutover_blockers: ["Lot-aware picking requires dual-write to be enabled."],
      lines: [
        {
          product_id: "p1",
          requested_cases: 8,
          on_hand_cases: 5,
          eligible_cases: 0,
          shortfall_cases: 8,
          eligible: false,
          blockers: ["Lot-aware picking requires dual-write to be enabled."],
        },
      ],
    })
    expect(snapshot.reserves_stock).toBe(false)
    expect(snapshot.picking_operational).toBe(false)
    expect(snapshot.lines[0]?.eligible_cases).toBe(0)
    expect(snapshot.lines[0]?.on_hand_cases).toBe(5)
  })

  it("parses a bare shortage array from verify_order details", () => {
    const lines = shortageLinesFromErrorDetails(
      JSON.stringify([
        {
          product_id: "p1",
          requested_cases: 4,
          on_hand_cases: 4,
          eligible_cases: 0,
          shortfall_cases: 4,
          eligible: false,
          blockers: ["quarantine"],
        },
      ]),
    )
    expect(lines).toHaveLength(1)
    expect(lines[0]?.shortfall_cases).toBe(4)
  })

  it("treats eligible equal to requested as covering even when on-hand is larger", () => {
    const covered = describeAtpLine({
      product_id: "p1",
      requested_cases: 2,
      on_hand_cases: 20,
      eligible_cases: 2,
      shortfall_cases: 0,
      eligible: true,
      blockers: [],
    })
    expect(covered.covering).toBe(true)
    expect(covered.onHandExceedsEligible).toBe(true)
    expect(covered.summary).toMatch(/informational crate stock/i)

    const failClosed = describeAtpLine({
      product_id: "p1",
      requested_cases: 2,
      on_hand_cases: 20,
      eligible_cases: 0,
      shortfall_cases: 2,
      eligible: false,
      blockers: ["Lot-aware picking requires dual-write to be enabled."],
    })
    expect(failClosed.covering).toBe(false)
    expect(failClosed.summary).toMatch(/Shortfall 2/)
  })

  it("labels acknowledged DN as the picking gate", () => {
    expect(isAcknowledgedDeliveryNote({ status: "acknowledged" } as never)).toBe(true)
    expect(isAcknowledgedDeliveryNote({ status: "sent" } as never)).toBe(false)
    expect(deliveryNoteHandoverLabel("sent")).toMatch(/waiting/i)
    expect(deliveryNoteHandoverLabel(null)).toMatch(/No delivery note/)
  })
})
