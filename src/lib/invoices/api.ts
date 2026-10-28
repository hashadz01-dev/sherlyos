import { callRpc } from "@/lib/masters/api"
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
  unit_amount: number | string
  line_amount: number | string
  price_scope: "shop" | "default"
  price_effective_from: string
  price_effective_to: string | null
  tax_amount: number | string
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
  issuable: boolean
  reason: string
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
  }
  branch_id: string
  as_of_date: string
  dispatch_confirmed_at: string
  currency_code: "INR"
  billed_cases: number
  billed_quantity: number | string
  subtotal_amount: number | string
  tax_amount: number | string
  grand_total: number | string
  amount_in_words: string
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
  copy_label?: string
  legal_seal_caption?: string
  signature_block?: { shown: boolean; reason: string }
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
