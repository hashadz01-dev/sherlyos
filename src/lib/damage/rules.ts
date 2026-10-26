/**
 * M5.2 damage-management lifecycle constants.
 * Stock posting, holds, and disposition stay in M5.3.
 */

export const damageScenarios = [
  "refill_supply",
  "unloading",
  "storage",
  "loading",
  "transit",
  "shop_return",
] as const

export type DamageScenario = (typeof damageScenarios)[number]

export const damageStatuses = [
  "draft",
  "submitted",
  "returned",
  "verified",
  "cancelled",
  "rejected",
] as const

export type DamageStatus = (typeof damageStatuses)[number]

/** Future M5.3 disposition labels only. Not operational in M5.2. */
export const reservedDamageDispositionStates = [
  "approved_writeoff",
  "approved_return_supplier",
  "approved_destroy",
  "disposed",
] as const

/**
 * On-hand scenarios that isolate allocatable stock.
 * Submit always calls apply_damage_stock_isolation. The M5.2 stub raises
 * 23514; the hold-ready flag cannot skip that call.
 */
export const stockHoldScenarios = ["storage", "loading", "shop_return"] as const

/** Inbound damaged cases were never posted as accepted RECEIPT stock. */
export const inboundDamageScenarios = ["refill_supply", "unloading"] as const

export const damageNavPermissions = [
  "damage.read",
  "damage.record",
  "damage.verify",
  "operations.monitor",
  "deliveries.execute",
] as const

export function scenarioRequiresStockHold(scenario: string) {
  return (stockHoldScenarios as readonly string[]).includes(scenario)
}

export function scenarioMaySubmitWithoutHold(scenario: string) {
  return (
    (inboundDamageScenarios as readonly string[]).includes(scenario) ||
    scenario === "transit"
  )
}

export function isEditableDamageStatus(status: DamageStatus) {
  return status === "draft" || status === "returned"
}

export function isTerminalDamageStatus(status: DamageStatus) {
  return status === "verified" || status === "cancelled" || status === "rejected"
}
