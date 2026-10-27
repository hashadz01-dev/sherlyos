import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import type { DispatchRequestStatus } from "@/lib/dispatch/rules"
import { toUserRpcMessage } from "@/lib/rpc/user-error"

export class DispatchRpcError extends Error {
  readonly code: string

  constructor(message: string, code = "") {
    super(message)
    this.name = "DispatchRpcError"
    this.code = code
  }
}

export const dispatchKeys = {
  queue: (status: string) => ["dispatch-queue", status] as const,
  detail: (id: string) => ["dispatch-request", id] as const,
  preview: (orderId: string) => ["dispatch-preview", orderId] as const,
  assigned: ["delivery-runs"] as const,
  assignees: (branchId: string) => ["dispatch-assignees", branchId] as const,
}

export type DispatchReservation = {
  id: string
  order_line_id: string
  product_id: string
  sku: string
  product_name: string
  crate_id: string
  crate_code: string
  zone_code: string
  lot_id: string
  manufacturer_lot_code: string | null
  expiry_date: string | null
  received_on?: string | null
  lot_status?: string
  reserved_cases: number
  picked_cases: number
  status: string
}

export type DispatchAssignment = {
  id: string
  assignee: string
  assignee_name: string | null
  assigned_by: string
  assigned_at: string
  unassigned_at: string | null
  reason: string | null
}

export type DispatchEvent = {
  id: string
  event_type: string
  actor_id: string
  from_status: string | null
  to_status: string
  dispatch_version: number
  payload: Record<string, unknown>
  created_at: string
}

export type DispatchQueueRow = {
  kind: "handoff" | "dispatch"
  id: string
  request_number: string
  order_id: string
  order_number: string
  branch_id: string
  status: DispatchRequestStatus
  version?: number
  picking_version?: number
  stock_consumed?: boolean
  assigned_to?: string | null
  assigned_to_name?: string | null
  created_at: string
}

export type DispatchPreview = {
  order_id: string
  order_number: string
  order_status: string
  order_version: number
  branch_id: string
  shop_id: string
  picking_request_id: string | null
  picking_request_number: string | null
  picking_status: string | null
  picking_version: number | null
  dispatch_id: string | null
  dispatch_number: string | null
  dispatch_status: string | null
  dispatch_version: number | null
  stock_consumed: boolean
  delivery_note_id: string | null
  delivery_note_number: string | null
  delivery_note_status: string | null
  shipment_id?: string | null
  shipment_number?: string | null
  shipment_status?: string | null
  shipment_revision?: number | null
  fulfilment_status?: string | null
  eligible: boolean
  blockers: string[]
  cutover: {
    dual_write_enabled: boolean
    aggregate_only_blocked: boolean
  }
  total_cases: number
  reservations: DispatchReservation[]
}

export type DispatchDetail = {
  id: string
  request_number: string
  order_id: string
  order_number: string
  order_status: string
  order_version: number
  shop_id: string
  branch_id: string
  picking_request_id: string
  picking_request_number: string
  picking_status: string
  picking_version: number
  delivery_note_id: string | null
  delivery_note_number: string | null
  delivery_note_status: string | null
  shipment_id?: string | null
  shipment_number?: string | null
  shipment_status?: string | null
  shipment_revision?: number | null
  backorder_id?: string | null
  fulfilment_status?: string | null
  status: DispatchRequestStatus
  version: number
  stock_consumed: boolean
  posted_transaction_id: string | null
  physical_return_status: string | null
  assigned_to: string | null
  assigned_to_name: string | null
  assigned_at: string | null
  dispatched_by: string | null
  dispatched_at: string | null
  in_transit_at: string | null
  delivered_at: string | null
  exception_at: string | null
  exception_reason: string | null
  recipient_name: string | null
  acknowledgement_notes: string | null
  acknowledged_at: string | null
  cancelled_at: string | null
  cancellation_reason: string | null
  created_by: string
  created_at: string
  updated_at: string
  cutover: {
    dual_write_enabled: boolean
    aggregate_only_blocked: boolean
  }
  total_cases: number
  reservations: DispatchReservation[]
  assignments: DispatchAssignment[]
  events: DispatchEvent[]
}

export type DispatchAssignee = {
  id: string
  full_name: string
}

async function dispatchRpc<T>(name: string, args: Record<string, unknown> = {}) {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) {
    throw new DispatchRpcError("Supabase is not configured.", "PGRST000")
  }
  const result = await supabase.rpc(name, args)
  if (result.error) {
    throw new DispatchRpcError(toUserRpcMessage(result.error), result.error.code)
  }
  return result.data as T
}

function asList<T>(data: unknown): T[] {
  return Array.isArray(data) ? (data as T[]) : []
}

export function listDispatchQueue(statusFilter?: string | null) {
  return dispatchRpc<DispatchQueueRow[]>("list_dispatch_queue", {
    status_filter: statusFilter && statusFilter !== "all" ? statusFilter : null,
  }).then((rows) => asList<DispatchQueueRow>(rows))
}

export function listAssignedDeliveries() {
  return dispatchRpc<DispatchQueueRow[]>("list_assigned_deliveries").then((rows) =>
    asList<DispatchQueueRow>(rows),
  )
}

export function previewDispatch(targetOrder: string) {
  return dispatchRpc<DispatchPreview>("preview_dispatch", {
    target_order: targetOrder,
  })
}

export function getDispatchRequest(targetDispatch: string) {
  return dispatchRpc<DispatchDetail>("get_dispatch_request", {
    target_dispatch: targetDispatch,
  })
}

export function prepareDispatch(input: {
  target_order: string
  expected_picking_version: number
  idempotency_key: string
}) {
  return dispatchRpc<DispatchDetail>("prepare_dispatch", input)
}

export function confirmDispatch(input: {
  target_dispatch: string
  expected_version: number
  idempotency_key: string
}) {
  return dispatchRpc<DispatchDetail>("confirm_dispatch", input)
}

export function cancelDispatch(input: {
  target_dispatch: string
  expected_version: number
  cancel_reason: string
  idempotency_key: string
}) {
  return dispatchRpc<DispatchDetail>("cancel_dispatch", input)
}

export function assignDispatchDelivery(input: {
  target_dispatch: string
  assignee: string
  expected_version: number
  idempotency_key: string
}) {
  return dispatchRpc<DispatchDetail>("assign_dispatch_delivery", input)
}

export function startDispatchDelivery(input: {
  target_dispatch: string
  expected_version: number
  idempotency_key: string
}) {
  return dispatchRpc<DispatchDetail>("start_dispatch_delivery", input)
}

export function acknowledgeDispatchDelivery(input: {
  target_dispatch: string
  recipient_name: string
  acknowledgement_notes: string | null
  expected_version: number
  idempotency_key: string
}) {
  return dispatchRpc<DispatchDetail>("acknowledge_dispatch_delivery", input)
}

export function reportDispatchDeliveryException(input: {
  target_dispatch: string
  exception_reason: string
  expected_version: number
  idempotency_key: string
}) {
  return dispatchRpc<DispatchDetail>("report_dispatch_delivery_exception", input)
}

export function listDispatchAssignees(targetBranch: string) {
  return dispatchRpc<DispatchAssignee[]>("list_dispatch_assignees", {
    target_branch: targetBranch,
  }).then((rows) => asList<DispatchAssignee>(rows))
}
