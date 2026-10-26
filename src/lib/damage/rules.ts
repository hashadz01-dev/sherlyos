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

/** GM verification queue and inspection. Monitor-only accounts may view. */
export const damageVerificationPermissions = [
  "damage.verify",
  "operations.monitor",
] as const

export type DamageDecisionBlocker = {
  code:
    | "permission"
    | "status"
    | "self"
    | "evidence"
    | "isolation"
    | "quantity"
    | "godown"
    | "scenario"
    | "holds"
    | "exceptional"
    | "posted"
  message: string
}

/**
 * UX gate matching verify_damage_report. Backend remains authoritative.
 * Isolation scenarios require persisted holds; readiness=false prevents
 * submit of those scenarios, so they do not reach this gate in production.
 */
export function collectVerificationBlockers(input: {
  status: string
  scenario: string
  canVerify: boolean
  isReporter: boolean
  hasFinalizedEvidence: boolean
  reportedCases: number
  isolatedCases: number
  godownActive?: boolean | null
}): DamageDecisionBlocker[] {
  const blockers: DamageDecisionBlocker[] = []
  if (!input.canVerify) {
    blockers.push({
      code: "permission",
      message: "Godown verification requires damage.verify at this godown.",
    })
  }
  if (input.status !== "submitted") {
    blockers.push({
      code: "status",
      message: "Only submitted reports can be verified.",
    })
  }
  if (input.isReporter) {
    blockers.push({
      code: "self",
      message: "The reporter cannot verify this damage report.",
    })
  }
  if (!input.hasFinalizedEvidence) {
    blockers.push({
      code: "evidence",
      message: "Finalized photographic evidence is required.",
    })
  }
  if (scenarioRequiresStockHold(input.scenario) && input.isolatedCases < 1) {
    blockers.push({
      code: "isolation",
      message:
        "Matching isolated holds are required. Storage, loading, and shop-return verification need them.",
    })
  }
  if (
    scenarioRequiresStockHold(input.scenario) &&
    input.isolatedCases > 0 &&
    input.isolatedCases !== input.reportedCases
  ) {
    blockers.push({
      code: "quantity",
      message: "Verified quantities cannot exceed isolated quantities.",
    })
  }
  if (input.godownActive === false) {
    blockers.push({
      code: "godown",
      message:
        "This godown is inactive. Operational verification is not allowed.",
    })
  }
  return blockers
}

export function canVerifyDamageReport(
  input: Parameters<typeof collectVerificationBlockers>[0],
) {
  return collectVerificationBlockers(input).length === 0
}

/** Return is submitted-only and forbidden for shop-return. Reason is required by the RPC. */
export function collectReturnBlockers(input: {
  status: string
  scenario: string
  canVerify: boolean
  godownActive?: boolean | null
}): DamageDecisionBlocker[] {
  const blockers: DamageDecisionBlocker[] = []
  if (!input.canVerify) {
    blockers.push({
      code: "permission",
      message: "Returning a report requires damage.verify.",
    })
  }
  if (input.status !== "submitted") {
    blockers.push({
      code: "status",
      message: "Only submitted reports can be returned for correction.",
    })
  }
  if (input.scenario === "shop_return") {
    blockers.push({
      code: "scenario",
      message:
        "Submitted shop-return damage cannot return to draft. Reject it or complete verification.",
    })
  }
  if (input.godownActive === false) {
    blockers.push({
      code: "godown",
      message: "This godown is inactive. Operational returns are not allowed.",
    })
  }
  return blockers
}

export function canReturnDamageReport(
  input: Parameters<typeof collectReturnBlockers>[0],
) {
  return collectReturnBlockers(input).length === 0
}

/** Reject is submitted-only. Reporter cannot reject their own report. */
export function collectRejectBlockers(input: {
  status: string
  canVerify: boolean
  isReporter: boolean
  godownActive?: boolean | null
}): DamageDecisionBlocker[] {
  const blockers: DamageDecisionBlocker[] = []
  if (!input.canVerify) {
    blockers.push({
      code: "permission",
      message: "Rejecting a report requires damage.verify.",
    })
  }
  if (input.status !== "submitted") {
    blockers.push({
      code: "status",
      message: "Only submitted reports can be rejected.",
    })
  }
  if (input.isReporter) {
    blockers.push({
      code: "self",
      message: "The reporter cannot reject this damage report.",
    })
  }
  if (input.godownActive === false) {
    blockers.push({
      code: "godown",
      message: "This godown is inactive. Operational rejection is not allowed.",
    })
  }
  return blockers
}

export function canRejectDamageReport(
  input: Parameters<typeof collectRejectBlockers>[0],
) {
  return collectRejectBlockers(input).length === 0
}

/**
 * UX gate matching post_ordinary_damage_writeoff.
 * Inbound and transit have no on-hand stock to post. Remaining holds are
 * required. Open exceptional requests block ordinary write-off.
 */
export function collectOrdinaryWriteoffBlockers(input: {
  status: string
  scenario: string
  canVerify: boolean
  hasFinalizedEvidence: boolean
  remainingHoldCases: number
  exceptionalOpen: boolean
  alreadyWrittenOff: boolean
  godownActive?: boolean | null
}): DamageDecisionBlocker[] {
  const blockers: DamageDecisionBlocker[] = []
  if (!input.canVerify) {
    blockers.push({
      code: "permission",
      message: "Ordinary write-off requires damage.verify.",
    })
  }
  const statusReady =
    input.status === "verified" ||
    (input.scenario === "shop_return" && input.status === "rejected")
  if (!statusReady) {
    blockers.push({
      code: "status",
      message:
        "Ordinary write-off requires a verified report, or a rejected shop-return still holding quarantine stock.",
    })
  }
  if (scenarioMaySubmitWithoutHold(input.scenario)) {
    blockers.push({
      code: "scenario",
      message: "This damage report has no on-hand stock to post.",
    })
  }
  if (!input.hasFinalizedEvidence) {
    blockers.push({
      code: "evidence",
      message: "Finalized photographic evidence is required.",
    })
  }
  if (input.alreadyWrittenOff) {
    blockers.push({
      code: "posted",
      message: "An ordinary write-off is already posted for this report.",
    })
  }
  if (input.remainingHoldCases < 1 && !input.alreadyWrittenOff) {
    blockers.push({
      code: "holds",
      message: "No isolated damage quantity remains to write off.",
    })
  }
  if (input.exceptionalOpen) {
    blockers.push({
      code: "exceptional",
      message: "An exceptional disposition is already open.",
    })
  }
  if (input.godownActive === false) {
    blockers.push({
      code: "godown",
      message:
        "This godown is inactive. Operational write-offs are not allowed.",
    })
  }
  return blockers
}

export function canPostOrdinaryDamageWriteoff(
  input: Parameters<typeof collectOrdinaryWriteoffBlockers>[0],
) {
  return collectOrdinaryWriteoffBlockers(input).length === 0
}

export function isValidDecisionReason(value: string) {
  const cleaned = value.trim()
  return cleaned.length >= 1 && cleaned.length <= 500
}

export type VerificationQueueState =
  | "awaiting"
  | "blocked_evidence"
  | "blocked_isolation"
  | "self"
  | "returned"
  | "rejected"
  | "verified"
  | "other"

/** Queue labels from persisted list facts, not inferred-only status. */
export function verificationQueueState(input: {
  status: string
  scenario: string
  reporterUserId?: string | null
  currentUserId?: string | null
  hasFinalizedEvidence?: boolean
  isolatedCases?: number
  reportedCases?: number
}): VerificationQueueState {
  if (input.status === "returned") return "returned"
  if (input.status === "rejected") return "rejected"
  if (input.status === "verified") return "verified"
  if (input.status !== "submitted") return "other"
  if (input.reporterUserId && input.reporterUserId === input.currentUserId) {
    return "self"
  }
  if (!input.hasFinalizedEvidence) return "blocked_evidence"
  if (
    scenarioRequiresStockHold(input.scenario) &&
    (input.isolatedCases ?? 0) < 1
  ) {
    return "blocked_isolation"
  }
  return "awaiting"
}

export function formatVerificationQueueState(state: VerificationQueueState) {
  switch (state) {
    case "awaiting":
      return "Eligible for verification"
    case "blocked_evidence":
      return "Blocked — missing evidence"
    case "blocked_isolation":
      return "Blocked — incomplete isolation"
    case "self":
      return "Blocked — reporter cannot self-verify"
    case "returned":
      return "Returned for correction"
    case "rejected":
      return "Rejected"
    case "verified":
      return "Verified"
    default:
      return "Not in verification queue"
  }
}

export function isSupportedDamagePhotoMime(mime: string) {
  const normalized = mime.toLowerCase() === "image/jpg" ? "image/jpeg" : mime
  return (damagePhotoMimeTypes as readonly string[]).includes(normalized)
}
