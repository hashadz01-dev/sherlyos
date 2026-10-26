import { callRpc } from "@/lib/masters/api"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import type { DamageScenario, DamageStatus } from "@/lib/damage/rules"

export type DamageReportLineInput = {
  product_id: string
  quantity_cases: number
  damage_reason: string
  crate_id?: string | null
  lot_id?: string | null
  notes?: string | null
  receipt_line_id?: string | null
}

export type DamageReportSummary = {
  id: string
  report_number: string
  scenario: DamageScenario
  godown_id: string
  godown_name: string
  status: DamageStatus
  version: number
  reporter_name: string | null
  created_at: string
  receipt_id?: string | null
  picking_request_id?: string | null
  dispatch_id?: string | null
  order_id?: string | null
  shop_id?: string | null
  total_cases?: number
  active_hold_cases?: number
  exceptional_open?: boolean
}

export type DamageHoldRow = {
  id: string
  line_id: string
  product_id: string
  crate_id: string
  crate_code?: string | null
  location_role?: string | null
  lot_id: string | null
  quantity_cases: number
  hold_kind: string
  status: string
  posted_transaction_id?: string | null
}

export type DamageExceptionalRequest = {
  id: string
  kind: string
  status: string
  version: number
  request_reason?: string | null
  requested_at?: string | null
}

export type DamageReportDetail = DamageReportSummary & {
  receipt_id: string | null
  picking_request_id: string | null
  dispatch_id: string | null
  order_id: string | null
  shop_id: string | null
  notes: string | null
  reporter_user_id?: string | null
  physical_custody_confirmed?: boolean
  updated_at?: string
  holds?: DamageHoldRow[]
  exceptional_requests?: DamageExceptionalRequest[]
  lines: {
    id: string
    product_id: string
    product_sku: string
    product_name: string
    crate_id: string | null
    crate_code: string | null
    lot_id: string | null
    quantity_cases: number
    damage_reason: string
    notes: string | null
    receipt_line_id: string | null
  }[]
  events: {
    action: string
    actor_name: string | null
    previous_status: string | null
    next_status: string
    created_at: string
    metadata: Record<string, unknown>
  }[]
  evidence: {
    id: string
    finalized: boolean
    mime_type: string | null
    uploaded_at: string
  }[]
}

export type DamageQueueItem = {
  id: string
  report_number: string
  scenario: DamageScenario
  status: DamageStatus
  godown_name: string
  created_at: string
  disposition_kind?: string
  exceptional_status?: string
}

export type DamageDashboard = {
  stock_hold_ready: boolean
  totals: {
    reports: number
    pending_verification: number
    verified: number
    active_hold_cases: number
    quarantined_cases: number
    pending_exceptional: number
  }
  queues: {
    recent_submitted: DamageQueueItem[]
    awaiting_verification: DamageQueueItem[]
    awaiting_disposition: DamageQueueItem[]
    exceptional_pending: DamageQueueItem[]
    recently_resolved: DamageQueueItem[]
  }
}

export type ListDamageReportsParams = {
  page?: number
  pageSize?: number
  targetGodown?: string | null
  status?: string | null
  scenario?: string | null
  search?: string | null
  fromDate?: string | null
  toDate?: string | null
}

function rpcDate(value: string | null | undefined) {
  const trimmed = value?.trim() ?? ""
  return trimmed === "" ? null : trimmed
}

export function listDamageReports(
  params: ListDamageReportsParams | number = 1,
  pageSize = 50,
  targetGodown?: string | null,
) {
  // Support the legacy positional call used by older tests and callers.
  if (typeof params === "number") {
    return callRpc<{
      items: DamageReportSummary[]
      total: number
      page: number
      page_size: number
    }>("list_damage_reports", {
      page: params,
      page_size: pageSize,
      target_godown: targetGodown ?? null,
      status_filter: null,
      scenario_filter: null,
      search_text: null,
      from_date: null,
      to_date: null,
    })
  }

  return callRpc<{
    items: DamageReportSummary[]
    total: number
    page: number
    page_size: number
  }>("list_damage_reports", {
    page: params.page ?? 1,
    page_size: params.pageSize ?? 50,
    target_godown: params.targetGodown ?? null,
    status_filter: params.status ?? null,
    scenario_filter: params.scenario ?? null,
    search_text: params.search ?? null,
    from_date: rpcDate(params.fromDate),
    to_date: rpcDate(params.toDate),
  })
}

export function getDamageDashboard(targetGodown?: string | null) {
  return callRpc<DamageDashboard>("get_damage_dashboard", {
    target_godown: targetGodown ?? null,
  })
}

export function getDamageStockHoldReadyStatus() {
  return callRpc<{ stock_hold_ready: boolean }>(
    "damage_stock_hold_ready_status",
    {},
  )
}

export function getDamageReport(targetReport: string) {
  return callRpc<DamageReportDetail>("get_damage_report", {
    target_report: targetReport,
  })
}

/** Signed preview for finalized evidence only. Never log the returned URL. */
export async function damagePhotoPreview(evidenceId: string) {
  const located = await callRpc<{
    bucket: string
    path: string
    mime_type: string | null
  }>("get_damage_photo_url", { target_evidence: evidenceId })
  const supabase = getSupabaseBrowserClient()
  if (!supabase) {
    throw new Error("Supabase is not configured.")
  }
  const signed = await supabase.storage
    .from(located.bucket)
    .createSignedUrl(located.path, 60)
  if (signed.error || !signed.data?.signedUrl) {
    throw new Error(signed.error?.message ?? "Photo preview is unavailable.")
  }
  return signed.data.signedUrl
}

export function createDamageReport(input: {
  scenario: DamageScenario
  targetGodown: string
  reportLines: DamageReportLineInput[]
  idempotencyKey: string
  notes?: string | null
  receiptId?: string | null
  pickingRequestId?: string | null
  dispatchId?: string | null
  orderId?: string | null
  shopId?: string | null
}) {
  return callRpc<DamageReportDetail>("create_damage_report", {
    scenario: input.scenario,
    target_godown: input.targetGodown,
    report_lines: input.reportLines,
    idempotency_key: input.idempotencyKey,
    notes: input.notes ?? null,
    receipt_id: input.receiptId ?? null,
    picking_request_id: input.pickingRequestId ?? null,
    dispatch_id: input.dispatchId ?? null,
    order_id: input.orderId ?? null,
    shop_id: input.shopId ?? null,
  })
}

export function confirmShopReturnCustody(
  targetReport: string,
  expectedVersion: number,
) {
  return callRpc<DamageReportDetail>("confirm_shop_return_custody", {
    target_report: targetReport,
    expected_version: expectedVersion,
  })
}

export function postOrdinaryDamageWriteoff(
  targetReport: string,
  expectedVersion: number,
  idempotencyKey: string,
) {
  return callRpc<DamageReportDetail>("post_ordinary_damage_writeoff", {
    target_report: targetReport,
    expected_version: expectedVersion,
    idempotency_key: idempotencyKey,
  })
}

export function requestExceptionalDamageDisposition(input: {
  targetReport: string
  expectedVersion: number
  dispositionKind: "return_supplier" | "destroy"
  requestReason: string
  idempotencyKey: string
}) {
  return callRpc<DamageReportDetail>("request_exceptional_damage_disposition", {
    target_report: input.targetReport,
    expected_version: input.expectedVersion,
    disposition_kind: input.dispositionKind,
    request_reason: input.requestReason,
    idempotency_key: input.idempotencyKey,
  })
}

export function approveExceptionalDamageDisposition(
  targetRequest: string,
  expectedVersion: number,
) {
  return callRpc<DamageReportDetail>("approve_exceptional_damage_disposition", {
    target_request: targetRequest,
    expected_version: expectedVersion,
  })
}

export function rejectExceptionalDamageDisposition(
  targetRequest: string,
  expectedVersion: number,
  decisionReason: string,
) {
  return callRpc<DamageReportDetail>("reject_exceptional_damage_disposition", {
    target_request: targetRequest,
    expected_version: expectedVersion,
    decision_reason: decisionReason,
  })
}

export function postExceptionalDamageDisposition(
  targetRequest: string,
  expectedVersion: number,
  idempotencyKey: string,
) {
  return callRpc<DamageReportDetail>("post_exceptional_damage_disposition", {
    target_request: targetRequest,
    expected_version: expectedVersion,
    idempotency_key: idempotencyKey,
  })
}

export function transferVerifiedDamageToQuarantine(
  targetReport: string,
  expectedVersion: number,
  idempotencyKey: string,
) {
  return callRpc<DamageReportDetail>("transfer_verified_damage_to_quarantine", {
    target_report: targetReport,
    expected_version: expectedVersion,
    idempotency_key: idempotencyKey,
  })
}
