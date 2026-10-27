import { describe, expect, it } from "vitest"
import { formatRefillReceivingLabel } from "@/features/refill/utils/labels"
import {
  canCreateLinkedRefillReceipt,
  excessCases,
  outstandingCases,
  refillReceivingCompletionLabel,
} from "@/lib/refill/rules"
import { acceptedCases } from "@/lib/receiving/rules"
import { receiptFormSchema } from "@/lib/validations/receiving"

const ids = {
  godownId: "11111111-1111-4111-8111-111111111111",
  supplierId: "22222222-2222-4222-8222-222222222222",
  productId: "33333333-3333-4333-8333-333333333333",
  zoneId: "55555555-5555-4555-8555-555555555555",
  crateId: "66666666-6666-4666-8666-666666666666",
  refillId: "88888888-8888-4888-8888-888888888888",
}

describe("refill-to-receipt mapping", () => {
  it("allows an optional refill id on the existing receiving form", () => {
    const unlinked = receiptFormSchema.safeParse({
      godownId: ids.godownId,
      supplierId: ids.supplierId,
      refillRequestId: "",
      documentReference: "INV-1",
      receivedDate: "2026-10-27",
      notes: "",
      lines: [
        {
          productId: ids.productId,
          zoneId: ids.zoneId,
          crateId: ids.crateId,
          documentCases: "10",
          countedCases: "10",
          damagedCases: "0",
        },
      ],
    })
    const linked = receiptFormSchema.safeParse({
      ...unlinked.data,
      refillRequestId: ids.refillId,
    })
    expect(unlinked.success).toBe(true)
    expect(linked.success).toBe(true)
  })

  it("rejects a non-uuid refill reference", () => {
    expect(
      receiptFormSchema.safeParse({
        godownId: ids.godownId,
        supplierId: ids.supplierId,
        refillRequestId: "not-a-uuid",
        documentReference: "INV-1",
        receivedDate: "2026-10-27",
        notes: "",
        lines: [
          {
            productId: ids.productId,
            zoneId: ids.zoneId,
            crateId: ids.crateId,
            documentCases: "1",
            countedCases: "1",
            damagedCases: "0",
          },
        ],
      }).success,
    ).toBe(false)
  })
})

describe("partial receipt reconciliation", () => {
  it("matches the owner example after two verified receipts", () => {
    const productA = { requested: 100, accepted: 40 + 30 }
    const productB = { requested: 60, accepted: 20 + 25 }
    expect(outstandingCases(productA.requested, productA.accepted)).toBe(30)
    expect(outstandingCases(productB.requested, productB.accepted)).toBe(15)
    expect(excessCases(productA.requested, productA.accepted)).toBe(0)
    expect(
      refillReceivingCompletionLabel({
        acceptedCases: productA.accepted + productB.accepted,
        outstandingCases:
          outstandingCases(productA.requested, productA.accepted) +
          outstandingCases(productB.requested, productB.accepted),
        excessCases: 0,
        pendingReceiptCases: 0,
      }),
    ).toBe("partially_received")
  })

  it("does not treat damaged cartons as accepted refill quantity", () => {
    expect(acceptedCases(40, 5)).toBe(35)
    expect(outstandingCases(100, acceptedCases(40, 5))).toBe(65)
  })

  it("keeps reserved unverified cases separate from posted accepted stock", () => {
    const requested = 100
    const postedAccepted = 40
    const draftReserved = 25
    const reserved = postedAccepted + draftReserved
    expect(outstandingCases(requested, postedAccepted)).toBe(60)
    expect(reserved).toBe(65)
    expect(reserved).not.toBe(postedAccepted)
  })

  it("treats another open receipt accepted quantity as reserved against the request", () => {
    const requested = 100
    const openAccepted = [39, 70]
    const reserved = openAccepted.reduce((sum, value) => sum + value, 0)
    expect(reserved > requested).toBe(true)
    expect(excessCases(requested, reserved)).toBe(9)
  })
})

describe("inactive godown receiving link", () => {
  it("blocks new linked receipts while still describing historical labels", () => {
    expect(
      canCreateLinkedRefillReceipt({
        canExecuteReceiving: true,
        requestStatus: "approved",
        godownActive: false,
      }),
    ).toBe(false)
    expect(formatRefillReceivingLabel("fully_received")).toBe(
      "Fully received against requested quantities",
    )
    expect(formatRefillReceivingLabel("excess_requires_review")).toBe(
      "Excess quantity requires review",
    )
  })
})
