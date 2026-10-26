import type { StatusTone } from "@/components/shared/StatusBadge"
import type { DamageScenario, DamageStatus } from "@/lib/damage/rules"

export const damageScenarioLabels: Record<DamageScenario, string> = {
  refill_supply: "Refill supply",
  unloading: "Unloading",
  storage: "Storage",
  loading: "Loading",
  transit: "Transit",
  shop_return: "Shop return",
}

export const damageScenarioDescriptions: Record<DamageScenario, string> = {
  refill_supply:
    "DMG-01. Damaged cases recorded on a posted supplier or refill receipt. Accepted stock is not reduced.",
  unloading:
    "DMG-02. Unloading damage against a posted receiving document. Uses remaining receipt damaged cases.",
  storage:
    "DMG-03. Damage found in an authorized godown crate. Submission isolates on-hand stock when isolation is ready.",
  loading:
    "DMG-04. Damage against an eligible picking allocation before dispatch is consumed. Converts the reservation when isolation is ready.",
  transit:
    "DMG-05. Damage on an assigned consumed dispatch. Delivery Persons may report only their assigned runs.",
  shop_return:
    "DMG-06. Shop, expired, or returned-goods damage. Physical custody confirmation is a later authorized workflow.",
}

export const damageStatusLabels: Record<DamageStatus, string> = {
  draft: "Draft",
  submitted: "Submitted",
  returned: "Returned",
  verified: "Verified",
  cancelled: "Cancelled",
  rejected: "Rejected",
}

export const damageStatusTone: Record<DamageStatus, StatusTone> = {
  draft: "neutral",
  submitted: "info",
  returned: "warning",
  verified: "success",
  cancelled: "danger",
  rejected: "danger",
}

export const damageHoldKindLabels: Record<string, string> = {
  on_hand_deduction: "On-hand hold",
  reservation_conversion: "Reservation conversion",
  quarantine_intake: "Quarantine intake",
}

export const damageHoldStatusLabels: Record<string, string> = {
  active: "Active hold",
  released: "Released",
  transferred: "In quarantine crate",
  written_off: "Written off",
  returned_supplier: "Returned to supplier",
}

export function formatDamageScenario(scenario: string) {
  return damageScenarioLabels[scenario as DamageScenario] ?? scenario
}

export function formatDamageStatus(status: string) {
  return damageStatusLabels[status as DamageStatus] ?? status
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

export function formatDate(value: string | null | undefined) {
  if (!value) return "—"
  return value.slice(0, 10)
}

/** Safe activity note: strip internal tokens from event metadata. */
export function activityNote(
  metadata: Record<string, unknown> | null | undefined,
) {
  if (!metadata) return null
  const note =
    (typeof metadata.note === "string" && metadata.note) ||
    (typeof metadata.reason === "string" && metadata.reason) ||
    (typeof metadata.decision_reason === "string" &&
      metadata.decision_reason) ||
    null
  return note
}

export function readinessMessage(stockHoldReady: boolean) {
  if (stockHoldReady) {
    return "Stock-affecting damage isolation is enabled for this environment."
  }
  return "Stock-affecting damage submission is unavailable. Holds and quarantine transfers stay inactive until readiness is enabled by operations."
}

export function sourceReferenceLabel(summary: {
  scenario: string
  receipt_id?: string | null
  picking_request_id?: string | null
  dispatch_id?: string | null
  order_id?: string | null
  shop_id?: string | null
}) {
  if (summary.receipt_id) return `Receipt ${summary.receipt_id.slice(0, 8)}`
  if (summary.picking_request_id)
    return `Picking ${summary.picking_request_id.slice(0, 8)}`
  if (summary.dispatch_id) return `Dispatch ${summary.dispatch_id.slice(0, 8)}`
  if (summary.order_id) return `Order ${summary.order_id.slice(0, 8)}`
  if (summary.shop_id) return `Shop ${summary.shop_id.slice(0, 8)}`
  return "—"
}
