import { describe, expect, it } from "vitest"
import { SHORT_SHIPMENT_OPERATIONAL } from "@/lib/picking/rules"
import { assertImportableProduct } from "@/lib/masters/m7-7-catalog"
// Shared with scripts/m7-7-import-local.mjs. tsc -b does not attach the sibling .d.ts to this specifier.
// @ts-expect-error catalogue is a local ESM module consumed by Node and Vitest
import * as catalog from "../../scripts/m7-7-catalog.mjs"

type Category = { code: string; name: string; description: string }
type Supplier = {
  ref: string
  name: string
  brands: string
  verification: string
  email: string | null
  phone: string | null
}
type Product = {
  sku: string | null
  name: string
  categoryCode: string
  supplierRef: string
  packSize: string
  unitsPerCase: number | null
  billingUnit: string | null
  sourceClass: string
  disposition: string
  notes: string
}

const CATEGORIES = catalog.CATEGORIES as Category[]
const SUPPLIERS = catalog.SUPPLIERS as Supplier[]
const PRODUCTS = catalog.PRODUCTS as Product[]
const insertableProducts = catalog.insertableProducts as () => Product[]
const skuList = catalog.skuList as () => string[]

describe("M7.7 catalogue", () => {
  it("keeps category names unique and does not invent a code column", () => {
    const names = CATEGORIES.map((row) => row.name.toLowerCase())
    expect(new Set(names).size).toBe(names.length)
    expect(CATEGORIES).toHaveLength(13)
  })

  it("does not claim unverified invoicing suppliers or store fabricated contacts", () => {
    expect(SUPPLIERS.every((row) => /pending/i.test(row.name))).toBe(true)
    expect(SUPPLIERS.every((row) => row.email == null && row.phone == null)).toBe(true)
  })

  it("rejects duplicate or oversized SKUs and invented case packs", () => {
    const skus = skuList().map((sku) => sku.toLowerCase())
    expect(new Set(skus).size).toBe(skus.length)
    for (const row of PRODUCTS) {
      assertImportableProduct(row)
    }
    expect(insertableProducts().every((row) => row.sourceClass === "CONFIRMED_DISTRIBUTION")).toBe(
      true,
    )
    expect(
      PRODUCTS.filter((row) => row.sourceClass !== "CONFIRMED_DISTRIBUTION").every(
        (row) => row.disposition === "STAGE",
      ),
    ).toBe(true)
  })

  it("does not explode spice families into unsupported size combinations", () => {
    const spices = PRODUCTS.filter((row) => row.categoryCode === "SPICES")
    expect(spices).toHaveLength(6)
    expect(spices.every((row) => row.sku == null && row.unitsPerCase == null)).toBe(true)
  })

  it("stages MattaNaad rice until carton quantity is approved", () => {
    const rice = PRODUCTS.filter((row) => row.supplierRef === "MATTANAAD")
    expect(rice.map((row) => row.packSize)).toEqual(["1kg", "5kg", "10kg", "30kg", "50kg"])
    expect(rice.every((row) => row.disposition === "STAGE" && row.unitsPerCase == null)).toBe(true)
    expect(PRODUCTS.some((row) => /2kg/i.test(row.packSize) && row.supplierRef === "MATTANAAD")).toBe(
      false,
    )
  })

  it("leaves short-shipment operationally off", () => {
    expect(SHORT_SHIPMENT_OPERATIONAL).toBe(false)
  })
})
