/**
 * M8.2B.1 shop statement rules. Payment posting is not implemented.
 * Invoice notes stay drafts. Credit adjustments stay internal previews.
 */

import { formatInr } from "@/lib/invoices/rules"
import { SHORT_SHIPMENT_OPERATIONAL } from "@/lib/picking/rules"

export const SHOP_STATEMENT_PERMISSION = "shops.statement.read"

export const shopStatementNavPermissions = [SHOP_STATEMENT_PERMISSION] as const

export const SHOP_STATEMENT_WATERMARK =
  "SALES STATEMENT PREVIEW — NOT A TAX LEDGER — PAYMENTS NOT POSTED"

export const PAYMENT_UNAVAILABLE_REASON =
  "Customer receipts and receivables are not implemented. Cash received and outstanding balance are not shown as zero."

export const shopDetailTabs = [
  "overview",
  "orders",
  "deliveries",
  "statement",
  "payments",
] as const

export type ShopDetailTab = (typeof shopDetailTabs)[number]

export type StatementSourceType = "invoice_note" | "delivery_note" | "credit_adjustment"

export type StatementMoney = {
  available: boolean
  amount: number | string | null
  display: string
}

export type ShopStatementEntry = {
  id: string
  sourceType: StatementSourceType
  sourceId: string
  transactionDate: string
  particulars: string
  referenceNumber: string
  billAmount: StatementMoney
  amountReceived: StatementMoney
  runningBalance: StatementMoney
  acknowledgement: string | null
  remarks: string | null
  status: string
  statusLabel: string
  href: string | null
}

export type ShopStatementSummary = {
  invoiceNoteCount: number
  deliveryNoteCount: number
  creditAdjustmentCount: number
  reviewedNoteTotal: StatementMoney
  submittedNoteTotal: StatementMoney
  draftNoteTotal: StatementMoney
  creditAdjustmentPreviewTotal: StatementMoney
  amountReceived: StatementMoney
  outstanding: StatementMoney
}

/** Payment columns stay unavailable. Never coerce a missing receipt to 0. */
export function unavailableMoney(): StatementMoney {
  return { available: false, amount: null, display: "Unavailable" }
}

function asNumber(value: number | string | null | undefined) {
  if (value == null || value === "") return null
  const parsed = typeof value === "number" ? value : Number(value)
  return Number.isFinite(parsed) ? parsed : null
}

/** Billed amounts may be shown. Empty billed cells are an em dash, never ₹0.00. */
export function billedMoney(amount: number | string | null | undefined): StatementMoney {
  const parsed = asNumber(amount)
  if (parsed == null) {
    return { available: true, amount: null, display: "—" }
  }
  return { available: true, amount: parsed, display: formatInr(parsed) }
}

export function isShopDetailTab(value: string): value is ShopDetailTab {
  return (shopDetailTabs as readonly string[]).includes(value)
}

export function statementEntryKey(sourceType: StatementSourceType, sourceId: string) {
  return `${sourceType}:${sourceId}`
}

/**
 * One row per source document. Same invoice note listed twice is dropped.
 * Payment fields are forced unavailable even if a caller passes a number.
 */
export function dedupeStatementEntries(entries: ShopStatementEntry[]) {
  const seen = new Set<string>()
  const rows: ShopStatementEntry[] = []
  for (const entry of entries) {
    const key = statementEntryKey(entry.sourceType, entry.sourceId)
    if (seen.has(key)) continue
    seen.add(key)
    rows.push({
      ...entry,
      id: key,
      amountReceived: unavailableMoney(),
      runningBalance: unavailableMoney(),
    })
  }
  return rows.sort((left, right) => {
    const date = left.transactionDate.localeCompare(right.transactionDate)
    if (date !== 0) return date
    const type = left.sourceType.localeCompare(right.sourceType)
    if (type !== 0) return type
    return left.sourceId.localeCompare(right.sourceId)
  })
}

export function summarizeStatement(entries: ShopStatementEntry[]): ShopStatementSummary {
  const sum = (type: StatementSourceType, status: string) =>
    entries
      .filter((row) => row.sourceType === type && row.status === status)
      .reduce((total, row) => total + (asNumber(row.billAmount.amount) ?? 0), 0)

  const reviewedRows = entries.filter((row) => row.sourceType === "invoice_note" && row.status === "reviewed")
  const submittedRows = entries.filter((row) => row.sourceType === "invoice_note" && row.status === "submitted")
  const draftRows = entries.filter((row) => row.sourceType === "invoice_note" && row.status === "draft")
  const creditRows = entries.filter((row) => row.sourceType === "credit_adjustment")

  return {
    invoiceNoteCount: entries.filter((row) => row.sourceType === "invoice_note").length,
    deliveryNoteCount: entries.filter((row) => row.sourceType === "delivery_note").length,
    creditAdjustmentCount: creditRows.length,
    reviewedNoteTotal: billedMoney(reviewedRows.length ? sum("invoice_note", "reviewed") : null),
    submittedNoteTotal: billedMoney(submittedRows.length ? sum("invoice_note", "submitted") : null),
    draftNoteTotal: billedMoney(draftRows.length ? sum("invoice_note", "draft") : null),
    creditAdjustmentPreviewTotal: billedMoney(creditRows.length ? creditRows.reduce((total, row) => total + (asNumber(row.billAmount.amount) ?? 0), 0) : null),
    amountReceived: unavailableMoney(),
    outstanding: unavailableMoney(),
  }
}

export function invoiceNoteParticulars() {
  return "Invoice note (not a tax invoice)"
}

export function creditAdjustmentParticulars() {
  return "Credit adjustment preview (not a GST credit note)"
}

export function deliveryNoteParticulars() {
  return "Delivery note"
}

export function invoiceNoteStatusLabel(status: string) {
  if (status === "draft") return "Draft — not a tax invoice"
  if (status === "submitted") return "Submitted — not a tax invoice"
  if (status === "reviewed") return "Reviewed — still not a tax invoice"
  if (status === "cancelled") return "Cancelled"
  return status
}

/** Credit-adjustment rows stay labelled as previews, never GST credit notes. */
export function creditAdjustmentStatusLabel(status: string) {
  if (status === "preview") return "Prepared — not a GST credit note"
  if (status === "blocked") return "Blocked — not a GST credit note"
  if (status === "approved") return "Approved (internal) — not a GST credit note"
  if (status === "rejected") return "Rejected"
  return status
}

/** Cutover flags stay off. This module must not flip them. */
export function shopStatementFlagsUnchanged() {
  return SHORT_SHIPMENT_OPERATIONAL === false
}
