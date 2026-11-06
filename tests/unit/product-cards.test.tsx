import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it } from "vitest"
import {
  ProductCard,
  categoryTint,
  productRelationLabel,
  readProductImage,
  readProductLayout,
  writeProductLayout,
  type ProductCardData,
} from "@/features/masters/products/ProductCards"

const coffee: ProductCardData = {
  id: "coffee-100",
  sku: "AVT-COFFEE-1000",
  name: "AVT Coffee Powder 100g",
  is_active: true,
  expiry_policy: null,
  billing_unit: "nos",
  billed_units_per_case: 120,
}

describe("product card presentation", () => {
  it("keeps a category on the same wash", () => {
    expect(categoryTint("Coffee")).toEqual(categoryTint("Coffee"))
    expect(categoryTint("  Coffee  ")).toEqual(categoryTint("Coffee"))
    expect(categoryTint(null)).toEqual(categoryTint(""))
    expect(categoryTint("Tea & Tea Bags")).not.toBe(categoryTint(null))
  })

  it("names a missing category and supplier without inventing a tint", () => {
    const names = new Map<string, string>()
    expect(productRelationLabel(null, names, "No category", "Category")).toEqual({
      label: "No category",
      tintName: null,
    })
    expect(productRelationLabel("pending", names, "No supplier", "Supplier")).toEqual({
      label: "Supplier",
      tintName: null,
    })
    names.set("coffee", "Coffee")
    expect(productRelationLabel("coffee", names, "No category", "Category").tintName).toBe(
      "Coffee",
    )
  })

  it("ignores a blank image and keeps a real one", () => {
    expect(readProductImage(coffee)).toBeNull()
    expect(readProductImage({ ...coffee, image_url: "  " } as ProductCardData)).toBeNull()
    expect(
      readProductImage({ ...coffee, image_url: " https://example.com/tin.jpg " } as ProductCardData),
    ).toBe("https://example.com/tin.jpg")
  })

  it("defaults to cards and remembers list inside storage", () => {
    window.localStorage.removeItem("sherlyos.products.layout")
    expect(readProductLayout()).toBe("cards")
    writeProductLayout("list")
    expect(readProductLayout()).toBe("list")
    writeProductLayout("cards")
    expect(readProductLayout()).toBe("cards")
  })

  it("falls back to cards when storage throws", () => {
    const storage = window.localStorage
    const original = storage.getItem.bind(storage)
    storage.getItem = () => {
      throw new Error("blocked")
    }
    expect(readProductLayout()).toBe("cards")
    storage.getItem = original
    const setItem = storage.setItem.bind(storage)
    storage.setItem = () => {
      throw new Error("blocked")
    }
    expect(() => writeProductLayout("list")).not.toThrow()
    storage.setItem = setItem
  })

  it("shows the pack and an unclassified chip, and hides deactivate until the menu", async () => {
    const user = userEvent.setup()
    render(
      <ProductCard
        product={coffee}
        categoryLabel="Coffee"
        supplierLabel="AVT"
        categoryTintName="Coffee"
        canClassifyExpiry
        canSetBilling
        canManage
        onEdit={() => undefined}
        onClassify={() => undefined}
        onBilling={() => undefined}
        onToggleStatus={() => undefined}
      />,
    )

    expect(screen.getByRole("article", { name: "AVT Coffee Powder 100g" })).toBeTruthy()
    expect(screen.getByRole("heading", { name: "AVT Coffee Powder 100g" })).toBeTruthy()
    expect(screen.getByText("AVT-COFFEE-1000")).toBeTruthy()
    expect(screen.getByText("· Coffee · AVT")).toBeTruthy()
    expect(screen.getByText("120 nos / case")).toBeTruthy()
    expect(screen.getByText("unclassified")).toBeTruthy()
    expect(screen.getByText("Active")).toBeTruthy()
    expect(screen.queryByText(/qty|quantity|on hand|in stock/i)).toBeNull()
    expect(screen.queryByRole("button", { name: "Deactivate" })).toBeNull()

    await user.click(screen.getByRole("button", { name: "More actions for AVT Coffee Powder 100g" }))
    expect(screen.getByRole("menuitem", { name: "Deactivate" })).toBeTruthy()
  })
})
