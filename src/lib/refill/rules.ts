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

/** M6.3 supplier-communication states. Separate from Admin approval status. */
export const refillCommunicationStatuses = ["not_sent", "sent"] as const
export type RefillCommunicationStatus = (typeof refillCommunicationStatuses)[number]

export const refillAcknowledgementStatuses = [
  "none",
  "pending",
  "acknowledged",
  "declined",
] as const
export type RefillAcknowledgementStatus =
  (typeof refillAcknowledgementStatuses)[number]

export const refillDispatchStatuses = ["not_recorded", "recorded"] as const
export type RefillDispatchStatus = (typeof refillDispatchStatuses)[number]

export const refillCommunicationChannels = [
  "phone",
  "whatsapp",
  "email",
  "other",
] as const
export type RefillCommunicationChannel = (typeof refillCommunicationChannels)[number]

export function isRefillCommunicationChannel(
  value: string,
): value is RefillCommunicationChannel {
  return (refillCommunicationChannels as readonly string[]).includes(value)
}

/**
 * Accounts may attest a first send only on an approved, unsent request.
 * Backend still re-checks permission, godown activity, and uniqueness.
 */
export function canRecordRefillSend(input: {
  status: RefillStatus
  communicationStatus: RefillCommunicationStatus
  godownActive: boolean
  canRequest: boolean
}) {
  return (
    input.canRequest &&
    input.status === "approved" &&
    input.communicationStatus === "not_sent" &&
    input.godownActive
  )
}

/** Acknowledgement (or audited correction) requires a recorded send. */
export function canRecordRefillAcknowledgement(input: {
  status: RefillStatus
  communicationStatus: RefillCommunicationStatus
  godownActive: boolean
  canRequest: boolean
}) {
  return (
    input.canRequest &&
    input.status === "approved" &&
    input.communicationStatus === "sent" &&
    input.godownActive
  )
}

/** Dispatch is blocked while the supplier response is declined. */
export function canRecordRefillDispatch(input: {
  status: RefillStatus
  communicationStatus: RefillCommunicationStatus
  acknowledgementStatus: RefillAcknowledgementStatus
  godownActive: boolean
  canRequest: boolean
}) {
  return (
    input.canRequest &&
    input.status === "approved" &&
    input.communicationStatus === "sent" &&
    input.acknowledgementStatus !== "declined" &&
    input.godownActive
  )
}

export function isValidRefillShortText(value: string, required = false) {
  const cleaned = value.trim()
  if (cleaned.length === 0) return !required
  return cleaned.length <= 120
}

export function refillSessionIdempotencyKey(
  storageKey: string,
  existing?: string | null,
) {
  if (existing && /^[A-Za-z0-9_-]{8,80}$/.test(existing)) return existing
  if (typeof sessionStorage !== "undefined") {
    const stored = sessionStorage.getItem(storageKey)
    if (stored && /^[A-Za-z0-9_-]{8,80}$/.test(stored)) return stored
  }
  const generated = refillCreateIdempotencyKey()
  if (typeof sessionStorage !== "undefined") {
    sessionStorage.setItem(storageKey, generated)
  }
  return generated
}

export function clearRefillSessionIdempotencyKey(storageKey: string) {
  if (typeof sessionStorage !== "undefined") {
    sessionStorage.removeItem(storageKey)
  }
}
