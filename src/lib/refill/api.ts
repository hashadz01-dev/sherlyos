import { callRpc } from "@/lib/masters/api"
import type { RefillStatus } from "@/lib/refill/rules"

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
  total_requested_cases: number
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
