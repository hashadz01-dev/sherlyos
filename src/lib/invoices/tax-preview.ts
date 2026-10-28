/**
 * M7.5C.2 tax-calculation preview client.
 * Amounts are NUMERIC strings from Postgres. This module does not compute GST.
 */
import { callRpc } from "@/lib/masters/api"

/** Matches the database watermark. Client code must not compute GST amounts. */
export const TAX_PREVIEW_WATERMARK = "TAX CALCULATION PREVIEW — NOT A TAX INVOICE"

export type InvoiceTaxPreviewLine = {
  invoice_note_line_id?: string
  product_id: string
  hsn_sac_code: string
  taxable_value: number | string
  cgst_amount: number | string
  sgst_amount: number | string
  igst_amount: number | string
  tax_amount: number | string
  line_total: number | string
}

export type InvoiceTaxPreview = {
  id?: string
  watermark: string
  calculated: boolean
  stale?: boolean
  ready: boolean
  legal_issuance_blocked: boolean
  blockers?: { code: string; message: string }[]
  pricing_treatment?: string
  supply_kind?: string
  taxable_value?: number | string
  cgst_amount?: number | string
  sgst_amount?: number | string
  igst_amount?: number | string
  tax_amount?: number | string
  invoice_total?: number | string
  input_fingerprint?: string
  lines?: InvoiceTaxPreviewLine[]
  returns_not_netted?: boolean
}

export function previewInvoiceTax(noteId: string, expectedVersion: number) {
  return callRpc<InvoiceTaxPreview>("preview_invoice_tax", {
    p_invoice_note_id: noteId,
    p_expected_version: expectedVersion,
  })
}

export function getInvoiceTaxPreview(noteId: string) {
  return callRpc<InvoiceTaxPreview>("get_invoice_tax_preview", {
    p_invoice_note_id: noteId,
  })
}
