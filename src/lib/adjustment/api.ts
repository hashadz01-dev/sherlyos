import { callRpc } from "@/lib/masters/api"
import type { AdjustmentStatus } from "@/lib/adjustment/rules"

export type AdjustmentSummary = {
  id: string
  request_number: string
  godown_id: string
  godown_name: string
  verification_id: string
  verification_number: string
  status: AdjustmentStatus
  exceptional: boolean | null
  requested_by_name: string | null
  created_at: string
  version: number
}

export type AdjustmentCandidate = {
  verification_id: string
  verification_number: string
  godown_id: string
  godown_name: string
  business_date: string
  evidence_id: string
  lines: {
    line_id: string
    crate_code: string
    sku: string
    product_name: string
    expected_cases: number
    physical_cases: number
    variance_cases: number
  }[]
}

export type AdjustmentDetail = {
  id: string
  request_number: string
  godown_name: string
  verification_id: string
  verification_number: string
  evidence_id: string
  compensates_request_id: string | null
  status: AdjustmentStatus
  exceptional: boolean | null
  version: number
  reason_code: string
  note: string
  requested_by: string
  requested_by_name: string | null
  approved_by_name: string | null
  posted_by_name: string | null
  other_manager_exists: boolean
  lines: {
    id: string
    crate_code: string
    sku: string
    product_name: string
    requested_cases: number
    current_cases: number | null
  }[]
  events: {
    event_type: string
    actor_name: string | null
    from_status: string | null
    to_status: string
    request_version: number
    note: string | null
    created_at: string
  }[]
}

export function listStockAdjustments() {
  return callRpc<AdjustmentSummary[]>("list_stock_adjustments", {})
}

export function listAdjustmentCandidates() {
  return callRpc<AdjustmentCandidate[]>("list_adjustment_candidates", {})
}

export function getStockAdjustment(requestId: string) {
  return callRpc<AdjustmentDetail>("get_stock_adjustment", { target_request: requestId })
}

export function createStockAdjustment(input: {
  verificationId: string
  reasonCode: string
  note: string
  lineIds: string[]
  idempotencyKey: string
}) {
  return callRpc<{ id: string; request_number: string }>("create_stock_adjustment", {
    target_verification: input.verificationId,
    reason_code: input.reasonCode,
    request_note: input.note,
    line_ids: input.lineIds,
    idempotency_key: input.idempotencyKey,
    compensates_request: null,
  })
}

export function submitStockAdjustment(requestId: string, version: number) {
  return callRpc<void>("submit_stock_adjustment", {
    target_request: requestId,
    expected_version: version,
  })
}

export function approveStockAdjustment(requestId: string, version: number, note: string) {
  return callRpc<void>("approve_stock_adjustment", {
    target_request: requestId,
    expected_version: version,
    approval_note: note,
  })
}

export function returnStockAdjustment(requestId: string, version: number, note: string) {
  return callRpc<void>("return_stock_adjustment", {
    target_request: requestId,
    expected_version: version,
    return_note: note,
  })
}

export function rejectStockAdjustment(requestId: string, version: number, note: string) {
  return callRpc<void>("reject_stock_adjustment", {
    target_request: requestId,
    expected_version: version,
    reject_note: note,
  })
}

export function postStockAdjustment(requestId: string, version: number, idempotencyKey: string) {
  return callRpc<{ id: string; reference_number: string }>("post_stock_adjustment", {
    target_request: requestId,
    expected_version: version,
    idempotency_key: idempotencyKey,
  })
}
