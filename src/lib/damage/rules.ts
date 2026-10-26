/**
 * Damage-management lifecycle constants.
 * Holds and disposition posting are M5.3 RPCs. M5.4A is read-only UI over those contracts.
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

export const damageHoldKinds = [
  "on_hand_deduction",
  "reservation_conversion",
  "quarantine_intake",
] as const

export const damageHoldStatuses = [
  "active",
  "released",
  "transferred",
  "written_off",
  "returned_supplier",
] as const

export const exceptionalDispositionKinds = [
  "return_supplier",
  "destroy",
] as const

/** Legacy labels retained for M5.4 copy. Operational kinds are exceptionalDispositionKinds. */
export const reservedDamageDispositionStates = [
  "approved_writeoff",
  "approved_return_supplier",
  "approved_destroy",
  "disposed",
] as const

/**
 * On-hand scenarios that isolate allocatable stock.
 * Submit always calls apply_damage_stock_isolation. The hold-ready flag may
 * only fail-closed; it cannot skip isolation.
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
  return (
    status === "verified" || status === "cancelled" || status === "rejected"
  )
}
