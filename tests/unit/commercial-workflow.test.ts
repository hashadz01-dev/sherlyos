import { describe, expect, it } from "vitest"
import { SHORT_SHIPMENT_OPERATIONAL } from "@/lib/picking/rules"
import {
  CREDIT_ADJUSTMENT_WATERMARK,
  INVOICE_DRAFT_WATERMARK,
  formatInr,
} from "@/lib/invoices/rules"

/**
 * Independent billed-unit oracle used by M7.5F HTTP/SQL proofs.
 * Do not import gst_line_calc or server RPCs here.
 */
function billedQuantity(cases: number, unitsPerCase: number) {
  return cases * unitsPerCase
}

function lineSubtotal(quantity: number, unitAmount: number) {
  return Number((quantity * unitAmount).toFixed(2))
}

function exclusiveTax(lineAmount: number, cgstRate: number, sgstRate: number) {
  const taxable = Number(lineAmount.toFixed(2))
  const cgst = Number((taxable * cgstRate / 100).toFixed(2))
  const sgst = Number((taxable * sgstRate / 100).toFixed(2))
  return { taxable, cgst, sgst, tax: Number((cgst + sgst).toFixed(2)) }
}

describe("M7.5F independent commercial math", () => {
  it("converts whole cases through billed units and historical unit price", () => {
    expect(billedQuantity(2, 12)).toBe(24)
    expect(lineSubtotal(24, 11)).toBe(264)
    expect(lineSubtotal(6, 7.25)).toBe(43.5)
    expect(lineSubtotal(12, 11)).toBe(132)
    expect(formatInr(132)).toMatch(/132/)
  })

  it("keeps exclusive GST rounding on 0.01 boundaries without inventing tax", () => {
    const zero = exclusiveTax(43.5, 0, 0)
    expect(zero.tax).toBe(0)
    const taxed = exclusiveTax(264, 2.5, 2.5)
    expect(taxed.taxable).toBe(264)
    expect(taxed.cgst).toBe(6.6)
    expect(taxed.sgst).toBe(6.6)
    expect(taxed.tax).toBe(13.2)
  })

  it("keeps commercial documents non-statutory", () => {
    expect(INVOICE_DRAFT_WATERMARK).toMatch(/NOT A TAX INVOICE/)
    expect(CREDIT_ADJUSTMENT_WATERMARK).toMatch(/NOT A GST CREDIT NOTE/)
    expect(SHORT_SHIPMENT_OPERATIONAL).toBe(false)
  })
})
