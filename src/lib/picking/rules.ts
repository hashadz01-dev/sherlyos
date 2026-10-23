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
