import { describe, expect, it } from "vitest"
import { findNavigationItem, navigationItems } from "@/app/navigation"
import { openingStockSchema, transferStockSchema } from "@/lib/validations/inventory"

describe("inventory navigation", () => {
  it("gates stock screens on the approved permissions", () => {
    expect(navigationItems.find((item) => item.to === "/inventory")?.permission).toBe(
      "stock.read",
    )
    expect(
      navigationItems.find((item) => item.to === "/inventory/opening")?.permission,
    ).toBe("stock.opening.post")
    expect(
      navigationItems.find((item) => item.to === "/inventory/transfers")?.permission,
    ).toBe("stock.transfer.post")
    expect(
      navigationItems.find((item) => item.to === "/inventory/history")?.permission,
    ).toBe("stock.read")
    expect(findNavigationItem("/inventory/history")?.title).toBe("Stock history")
    expect(navigationItems.at(-1)?.to).toBe("/users-roles")
  })
})

describe("inventory forms", () => {
  const ids = {
    branchId: "11111111-1111-4111-8111-111111111111",
    zoneId: "22222222-2222-4222-8222-222222222222",
    crateId: "33333333-3333-4333-8333-333333333333",
    otherCrateId: "44444444-4444-4444-8444-444444444444",
    productId: "55555555-5555-4555-8555-555555555555",
    lotId: "66666666-6666-4666-8666-666666666666",
  }

  it("accepts a whole-carton opening quantity", () => {
    expect(
      openingStockSchema.safeParse({
        branchId: ids.branchId,
        zoneId: ids.zoneId,
        crateId: ids.crateId,
        productId: ids.productId,
        quantity: "12",
        notes: "",
        manufacturerLotCode: "",
        manufacturedOn: "",
        expiryDate: "",
        dualWriteEnabled: false,
        expiryPolicy: null,
      }).success,
    ).toBe(true)
  })

  it("requires expiry for lot-aware expiry-controlled openings", () => {
    expect(
      openingStockSchema.safeParse({
        branchId: ids.branchId,
        zoneId: ids.zoneId,
        crateId: ids.crateId,
        productId: ids.productId,
        quantity: "12",
        notes: "",
        manufacturerLotCode: "",
        manufacturedOn: "",
        expiryDate: "",
        dualWriteEnabled: true,
        expiryPolicy: "expiry_controlled",
      }).success,
    ).toBe(false)
    expect(
      openingStockSchema.safeParse({
        branchId: ids.branchId,
        zoneId: ids.zoneId,
        crateId: ids.crateId,
        productId: ids.productId,
        quantity: "12",
        notes: "",
        manufacturerLotCode: "A1",
        manufacturedOn: "",
        expiryDate: "2027-01-01",
        dualWriteEnabled: true,
        expiryPolicy: "expiry_controlled",
      }).success,
    ).toBe(true)
  })

  it("rejects a zero quantity and a transfer into the same crate", () => {
    expect(
      openingStockSchema.safeParse({
        branchId: ids.branchId,
        zoneId: ids.zoneId,
        crateId: ids.crateId,
        productId: ids.productId,
        quantity: "0",
        notes: "",
        manufacturerLotCode: "",
        manufacturedOn: "",
        expiryDate: "",
        dualWriteEnabled: false,
        expiryPolicy: null,
      }).success,
    ).toBe(false)
    expect(
      transferStockSchema.safeParse({
        branchId: ids.branchId,
        sourceZoneId: ids.zoneId,
        sourceCrateId: ids.crateId,
        destinationZoneId: ids.zoneId,
        destinationCrateId: ids.crateId,
        productId: ids.productId,
        quantity: "1",
        notes: "",
        dualWriteEnabled: false,
        lotMoves: [],
      }).success,
    ).toBe(false)
    expect(
      transferStockSchema.safeParse({
        branchId: ids.branchId,
        sourceZoneId: ids.zoneId,
        sourceCrateId: ids.crateId,
        destinationZoneId: ids.zoneId,
        destinationCrateId: ids.otherCrateId,
        productId: ids.productId,
        quantity: "1",
        notes: "",
        dualWriteEnabled: false,
        lotMoves: [],
      }).success,
    ).toBe(true)
  })

  it("requires lot moves that sum to transfer quantity when dual-write is on", () => {
    expect(
      transferStockSchema.safeParse({
        branchId: ids.branchId,
        sourceZoneId: ids.zoneId,
        sourceCrateId: ids.crateId,
        destinationZoneId: ids.zoneId,
        destinationCrateId: ids.otherCrateId,
        productId: ids.productId,
        quantity: "5",
        notes: "",
        dualWriteEnabled: true,
        lotMoves: [{ lotId: ids.lotId, quantity: "3" }],
      }).success,
    ).toBe(false)
    expect(
      transferStockSchema.safeParse({
        branchId: ids.branchId,
        sourceZoneId: ids.zoneId,
        sourceCrateId: ids.crateId,
        destinationZoneId: ids.zoneId,
        destinationCrateId: ids.otherCrateId,
        productId: ids.productId,
        quantity: "5",
        notes: "",
        dualWriteEnabled: true,
        lotMoves: [{ lotId: ids.lotId, quantity: "5" }],
      }).success,
    ).toBe(true)
  })
})
