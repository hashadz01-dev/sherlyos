import { describe, expect, it } from "vitest"
import type { CreditAdjustmentDetail } from "@/lib/invoices/api"
import {
  buildCreditAdjustmentPdf,
  creditAdjustmentPdfFilename,
} from "@/lib/invoices/credit-adjustment-pdf"
import {
  CREDIT_ADJUSTMENT_WATERMARK,
  creditAdjustmentNavPermissions,
  formatInr,
} from "@/lib/invoices/rules"

function sampleAdjustment(
  overrides: Partial<CreditAdjustmentDetail> = {},
): CreditAdjustmentDetail {
  return {
    id: "11111111-1111-4111-8111-111111111111",
    adjustment_number: "CA-20261028-000001",
    status: "preview",
    version: 1,
    watermark: CREDIT_ADJUSTMENT_WATERMARK,
    legal_credit_note_number: null,
    legal_issuance_blocked: true,
    tax_preview_state: "tax_unavailable",
    tax_preview_id: null,
    tax_input_fingerprint: null,
    return_id: "22222222-2222-4222-8222-222222222222",
    return_number: "RET-1",
    return_status: "closed_missing",
    dispatch_id: "33333333-3333-4333-8333-333333333333",
    dispatch_number: "DS-1",
    invoice_note_id: "44444444-4444-4444-8444-444444444444",
    invoice_note_number: "IN-20261028-000001",
    invoice_note_version: 3,
    shop_id: "55555555-5555-4555-8555-555555555555",
    shop_name: "Sample shop",
    branch_id: "66666666-6666-4666-8666-666666666666",
    credited_cases: 1,
    credited_quantity: "12",
    subtotal_amount: "126.00",
    cgst_amount: "0",
    sgst_amount: "0",
    igst_amount: "0",
    tax_amount: "0",
    adjustment_total: "126.00",
    blockers: [
      {
        code: "gst_credit_note_disabled",
        message: "This preview is not a GST credit note and does not allocate a legal credit-note number.",
      },
      {
        code: "tax_preview_missing",
        message: "No current tax-preview snapshot exists. Tax components are not invented.",
      },
    ],
    created_at: "2026-10-28T10:00:00Z",
    generated_at: "2026-10-28T10:00:00Z",
    lines: [
      {
        id: "77777777-7777-4777-8777-777777777777",
        line_no: 1,
        product_id: "88888888-8888-4888-8888-888888888888",
        product_sku: "SOAP-1",
        product_name: "Sample soap with a deliberately long product description for wrapping",
        original_shipped_cases: 2,
        credited_cases: 1,
        billing_unit: "nos",
        billed_units_per_case: "12",
        billed_quantity: "12",
        unit_amount: "10.50",
        line_subtotal: "126.00",
        taxable_value: "126.00",
        cgst_amount: "0",
        sgst_amount: "0",
        igst_amount: "0",
        tax_amount: "0",
        line_total: "126.00",
      },
    ],
    ...overrides,
  }
}

describe("credit-adjustment presentation", () => {
  it("keeps the non-statutory watermark and Accounts-only navigation", () => {
    expect(CREDIT_ADJUSTMENT_WATERMARK).toBe(
      "CREDIT ADJUSTMENT PREVIEW — NOT A GST CREDIT NOTE",
    )
    expect(creditAdjustmentNavPermissions).toEqual(["invoices.review"])
    expect(sampleAdjustment().legal_credit_note_number).toBeNull()
    expect(sampleAdjustment().legal_issuance_blocked).toBe(true)
    expect(sampleAdjustment().status).toBe("preview")
  })

  it("formats independent snapshot totals in INR", () => {
    expect(formatInr(126)).toMatch(/126\.00/)
    expect(Number(sampleAdjustment().subtotal_amount)).toBe(126)
  })
})

describe("credit-adjustment PDF", () => {
  it("embeds the watermark and does not invent a legal credit-note number", () => {
    const pdf = buildCreditAdjustmentPdf(sampleAdjustment())
    const ascii = new TextDecoder("latin1").decode(pdf)
    expect(ascii.startsWith("%PDF")).toBe(true)
    expect(ascii).toContain("NOT A GST CREDIT NOTE")
    expect(ascii).toContain("NO LEGAL CREDIT NOTE NUMBER")
    expect(ascii).not.toContain("Issue")
    expect(ascii).not.toContain("Finalize")
    expect(creditAdjustmentPdfFilename(sampleAdjustment())).toBe(
      "CA-20261028-000001-credit-adjustment-preview.pdf",
    )
  })

  it("paginates long item tables and long product names across more than one A4 page", () => {
    const lines = Array.from({ length: 48 }, (_, index) => ({
      ...sampleAdjustment().lines[0],
      id: `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
      line_no: index + 1,
      product_name: `Long product name ${index} ${"x".repeat(40)}`,
    }))
    const pdf = buildCreditAdjustmentPdf(sampleAdjustment({ lines }))
    const ascii = new TextDecoder("latin1").decode(pdf)
    expect(ascii).toMatch(/\/Type\s*\/Pages/)
    const count = ascii.match(/\/Count\s+(\d+)/)
    expect(Number(count?.[1] ?? 0)).toBeGreaterThan(1)
  })
})
