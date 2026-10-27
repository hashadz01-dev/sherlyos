import type { StatusTone } from "@/components/shared/StatusBadge"
import type { RefillStatus } from "@/lib/refill/rules"

export const refillStatusLabels: Record<RefillStatus, string> = {
  draft: "Draft",
  submitted: "Submitted",
  held: "Held",
  approved: "Approved",
  rejected: "Rejected",
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
