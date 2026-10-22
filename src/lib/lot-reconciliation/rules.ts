import { parseCaseCount } from "@/lib/verification/rules"

/** Session statuses returned by M1-S2.2. There is no applied state in this stage. */
export const lotReconciliationStatuses = [
  "draft",
  "submitted",
  "approved",
  "rejected",
  "cancelled",
] as const

export type LotReconciliationStatus = (typeof lotReconciliationStatuses)[number]

export const lotConditions = ["available", "quarantined", "expired"] as const

export type LotCondition = (typeof lotConditions)[number]

export type ExpiryPolicy = "expiry_controlled" | "non_expiring" | null

export type LotEvidenceDraft = {
  manufacturer_lot_code: string
  expiry_date: string
  expiry_unknown: boolean
  identity_unknown: boolean
  quantity: string
  condition: LotCondition
}

export type LotEvidenceRpc = {
  manufacturer_lot_code: string | null
  expiry_date: string | null
  expiry_unknown: boolean
  identity_unknown: boolean
  quantity: number
  condition: LotCondition
}

/** Why a line is shown as unmatched, not counted, or lot-invalid. */
export function lineVariance(expected: number, counted: number | null) {
  if (counted === null) return null
  return counted - expected
}

export function lineCountState(expected: number, counted: number | null) {
  if (counted === null) return "not_counted" as const
  const variance = counted - expected
  if (variance === 0) return "matched" as const
  if (variance < 0) return "shortage" as const
  return "excess" as const
}

export function lotQuantitySum(lots: { quantity: number }[]) {
  return lots.reduce((total, lot) => total + lot.quantity, 0)
}

export function lotBreakdownState(counted: number | null, lots: { quantity: number }[]) {
  if (counted === null) return "waiting" as const
  const sum = lotQuantitySum(lots)
  if (counted === 0) return lots.length === 0 ? ("complete" as const) : ("invalid" as const)
  if (lots.length === 0) return "missing" as const
  return sum === counted ? ("complete" as const) : ("invalid" as const)
}

/**
 * Client-side lot identity rules that mirror the RPC checks.
 * Unknown identity must not carry a fabricated code or date.
 */
export function lotEntryIssues(entry: LotEvidenceDraft, policy: ExpiryPolicy) {
  const issues: string[] = []
  const qty = parseCaseCount(entry.quantity)
  if (!qty.ok || qty.cases < 1) {
    issues.push("Each lot entry needs a whole carton quantity of at least 1.")
  }
  if (entry.identity_unknown) {
    if (entry.manufacturer_lot_code.trim()) {
      issues.push("Unknown identity cannot include a manufacturer lot code.")
    }
    if (entry.expiry_date.trim()) {
      issues.push("Unknown identity cannot include an expiry date.")
    }
    if (entry.condition === "expired") {
      issues.push("Unknown-identity lots cannot be marked expired without a date.")
    }
    return issues
  }
  if (!entry.manufacturer_lot_code.trim()) {
    issues.push("Enter a manufacturer lot code, or mark identity as unknown.")
  }
  if (entry.manufacturer_lot_code.trim().length > 80) {
    issues.push("Manufacturer lot code is too long.")
  }
  if (entry.expiry_unknown && entry.expiry_date.trim()) {
    issues.push("Clear the expiry date when expiry is unknown.")
  }
  if (!entry.expiry_unknown && !entry.expiry_date.trim() && policy === "expiry_controlled") {
    issues.push("Expiry-controlled lots need a date or an explicit unknown expiry.")
  }
  if (policy === "non_expiring" && (entry.expiry_date.trim() || entry.expiry_unknown)) {
    issues.push("Non-expiring products cannot carry expiry values.")
  }
  if (entry.condition === "expired" && !entry.expiry_date.trim()) {
    issues.push("Expired lots require an expiry date.")
  }
  return issues
}

export function lotsToRpc(entries: LotEvidenceDraft[]): LotEvidenceRpc[] {
  return entries.map((entry) => {
    const qty = parseCaseCount(entry.quantity)
    const identityUnknown = entry.identity_unknown
    return {
      manufacturer_lot_code: identityUnknown ? null : entry.manufacturer_lot_code.trim() || null,
      expiry_date:
        identityUnknown || entry.expiry_unknown || !entry.expiry_date.trim()
          ? null
          : entry.expiry_date.trim(),
      expiry_unknown: identityUnknown ? true : entry.expiry_unknown,
      identity_unknown: identityUnknown,
      quantity: qty.ok ? qty.cases : 0,
      condition: entry.condition,
    }
  })
}

export function emptyLotDraft(): LotEvidenceDraft {
  return {
    manufacturer_lot_code: "",
    expiry_date: "",
    expiry_unknown: false,
    identity_unknown: false,
    quantity: "",
    condition: "available",
  }
}

export function unknownIdentityDraft(quantity: string): LotEvidenceDraft {
  return {
    manufacturer_lot_code: "",
    expiry_date: "",
    expiry_unknown: true,
    identity_unknown: true,
    quantity,
    condition: "available",
  }
}

export function createSessionIssues(input: { godownId: string; crateIds: string[] }) {
  const issues: string[] = []
  if (!input.godownId) issues.push("Select a godown.")
  if (input.crateIds.length === 0) issues.push("Select at least one crate.")
  if (new Set(input.crateIds).size !== input.crateIds.length) {
    issues.push("Remove duplicate crate selections.")
  }
  return issues
}

export function cratesBelongToGodown(input: {
  crateIds: string[]
  crates: { id: string; zone_id: string }[]
  zones: { id: string; branch_id: string }[]
  godownId: string
}) {
  const zoneById = new Map(input.zones.map((zone) => [zone.id, zone]))
  return input.crateIds.every((crateId) => {
    const crate = input.crates.find((row) => row.id === crateId)
    if (!crate) return false
    return zoneById.get(crate.zone_id)?.branch_id === input.godownId
  })
}

export type SubmitSummary = {
  totalLines: number
  countedLines: number
  missingCounts: number
  lotMismatches: number
  unmatchedLines: number
  unclassifiedProducts: number
  foundProductLines: number
}

export function submitSummary(
  lines: {
    product_id: string
    expected_quantity: number
    counted_quantity: number | null
    is_found_product: boolean
    expiry_policy: ExpiryPolicy
    lots: { quantity: number }[]
  }[],
): SubmitSummary {
  return {
    totalLines: lines.length,
    countedLines: lines.filter((line) => line.counted_quantity !== null).length,
    missingCounts: lines.filter((line) => line.counted_quantity === null).length,
    lotMismatches: lines.filter((line) => {
      const state = lotBreakdownState(line.counted_quantity, line.lots)
      return state === "invalid" || state === "missing"
    }).length,
    unmatchedLines: lines.filter(
      (line) =>
        line.counted_quantity !== null
        && line.counted_quantity !== line.expected_quantity,
    ).length,
    unclassifiedProducts: new Set(
      lines
        .filter((line) => line.expiry_policy !== "expiry_controlled" && line.expiry_policy !== "non_expiring")
        .map((line) => line.product_id),
    ).size,
    foundProductLines: lines.filter((line) => line.is_found_product).length,
  }
}

/** Submit requires complete counts and lot totals. Match and classification are approval-only. */
export function canSubmitFromSummary(summary: SubmitSummary) {
  return summary.totalLines >= 0 && summary.missingCounts === 0 && summary.lotMismatches === 0
}

export function lotReconciliationActions(input: {
  status: LotReconciliationStatus
  isSubmitter: boolean
  canPhysical: boolean
  canAdmin: boolean
}) {
  const draft = input.status === "draft"
  const submitted = input.status === "submitted"
  const rejected = input.status === "rejected"
  return {
    saveCount: input.canPhysical && draft,
    saveLots: input.canPhysical && draft,
    foundProduct: input.canPhysical && draft,
    refresh: input.canPhysical && draft,
    submit: input.canPhysical && draft,
    approve: input.canAdmin && submitted && !input.isSubmitter,
    reject: input.canAdmin && submitted,
    reopen: input.canPhysical && rejected,
    cancel: input.canAdmin && (draft || rejected),
    /** Approved stays locked until M1-S3; cancelled is terminal. */
    immutable: input.status === "approved" || input.status === "cancelled" || submitted,
  }
}

export function isStaleVersionError(error: unknown) {
  if (!(error instanceof Error)) return false
  const code = "code" in error && typeof error.code === "string" ? error.code : ""
  return code === "PT409" || /changed by someone else/i.test(error.message)
}

export function reconciliationErrorMessage(error: unknown) {
  if (isStaleVersionError(error)) {
    return "This session was changed by someone else. Review the latest counts before saving again."
  }
  if (error instanceof Error && /overlapping lot reconciliation/i.test(error.message)) {
    return "An overlapping reconciliation already holds one of these crates. Cancel or finish that session first."
  }
  if (error instanceof Error && error.message.trim()) return error.message
  return "The reconciliation could not be saved."
}

export function eventLabel(eventType: string) {
  const labels: Record<string, string> = {
    created: "Session created",
    scope_assigned: "Crate scope assigned",
    count_saved: "Count saved",
    lots_saved: "Lot evidence saved",
    found_product_added: "Unexpected product recorded",
    expected_refreshed: "Expected stock refreshed",
    submitted: "Submitted",
    approved: "Approved",
    rejected: "Rejected",
    reopened: "Reopened",
    cancelled: "Cancelled",
  }
  return labels[eventType] ?? eventType.replaceAll("_", " ")
}

export function newIdempotencyKey(prefix: string) {
  return `${prefix}-${crypto.randomUUID()}`
}

export function lotDraftFromServer(lot: {
  manufacturer_lot_code: string | null
  expiry_date: string | null
  expiry_unknown: boolean
  identity_unknown: boolean
  quantity: number
  condition: LotCondition
}): LotEvidenceDraft {
  return {
    manufacturer_lot_code: lot.manufacturer_lot_code ?? "",
    expiry_date: lot.expiry_date ? lot.expiry_date.slice(0, 10) : "",
    expiry_unknown: lot.expiry_unknown,
    identity_unknown: lot.identity_unknown,
    quantity: String(lot.quantity),
    condition: lot.condition,
  }
}

export function formatTimestamp(value: string | null | undefined) {
  if (!value) return "—"
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return value
  return parsed.toLocaleString()
}

/** GM often lacks employees.read, so names are not on the payload. */
export function actorLabel(actorId: string | null | undefined, currentUserId: string | undefined) {
  if (!actorId) return "Unknown"
  if (currentUserId && actorId === currentUserId) return "You"
  return actorId.slice(0, 8)
}

export function countStateLabel(state: ReturnType<typeof lineCountState>) {
  if (state === "not_counted") return "Not counted"
  if (state === "matched") return "Matched"
  if (state === "shortage") return "Shortage"
  return "Excess"
}

export function lotStateLabel(state: ReturnType<typeof lotBreakdownState>) {
  if (state === "waiting") return "Waiting for count"
  if (state === "missing") return "Lot evidence missing"
  if (state === "invalid") return "Invalid lot breakdown"
  return "Lot evidence complete"
}

export function sessionListAction(input: {
  status: LotReconciliationStatus
  canPhysical: boolean
  canAdmin: boolean
}) {
  if (input.status === "draft" && input.canPhysical) return "Count"
  if (input.status === "submitted" && input.canAdmin) return "Review"
  if (input.status === "rejected" && input.canPhysical) return "Reopen"
  return "View"
}

export const statusTone: Record<
  LotReconciliationStatus,
  "neutral" | "info" | "success" | "warning" | "danger"
> = {
  draft: "neutral",
  submitted: "info",
  approved: "success",
  rejected: "danger",
  cancelled: "warning",
}
