/**
 * Damage-management lifecycle constants.
 * Holds and disposition posting are M5.3 RPCs. M5.4B drafts and submit use
 * the existing create/update/submit/photo contracts; isolation stays fail-closed.
 */

/** Private bucket limits from storage.buckets.stock-damage-evidence. */
export const damagePhotoMaxBytes = 10 * 1024 * 1024
export const damagePhotoMimeTypes = [
  "image/jpeg",
  "image/png",
  "image/webp",
] as const

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

/** Create/edit routes. Admin monitor-only accounts are excluded. */
export const damageCreatePermissions = [
  "damage.record",
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

/**
 * UX-only scenario enablement. Backend assert_damage_create_auth remains
 * authoritative and may still reject a selected scenario.
 */
export function scenariosAvailableForPermissions(
  can: (permission: string) => boolean,
): DamageScenario[] {
  const available: DamageScenario[] = []
  const recorder = can("damage.record")
  const verifier = can("damage.verify")
  if (recorder && (can("receiving.execute") || verifier)) {
    available.push("refill_supply", "unloading")
  }
  if (recorder && verifier) {
    available.push("storage")
  }
  if (recorder && (can("loading.assist") || verifier)) {
    available.push("loading")
  }
  if (recorder || can("deliveries.execute")) {
    available.push("transit")
  }
  if (recorder && verifier) {
    available.push("shop_return")
  }
  return available
}

export function canOpenDamageCreate(can: (permission: string) => boolean) {
  return can("damage.record") || can("deliveries.execute")
}

/**
 * Quarantine inventory is not a transit reporting surface.
 * Backend list_damage_quarantine_inventory rejects deliveries.execute-only.
 */
export const damageQuarantinePermissions = [
  "damage.read",
  "damage.record",
  "damage.verify",
  "operations.monitor",
] as const

/** UX gate only. confirm_shop_return_custody uses assert_damage_create_auth. */
export function canConfirmShopReturnCustody(input: {
  scenario: string
  status: string
  alreadyConfirmed: boolean
  canRecord: boolean
  canVerify: boolean
}) {
  return (
    input.scenario === "shop_return" &&
    isEditableDamageStatus(input.status as DamageStatus) &&
    !input.alreadyConfirmed &&
    input.canRecord &&
    input.canVerify
  )
}

/**
 * UX gate only. transfer_verified_damage_to_quarantine requires damage.verify,
 * verified storage, and remaining active on-hand holds. Quantity is not partial.
 */
export function canTransferVerifiedDamage(input: {
  scenario: string
  status: string
  canVerify: boolean
  activeOnHandHolds: number
}) {
  return (
    input.canVerify &&
    input.scenario === "storage" &&
    input.status === "verified" &&
    input.activeOnHandHolds > 0
  )
}

export function isSupportedDamagePhotoMime(mime: string) {
  const normalized = mime.toLowerCase() === "image/jpg" ? "image/jpeg" : mime
  return (damagePhotoMimeTypes as readonly string[]).includes(normalized)
}
