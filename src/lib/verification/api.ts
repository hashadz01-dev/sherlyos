import { callRpc } from "@/lib/masters/api"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import type { ClosureResult, VerificationStatus } from "@/lib/verification/rules"

export type VerificationOptions = {
  godowns: { id: string; code: string; name: string }[]
  zones: { id: string; branch_id: string; code: string; name: string }[]
  crates: { id: string; zone_id: string; code: string; name: string | null }[]
  products: { id: string; sku: string; name: string }[]
}

export type VerificationPreview = {
  crate_count: number
  product_count: number
  expected_cases: number
  lines: {
    zone_code: string
    crate_id: string
    crate_code: string
    product_id: string
    sku: string
    product_name: string
    expected_cases: number
  }[]
}

export type VerificationSummary = {
  id: string
  verification_number: string
  godown_id: string
  godown_name: string
  business_date: string
  status: VerificationStatus
  started_by_name: string | null
  started_at: string
  closure_result: ClosureResult | null
  crate_count: number
  line_count: number
  counted_count: number
  discrepancy_count: number
  scope_codes: string
}

export type VerificationIndicator = {
  godown_id: string
  godown_name: string
  last_verification_date: string | null
  missing_today: boolean
  open_verification_id: string | null
}

export type VerificationList = {
  verifications: VerificationSummary[]
  indicators: VerificationIndicator[]
}

export type VerificationMovement = {
  ledger_id: string
  quantity: number
  posted_at: string
  transaction_type: string
  reference_number: string
}

export type VerificationLine = {
  id: string
  crate_id: string
  crate_code: string
  crate_name: string | null
  crate_active: boolean
  zone_id: string
  zone_code: string
  zone_name: string
  zone_active: boolean
  product_id: string
  sku: string
  product_name: string
  product_active: boolean
  expected_cases: number
  counted_cases: number | null
  recount_cases: number | null
  first_counted_by_name: string | null
  first_counted_at: string | null
  recounted_by_name: string | null
  recounted_at: string | null
  line_version: number
  recount_requested: boolean
  ledger_movement_cases: number
  reconciled_expected_cases: number | null
  final_variance_cases: number | null
  movement_ids: string[]
  acknowledged_ledger_ids: string[]
  movements: VerificationMovement[]
  discrepancy_status: string
  discrepancy_reason: string | null
  reviewed_by_name: string | null
  reviewed_at: string | null
  inactive_review_reason: string | null
  inactive_reviewed_by_name: string | null
  inactive_reviewed_at: string | null
}

export type VerificationDetail = {
  verification: {
    id: string
    verification_number: string
    godown_id: string
    godown_name: string
    business_date: string
    status: VerificationStatus
    snapshot_at: string
    started_by_name: string | null
    started_at: string
    submitted_at: string | null
    closed_by_name: string | null
    closed_at: string | null
    closure_result: ClosureResult | null
    closure_note: string | null
    correction_request_status: string
  }
  scopes: {
    id: string
    zone_id: string
    zone_code: string
    zone_name: string
    zone_active: boolean
    crate_id: string
    crate_code: string
    crate_name: string | null
    crate_active: boolean
    inactive_review_reason: string | null
    inactive_reviewed_by_name: string | null
    inactive_reviewed_at: string | null
  }[]
  lines: VerificationLine[]
  counts: {
    id: string
    line_id: string
    count_kind: string
    counted_cases: number
    counted_by_name: string | null
    counted_at: string
  }[]
  evidence: {
    id: string
    mime_type: string | null
    file_size: number | null
    uploaded_by_name: string | null
    uploaded_at: string
    note: string | null
    verified_at: string | null
  }[]
  history: {
    action: string
    actor_name: string | null
    occurred_at: string
  }[]
  unassigned_movements: {
    crate_id: string
    product_id: string
    sku: string
    product_name: string
    quantity: number
    transaction_type: string
    reference_number: string
  }[]
  products: { id: string; sku: string; name: string }[]
  closure: {
    lines_total: number
    lines_counted: number
    matched: number
    shortages: number
    overages: number
    movement_affected: number
    unreconciled: number
    recount_missing: number
    verified_photos: number
    blockers: string[]
  }
}

function client() {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) throw new Error("Supabase is not configured.")
  return supabase
}

export function listVerificationOptions() {
  return callRpc<VerificationOptions>("list_verification_options", {})
}

export function previewVerificationScope(args: {
  target_godown: string
  zone_ids: string[]
  crate_ids: string[]
}) {
  return callRpc<VerificationPreview>("preview_verification_scope", args)
}

export function listStockVerifications() {
  return callRpc<VerificationList>("list_stock_verifications", {})
}

export function getStockVerification(targetVerification: string) {
  return callRpc<VerificationDetail>("get_stock_verification", {
    target_verification: targetVerification,
  })
}

export function startStockVerification(args: {
  target_godown: string
  verification_date: string
  zone_ids: string[]
  crate_ids: string[]
}) {
  return callRpc<string>("start_stock_verification", args)
}

export function addVerificationFoundProduct(args: {
  target_verification: string
  target_crate: string
  target_product: string
}) {
  return callRpc<string>("add_verification_found_product", args)
}

export function saveVerificationCount(targetLine: string, countedCases: number, expectedVersion: number) {
  return callRpc<null>("save_verification_count", {
    target_line: targetLine,
    counted_cases: countedCases,
    expected_version: expectedVersion,
  })
}

export function submitStockVerification(targetVerification: string) {
  return callRpc<null>("submit_stock_verification", { target_verification: targetVerification })
}

export function reportStockDiscrepancy(targetLine: string, discrepancyReason: string) {
  return callRpc<null>("report_stock_discrepancy", {
    target_line: targetLine,
    discrepancy_reason: discrepancyReason,
  })
}

export function requestVerificationRecount(targetLine: string) {
  return callRpc<null>("request_verification_recount", { target_line: targetLine })
}

export function saveVerificationRecount(targetLine: string, countedCases: number, expectedVersion: number) {
  return callRpc<null>("save_verification_recount", {
    target_line: targetLine,
    counted_cases: countedCases,
    expected_version: expectedVersion,
  })
}

export function reviewVerificationDiscrepancy(
  targetLine: string,
  discrepancyReason: string,
  movementIds: string[],
) {
  return callRpc<null>("review_verification_discrepancy", {
    target_line: targetLine,
    discrepancy_reason: discrepancyReason,
    movement_ids: movementIds,
  })
}

export function reviewVerificationInactiveObject(targetKind: "line" | "scope", targetId: string, reviewReason: string) {
  return callRpc<null>("review_verification_inactive_object", {
    target_kind: targetKind,
    target_id: targetId,
    review_reason: reviewReason,
  })
}

export function closeStockVerification(
  targetVerification: string,
  closureResult: ClosureResult,
  closureNote: string,
) {
  return callRpc<null>("close_stock_verification", {
    target_verification: targetVerification,
    closure_result: closureResult,
    closure_note: closureNote,
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

export async function uploadVerificationPhoto(verificationId: string, file: File, note: string) {
  const created = await callRpc<{ id: string; bucket: string; path: string }>(
    "create_verification_photo_upload",
    {
      target_verification: verificationId,
      photo_note: note.trim() ? note.trim() : null,
      target_line: null,
    },
  )
  const uploaded = await client()
    .storage.from(created.bucket)
    .upload(created.path, file, { contentType: file.type, upsert: false })
  if (uploaded.error) throw new Error(uploaded.error.message)
  const payload = new Uint8Array(await file.arrayBuffer())
  await callRpc<null>("finalize_verification_photo_upload", {
    target_evidence: created.id,
    image_base64: bytesToBase64(payload),
  })
}

export async function verificationPhotoPreview(evidenceId: string) {
  const located = await callRpc<{ bucket: string; path: string; mime_type: string }>(
    "get_verification_photo_url",
    { target_evidence: evidenceId },
  )
  const signed = await client().storage.from(located.bucket).createSignedUrl(located.path, 60)
  if (signed.error || !signed.data?.signedUrl) {
    throw new Error(signed.error?.message ?? "Photo preview is unavailable.")
  }
  return signed.data.signedUrl
}
