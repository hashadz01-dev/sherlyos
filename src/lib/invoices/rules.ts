/**
 * M7.5B invoice-note draft rules.
 * These notes are not tax invoices. Finalization stays blocked until
 * accountant-approved GST, numbering, and date rules exist.
 */

export const invoiceNoteStatuses = [
  "draft",
  "submitted",
  "reviewed",
  "cancelled",
] as const

export type InvoiceNoteStatus = (typeof invoiceNoteStatuses)[number]

export const invoiceNoteStatusLabel: Record<InvoiceNoteStatus, string> = {
  draft: "Draft",
  submitted: "Submitted",
  reviewed: "Reviewed",
  cancelled: "Cancelled",
}

export const invoiceNoteStatusTone: Record<
  InvoiceNoteStatus,
  "neutral" | "info" | "success" | "warning" | "danger"
> = {
  draft: "neutral",
  submitted: "warning",
  reviewed: "info",
  cancelled: "danger",
}

export const invoiceNavPermissions = [
  "invoice_notes.prepare",
  "invoices.review",
  "operations.monitor",
] as const

export const invoicePreparePermissions = ["invoice_notes.prepare"] as const
export const invoiceReviewPermissions = ["invoices.review"] as const
export const priceNavPermissions = [
  "products.price.manage",
  "products.price.read",
] as const

export const INVOICE_DRAFT_WATERMARK = "DRAFT INVOICE NOTE — NOT A TAX INVOICE"
export const INVOICE_NO_LEGAL_SEAL = "NO LEGAL SEAL — DRAFT ONLY"

export const invoicePreviewCopies = ["recipient", "transporter", "accounts"] as const
export type InvoicePreviewCopy = (typeof invoicePreviewCopies)[number]

export const invoicePreviewCopyLabel: Record<InvoicePreviewCopy, string> = {
  recipient: "Recipient copy",
  transporter: "Transporter / driver copy",
  accounts: "Accounts copy",
}

export function isInvoiceNoteStatus(value: string): value is InvoiceNoteStatus {
  return (invoiceNoteStatuses as readonly string[]).includes(value)
}

/** INR display. Amounts stay NUMERIC on the server; this is presentation only. */
export function formatInr(amount: number | string | null | undefined) {
  const value = typeof amount === "number" ? amount : Number(amount ?? 0)
  if (!Number.isFinite(value)) return "—"
  return new Intl.NumberFormat("en-IN", {
    style: "currency",
    currency: "INR",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(value)
}

export function invoiceEventLabel(eventType: string) {
  if (eventType === "prepared") return "Draft prepared"
  if (eventType === "submitted") return "Submitted for review"
  if (eventType === "reviewed") return "Reviewed by Accounts"
  if (eventType === "cancelled") return "Cancelled"
  return eventType
}
