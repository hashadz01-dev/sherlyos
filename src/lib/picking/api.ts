import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import {
  parsePickingFulfilment,
  type PickingFulfilment,
  type PickingRequestStatus,
} from "@/lib/picking/rules"
import { toUserRpcMessage } from "@/lib/rpc/user-error"

export type { PickingFulfilment } from "@/lib/picking/rules"

export class PickingRpcError extends Error {
  readonly code: string

  constructor(message: string, code = "") {
    super(message)
    this.name = "PickingRpcError"
    this.code = code
  }
}

export const pickingKeys = {
  queue: (status: string) => ["picking-queue", status] as const,
  detail: (id: string) => ["picking-request", id] as const,
  preview: (orderId: string) => ["picking-preview", orderId] as const,
  exceptions: ["picking-exceptions"] as const,
  handoff: (id: string) => ["picking-handoff", id] as const,
}

export type AllocationSlice = {
  lot_id: string
  crate_id: string
  crate_code: string
  zone_code: string
  manufacturer_lot_code: string | null
  expiry_date: string | null
  received_on: string | null
  available_cases: number
  reserved_cases: number
  policy: string
}

export type AllocationLine = {
  order_line_id: string
  product_id: string
  sku: string
  product_name: string
  expiry_policy: string | null
  requested_cases: number
  allocated_cases: number
  shortfall_cases: number
  eligible: boolean
  blockers: string[]
  slices: AllocationSlice[]
}

export type AllocationPreview = {
  order_id: string
  order_number: string
  order_status: string
  order_version: number
  branch_id: string
  shop_id: string
  delivery_note_id?: string | null
  delivery_note_status?: string | null
  eligible: boolean
  blockers: string[]
  cutover: {
    dual_write_enabled: boolean
    aggregate_only_blocked: boolean
  }
  lines: AllocationLine[]
}

export type PickingQueueRow = {
  kind: "pending_order" | "picking_request"
  id?: string
  request_number?: string
  order_id: string
  order_number: string
  order_status?: string
  order_version?: number
  branch_id: string
  shop_id?: string
  delivery_note_status?: string
  status: PickingRequestStatus
  version?: number
  assigned_to?: string | null
  created_at: string
  updated_at?: string
  ordered_cases?: number
  allocated_cases?: number
  picked_cases?: number
  shortfall_cases?: number
  has_shortage?: boolean
}

export type PickingReservation = {
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
  received_on: string | null
  lot_status: string
  reserved_cases: number
  picked_cases: number
  remaining_cases: number
  status: string
}

export type PickingException = {
  id: string
  picking_request_id?: string
  request_number?: string
  order_number?: string
  reservation_id?: string | null
  exception_type: string
  message: string
  quantity: number | null
  created_at: string
}

export type PickingEvent = {
  id: string
  event_type: string
  actor_id: string
  from_status: string | null
  to_status: string
  request_version: number
  payload: Record<string, unknown>
  created_at: string
}

export type PickingDetail = {
  id: string
  request_number: string
  order_id: string
  order_number: string
  order_status: string
  order_version: number
  shop_id: string
  branch_id: string
  status: PickingRequestStatus
  version: number
  assigned_to: string | null
  created_by: string
  started_at: string | null
  completed_at: string | null
  handed_off_at: string | null
  cancelled_at: string | null
  cancellation_reason: string | null
  blocked_reason: string | null
  created_at: string
  updated_at: string
  delivery_note_status?: string | null
  fulfilment?: PickingFulfilment
  cutover: {
    dual_write_enabled: boolean
    aggregate_only_blocked: boolean
  }
  reservations: PickingReservation[]
  exceptions: PickingException[]
  events: PickingEvent[]
}

async function pickingRpc<T>(name: string, args: Record<string, unknown> = {}) {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) {
    throw new PickingRpcError("Supabase is not configured.", "PGRST000")
  }
  const result = await supabase.rpc(name, args)
  if (result.error) {
    throw new PickingRpcError(toUserRpcMessage(result.error), result.error.code)
  }
  return result.data as T
}

function asList<T>(data: unknown): T[] {
  return Array.isArray(data) ? (data as T[]) : []
}

function asPickingDetail(data: PickingDetail): PickingDetail {
  return {
    ...data,
    fulfilment: parsePickingFulfilment(data.fulfilment),
  }
}

export function listPickingRequests(statusFilter?: string | null) {
  return pickingRpc<PickingQueueRow[]>("list_picking_requests", {
    status_filter: statusFilter && statusFilter !== "all" ? statusFilter : null,
  }).then((rows) => asList<PickingQueueRow>(rows))
}

export function getPickingRequest(targetRequest: string) {
  return pickingRpc<PickingDetail>("get_picking_request", {
    target_request: targetRequest,
  }).then(asPickingDetail)
}

export function previewOrderAllocation(targetOrder: string) {
  return pickingRpc<AllocationPreview>("preview_order_allocation", {
    target_order: targetOrder,
  })
}

export function reserveOrderAllocation(input: {
  target_order: string
  expected_order_version: number
  idempotency_key: string
}) {
  return pickingRpc<PickingDetail>("reserve_order_allocation", input).then(asPickingDetail)
}

export function assignPickingRequest(input: {
  target_request: string
  assignee: string
  expected_version: number
  idempotency_key: string
}) {
  return pickingRpc<PickingDetail>("assign_picking_request", input).then(asPickingDetail)
}

export function startPicking(input: {
  target_request: string
  expected_version: number
  idempotency_key: string
}) {
  return pickingRpc<PickingDetail>("start_picking", input).then(asPickingDetail)
}

export function confirmPickingQuantity(input: {
  target_request: string
  target_reservation: string
  picked_quantity: number
  expected_version: number
  idempotency_key: string
}) {
  return pickingRpc<PickingDetail>("confirm_picking_quantity", input).then(asPickingDetail)
}

export function reportPickingShortage(input: {
  target_request: string
  target_reservation: string
  short_quantity: number
  shortage_note: string
  expected_version: number
  idempotency_key: string
}) {
  return pickingRpc<PickingDetail>("report_picking_shortage", input).then(asPickingDetail)
}

export function completePicking(input: {
  target_request: string
  expected_version: number
  idempotency_key: string
}) {
  return pickingRpc<PickingDetail>("complete_picking", input).then(asPickingDetail)
}

export function confirmPickingHandoff(input: {
  target_request: string
  expected_version: number
  idempotency_key: string
}) {
  return pickingRpc<PickingDetail>("confirm_picking_handoff", input).then(asPickingDetail)
}

export function cancelPickingRequest(input: {
  target_request: string
  expected_version: number
  cancel_reason: string
  idempotency_key: string
}) {
  return pickingRpc<PickingDetail>("cancel_picking_request", input).then(asPickingDetail)
}

export function getPickingHandoff(targetRequest: string) {
  return pickingRpc<unknown>("get_picking_handoff", {
    target_request: targetRequest,
  })
}

export function listPickingExceptions() {
  return pickingRpc<PickingException[]>("list_picking_exceptions").then((rows) =>
    asList<PickingException>(rows),
  )
}
