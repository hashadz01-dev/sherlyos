import { describe, expect, it } from "vitest"
import { formatInr } from "@/lib/invoices/rules"
import { parseShopStatement, type ShopStatementPayload } from "@/lib/shops/api"
import {
  SHOP_STATEMENT_PERMISSION,
  billedMoney,
  dedupeStatementEntries,
  invoiceNoteParticulars,
  shopStatementFlagsUnchanged,
  summarizeStatement,
  unavailableMoney,
  type ShopStatementEntry,
} from "@/lib/shops/rules"
import { shopStatementPdfFilename } from "@/lib/shops/statement-pdf"

function entry(
  overrides: Partial<ShopStatementEntry> &
    Pick<ShopStatementEntry, "sourceType" | "sourceId" | "transactionDate" | "referenceNumber">,
): ShopStatementEntry {
  return {
    id: `${overrides.sourceType}:${overrides.sourceId}`,
    particulars: invoiceNoteParticulars(),
    billAmount: billedMoney("100"),
    amountReceived: unavailableMoney(),
    runningBalance: unavailableMoney(),
    acknowledgement: null,
    remarks: null,
    status: "reviewed",
    statusLabel: "Reviewed — still not a tax invoice",
    href: null,
    ...overrides,
  }
}

describe("M8.2B.1 shop sales statement", () => {
  it("does not treat a missing payment as zero-paid", () => {
    expect(unavailableMoney().display).toBe("Unavailable")
    expect(unavailableMoney().amount).toBeNull()
    expect(unavailableMoney().available).toBe(false)
    expect(formatInr(null)).toBe("₹0.00")
    expect(unavailableMoney().display).not.toBe(formatInr(null))
    expect(unavailableMoney().display).not.toBe(formatInr(0))
  })

  it("does not invent an outstanding balance", () => {
    const summary = summarizeStatement([
      entry({
        sourceType: "invoice_note",
        sourceId: "n1",
        transactionDate: "2026-10-01",
        referenceNumber: "IN-1",
        billAmount: billedMoney("250.00"),
      }),
    ])
    expect(summary.outstanding.available).toBe(false)
    expect(summary.outstanding.amount).toBeNull()
    expect(summary.amountReceived.available).toBe(false)
    expect(summary.reviewedNoteTotal.display).toBe(formatInr(250))
  })

  it("keeps one row per source document", () => {
    const rows = dedupeStatementEntries([
      entry({
        sourceType: "invoice_note",
        sourceId: "same",
        transactionDate: "2026-10-02",
        referenceNumber: "IN-1",
      }),
      entry({
        sourceType: "invoice_note",
        sourceId: "same",
        transactionDate: "2026-10-02",
        referenceNumber: "IN-1-dup",
        amountReceived: billedMoney("10"),
      }),
    ])
    expect(rows).toHaveLength(1)
    expect(rows[0]?.amountReceived.display).toBe("Unavailable")
  })

  it("does not merge the same name on two shops", () => {
    const payload: ShopStatementPayload = {
      shop: { id: "s1", name: "PRIME", phone: null, address: null, is_active: true },
      watermark: "preview",
      payment_accounting: {
        available: false,
        received_available: false,
        outstanding_available: false,
        reason: "no payments",
      },
      entries: [],
      summary: {
        invoice_note_count: 0,
        delivery_note_count: 0,
        credit_adjustment_count: 0,
        reviewed_note_total: null,
        submitted_note_total: null,
        draft_note_total: null,
        credit_adjustment_preview_total: null,
      },
    }
    const thevara = parseShopStatement(payload)
    const thripunithura = parseShopStatement({
      ...payload,
      shop: { ...payload.shop, id: "s2" },
    })
    expect(thevara.shop.id).not.toBe(thripunithura.shop.id)
    expect(thevara.summary.outstanding.display).toBe("Unavailable")
  })

  it("forces payment fields off even when a payload tries to send a receipt", () => {
    const view = parseShopStatement({
      shop: { id: "s1", name: "Family supermarket", phone: null, address: null, is_active: true },
      watermark: "",
      payment_accounting: {
        available: true,
        received_available: true,
        outstanding_available: true,
        reason: "",
      },
      entries: [
        {
          source_type: "invoice_note",
          source_id: "n1",
          transaction_date: "2026-10-01",
          particulars: "",
          reference_number: "IN-1",
          bill_amount: "80",
          bill_amount_available: true,
          amount_received: "80",
          amount_received_available: true,
          running_balance: "0",
          running_balance_available: true,
          acknowledgement: null,
          remarks: null,
          status: "draft",
          status_label: "",
          href: "/invoices/n1",
        },
      ],
      summary: {
        invoice_note_count: 1,
        delivery_note_count: 0,
        credit_adjustment_count: 0,
        reviewed_note_total: 0,
        submitted_note_total: 0,
        draft_note_total: 80,
        credit_adjustment_preview_total: 0,
      },
    })
    expect(view.entries[0]?.particulars).toBe(invoiceNoteParticulars())
    expect(view.entries[0]?.statusLabel).toContain("not a tax invoice")
    expect(view.entries[0]?.amountReceived.display).toBe("Unavailable")
    expect(view.entries[0]?.runningBalance.display).toBe("Unavailable")
    expect(view.summary.amountReceived.display).toBe("Unavailable")
    expect(shopStatementPdfFilename(view)).toMatch(/Family-supermarket-sales-statement-preview\.pdf/)
  })

  it("keeps statement permission distinct and flags unchanged", () => {
    expect(SHOP_STATEMENT_PERMISSION).toBe("shops.statement.read")
    expect(shopStatementFlagsUnchanged()).toBe(true)
  })
})
