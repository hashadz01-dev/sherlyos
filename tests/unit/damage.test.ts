import { describe, expect, it } from "vitest"
import { navigationItems } from "@/app/navigation"
import {
  activityNote,
  formatCases,
  formatDamageScenario,
  formatDamageStatus,
  readinessMessage,
  sourceReferenceLabel,
} from "@/features/damage/utils/labels"
import { damageQuantityBreakdown } from "@/features/damage/utils/quantities"
import {
  damageNavPermissions,
  damageScenarios,
  damageStatuses,
  isEditableDamageStatus,
  isTerminalDamageStatus,
  reservedDamageDispositionStates,
  scenarioMaySubmitWithoutHold,
  scenarioRequiresStockHold,
} from "@/lib/damage/rules"

describe("damage foundation rules", () => {
  it("covers the six blueprint scenarios and M5.2 statuses only", () => {
    expect(damageScenarios).toEqual([
      "refill_supply",
      "unloading",
      "storage",
      "loading",
      "transit",
      "shop_return",
    ])
    expect(damageStatuses).toEqual([
      "draft",
      "submitted",
      "returned",
      "verified",
      "cancelled",
      "rejected",
    ])
    expect(reservedDamageDispositionStates).not.toEqual(
      expect.arrayContaining(damageStatuses as unknown as string[]),
    )
  })

  it("requires isolation for on-hand scenarios and allows inbound or transit without holds", () => {
    expect(scenarioRequiresStockHold("storage")).toBe(true)
    expect(scenarioRequiresStockHold("loading")).toBe(true)
    expect(scenarioRequiresStockHold("shop_return")).toBe(true)
    expect(scenarioRequiresStockHold("refill_supply")).toBe(false)
    expect(scenarioRequiresStockHold("unloading")).toBe(false)
    expect(scenarioRequiresStockHold("transit")).toBe(false)
    expect(scenarioMaySubmitWithoutHold("refill_supply")).toBe(true)
    expect(scenarioMaySubmitWithoutHold("unloading")).toBe(true)
    expect(scenarioMaySubmitWithoutHold("transit")).toBe(true)
    expect(scenarioMaySubmitWithoutHold("storage")).toBe(false)
  })

  it("treats verified reports as terminal and drafts as editable", () => {
    expect(isEditableDamageStatus("draft")).toBe(true)
    expect(isEditableDamageStatus("returned")).toBe(true)
    expect(isEditableDamageStatus("submitted")).toBe(false)
    expect(isTerminalDamageStatus("verified")).toBe(true)
    expect(isTerminalDamageStatus("cancelled")).toBe(true)
    expect(isTerminalDamageStatus("rejected")).toBe(true)
    expect(isTerminalDamageStatus("submitted")).toBe(false)
  })

  it("gates the damage route with the M5.2/M5.4A nav permission set", () => {
    expect(
      navigationItems.find((item) => item.to === "/damage")?.anyPermissions,
    ).toEqual([...damageNavPermissions])
    expect(
      navigationItems.find((item) => item.to === "/damage")?.description,
    ).toMatch(/Authorized damage reports/i)
  })
})

describe("damage display helpers", () => {
  it("maps scenario and status labels for the read UI", () => {
    expect(formatDamageScenario("storage")).toBe("Storage")
    expect(formatDamageScenario("shop_return")).toBe("Shop return")
    expect(formatDamageStatus("submitted")).toBe("Submitted")
    expect(formatDamageStatus("verified")).toBe("Verified")
  })

  it("formats carton quantities without inventing stock", () => {
    expect(formatCases(0)).toBe("0 cases")
    expect(formatCases(1)).toBe("1 case")
    expect(formatCases(12)).toBe("12 cases")
  })

  it("explains readiness without exposing configuration keys", () => {
    expect(readinessMessage(false)).toMatch(/unavailable/i)
    expect(readinessMessage(false)).not.toMatch(/damage\.stock_hold_ready/)
    expect(readinessMessage(true)).toMatch(/enabled/i)
  })

  it("builds source references from authorized ids only", () => {
    expect(
      sourceReferenceLabel({
        scenario: "storage",
        receipt_id: null,
        picking_request_id: null,
        dispatch_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        order_id: null,
        shop_id: null,
      }),
    ).toBe("Dispatch aaaaaaaa")
  })

  it("keeps activity notes free of internal tokens", () => {
    expect(activityNote({ note: "Returned for clearer photos" })).toBe(
      "Returned for clearer photos",
    )
    expect(
      activityNote({ idempotency_key: "secret", guc_token: "x" }),
    ).toBeNull()
  })

  it("separates reported, held, quarantined, and written-off quantities", () => {
    const breakdown = damageQuantityBreakdown({
      lines: [
        {
          id: "l1",
          product_id: "p1",
          product_sku: "SKU",
          product_name: "Item",
          crate_id: "c1",
          crate_code: "C1",
          lot_id: null,
          quantity_cases: 5,
          damage_reason: "crushed",
          notes: null,
          receipt_line_id: null,
        },
      ],
      holds: [
        {
          id: "h1",
          line_id: "l1",
          product_id: "p1",
          crate_id: "c1",
          location_role: "storage",
          lot_id: null,
          quantity_cases: 3,
          hold_kind: "on_hand_deduction",
          status: "active",
        },
        {
          id: "h2",
          line_id: "l1",
          product_id: "p1",
          crate_id: "q1",
          location_role: "quarantine",
          lot_id: null,
          quantity_cases: 2,
          hold_kind: "quarantine_intake",
          status: "transferred",
        },
        {
          id: "h3",
          line_id: "l1",
          product_id: "p1",
          crate_id: "q1",
          location_role: "quarantine",
          lot_id: null,
          quantity_cases: 1,
          hold_kind: "quarantine_intake",
          status: "written_off",
        },
      ],
    })
    expect(breakdown).toEqual({
      reportedCases: 5,
      heldCases: 3,
      quarantinedCases: 2,
      writtenOffCases: 1,
    })
  })
})
