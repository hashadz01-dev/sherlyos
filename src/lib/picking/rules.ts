/** Warehouse picking statuses. Order.status stays verified until cancel. */
export const pickingRequestStatuses = [
  "pending_allocation",
  "allocated",
  "picking",
  "picked",
  "ready_for_dispatch",
  "cancelled",
  "blocked",
] as const

export type PickingRequestStatus = (typeof pickingRequestStatuses)[number]

export const pickingExceptionTypes = [
  "shortage",
  "expired_stock",
  "unknown_legacy",
  "missing_received_on",
  "unclassified",
  "cutover_blocked",
  "stale",
  "conflict",
  "cancelled",
] as const

export type PickingExceptionType = (typeof pickingExceptionTypes)[number]

export const pickingStatusLabel: Record<PickingRequestStatus, string> = {
  pending_allocation: "Pending allocation",
  allocated: "Allocated",
  picking: "Picking",
  picked: "Picked",
  ready_for_dispatch: "Ready for dispatch",
  cancelled: "Cancelled",
  blocked: "Blocked",
}

export const pickingStatusTone: Record<
  PickingRequestStatus,
  "neutral" | "info" | "success" | "warning" | "danger"
> = {
  pending_allocation: "neutral",
  allocated: "info",
  picking: "warning",
  picked: "info",
  ready_for_dispatch: "success",
  cancelled: "danger",
  blocked: "danger",
}

export const pickingEventLabel: Record<string, string> = {
  allocated: "Reservation confirmed",
  assigned: "Task assigned",
  picking_started: "Picking started",
  quantity_confirmed: "Quantity confirmed",
  exception_recorded: "Exception recorded",
  reservation_released: "Reservation released",
  picking_completed: "Picking completed",
  handed_off: "Ready for dispatch",
  cancelled: "Cancelled",
  blocked: "Blocked",
}

export function isStalePickingVersion(error: { message: string; code?: string }) {
  return error.code === "PT409" || /changed by someone else/i.test(error.message)
}

/** Remaining cartons the picker still owes against the hold. */
export function remainingCases(reserved: number, picked: number) {
  return Math.max(reserved - picked, 0)
}

export function cutoverBlocksPicking(input: {
  dual_write_enabled: boolean
  aggregate_only_blocked: boolean
}) {
  if (!input.dual_write_enabled) {
    return "Lot-aware picking requires dual-write to be enabled. Aggregate-only stock has no valid lot identities."
  }
  return null
}

/**
 * Production cutover flags stay false, so never present short-shipment as
 * live warehouse stock movement. The approval workflow itself is implemented.
 */
export const SHORT_SHIPMENT_OPERATIONAL = false

export const shortShipmentNotOperationalMessage =
  "Create a short-shipment document. Godown Manager confirms picked lots; Accounts approves shipped quantities before handoff. Dispatch stays blocked until lot cutover."

export type PickingFulfilment = {
  ordered_cases: number
  allocated_cases: number
  picked_cases: number
  remaining_cases: number
  shortfall_cases: number
  shortage_cases: number
  has_shortage: boolean
  short_shipment_operational: boolean
  short_shipment_workflow: boolean
  proposed_shipment_cases: number
  approved_shipment_cases: number
  dispatched_cases: number
  outstanding_cases: number
  shipment_status: string | null
  shipment_number: string | null
  shipment_revision: number | null
  gm_confirmed: boolean
  accounts_approved: boolean
}

const emptyFulfilment = (): PickingFulfilment => ({
  ordered_cases: 0,
  allocated_cases: 0,
  picked_cases: 0,
  remaining_cases: 0,
  shortfall_cases: 0,
  shortage_cases: 0,
  has_shortage: false,
  short_shipment_operational: false,
  short_shipment_workflow: true,
  proposed_shipment_cases: 0,
  approved_shipment_cases: 0,
  dispatched_cases: 0,
  outstanding_cases: 0,
  shipment_status: null,
  shipment_number: null,
  shipment_revision: null,
  gm_confirmed: false,
  accounts_approved: false,
})

export function parsePickingFulfilment(raw: unknown): PickingFulfilment {
  if (!raw || typeof raw !== "object") return emptyFulfilment()
  const record = raw as Record<string, unknown>
  return {
    ordered_cases: Number(record.ordered_cases ?? 0),
    allocated_cases: Number(record.allocated_cases ?? 0),
    picked_cases: Number(record.picked_cases ?? 0),
    remaining_cases: Number(record.remaining_cases ?? 0),
    shortfall_cases: Number(record.shortfall_cases ?? 0),
    shortage_cases: Number(record.shortage_cases ?? 0),
    has_shortage: record.has_shortage === true,
    // Live stock movement still requires cutover flags. Ignore any payload
    // that claims short-shipment is operational while they remain false.
    short_shipment_operational: false,
    short_shipment_workflow: record.short_shipment_workflow === true,
    proposed_shipment_cases: Number(record.proposed_shipment_cases ?? 0),
    approved_shipment_cases: Number(record.approved_shipment_cases ?? 0),
    dispatched_cases: Number(record.dispatched_cases ?? 0),
    outstanding_cases: Number(record.outstanding_cases ?? 0),
    shipment_status: record.shipment_status ? String(record.shipment_status) : null,
    shipment_number: record.shipment_number ? String(record.shipment_number) : null,
    shipment_revision: record.shipment_revision == null ? null : Number(record.shipment_revision),
    gm_confirmed: record.gm_confirmed === true,
    accounts_approved: record.accounts_approved === true,
  }
}

export function pickingHasShortage(exceptions: { exception_type: string }[]) {
  return exceptions.some((item) => item.exception_type === "shortage")
}

export type OrderPickingNextActionInput = {
  orderStatus: string
  dnStatus: string | null | undefined
  pickingStatus: string | null | undefined
  hasShortage: boolean
  cutoverBlocked: boolean
  shipmentStatus?: string | null
  fulfilmentStatus?: string | null
}

/** Operator-facing next step. Verified does not mean reserved. */
export function nextOrderPickingAction(input: OrderPickingNextActionInput) {
  if (input.orderStatus === "cancelled") return "Order is cancelled."
  if (input.orderStatus === "draft") return "Submit the order."
  if (input.orderStatus === "held") return "Correct the order and resubmit."
  if (input.orderStatus === "submitted") {
    return "Verify using picking-eligible ATP. Verification does not reserve stock."
  }
  if (input.orderStatus !== "verified") return "No picking action on this order."
  if (input.fulfilmentStatus === "partially_fulfilled") {
    return "Original order is partially fulfilled. Outstanding cases are on the linked backorder."
  }
  if (input.hasShortage || input.shipmentStatus) {
    if (input.shipmentStatus === "dispatched") {
      return "Short shipment dispatched. Outstanding cases are on the linked backorder."
    }
    if (input.shipmentStatus === "approved") {
      if (input.pickingStatus === "ready_for_dispatch") {
        return input.cutoverBlocked
          ? "Approved short-shipment is ready. Dispatch stays blocked until lot cutover."
          : "Prepare dispatch. confirm_dispatch will deduct only approved shipped lots."
      }
      return input.cutoverBlocked
        ? "Accounts approved the short-shipment quantities. Godown Manager can mark ready for dispatch. Stock deduction stays blocked until lot cutover."
        : "Accounts approved the short-shipment quantities. Godown Manager can mark ready for dispatch."
    }
    if (input.shipmentStatus === "gm_confirmed") {
      return "Godown Manager confirmed picked quantities. Accounts must approve the commercial shipped quantities."
    }
    if (input.shipmentStatus === "draft") {
      return "Godown Manager must confirm the picked quantities on this short-shipment document."
    }
    return shortShipmentNotOperationalMessage
  }
  if (input.pickingStatus === "ready_for_dispatch") {
    return "Prepare dispatch. confirm_dispatch is the stock writer."
  }
  if (input.pickingStatus === "picked") {
    return "Godown Manager can mark ready for dispatch after a full pick."
  }
  if (input.pickingStatus === "picking" || input.pickingStatus === "allocated") {
    return "Continue warehouse picking. Reserved quantity is a hold, not a ledger debit."
  }
  if (input.pickingStatus === "blocked") {
    return "Picking is blocked. Resolve the exception or cancel and reallocate."
  }
  if (input.cutoverBlocked) {
    return "Lot-aware picking is blocked until dual-write cutover."
  }
  if (!input.dnStatus) {
    return "Create and send the delivery note. Godown Manager must acknowledge it before allocation."
  }
  if (input.dnStatus !== "acknowledged") {
    return "Wait for Godown Manager acknowledgement. Allocation is blocked until the delivery note is acknowledged."
  }
  return "Allocate FEFO/FIFO reservations. A verified order does not guarantee reserved stock."
}
