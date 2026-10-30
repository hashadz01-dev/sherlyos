/**
 * Printable shop statement PDF. Amounts are copied from the authorized
 * statement payload. This module does not invent receipts or balances.
 */
import { jsPDF } from "jspdf"
import autoTable from "jspdf-autotable"
import type { ShopStatementView } from "@/lib/shops/api"
import { SHOP_STATEMENT_WATERMARK } from "@/lib/shops/rules"

function text(value: string | null | undefined) {
  const trimmed = value?.trim()
  return trimmed ? trimmed : "—"
}

export function shopStatementPdfFilename(view: ShopStatementView) {
  const slug = view.shop.name.replace(/[^A-Za-z0-9]+/g, "-").replace(/^-|-$/g, "")
  return `${slug || "shop"}-sales-statement-preview.pdf`
}

export function buildShopStatementPdf(view: ShopStatementView): Uint8Array {
  const doc = new jsPDF({ orientation: "landscape", unit: "mm", format: "a4" })
  const pageWidth = doc.internal.pageSize.getWidth()
  const pageHeight = doc.internal.pageSize.getHeight()

  const paintChrome = (page: number) => {
    doc.setTextColor(200, 80, 80)
    doc.setFont("helvetica", "bold")
    doc.setFontSize(11)
    doc.text(SHOP_STATEMENT_WATERMARK, pageWidth / 2, pageHeight / 2, {
      align: "center",
      angle: -18,
    })
    doc.setTextColor(20, 20, 20)
    doc.setFont("helvetica", "bold")
    doc.setFontSize(12)
    doc.text("Sherly's Distributors & Agents", 12, 12)
    doc.setFont("helvetica", "normal")
    doc.setFontSize(8)
    doc.setTextColor(160, 40, 40)
    doc.text(SHOP_STATEMENT_WATERMARK, 12, 17)
    doc.setTextColor(80, 80, 80)
    doc.text(`Page ${page}`, pageWidth - 12, 12, { align: "right" })
  }

  paintChrome(1)
  doc.setTextColor(20, 20, 20)
  doc.setFont("helvetica", "bold")
  doc.setFontSize(14)
  doc.text(text(view.shop.name), 12, 26)
  doc.setFont("helvetica", "normal")
  doc.setFontSize(9)
  doc.text(view.shop.is_active ? "Active shop" : "Inactive shop", 12, 32)
  doc.text(view.paymentReason, 12, 37)

  let tableEndY = 42
  autoTable(doc, {
    startY: 42,
    margin: { left: 12, right: 12, top: 22, bottom: 18 },
    head: [[
      "Date",
      "Particulars",
      "Bill / ref.",
      "Bill amount",
      "Cash received",
      "Balance",
      "Ack.",
      "Remarks",
      "Status",
    ]],
    body: view.entries.map((row) => [
      row.transactionDate,
      row.particulars,
      row.referenceNumber,
      row.billAmount.display,
      row.amountReceived.display,
      row.runningBalance.display,
      text(row.acknowledgement),
      text(row.remarks),
      row.statusLabel,
    ]),
    styles: { fontSize: 8, cellPadding: 1.4 },
    headStyles: { fillColor: [15, 23, 42] },
    didDrawPage: (data) => {
      paintChrome(data.pageNumber)
      if (data.cursor) tableEndY = data.cursor.y
    },
  })

  const summaryY = Math.min(tableEndY, 180) + 8
  doc.setFont("helvetica", "bold")
  doc.setFontSize(9)
  doc.setTextColor(20, 20, 20)
  doc.text(
    [
      `Reviewed notes ${view.summary.reviewedNoteTotal.display}`,
      `Submitted notes ${view.summary.submittedNoteTotal.display}`,
      `Draft notes ${view.summary.draftNoteTotal.display}`,
      `Credit previews ${view.summary.creditAdjustmentPreviewTotal.display}`,
      `Cash received ${view.summary.amountReceived.display}`,
      `Outstanding ${view.summary.outstanding.display}`,
    ].join("   ·   "),
    12,
    summaryY,
  )

  return new Uint8Array(doc.output("arraybuffer"))
}

export function downloadShopStatementPdf(view: ShopStatementView) {
  const bytes = buildShopStatementPdf(view)
  const blob = new Blob([Uint8Array.from(bytes)], { type: "application/pdf" })
  const url = URL.createObjectURL(blob)
  const link = document.createElement("a")
  link.href = url
  link.download = shopStatementPdfFilename(view)
  link.click()
  URL.revokeObjectURL(url)
}
