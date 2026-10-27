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
 * D4 is approved in principle only. Dispatch still requires a full order fill.
 * Do not present short-shipment as an operational path.
 */
export const SHORT_SHIPMENT_OPERATIONAL = false

export const shortShipmentNotOperationalMessage =
  "Controlled short-shipment is not operational. Dispatch still requires a full order fill. Cancel this picking request and reallocate, or pick every reserved carton."

export type PickingFulfilment = {
  ordered_cases: number
  allocated_cases: number
  picked_cases: number
  remaining_cases: number
  shortfall_cases: number
  shortage_cases: number
  has_shortage: boolean
  short_shipment_operational: boolean
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
    // D4 is not operational yet. Ignore any payload that claims otherwise.
    short_shipment_operational: false,
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
  if (input.hasShortage) return shortShipmentNotOperationalMessage
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
