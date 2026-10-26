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
  shop_name?: string | null
  physical_custody_confirmed?: boolean
  reporter_user_id?: string | null
  godown_active?: boolean
  has_finalized_evidence?: boolean
  finalized_evidence_count?: number
  total_cases?: number
  active_hold_cases?: number
  exceptional_open?: boolean
}

export type DamageHoldRow = {
  id: string
  line_id: string
  product_id: string
  product_sku?: string | null
  product_name?: string | null
  crate_id: string
  crate_code?: string | null
  location_role?: string | null
  zone_code?: string | null
  zone_name?: string | null
  lot_id: string | null
  quantity_cases: number
  hold_kind: string
  status: string
  source_reservation_id?: string | null
  posted_transaction_id?: string | null
  created_at?: string | null
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
  shop_name?: string | null
  notes: string | null
  reporter_user_id?: string | null
  physical_custody_confirmed?: boolean
  physical_custody_confirmed_at?: string | null
  physical_custody_confirmed_by?: string | null
  physical_custody_confirmed_by_name?: string | null
  verifier_user_id?: string | null
  verifier_name?: string | null
  verified_at?: string | null
  returned_at?: string | null
  returned_by?: string | null
  returned_by_name?: string | null
  return_reason?: string | null
  rejected_at?: string | null
  rejected_by?: string | null
  rejected_by_name?: string | null
  rejection_reason?: string | null
  godown_active?: boolean
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
    note?: string | null
  }[]
}

export type DamageSourceLine = {
  receipt_line_id?: string
  product_id: string
  product_sku: string
  product_name: string
  crate_id?: string | null
  crate_code?: string | null
  lot_id?: string | null
  damaged_cases?: number
  already_reported?: number
  remaining_cases?: number
  reserved_cases?: number
}

export type DamageSourceItem = {
  id: string
  kind: "receipt" | "godown" | "picking" | "dispatch_consumed" | "shop"
  label: string
  godown_id: string
  receipt_id?: string | null
  picking_request_id?: string | null
  dispatch_id?: string | null
  order_id?: string | null
  shop_id?: string | null
  supplier_name?: string | null
  received_date?: string | null
  status?: string | null
  assigned_to?: string | null
  lines?: DamageSourceLine[]
}

export type DamageSourceCatalogs = {
  crates?: {
    id: string
    code: string
    name: string | null
    zone_code: string
  }[]
  products?: { id: string; sku: string; name: string }[]
  products_total?: number
  products_page?: number
  balances?: {
    crate_id: string
    product_id: string
    on_hand_cases: number
  }[]
}

export type DamageSourceList = {
  total: number
  page: number
  page_size: number
  items: DamageSourceItem[]
  catalogs: DamageSourceCatalogs
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
    awaiting_custody?: DamageQueueItem[]
    awaiting_disposition: DamageQueueItem[]
    exceptional_pending: DamageQueueItem[]
    recently_resolved: DamageQueueItem[]
  }
}

export type DamageQuarantineRow = {
  hold_id: string
  damage_report_id: string
  report_number: string
  report_status: DamageStatus
  scenario: DamageScenario
  godown_id: string
  godown_name: string
  godown_active: boolean
  product_id: string
  product_sku: string
  product_name: string
  quantity_cases: number
  hold_kind: string
  hold_status: string
  isolation_class: string
  crate_id: string
  crate_code: string | null
  location_role: string | null
  zone_code: string | null
  zone_name: string | null
  lot_id: string | null
  source_reservation_id: string | null
  posted_transaction_id: string | null
  created_at: string
}

/** Filter-wide carton totals. Never derived from the current page of items. */
export type DamageQuarantineTotals = {
  hold_rows: number
  current_unavailable_cases: number
  logical_hold_cases: number
  reservation_converted_cases: number
  shop_return_intake_cases: number
  transferred_quarantine_cases: number
  written_off_cases: number
  returned_supplier_cases: number
  released_cases: number
}

export type ListDamageQuarantineResult = {
  items: DamageQuarantineRow[]
  total: number
  page: number
  page_size: number
  totals: DamageQuarantineTotals
}

export type ListDamageQuarantineParams = {
  page?: number
  pageSize?: number
  targetGodown?: string | null
  targetProduct?: string | null
  scenario?: string | null
  holdKind?: string | null
  holdStatus?: string | null
  productSearch?: string | null
  fromDate?: string | null
  toDate?: string | null
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

export function listDamageQuarantineInventory(
  params: ListDamageQuarantineParams = {},
) {
  return callRpc<ListDamageQuarantineResult>(
    "list_damage_quarantine_inventory",
    {
      page: params.page ?? 1,
      page_size: params.pageSize ?? 50,
      target_godown: params.targetGodown ?? null,
      target_product: params.targetProduct ?? null,
      scenario_filter: params.scenario ?? null,
      hold_kind_filter: params.holdKind ?? null,
      hold_status_filter: params.holdStatus ?? null,
      product_search: params.productSearch ?? null,
      from_date: rpcDate(params.fromDate),
      to_date: rpcDate(params.toDate),
    },
  )
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

export function listDamageReportSources(input: {
  scenario: DamageScenario
  targetGodown: string
  search?: string | null
  page?: number
  pageSize?: number
  catalogSearch?: string | null
  catalogPage?: number
}) {
  return callRpc<DamageSourceList>("list_damage_report_sources", {
    scenario: input.scenario,
    target_godown: input.targetGodown,
    search_text: input.search ?? null,
    page: input.page ?? 1,
    page_size: input.pageSize ?? 50,
    catalog_search: input.catalogSearch ?? null,
    catalog_page: input.catalogPage ?? 1,
  })
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

export function updateDamageReport(input: {
  targetReport: string
  expectedVersion: number
  reportLines: DamageReportLineInput[]
  notes?: string | null
  receiptId?: string | null
  pickingRequestId?: string | null
  dispatchId?: string | null
  orderId?: string | null
  shopId?: string | null
}) {
  return callRpc<DamageReportDetail>("update_damage_report", {
    target_report: input.targetReport,
    expected_version: input.expectedVersion,
    report_lines: input.reportLines,
    notes: input.notes ?? null,
    receipt_id: input.receiptId ?? null,
    picking_request_id: input.pickingRequestId ?? null,
    dispatch_id: input.dispatchId ?? null,
    order_id: input.orderId ?? null,
    shop_id: input.shopId ?? null,
  })
}

export function submitDamageReport(
  targetReport: string,
  expectedVersion: number,
  idempotencyKey: string,
) {
  return callRpc<DamageReportDetail>("submit_damage_report", {
    target_report: targetReport,
    expected_version: expectedVersion,
    idempotency_key: idempotencyKey,
  })
}

function bytesToBase64(bytes: Uint8Array) {
  let binary = ""
  const chunk = 0x8000
  for (let index = 0; index < bytes.length; index += chunk) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunk))
  }
  return btoa(binary)
}

/**
 * Create catalog row, upload bytes to the private bucket, then finalize through
 * the trusted RPC. Browser upload success is never treated as finalization.
 */
export async function uploadDamagePhoto(
  reportId: string,
  file: File,
  note: string,
  onStatus?: (status: "uploading" | "finalizing") => void,
) {
  const created = await callRpc<{ id: string; bucket: string; path: string }>(
    "create_damage_photo_upload",
    {
      target_report: reportId,
      photo_note: note.trim(),
    },
  )
  const supabase = getSupabaseBrowserClient()
  if (!supabase) {
    throw new Error("Supabase is not configured.")
  }
  onStatus?.("uploading")
  const uploaded = await supabase.storage
    .from(created.bucket)
    .upload(created.path, file, { contentType: file.type, upsert: false })
  if (uploaded.error) {
    throw new Error(uploaded.error.message)
  }
  onStatus?.("finalizing")
  const payload = new Uint8Array(await file.arrayBuffer())
  await callRpc<null>("finalize_damage_photo_upload", {
    target_evidence: created.id,
    image_base64: bytesToBase64(payload),
  })
  return created.id
}

export function verifyDamageReport(
  targetReport: string,
  expectedVersion: number,
) {
  return callRpc<DamageReportDetail>("verify_damage_report", {
    target_report: targetReport,
    expected_version: expectedVersion,
  })
}

export function returnDamageReport(
  targetReport: string,
  expectedVersion: number,
  reason: string,
) {
  return callRpc<DamageReportDetail>("return_damage_report", {
    target_report: targetReport,
    expected_version: expectedVersion,
    reason,
  })
}

export function rejectDamageReport(
  targetReport: string,
  expectedVersion: number,
  reason: string,
) {
  return callRpc<DamageReportDetail>("reject_damage_report", {
    target_report: targetReport,
    expected_version: expectedVersion,
    reason,
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
