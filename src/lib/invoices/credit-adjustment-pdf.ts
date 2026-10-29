/**
 * Snapshot-backed A4 PDF for internal credit-adjustment previews.
 * Amounts are copied from the authorized RPC payload. This module does not
 * recalculate GST or allocate a statutory credit-note number.
 */
import { jsPDF } from "jspdf"
import autoTable from "jspdf-autotable"
import type { CreditAdjustmentDetail } from "@/lib/invoices/api"
import {
  CREDIT_ADJUSTMENT_WATERMARK,
  creditAdjustmentStatusLabel,
  isCreditAdjustmentStatus,
} from "@/lib/invoices/rules"

function inr(amount: number | string | null | undefined) {
  const value = typeof amount === "number" ? amount : Number(amount ?? Number.NaN)
  if (!Number.isFinite(value)) return "—"
  return `INR ${new Intl.NumberFormat("en-IN", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(value)}`
}

function text(value: string | null | undefined) {
  const trimmed = value?.trim()
  return trimmed ? trimmed : "—"
}

function drawWatermark(doc: jsPDF) {
  const { width, height } = doc.internal.pageSize
  doc.saveGraphicsState()
  doc.setTextColor(220, 90, 90)
  doc.setFont("helvetica", "bold")
  doc.setFontSize(14)
  doc.text(CREDIT_ADJUSTMENT_WATERMARK, width / 2, height / 2, {
    align: "center",
    angle: -24,
  })
  doc.restoreGraphicsState()
}

export function creditAdjustmentPdfFilename(row: CreditAdjustmentDetail) {
  return `${row.adjustment_number}-credit-adjustment-preview.pdf`
}

/** Build a downloadable PDF from the credit-adjustment RPC payload. */
export function buildCreditAdjustmentPdf(row: CreditAdjustmentDetail): Uint8Array {
  const doc = new jsPDF({ orientation: "portrait", unit: "mm", format: "a4" })
  const pageWidth = doc.internal.pageSize.getWidth()
  const generated = row.generated_at
    ? `${String(row.generated_at).replace("T", " ").slice(0, 19)} UTC`
    : "—"
  let tableEndY = 40

  const paintChrome = (page: number) => {
    drawWatermark(doc)
    doc.setTextColor(20, 20, 20)
    doc.setFont("helvetica", "bold")
    doc.setFontSize(11)
    doc.text("INTERNAL CREDIT ADJUSTMENT PREVIEW", 12, 12)
    doc.setFont("helvetica", "normal")
    doc.setFontSize(8)
    doc.setTextColor(160, 40, 40)
    doc.text(CREDIT_ADJUSTMENT_WATERMARK, 12, 17)
    doc.setTextColor(80, 80, 80)
    doc.text(`Page ${page}`, pageWidth - 12, 12, { align: "right" })
    doc.text("NO LEGAL CREDIT NOTE NUMBER", pageWidth - 12, 17, { align: "right" })
  }

  paintChrome(1)
  let y = 24
  doc.setTextColor(20, 20, 20)
  doc.setFont("helvetica", "bold")
  doc.setFontSize(13)
  doc.text(text(row.shop_name), 12, y)
  y += 6

  const meta: [string, string][] = [
    ["Adjustment", row.adjustment_number],
    ["Invoice note", text(row.invoice_note_number)],
    ["Dispatch", text(row.dispatch_number)],
    ["Verified return", text(row.return_number)],
    ["Return status", text(row.return_status)],
    ["Tax preview", text(row.tax_preview_state)],
    [
      "Internal status",
      isCreditAdjustmentStatus(row.status)
        ? creditAdjustmentStatusLabel[row.status]
        : text(row.status),
    ],
    ["Reviewer", text(row.reviewer_name)],
    [
      "Remaining eligible",
      row.reconciliation ? String(row.reconciliation.remaining_eligible_cases) : "—",
    ],
    ["Snapshot", generated],
    ["Legal credit note", "not allocated"],
  ]
  doc.setFont("helvetica", "normal")
  doc.setFontSize(8)
  meta.forEach(([label, value], index) => {
    const col = index % 2
    const rowIndex = Math.floor(index / 2)
    const x = 12 + col * 95
    const yy = y + rowIndex * 8
    doc.setTextColor(90, 90, 90)
    doc.text(label, x, yy)
    doc.setTextColor(20, 20, 20)
    doc.text(value, x, yy + 4)
  })
  y += Math.ceil(meta.length / 2) * 8 + 4

  autoTable(doc, {
    startY: y,
    margin: { left: 12, right: 12, top: 22, bottom: 18 },
    head: [["Product", "Cases", "Billed qty", "Unit", "Subtotal", "Tax", "Total"]],
    body: row.lines.map((line) => [
      `${text(line.product_name)}\n${text(line.product_sku)}`,
      String(line.credited_cases),
      `${String(line.billed_quantity)} ${line.billing_unit}`,
      inr(line.unit_amount),
      inr(line.line_subtotal),
      inr(line.tax_amount),
      inr(line.line_total),
    ]),
    styles: { fontSize: 8, cellPadding: 1.6, overflow: "linebreak" },
    headStyles: { fillColor: [14, 28, 51], textColor: 255 },
    didDrawPage: (data) => {
      if (data.pageNumber > 1) paintChrome(data.pageNumber)
      if (data.cursor) tableEndY = data.cursor.y
    },
  })

  let foot = tableEndY + 8
  doc.setFontSize(9)
  doc.setTextColor(20, 20, 20)
  doc.text(`Subtotal ${inr(row.subtotal_amount)}`, 12, foot)
  foot += 4
  doc.text(`CGST ${inr(row.cgst_amount)}  SGST ${inr(row.sgst_amount)}  IGST ${inr(row.igst_amount)}`, 12, foot)
  foot += 4
  doc.setFont("helvetica", "bold")
  doc.text(`Preview total ${inr(row.adjustment_total)}`, 12, foot)
  foot += 8
  doc.setFont("helvetica", "normal")
  doc.setFontSize(8)
  doc.setTextColor(160, 40, 40)
  doc.text(CREDIT_ADJUSTMENT_WATERMARK, 12, foot)
  return new Uint8Array(doc.output("arraybuffer"))
}

export function downloadCreditAdjustmentPdf(row: CreditAdjustmentDetail) {
  const bytes = buildCreditAdjustmentPdf(row)
  const blob = new Blob([Uint8Array.from(bytes)], { type: "application/pdf" })
  const url = URL.createObjectURL(blob)
  const link = document.createElement("a")
  link.href = url
  link.download = creditAdjustmentPdfFilename(row)
  link.click()
  URL.revokeObjectURL(url)
}
