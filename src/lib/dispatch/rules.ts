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
