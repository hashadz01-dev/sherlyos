import { describe, expect, it } from "vitest"
import {
  INVOICE_DRAFT_WATERMARK,
  INVOICE_NO_LEGAL_SEAL,
  formatInr,
  invoiceEventLabel,
  isInvoiceNoteStatus,
} from "@/lib/invoices/rules"
import { SHORT_SHIPMENT_OPERATIONAL } from "@/lib/picking/rules"

describe("invoice-note presentation", () => {
  it("keeps the draft watermark and withholds the legal seal", () => {
    expect(INVOICE_DRAFT_WATERMARK).toBe("DRAFT INVOICE NOTE — NOT A TAX INVOICE")
    expect(INVOICE_NO_LEGAL_SEAL).toMatch(/NO LEGAL SEAL/i)
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
