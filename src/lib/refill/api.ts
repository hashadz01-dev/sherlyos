import { callRpc } from "@/lib/masters/api"
import type {
  RefillAcknowledgementStatus,
  RefillCommunicationChannel,
  RefillCommunicationStatus,
  RefillDispatchStatus,
  RefillStatus,
} from "@/lib/refill/rules"

export type RefillLineInput = {
  product_id: string
  requested_cases: number
}

export type RefillLine = RefillLineInput & {
  id: string
  product_sku: string
  product_name: string
}

export type RefillEvent = {
  id: string
  action: string
  previous_status: string | null
  next_status: string
  reason: string | null
  version: number
  actor_id: string
  actor_name: string | null
  created_at: string
}

export type RefillCommunication = {
  id: string
  channel: RefillCommunicationChannel
  communicated_at: string
  external_reference: string | null
  notes: string | null
  recorded_by: string
  recorder_name: string | null
  recorded_at: string
  acknowledgement_status: Exclude<RefillAcknowledgementStatus, "none">
  acknowledgement_at: string | null
  acknowledgement_reference: string | null
  acknowledgement_notes: string | null
  acknowledgement_reason: string | null
  acknowledged_by: string | null
  acknowledger_name: string | null
  acknowledged_recorded_at: string | null
}

export type RefillDispatch = {
  id: string
  supplier_dispatch_reference: string | null
  dispatched_on: string
  expected_arrival_on: string | null
  transport_provider: string | null
  vehicle_reference: string | null
  tracking_reference: string | null
  notes: string | null
  recorded_by: string
  recorder_name: string | null
  recorded_at: string
  updated_by: string | null
  updated_at: string
}

export type RefillRequestDetail = {
  id: string
  request_number: string
  supplier_id: string
  supplier_name: string
  destination_godown_id: string
  godown_code: string
  godown_name: string
  godown_active: boolean
  status: RefillStatus
  notes: string | null
  version: number
  created_by: string
  creator_name: string | null
  created_at: string
  updated_by: string | null
  updated_at: string
  submitted_by: string | null
  submitted_at: string | null
  held_by: string | null
  held_at: string | null
  hold_reason: string | null
  decided_by: string | null
  decided_at: string | null
  decision_reason: string | null
  communication_status: RefillCommunicationStatus
  acknowledgement_status: RefillAcknowledgementStatus
  dispatch_status: RefillDispatchStatus
  expected_arrival_on: string | null
  total_requested_cases: number
  communication: RefillCommunication | null
  dispatch: RefillDispatch | null
  lines: RefillLine[]
  events: RefillEvent[]
}

export type RefillRequestSummary = {
  id: string
  request_number: string
  supplier_id: string
  supplier_name: string
  destination_godown_id: string
  godown_code: string
  godown_name: string
  godown_active: boolean
  status: RefillStatus
  communication_status: RefillCommunicationStatus
  acknowledgement_status: RefillAcknowledgementStatus
  dispatch_status: RefillDispatchStatus
  expected_arrival_on: string | null
  version: number
  total_requested_cases: number
  created_at: string
  submitted_at: string | null
  created_by: string
}

export type RefillListResult = {
  total: number
  page: number
  page_size: number
  items: RefillRequestSummary[]
}

export type RefillOptions = {
  godowns: { id: string; code: string; name: string; is_active: boolean }[]
  suppliers: { id: string; name: string; is_active: boolean }[]
  products: {
    id: string
    sku: string
    name: string
    supplier_id: string
    is_active: boolean
  }[]
}

export function listStockRefillOptions() {
  return callRpc<RefillOptions>("list_stock_refill_options", {})
}

export function listStockRefillRequests(args: {
  page?: number
  pageSize?: number
  status?: string | null
  godownId?: string | null
  supplierId?: string | null
  search?: string | null
}) {
  return callRpc<RefillListResult>("list_stock_refill_requests", {
    page: args.page ?? 1,
    page_size: args.pageSize ?? 25,
    status_filter: args.status && args.status !== "all" ? args.status : null,
    target_godown: args.godownId && args.godownId !== "all" ? args.godownId : null,
    target_supplier:
      args.supplierId && args.supplierId !== "all" ? args.supplierId : null,
    search_text: args.search?.trim() ? args.search.trim() : null,
  })
}

export function getStockRefillRequest(targetRequest: string) {
  return callRpc<RefillRequestDetail>("get_stock_refill_request", {
    target_request: targetRequest,
  })
}

export function createStockRefillRequest(args: {
  supplierId: string
  godownId: string
  lines: RefillLineInput[]
  notes: string | null
  idempotencyKey: string
}) {
  return callRpc<RefillRequestDetail>("create_stock_refill_request", {
    target_supplier: args.supplierId,
    target_godown: args.godownId,
    request_lines: args.lines,
    idempotency_key: args.idempotencyKey,
    notes: args.notes,
  })
}

export function updateStockRefillRequest(args: {
  requestId: string
  expectedVersion: number
  supplierId: string
  godownId: string
  lines: RefillLineInput[]
  notes: string | null
}) {
  return callRpc<RefillRequestDetail>("update_stock_refill_request", {
    target_request: args.requestId,
    expected_version: args.expectedVersion,
    target_supplier: args.supplierId,
    target_godown: args.godownId,
    request_lines: args.lines,
    notes: args.notes,
  })
}

export function submitStockRefillRequest(
  targetRequest: string,
  expectedVersion: number,
  idempotencyKey: string,
) {
  return callRpc<RefillRequestDetail>("submit_stock_refill_request", {
    target_request: targetRequest,
    expected_version: expectedVersion,
    idempotency_key: idempotencyKey,
  })
}

export function approveStockRefillRequest(
  targetRequest: string,
  expectedVersion: number,
  idempotencyKey: string,
  decisionReason: string | null,
) {
  return callRpc<RefillRequestDetail>("approve_stock_refill_request", {
    target_request: targetRequest,
    expected_version: expectedVersion,
    idempotency_key: idempotencyKey,
    decision_reason: decisionReason,
  })
}

export function holdStockRefillRequest(
  targetRequest: string,
  expectedVersion: number,
  decisionReason: string,
  idempotencyKey: string,
) {
  return callRpc<RefillRequestDetail>("hold_stock_refill_request", {
    target_request: targetRequest,
    expected_version: expectedVersion,
    decision_reason: decisionReason,
    idempotency_key: idempotencyKey,
  })
}

export function rejectStockRefillRequest(
  targetRequest: string,
  expectedVersion: number,
  decisionReason: string,
  idempotencyKey: string,
) {
  return callRpc<RefillRequestDetail>("reject_stock_refill_request", {
    target_request: targetRequest,
    expected_version: expectedVersion,
    decision_reason: decisionReason,
    idempotency_key: idempotencyKey,
  })
}

export function recordStockRefillSupplierCommunication(args: {
  requestId: string
  expectedVersion: number
  channel: RefillCommunicationChannel
  communicatedAt: string
  idempotencyKey: string
  externalReference: string | null
  notes: string | null
}) {
  return callRpc<RefillRequestDetail>("record_stock_refill_supplier_communication", {
    target_request: args.requestId,
    expected_version: args.expectedVersion,
    communication_channel: args.channel,
    communicated_at: args.communicatedAt,
    idempotency_key: args.idempotencyKey,
    external_reference: args.externalReference,
    notes: args.notes,
  })
}

export function recordStockRefillSupplierAcknowledgement(args: {
  requestId: string
  expectedVersion: number
  status: "acknowledged" | "declined"
  responseAt: string
  idempotencyKey: string
  acknowledgementReference: string | null
  notes: string | null
  declineReason: string | null
}) {
  return callRpc<RefillRequestDetail>(
    "record_stock_refill_supplier_acknowledgement",
    {
      target_request: args.requestId,
      expected_version: args.expectedVersion,
      acknowledgement_status: args.status,
      response_at: args.responseAt,
      idempotency_key: args.idempotencyKey,
      acknowledgement_reference: args.acknowledgementReference,
      notes: args.notes,
      decline_reason: args.declineReason,
    },
  )
}

export function recordStockRefillSupplierDispatch(args: {
  requestId: string
  expectedVersion: number
  dispatchedOn: string
  idempotencyKey: string
  supplierDispatchReference: string | null
  expectedArrivalOn: string | null
  transportProvider: string | null
  vehicleReference: string | null
  trackingReference: string | null
  notes: string | null
}) {
  return callRpc<RefillRequestDetail>("record_stock_refill_supplier_dispatch", {
    target_request: args.requestId,
    expected_version: args.expectedVersion,
    dispatched_on: args.dispatchedOn,
    idempotency_key: args.idempotencyKey,
    supplier_dispatch_reference: args.supplierDispatchReference,
    expected_arrival_on: args.expectedArrivalOn,
    transport_provider: args.transportProvider,
    vehicle_reference: args.vehicleReference,
    tracking_reference: args.trackingReference,
    notes: args.notes,
  })
}
