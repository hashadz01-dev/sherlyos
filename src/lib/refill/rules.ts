/** M6.2 refill request statuses. Must match stock_refill_requests.status. */
export const refillStatuses = [
  "draft",
  "submitted",
  "held",
  "approved",
  "rejected",
] as const

export type RefillStatus = (typeof refillStatuses)[number]

export const refillNavPermissions = ["refill.request", "refill.approve"] as const

export const refillCreatePermissions = ["refill.request"] as const

export function isRefillStatus(value: string): value is RefillStatus {
  return (refillStatuses as readonly string[]).includes(value)
}

export function isEditableRefillStatus(status: RefillStatus) {
  return status === "draft" || status === "held"
}

export function isTerminalRefillStatus(status: RefillStatus) {
  return status === "rejected"
}

export function parseRequestedCases(raw: string | number) {
  const value = typeof raw === "number" ? raw : Number(String(raw).trim())
  if (!Number.isInteger(value) || value < 1 || value > 1_000_000) {
    return null
  }
  return value
}

export function validateRefillLines(
  lines: { product_id: string; requested_cases: number }[],
) {
  const errors: string[] = []
  if (lines.length < 1) {
    errors.push("Add at least one SKU line.")
  }
  const seen = new Set<string>()
  for (const line of lines) {
    if (!line.product_id) {
      errors.push("Each line needs a product.")
      continue
    }
    if (seen.has(line.product_id)) {
      errors.push("Duplicate SKU lines are not allowed.")
    }
    seen.add(line.product_id)
    if (parseRequestedCases(line.requested_cases) == null) {
      errors.push("Requested quantity must be a whole number of cases from 1 to 1,000,000.")
    }
  }
  return [...new Set(errors)]
}

export function isValidDecisionReason(reason: string) {
  const cleaned = reason.trim()
  return cleaned.length >= 1 && cleaned.length <= 500
}

export function canEditRefillRequest(input: {
  status: RefillStatus
  createdBy: string | null
  viewerId: string | null
  canRequest: boolean
}) {
  return (
    input.canRequest &&
    isEditableRefillStatus(input.status) &&
    Boolean(input.createdBy) &&
    input.createdBy === input.viewerId
  )
}

export function canSubmitRefillRequest(input: {
  status: RefillStatus
  createdBy: string | null
  viewerId: string | null
  canRequest: boolean
}) {
  return canEditRefillRequest(input)
}

export function canDecideRefillRequest(input: {
  status: RefillStatus
  canApprove: boolean
}) {
  return input.canApprove && input.status === "submitted"
}

export function refillCreateIdempotencyKey(existing?: string | null) {
  if (existing && /^[A-Za-z0-9_-]{8,80}$/.test(existing)) return existing
  return `rf-${crypto.randomUUID().replaceAll("-", "").slice(0, 24)}`
}

export function refillMutationIdempotencyKey(prefix: string, requestId: string) {
  const compact = requestId.replaceAll("-", "").slice(0, 20)
  return `${prefix}-${compact}`
}
