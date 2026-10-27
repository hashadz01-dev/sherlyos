import type { StatusTone } from "@/components/shared/StatusBadge"
import type {
  RefillAcknowledgementStatus,
  RefillCommunicationChannel,
  RefillCommunicationStatus,
  RefillDispatchStatus,
  RefillReceivingCompletionLabel,
  RefillStatus,
} from "@/lib/refill/rules"

export const refillStatusLabels: Record<RefillStatus, string> = {
  draft: "Draft",
  submitted: "Submitted",
  held: "Held",
  approved: "Approved",
  rejected: "Rejected",
}

export const refillCommunicationLabels: Record<RefillCommunicationStatus, string> = {
  not_sent: "Not sent",
  sent: "Sent — manually recorded",
}

export const refillAcknowledgementLabels: Record<RefillAcknowledgementStatus, string> =
  {
    none: "Not sent",
    pending: "Awaiting supplier response",
    acknowledged: "Supplier acknowledged — manually recorded",
    declined: "Supplier declined",
  }

export const refillDispatchLabels: Record<RefillDispatchStatus, string> = {
  not_recorded: "Dispatch not recorded",
  recorded: "Supplier dispatch recorded",
}

export const refillChannelLabels: Record<RefillCommunicationChannel, string> = {
  phone: "Phone",
  whatsapp: "WhatsApp",
  email: "Email",
  other: "Other",
}

export const refillCommunicationTone: Record<RefillCommunicationStatus, StatusTone> = {
  not_sent: "neutral",
  sent: "info",
}

export const refillAcknowledgementTone: Record<RefillAcknowledgementStatus, StatusTone> =
  {
    none: "neutral",
    pending: "warning",
    acknowledged: "success",
    declined: "danger",
  }

export const refillDispatchTone: Record<RefillDispatchStatus, StatusTone> = {
  not_recorded: "neutral",
  recorded: "info",
}

export const refillStatusTone: Record<RefillStatus, StatusTone> = {
  draft: "neutral",
  submitted: "info",
  held: "warning",
  approved: "success",
  rejected: "danger",
}

export const refillEventLabels: Record<string, string> = {
  created: "Request created",
  updated: "Request updated",
  submitted: "Submitted for Admin review",
  held: "Held for correction",
  resubmitted: "Resubmitted for Admin review",
  approved: "Approved — not a stock receipt",
  rejected: "Rejected",
  sent_to_supplier: "Marked as sent — manually recorded",
  supplier_acknowledged: "Supplier acknowledged — manually recorded",
  supplier_declined: "Supplier declined",
  supplier_acknowledgement_corrected: "Supplier acknowledgement corrected",
  supplier_dispatch_recorded: "Supplier dispatch recorded",
  supplier_dispatch_corrected: "Supplier dispatch corrected",
}

export function formatRefillCommunication(status: string) {
  return refillCommunicationLabels[status as RefillCommunicationStatus] ?? status
}

export function formatRefillAcknowledgement(status: string) {
  return (
    refillAcknowledgementLabels[status as RefillAcknowledgementStatus] ?? status
  )
}

export function formatRefillDispatch(status: string) {
  return refillDispatchLabels[status as RefillDispatchStatus] ?? status
}

export function formatRefillChannel(channel: string) {
  return refillChannelLabels[channel as RefillCommunicationChannel] ?? channel
}

export function formatDateOnly(value: string | null | undefined) {
  if (!value) return "—"
  const date = new Date(`${value}T00:00:00`)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleDateString()
}

export function formatRefillStatus(status: string) {
  return refillStatusLabels[status as RefillStatus] ?? status
}

export function formatRefillEvent(action: string) {
  return refillEventLabels[action] ?? action.replaceAll("_", " ")
}

export function formatCases(value: number | null | undefined) {
  const amount = Number(value ?? 0)
  if (!Number.isFinite(amount)) return "0 cases"
  return `${amount} ${amount === 1 ? "case" : "cases"}`
}

export function formatTimestamp(value: string | null | undefined) {
  if (!value) return "—"
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString()
}

/** Operator copy for persisted M6.4 reconciliation labels. */
export const refillReceivingLabelCopy: Record<RefillReceivingCompletionLabel, string> =
  {
    not_started: "No verified receipts yet",
    pending_verification: "Receiving pending verification",
    partially_received: "Partially received",
    fully_received: "Fully received against requested quantities",
    excess_requires_review: "Excess quantity requires review",
  }

export function formatRefillReceivingLabel(label: string) {
  return (
    refillReceivingLabelCopy[label as RefillReceivingCompletionLabel] ?? label
  )
}

export const receiptStatusLabels: Record<string, string> = {
  draft: "Draft — reserves requested quantity",
  submitted: "Submitted — pending verification",
  held: "Held",
  posted: "Verified and posted",
  cancelled: "Cancelled — no longer reserved",
}

export function formatLinkedReceiptStatus(status: string) {
  return receiptStatusLabels[status] ?? status
}

export const receiptStatusTone: Record<string, StatusTone> = {
  draft: "warning",
  submitted: "info",
  held: "warning",
  posted: "success",
  cancelled: "neutral",
}
