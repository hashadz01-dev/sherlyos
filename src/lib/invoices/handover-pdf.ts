/**
 * Snapshot-backed A4 PDF for invoice handover previews.
 * Amounts and HSN are copied from the authorized RPC payload. This module
 * does not recalculate GST or allocate a statutory invoice number.
 */
import { jsPDF } from "jspdf"
import autoTable from "jspdf-autotable"
import type { InvoiceNoteDetail } from "@/lib/invoices/api"
import {
  INVOICE_PREVIEW_WATERMARK,
  TAX_PREVIEW_WATERMARK,
  isDriverHandoverCopy,
  type InvoicePreviewCopy,
} from "@/lib/invoices/rules"

function asCopy(note: InvoiceNoteDetail): InvoicePreviewCopy {
  return note.copy ?? "driver"
}

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
  doc.setFontSize(16)
  doc.text(INVOICE_PREVIEW_WATERMARK, width / 2, height / 2, {
    align: "center",
    angle: -24,
  })
  doc.restoreGraphicsState()
}

export function handoverPdfFilename(note: InvoiceNoteDetail) {
  const family = note.copy_family ?? (isDriverHandoverCopy(asCopy(note)) ? "driver" : "accounts")
  return `${note.note_number}-${family}-preview.pdf`
}

/** Build a downloadable PDF from the handover RPC payload. */
export function buildInvoiceHandoverPdf(note: InvoiceNoteDetail): Uint8Array {
  const doc = new jsPDF({ orientation: "portrait", unit: "mm", format: "a4" })
  const driver = isDriverHandoverCopy(asCopy(note))
  const pageWidth = doc.internal.pageSize.getWidth()
  const generated = note.generated_at
    ? `${String(note.generated_at).replace("T", " ").slice(0, 19)} UTC`
    : "—"
  let tableEndY = 40

  const paintChrome = (page: number) => {
    drawWatermark(doc)
    doc.setTextColor(20, 20, 20)
    doc.setFont("helvetica", "bold")
    doc.setFontSize(11)
    doc.text(
      note.copy_label ??
        (driver ? "DRIVER / DELIVERY HANDOVER COPY" : "ACCOUNTS / FINANCIAL PREVIEW COPY"),
      12,
      12,
    )
    doc.setFont("helvetica", "normal")
    doc.setFontSize(8)
    doc.setTextColor(160, 40, 40)
    doc.text(INVOICE_PREVIEW_WATERMARK, 12, 17)
    doc.setTextColor(80, 80, 80)
    doc.text(`Page ${page}`, pageWidth - 12, 12, { align: "right" })
    doc.text(text(note.legal_seal_caption), pageWidth - 12, 17, { align: "right" })
  }

  paintChrome(1)
  let y = 24
  doc.setTextColor(20, 20, 20)
  doc.setFont("helvetica", "bold")
  doc.setFontSize(13)
  if (driver) {
    doc.text(text(note.shop.name), 12, y)
  } else if (note.seller_identity?.available) {
    doc.text(text(note.seller_identity.legal_name), 12, y)
  } else {
    doc.text("Verified seller identity unavailable", 12, y)
  }
  y += 5
  doc.setFont("helvetica", "normal")
  doc.setFontSize(9)
  const identityLines = driver
    ? [text(note.shop.address), note.godown ? `From godown ${note.godown.name} (${note.godown.code})` : ""]
    : [
        note.seller_identity?.available
          ? text(note.seller_identity.registered_address)
          : text(note.seller_identity?.reason),
        note.seller_identity?.available && note.seller_identity.gstin
          ? `GSTIN ${note.seller_identity.gstin}`
          : "",
      ]
  for (const line of identityLines.filter(Boolean)) {
    const wrapped = doc.splitTextToSize(line, pageWidth - 24)
    doc.text(wrapped, 12, y)
    y += wrapped.length * 4
  }

  y += 2
  const meta: [string, string][] = [
    ["Draft note", note.note_number],
    ["Dispatch", text(note.dispatch_number)],
    ["Dispatch date", text(note.as_of_date ?? note.dispatch_confirmed_at?.slice(0, 10))],
    ["Shop", text(note.shop.name)],
  ]
  if (!driver) {
    meta.push(["Invoice-note status", note.status])
    meta.push(["Generated", generated])
  } else {
    meta.push(["Delivery location", text(note.shop.address)])
  }
  doc.setFontSize(8)
  meta.forEach(([label, value], index) => {
    const col = index % 2
    const row = Math.floor(index / 2)
    const x = 12 + col * 95
    const yy = y + row * 8
    doc.setTextColor(90, 90, 90)
    doc.text(label, x, yy)
    doc.setTextColor(20, 20, 20)
    doc.text(value, x, yy + 4)
  })
  y += Math.ceil(meta.length / 2) * 8 + 4

  const tableHooks = {
    didDrawPage: (data: { pageNumber: number; cursor: { y: number } | null }) => {
      if (data.pageNumber > 1) paintChrome(data.pageNumber)
      if (data.cursor) tableEndY = data.cursor.y
    },
  }

  if (driver) {
    autoTable(doc, {
      startY: y,
      margin: { left: 12, right: 12, top: 22, bottom: 18 },
      head: [["Product", "SKU", "Cases", "Billing units"]],
      body: note.lines.map((line) => [
        text(line.product_name),
        text(line.product_sku),
        String(line.shipped_cases),
        `${String(line.billed_quantity)} ${line.billing_unit}`,
      ]),
      styles: { fontSize: 8, cellPadding: 1.6, overflow: "linebreak" },
      headStyles: { fillColor: [14, 28, 51], textColor: 255 },
      ...tableHooks,
    })
    let foot = tableEndY + 10
    doc.setFontSize(9)
    doc.text(note.handover_acknowledgement?.note ?? "This copy is not a tax invoice.", 12, foot)
    foot += 12
    doc.line(12, foot, 80, foot)
    doc.line(110, foot, 198, foot)
    doc.setFontSize(8)
    doc.text(
      note.handover_acknowledgement?.driver_signature_label ?? "Driver signature",
      12,
      foot + 5,
    )
    doc.text(
      note.handover_acknowledgement?.receiver_signature_label ?? "Receiver signature",
      110,
      foot + 5,
    )
  } else {
    if (note.customer_identity?.available) {
      doc.setFontSize(8)
      doc.setTextColor(90, 90, 90)
      doc.text("Customer (verified tax identity)", 12, y)
      doc.setTextColor(20, 20, 20)
      y += 4
      doc.text(text(note.customer_identity.billing_name), 12, y)
      y += 4
      const addr = doc.splitTextToSize(text(note.customer_identity.billing_address), pageWidth - 24)
      doc.text(addr, 12, y)
      y += addr.length * 4
      if (note.customer_identity.gstin) {
        doc.text(`GSTIN ${note.customer_identity.gstin}`, 12, y)
        y += 4
      }
    } else {
      doc.setFontSize(8)
      doc.setTextColor(120, 60, 20)
      doc.text(text(note.customer_identity?.reason) || "Customer tax identity unavailable.", 12, y)
      y += 6
      doc.setTextColor(20, 20, 20)
    }

    autoTable(doc, {
      startY: y,
      margin: { left: 12, right: 12, top: 22, bottom: 22 },
      head: [["Product", "HSN", "Cases", "Billed qty", "Rate", "Line", "Taxable", "Tax", "Total"]],
      body: note.lines.map((line) => {
        const previewLine = note.tax_preview?.lines?.find(
          (row) => row.invoice_note_line_id === line.id,
        )
        const taxReady = note.financial_preview_state === "tax_preview"
        return [
          text(line.product_name),
          text(line.hsn_sac_code),
          String(line.shipped_cases),
          `${String(line.billed_quantity)} ${line.billing_unit}`,
          inr(line.unit_amount),
          inr(line.line_amount),
          taxReady ? inr(previewLine?.taxable_value) : "—",
          taxReady ? inr(previewLine?.tax_amount) : "—",
          taxReady ? inr(previewLine?.line_total) : "—",
        ]
      }),
      styles: { fontSize: 7, cellPadding: 1.2, overflow: "linebreak" },
      headStyles: { fillColor: [14, 28, 51], textColor: 255 },
      ...tableHooks,
    })
    let foot = tableEndY + 8
    doc.setFontSize(9)
    doc.setTextColor(160, 40, 40)
    doc.text(note.tax_preview_watermark ?? TAX_PREVIEW_WATERMARK, 12, foot)
    foot += 5
    doc.setTextColor(20, 20, 20)
    if (note.financial_preview_state === "tax_preview") {
      doc.text(`Taxable ${inr(note.tax_preview?.taxable_value)}`, 12, foot)
      doc.text(`CGST ${inr(note.tax_preview?.cgst_amount)}`, 70, foot)
      doc.text(`SGST ${inr(note.tax_preview?.sgst_amount)}`, 120, foot)
      foot += 5
      doc.text(`IGST ${inr(note.tax_preview?.igst_amount)}`, 12, foot)
      doc.text(`Tax preview ${inr(note.tax_preview?.tax_amount)}`, 70, foot)
      doc.text(`Preview total ${inr(note.tax_preview?.invoice_total)}`, 120, foot)
    } else if (note.financial_preview_state === "tax_stale") {
      doc.setTextColor(120, 60, 20)
      doc.text(
        "Tax preview is stale. Stored preview amounts are shown only as a warning and are not current.",
        12,
        foot,
      )
    } else {
      doc.setTextColor(120, 60, 20)
      doc.text("Tax preview unavailable. Totals are not invented.", 12, foot)
    }
    foot += 8
    doc.setTextColor(20, 20, 20)
    doc.setFontSize(8)
    doc.text(
      `Reviewed snapshot total ${inr(note.grand_total)} (tax_amount on the note remains 0).`,
      12,
      foot,
    )
    foot += 4
    doc.text(
      `Source note ${note.source?.invoice_note_id ?? note.id} v${note.source?.invoice_note_version ?? note.version}.`,
      12,
      foot,
    )
    foot += 4
    doc.text(`Generated ${generated}. No legal invoice number is allocated.`, 12, foot)
  }

  return new Uint8Array(doc.output("arraybuffer"))
}

export function downloadInvoiceHandoverPdf(note: InvoiceNoteDetail) {
  const bytes = buildInvoiceHandoverPdf(note)
  const blob = new Blob([Uint8Array.from(bytes)], { type: "application/pdf" })
  const url = URL.createObjectURL(blob)
  const link = document.createElement("a")
  link.href = url
  link.download = handoverPdfFilename(note)
  link.click()
  URL.revokeObjectURL(url)
}
