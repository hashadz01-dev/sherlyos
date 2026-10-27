/** Operational shipment document statuses. Not a tax invoice. */
export const shipmentStatuses = [
  "draft",
  "gm_confirmed",
  "approved",
  "dispatched",
  "cancelled",
] as const

export type ShipmentStatus = (typeof shipmentStatuses)[number]

export const shipmentStatusLabel: Record<ShipmentStatus, string> = {
  draft: "Draft shipment",
  gm_confirmed: "GM confirmed",
  approved: "Accounts approved",
  dispatched: "Dispatched",
  cancelled: "Cancelled",
}

export const shipmentStatusTone: Record<
  ShipmentStatus,
  "neutral" | "info" | "success" | "warning" | "danger"
> = {
  draft: "neutral",
  gm_confirmed: "info",
  approved: "success",
  dispatched: "success",
  cancelled: "danger",
}

export type ShipmentLot = {
  id: string
  reservation_id: string
  order_line_id: string
  product_id: string
  sku: string
  product_name: string
  lot_id: string
  crate_id: string
  crate_code: string
  zone_code: string
  manufacturer_lot_code: string | null
  expiry_date: string | null
  reserved_cases: number
  picked_cases: number
  proposed_cases: number
  approved_cases: number
  shipped_cases: number
  released_cases: number
}

export type ShipmentSummary = {
  id: string
  shipment_number: string
  status: ShipmentStatus
  revision: number
  version: number
  delivery_note_id?: string | null
  dispatch_request_id?: string | null
  backorder_id?: string | null
  gm_confirmed_at?: string | null
  accounts_approved_at?: string | null
  ordered_cases?: number
  picked_cases?: number
  approved_cases?: number
  proposed_cases?: number
  shipped_cases?: number
  outstanding_cases?: number
  lots?: ShipmentLot[]
}

export function isShipmentStatus(value: string | null | undefined): value is ShipmentStatus {
  return shipmentStatuses.includes(value as ShipmentStatus)
}

export function parseShipmentSummary(raw: unknown): ShipmentSummary | null {
  if (!raw || typeof raw !== "object") return null
  const record = raw as Record<string, unknown>
  if (typeof record.id !== "string" || !isShipmentStatus(String(record.status ?? ""))) {
    return null
  }
  return {
    id: record.id,
    shipment_number: String(record.shipment_number ?? ""),
    status: record.status as ShipmentStatus,
    revision: Number(record.revision ?? 1),
    version: Number(record.version ?? 1),
    delivery_note_id: record.delivery_note_id ? String(record.delivery_note_id) : null,
    dispatch_request_id: record.dispatch_request_id
      ? String(record.dispatch_request_id)
      : null,
    backorder_id: record.backorder_id ? String(record.backorder_id) : null,
    gm_confirmed_at: record.gm_confirmed_at ? String(record.gm_confirmed_at) : null,
    accounts_approved_at: record.accounts_approved_at
      ? String(record.accounts_approved_at)
      : null,
    ordered_cases: Number(record.ordered_cases ?? 0),
    picked_cases: Number(record.picked_cases ?? 0),
    approved_cases: Number(record.approved_cases ?? 0),
    proposed_cases: Number(record.proposed_cases ?? 0),
    shipped_cases: Number(record.shipped_cases ?? 0),
    outstanding_cases: Number(record.outstanding_cases ?? 0),
    lots: Array.isArray(record.lots) ? (record.lots as ShipmentLot[]) : undefined,
  }
}

/**
 * Operator copy. Cutover still blocks live stock movement even after Accounts
 * approves, so this never claims warehouse short-shipment is live-operational.
 */
export function shortShipmentNextAction(input: {
  hasShortage: boolean
  shipmentStatus: ShipmentStatus | null
  pickingStatus: string | null | undefined
  cutoverBlocked: boolean
}) {
  if (!input.hasShortage && !input.shipmentStatus) return null
  if (input.shipmentStatus === "dispatched") {
    return "Short shipment dispatched. Outstanding cases are on the linked backorder. The original order is not fully fulfilled."
  }
  if (input.shipmentStatus === "cancelled") {
    return "Short-shipment document was cancelled. Recreate it from the current picked lots before handoff."
  }
  if (input.shipmentStatus === "approved") {
    if (input.pickingStatus === "picked") {
      return input.cutoverBlocked
        ? "Accounts approved the short-shipment quantities. Godown Manager can mark ready for dispatch. Stock deduction stays blocked until lot cutover."
        : "Accounts approved the short-shipment quantities. Godown Manager can mark ready for dispatch. confirm_dispatch will deduct only approved shipped lots."
    }
    return input.cutoverBlocked
      ? "Approved short-shipment is ready. Dispatch stays blocked until lot cutover."
      : "Approved short-shipment is ready for dispatch. confirm_dispatch deducts only approved shipped lots."
  }
  if (input.shipmentStatus === "gm_confirmed") {
    return "Godown Manager confirmed picked quantities. Accounts must approve the commercial shipped quantities."
  }
  if (input.shipmentStatus === "draft") {
    return "Godown Manager must confirm the picked quantities on this short-shipment document."
  }
  if (input.hasShortage) {
    return "Create a short-shipment document. Godown Manager confirms picked lots; Accounts approves shipped quantities before handoff. Dispatch stays blocked until lot cutover."
  }
  return null
}
