import { describe, expect, it } from "vitest"
import { navigationItems } from "@/app/navigation"
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

  it("blocks stock-affecting submit until M5.3 and allows inbound or transit", () => {
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

  it("gates the placeholder damage route without building M5.4", () => {
    expect(navigationItems.find((item) => item.to === "/damage")?.anyPermissions).toEqual([
      ...damageNavPermissions,
    ])
  })
})
