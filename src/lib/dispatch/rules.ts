/** Dispatch sidecar statuses. Order.status stays verified until cancel. */
export const dispatchRequestStatuses = [
  "ready_for_dispatch",
  "preparing",
  "dispatched",
  "in_transit",
  "delivered",
  "exception",
  "cancelled",
] as const

export type DispatchRequestStatus = (typeof dispatchRequestStatuses)[number]

export const dispatchStatusLabel: Record<DispatchRequestStatus, string> = {
  ready_for_dispatch: "Ready for dispatch",
  preparing: "Preparing",
  dispatched: "Dispatched",
  in_transit: "Out for delivery",
  delivered: "Delivered",
  exception: "Delivery exception",
  cancelled: "Cancelled",
}

export const dispatchStatusTone: Record<
  DispatchRequestStatus,
  "neutral" | "info" | "success" | "warning" | "danger"
> = {
  ready_for_dispatch: "success",
  preparing: "warning",
  dispatched: "info",
  in_transit: "info",
  delivered: "success",
  exception: "danger",
  cancelled: "danger",
}

export const dispatchEventLabel: Record<string, string> = {
  prepared: "Dispatch prepared",
  cancelled: "Dispatch cancelled",
  dispatched: "Stock consumed",
  assigned: "Delivery assigned",
  in_transit: "Out for delivery",
  delivered: "Delivery acknowledged",
  exception_recorded: "Delivery exception",
  partial_recorded: "Partial delivery recorded",
  return_posted: "Delivery return posted",
  return_closed_missing: "Missing return closed",
}

export const deliveryReturnStatusLabel: Record<string, string> = {
  awaiting_handback: "Awaiting driver handback",
  handed_back: "Handed back — awaiting count",
  counted: "Counted — awaiting approval",
  approved: "Approved — awaiting stock posting",
  posted: "Returned to stock",
  closed_missing: "Closed — missing, no stock credit",
  cancelled: "Return cancelled",
}

export const deliveryReturnStatusTone: Record<
  string,
  "neutral" | "info" | "success" | "warning" | "danger"
> = {
  awaiting_handback: "warning",
  handed_back: "info",
  counted: "info",
  approved: "warning",
  posted: "success",
  closed_missing: "danger",
  cancelled: "danger",
}

export const deliveryReturnEventLabel: Record<string, string> = {
  opened: "Return opened",
  handed_back: "Driver handback",
  counted: "Store Keeper count",
  approved: "Godown Manager approved",
  returned_to_count: "Sent back to count",
  posted: "Stock credited",
  closed_missing: "Closed as missing",
  cancelled: "Return cancelled",
}

export const vehicleTypeLabel: Record<string, string> = {
  truck: "Truck",
  van: "Van",
  two_wheeler: "Two-wheeler",
  other: "Other",
}

/** Reassignment is allowed only after consume and before the run starts. */
export function canReassignDelivery(
  status: DispatchRequestStatus,
  stockConsumed: boolean,
) {
  return stockConsumed && status === "dispatched"
}

/** Start requires a posted dispatch plus an assigned driver and vehicle. */
export function canStartDelivery(input: {
  status: DispatchRequestStatus
  assignedTo: string | null
  vehicleId: string | null
}) {
  return input.status === "dispatched" && Boolean(input.assignedTo) && Boolean(input.vehicleId)
}

export function isStaleDispatchVersion(error: { message: string; code?: string }) {
  return error.code === "PT409" || /changed by someone else/i.test(error.message)
}

/** Dual-write off is a hard dispatch blocker; there is no aggregate-only fallback. */
export function cutoverBlocksDispatch(input: {
  dual_write_enabled: boolean
  aggregate_only_blocked: boolean
}) {
  if (!input.dual_write_enabled) {
    return "Lot-aware dispatch requires dual-write to be enabled. Aggregate-only stock has no valid lot identities."
  }
  return null
}

/** Dual-write off is a hard return-posting blocker; there is no aggregate credit path. */
export function cutoverBlocksDeliveryReturn(dualWriteEnabled: boolean) {
  if (!dualWriteEnabled) {
    return "Lot-aware delivery returns require dual-write. Aggregate-only credit is not allowed."
  }
  return null
}

export function lotClassificationTotal(input: {
  delivered_cases: number
  saleable_cases: number
  damaged_cases: number
  uncertain_cases: number
  missing_cases: number
}) {
  return (
    input.delivered_cases +
    input.saleable_cases +
    input.damaged_cases +
    input.uncertain_cases +
    input.missing_cases
  )
}
