import { describe, expect, it } from "vitest"
import { productSearchLabel } from "@/lib/masters/product-search"

describe("productSearchLabel", () => {
  it("keeps duplicate names distinct by SKU", () => {
    expect(productSearchLabel({ sku: "AAA-1", name: "Soap" })).toBe("AAA-1 · Soap")
    expect(productSearchLabel({ sku: "AAA-2", name: "Soap" })).toBe("AAA-2 · Soap")
  })
})
