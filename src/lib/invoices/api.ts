import { callRpc } from "@/lib/masters/api"
import type { InvoiceTaxPreview } from "@/lib/invoices/tax-preview"
import type {
  InvoiceNoteStatus,
  InvoicePreviewCopy,
} from "@/lib/invoices/rules"

export const invoiceKeys = {
  list: (status: string, branchId: string, shopId: string) =>
    ["invoice-notes", status, branchId, shopId] as const,
  detail: (id: string) => ["invoice-note", id] as const,
  preview: (id: string, copy: InvoicePreviewCopy) =>
    ["invoice-note-preview", id, copy] as const,
  eligible: ["invoice-eligible-dispatches"] as const,
  readiness: ["invoice-finalization-readiness"] as const,
  taxPreview: (id: string) => ["invoice-tax-preview", id] as const,
  creditAdjustments: (status: string, branchId: string) =>
    ["credit-adjustments", status, branchId] as const,
  creditAdjustment: (id: string) => ["credit-adjustment", id] as const,
}

export type InvoiceStatutoryBlocker = {
  code: string
  message: string
}

export type InvoiceStatutoryReadiness = {
  ready: boolean
  legal_issuance_blocked: boolean
  currency_code: string
  issuance_blocked_reason?: string
  numbering_allocation_enabled?: boolean
  cancellation_blocked?: boolean
  issued_invoice_count?: number
  blockers: InvoiceStatutoryBlocker[]
}

export type InvoiceCancellationReadiness = {
  ready: boolean
  legal_cancellation_blocked: boolean
  rewrites_financial_values: boolean
  deletes_history: boolean
  blockers: InvoiceStatutoryBlocker[]
}

export type InvoiceNoteLine = {
  id: string
  line_no: number
  order_line_id: string
  product_id: string
  lot_id: string
  crate_id: string
  product_sku: string
  product_name: string
  shipped_cases: number
  billing_unit: string
  billed_units_per_case: number | string
  billed_quantity: number | string
  unit_amount?: number | string
  line_amount?: number | string
  price_scope?: "shop" | "default"
  price_effective_from?: string
  price_effective_to?: string | null
  tax_amount?: number | string
  hsn_sac_code?: string | null
}

export type InvoiceNoteEvent = {
  id: string
  event_type: string
  from_status: string | null
  to_status: string
  note_version: number
  created_at: string
  actor_id: string
}

export type InvoiceCreditNoteCandidate = {
  return_id: string
  return_number: string
  status: string
  version?: number
  issuable: boolean
  credit_eligible?: boolean
  existing_adjustment_id?: string | null
  reason: string
}

export type CreditAdjustmentStatus = "preview" | "blocked"

export type CreditAdjustmentBlocker = {
  code: string
  message: string
}

export type CreditAdjustmentLine = {
  id: string
  line_no: number
  product_id: string
  product_sku: string
  product_name: string
  original_shipped_cases: number
  credited_cases: number
  billing_unit: string
  billed_units_per_case: number | string
  billed_quantity: number | string
  unit_amount: number | string
  line_subtotal: number | string
  taxable_value: number | string
  cgst_rate?: number | string | null
  sgst_rate?: number | string | null
  igst_rate?: number | string | null
  cgst_amount: number | string
  sgst_amount: number | string
  igst_amount: number | string
  tax_amount: number | string
  line_total: number | string
}

export type CreditAdjustmentDetail = {
  id: string
  adjustment_number: string
  status: CreditAdjustmentStatus
  version: number
  watermark: string
  legal_credit_note_number: string | null
  legal_issuance_blocked: boolean
  tax_preview_state: "tax_preview" | "tax_unavailable" | "tax_stale" | "tax_incomplete"
  tax_preview_id: string | null
  tax_input_fingerprint: string | null
  return_id: string
  return_number: string
  return_status: string
  dispatch_id: string
  dispatch_number: string
  invoice_note_id: string
  invoice_note_number: string
  invoice_note_version: number
  shop_id: string
  shop_name: string
  branch_id: string
  credited_cases: number
  credited_quantity: number | string
  subtotal_amount: number | string
  cgst_amount: number | string
  sgst_amount: number | string
  igst_amount: number | string
  tax_amount: number | string
  adjustment_total: number | string
  blockers: CreditAdjustmentBlocker[]
  created_at: string
  generated_at?: string
  lines: CreditAdjustmentLine[]
}

export type CreditAdjustmentListRow = {
  id: string
  adjustment_number: string
  status: CreditAdjustmentStatus
  watermark: string
  return_id: string
  return_number?: string
  invoice_note_id: string
  invoice_note_number?: string
  shop_id: string
  shop_name?: string
  branch_id: string
  credited_cases: number
  adjustment_total: number | string
  tax_preview_state: string
  legal_issuance_blocked: boolean
  created_at: string
}

export type InvoiceNoteDetail = {
  id: string
  note_number: string
  status: InvoiceNoteStatus
  version: number
  idempotency_key: string
  dispatch_id: string
  dispatch_number: string
  order_id: string
  order_number: string
  shop_id: string
  shop: {
    id: string
    name: string
    address: string | null
    phone?: string | null
  }
  godown?: {
    id: string
    code: string
    name: string
  }
  branch_id: string
  as_of_date: string
  dispatch_confirmed_at: string
  currency_code: "INR"
  billed_cases: number
  billed_quantity: number | string
  subtotal_amount?: number | string
  tax_amount?: number | string
  grand_total?: number | string
  amount_in_words?: string
  remarks: string | null
  watermark: string
  legal_issuance_blocked: boolean
  has_legal_seal: boolean
  company: {
    ready: boolean
    legal_name: string | null
    registered_address: string | null
    tax_id: string | null
  }
  statutory: InvoiceStatutoryReadiness
  submitted_at: string | null
  reviewed_at: string | null
  cancelled_at: string | null
  created_at: string
  lines: InvoiceNoteLine[]
  events: InvoiceNoteEvent[]
  credit_note_candidates: InvoiceCreditNoteCandidate[]
  copy?: InvoicePreviewCopy
  copy_family?: "driver" | "accounts"
  copy_label?: string
  document_kind?: "driver" | "accounts"
  generated_at?: string
  legal_invoice_number?: string | null
  legal_seal_caption?: string
  signature_block?: { shown: boolean; reason: string }
  handover_acknowledgement?: {
    driver_signature_label: string
    receiver_signature_label: string
    note: string
  }
  seller_identity?: {
    available: boolean
    legal_name?: string
    registered_address?: string
    gstin?: string | null
    state_code?: string | null
    reason?: string
  }
  customer_identity?: {
    available: boolean
    billing_name?: string
    billing_address?: string
    gstin?: string | null
    registration_status?: string
    shop_name?: string
    shop_address?: string | null
    reason?: string
  }
  tax_preview?: InvoiceTaxPreview
  tax_preview_watermark?: string
  financial_preview_state?:
    | "omitted_for_driver_copy"
    | "tax_unavailable"
    | "tax_stale"
    | "tax_preview"
  source?: {
    invoice_note_id: string
    invoice_note_version: number
    dispatch_id: string
    quantities_from?: string | null
    prices_from?: string | null
    tax_from?: string | null
    tax_preview_id?: string | null
  }
}

export type InvoiceNoteListRow = {
  id: string
  note_number: string
  status: InvoiceNoteStatus
  version: number
  dispatch_id: string
  order_id: string
  shop_id: string
  shop_name: string
  branch_id: string
  billed_cases: number
  grand_total: number | string
  currency_code: "INR"
  watermark: string
  legal_issuance_blocked: boolean
  created_at: string
}

export type InvoiceEligibleDispatch = {
  dispatch_id: string
  dispatch_number: string
  order_id: string
  order_number: string
  shop_id: string
  shop_name: string
  branch_id: string
  status: string
  dispatched_at: string
}

export function listInvoiceNotes(options: {
  status?: string
  branchId?: string
  shopId?: string
}) {
  return callRpc<InvoiceNoteListRow[]>("list_invoice_notes", {
    p_status: options.status && options.status !== "all" ? options.status : null,
    p_branch_id: options.branchId && options.branchId !== "all" ? options.branchId : null,
    p_shop_id: options.shopId && options.shopId !== "all" ? options.shopId : null,
  })
}

export function getInvoiceNote(noteId: string) {
  return callRpc<InvoiceNoteDetail>("get_invoice_note", {
    p_invoice_note_id: noteId,
  })
}

export function getInvoiceNotePreview(noteId: string, copy: InvoicePreviewCopy) {
  return callRpc<InvoiceNoteDetail>("get_invoice_note_preview", {
    p_invoice_note_id: noteId,
    p_copy: copy,
  })
}

export function listInvoiceEligibleDispatches() {
  return callRpc<InvoiceEligibleDispatch[]>("list_invoice_eligible_dispatches", {})
}

export function assessInvoiceFinalizationReadiness(noteId?: string) {
  return callRpc<InvoiceStatutoryReadiness>("assess_invoice_finalization_readiness", {
    p_invoice_note_id: noteId ?? null,
  })
}

/** Read-only. Never cancels an issued invoice or posts a credit note. */
export function assessStatutoryCancellationReadiness(invoiceId?: string) {
  return callRpc<InvoiceCancellationReadiness>("assess_statutory_cancellation_readiness", {
    p_statutory_invoice_id: invoiceId ?? null,
  })
}

export function prepareInvoiceNote(options: {
  dispatchId: string
  idempotencyKey: string
  expectedVersion: number
  remarks?: string
}) {
  return callRpc<InvoiceNoteDetail>("prepare_invoice_note", {
    p_dispatch_id: options.dispatchId,
    p_idempotency_key: options.idempotencyKey,
    p_expected_version: options.expectedVersion,
    p_remarks: options.remarks ?? null,
  })
}

export function submitInvoiceNote(noteId: string, expectedVersion: number) {
  return callRpc<InvoiceNoteDetail>("submit_invoice_note", {
    p_invoice_note_id: noteId,
    p_expected_version: expectedVersion,
  })
}

export function reviewInvoiceNote(noteId: string, expectedVersion: number) {
  return callRpc<InvoiceNoteDetail>("review_invoice_note", {
    p_invoice_note_id: noteId,
    p_expected_version: expectedVersion,
  })
}

export function cancelInvoiceNote(noteId: string, expectedVersion: number) {
  return callRpc<InvoiceNoteDetail>("cancel_invoice_note", {
    p_invoice_note_id: noteId,
    p_expected_version: expectedVersion,
  })
}

/** Accounts preview only. Never issues a GST credit note or writes stock. */
export function prepareCreditAdjustment(options: {
  returnId: string
  idempotencyKey: string
  expectedVersion: number
}) {
  return callRpc<CreditAdjustmentDetail>("prepare_credit_adjustment", {
    p_return_id: options.returnId,
    p_idempotency_key: options.idempotencyKey,
    p_expected_version: options.expectedVersion,
  })
}

export function getCreditAdjustment(adjustmentId: string) {
  return callRpc<CreditAdjustmentDetail>("get_credit_adjustment", {
    p_adjustment_id: adjustmentId,
  })
}

export function listCreditAdjustments(options: { status?: string; branchId?: string } = {}) {
  return callRpc<CreditAdjustmentListRow[]>("list_credit_adjustments", {
    p_status: options.status && options.status !== "all" ? options.status : null,
    p_branch_id: options.branchId && options.branchId !== "all" ? options.branchId : null,
  })
}
