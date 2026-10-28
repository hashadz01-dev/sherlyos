import { describe, expect, it } from "vitest"
import type { InvoiceNoteDetail } from "@/lib/invoices/api"
import {
  buildInvoiceHandoverPdf,
  handoverPdfFilename,
} from "@/lib/invoices/handover-pdf"
import {
  INVOICE_DRAFT_WATERMARK,
  INVOICE_NO_LEGAL_SEAL,
  INVOICE_PREVIEW_WATERMARK,
  TAX_PREVIEW_WATERMARK,
  formatInr,
  invoiceEventLabel,
  isDriverHandoverCopy,
  isInvoiceHandoverCopy,
  isInvoiceNoteStatus,
} from "@/lib/invoices/rules"
import { SHORT_SHIPMENT_OPERATIONAL } from "@/lib/picking/rules"

function sampleNote(overrides: Partial<InvoiceNoteDetail> = {}): InvoiceNoteDetail {
  return {
    id: "11111111-1111-4111-8111-111111111111",
    note_number: "IN-20261028-000001",
    status: "reviewed",
    version: 3,
    idempotency_key: "sample",
    dispatch_id: "22222222-2222-4222-8222-222222222222",
    dispatch_number: "DSP-1",
    order_id: "33333333-3333-4333-8333-333333333333",
    order_number: "ORD-1",
    shop_id: "44444444-4444-4444-8444-444444444444",
    shop: { id: "44444444-4444-4444-8444-444444444444", name: "Sample shop", address: "12 Market Road" },
    branch_id: "55555555-5555-4555-8555-555555555555",
    as_of_date: "2026-10-28",
    dispatch_confirmed_at: "2026-10-28T08:00:00Z",
    currency_code: "INR",
    billed_cases: 2,
    billed_quantity: "24",
    subtotal_amount: "252.00",
    tax_amount: "0",
    grand_total: "252.00",
    amount_in_words: "Two hundred fifty-two rupees only",
    remarks: null,
    watermark: INVOICE_PREVIEW_WATERMARK,
    legal_issuance_blocked: true,
    has_legal_seal: false,
    company: { ready: false, legal_name: null, registered_address: null, tax_id: null },
    statutory: { ready: false, legal_issuance_blocked: true, currency_code: "INR", blockers: [] },
    submitted_at: null,
    reviewed_at: "2026-10-28T09:00:00Z",
    cancelled_at: null,
    created_at: "2026-10-28T07:00:00Z",
    lines: [
      {
        id: "66666666-6666-4666-8666-666666666666",
        line_no: 1,
        order_line_id: "77777777-7777-4777-8777-777777777777",
        product_id: "88888888-8888-4888-8888-888888888888",
        lot_id: "99999999-9999-4999-8999-999999999999",
        crate_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        product_sku: "SOAP-1",
        product_name: "Sample soap with a deliberately long product description for wrapping",
        shipped_cases: 2,
        billing_unit: "nos",
        billed_units_per_case: "12",
        billed_quantity: "24",
        unit_amount: "10.50",
        line_amount: "252.00",
        price_scope: "default",
        price_effective_from: "2020-01-01",
        price_effective_to: null,
        tax_amount: "0",
      },
    ],
    events: [],
    credit_note_candidates: [],
    copy: "driver",
    copy_family: "driver",
    copy_label: "DRIVER / DELIVERY HANDOVER COPY",
    generated_at: "2026-10-28T10:00:00Z",
    legal_invoice_number: null,
    handover_acknowledgement: {
      driver_signature_label: "Driver signature (acknowledgement only)",
      receiver_signature_label: "Receiver signature (acknowledgement only)",
      note: "This copy is not a tax invoice and does not authorize stock or payment.",
    },
    ...overrides,
  }
}

describe("invoice-note presentation", () => {
  it("keeps the draft watermark and withholds the legal seal", () => {
    expect(INVOICE_DRAFT_WATERMARK).toBe("DRAFT INVOICE NOTE — NOT A TAX INVOICE")
    expect(INVOICE_PREVIEW_WATERMARK).toBe("DRAFT INVOICE PREVIEW — NOT A TAX INVOICE")
    expect(INVOICE_NO_LEGAL_SEAL).toMatch(/NO LEGAL SEAL/i)
    expect(TAX_PREVIEW_WATERMARK).toBe("TAX CALCULATION PREVIEW — NOT A TAX INVOICE")
    expect(isDriverHandoverCopy("transporter")).toBe(true)
    expect(isInvoiceHandoverCopy("accounts")).toBe(true)
    expect(isInvoiceHandoverCopy("recipient")).toBe(false)
  })

  it("formats INR without inventing another currency", () => {
    expect(formatInr(196.5)).toMatch(/₹/)
    expect(formatInr(196.5)).toMatch(/196\.50/)
  })

  it("accepts only draft lifecycle statuses", () => {
    expect(isInvoiceNoteStatus("draft")).toBe(true)
    expect(isInvoiceNoteStatus("issued")).toBe(false)
    expect(invoiceEventLabel("reviewed")).toBe("Reviewed by Accounts")
  })

  it("does not treat short-shipment as operational", () => {
    expect(SHORT_SHIPMENT_OPERATIONAL).toBe(false)
  })
})

describe("invoice handover PDF", () => {
  it("embeds the preview watermark and does not invent a legal invoice number", () => {
    const pdf = buildInvoiceHandoverPdf(sampleNote())
    const ascii = new TextDecoder("latin1").decode(pdf)
    expect(ascii.startsWith("%PDF")).toBe(true)
    expect(ascii).toContain("NOT A TAX INVOICE")
    expect(ascii).toContain("DRIVER")
    expect(ascii).not.toContain("TAX-INV")
    expect(handoverPdfFilename(sampleNote())).toBe("IN-20261028-000001-driver-preview.pdf")
  })

  it("paginates long item tables across more than one A4 page", () => {
    const lines = Array.from({ length: 48 }, (_, index) => ({
      ...sampleNote().lines[0],
      id: `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
      line_no: index + 1,
      product_name: `Long product name ${index} ${"x".repeat(40)}`,
    }))
    const pdf = buildInvoiceHandoverPdf(sampleNote({ lines }))
    const ascii = new TextDecoder("latin1").decode(pdf)
    expect(ascii).toMatch(/\/Type\s*\/Pages/)
    expect(ascii).toContain("Count")
    const count = ascii.match(/\/Count\s+(\d+)/)
    expect(Number(count?.[1] ?? 0)).toBeGreaterThan(1)
  })
})
