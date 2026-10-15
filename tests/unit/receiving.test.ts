import { describe, expect, it } from "vitest"
import { navigationItems } from "@/app/navigation"
import { stockMovementLabel, stockTransactionLabel } from "@/lib/inventory/labels"
import {
  acceptedCases,
  normalizeDocumentReference,
  receiptActions,
  receiptTotals,
  receivingErrorMessage,
} from "@/lib/receiving/rules"
import { receiptFormSchema } from "@/lib/validations/receiving"

const ids = {
  godownId: "11111111-1111-4111-8111-111111111111",
  supplierId: "22222222-2222-4222-8222-222222222222",
  productId: "33333333-3333-4333-8333-333333333333",
  otherProductId: "44444444-4444-4444-8444-444444444444",
  zoneId: "55555555-5555-4555-8555-555555555555",
  crateId: "66666666-6666-4666-8666-666666666666",
  otherCrateId: "77777777-7777-4777-8777-777777777777",
}

function receipt(lines: Array<Record<string, string>>) {
  return {
    godownId: ids.godownId,
    supplierId: ids.supplierId,
    documentReference: "Inv 15",
    receivedDate: "2026-10-15",
    notes: "",
    lines: lines.map((line) => ({
      productId: ids.productId,
      zoneId: ids.zoneId,
      crateId: ids.crateId,
      documentCases: "1",
      countedCases: "1",
      damagedCases: "0",
      ...line,
    })),
  }
}

describe("receiving rules", () => {
  it("normalizes a supplier document reference", () => {
    expect(normalizeDocumentReference("  INV   15 ")).toBe("inv 15")
  })

  it("calculates accepted cases from counted and damaged cases", () => {
    expect(acceptedCases(10, 3)).toBe(7)
    expect(acceptedCases(4, 4)).toBe(0)
  })

  it("totals several receipt lines", () => {
    expect(
      receiptTotals([
        { documentCases: 8, countedCases: 6, damagedCases: 1 },
        { documentCases: 2, countedCases: 2, damagedCases: 2 },
      ]),
    ).toEqual({
      documentCases: 10,
      countedCases: 8,
      damagedCases: 3,
      acceptedCases: 5,
    })
  })

  it("limits actions to the caller's permission and the receipt status", () => {
    expect(
      receiptActions({
        status: "draft",
        isCreator: true,
        canExecute: true,
        canVerify: false,
      }).canVerify,
    ).toBe(false)
    expect(
      receiptActions({
        status: "submitted",
        isCreator: false,
        canExecute: false,
        canVerify: true,
      }).canVerify,
    ).toBe(true)
    expect(
      receiptActions({
        status: "posted",
        isCreator: true,
        canExecute: true,
        canVerify: true,
      }),
    ).toMatchObject({
      canEdit: false,
      canCancelOwn: false,
      canCancelAsManager: false,
      canVerify: false,
    })
    expect(
      receiptActions({
        status: "held",
        isCreator: true,
        canExecute: true,
        canVerify: false,
      }).canRelease,
    ).toBe(true)
  })

  it("surfaces the database error message", () => {
    expect(receivingErrorMessage(new Error("document reference was already used"))).toBe(
      "document reference was already used",
    )
    expect(receivingErrorMessage("nope")).toBe("The receipt could not be saved.")
  })

  it("labels a posted receipt in inventory history", () => {
    expect(stockTransactionLabel("RECEIPT")).toBe("Receipt")
    expect(
      stockMovementLabel({
        transactionType: "RECEIPT",
        sourceCrateCode: null,
        destinationCrateCode: "A1",
      }),
    ).toBe("A1")
  })
})

describe("receiving form", () => {
  it("accepts several products and crates when damaged cases do not exceed the count", () => {
    const parsed = receiptFormSchema.safeParse(
      receipt([
        { documentCases: "8", countedCases: "6", damagedCases: "1" },
        {
          productId: ids.otherProductId,
          crateId: ids.otherCrateId,
          documentCases: "0",
          countedCases: "2",
          damagedCases: "2",
        },
      ]),
    )
    expect(parsed.success).toBe(true)
  })

  it("rejects a missing document, a decimal, a negative, and too much damage", () => {
    expect(
      receiptFormSchema.safeParse(receipt([{ documentCases: "1" }])).success &&
        receiptFormSchema.safeParse({
          ...receipt([{ documentCases: "1" }]),
          documentReference: "   ",
        }).success,
    ).toBe(false)
    expect(receiptFormSchema.safeParse(receipt([{ countedCases: "1.5" }])).success).toBe(false)
    expect(receiptFormSchema.safeParse(receipt([{ damagedCases: "-1" }])).success).toBe(false)
    expect(
      receiptFormSchema.safeParse(receipt([{ countedCases: "2", damagedCases: "3" }])).success,
    ).toBe(false)
  })
})

describe("receiving navigation", () => {
  it("shows receiving to store keepers, godown managers, and monitoring admins", () => {
    expect(navigationItems.find((item) => item.to === "/receiving")?.anyPermissions).toEqual([
      "receiving.execute",
      "receiving.verify",
      "operations.monitor",
    ])
  })
})
