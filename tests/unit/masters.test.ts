import { describe, expect, it } from "vitest"
import { findNavigationItem, navigationItems } from "@/app/navigation"
import { matchesSearch, matchesStatus } from "@/lib/masters/filters"
import {
  categorySchema,
  crateSchema,
  productSchema,
  shopSchema,
  supplierSchema,
  vehicleSchema,
  zoneSchema,
} from "@/lib/validations/masters"

describe("master data navigation", () => {
  it("keeps users and role last and gates each master screen", () => {
    expect(navigationItems.at(-1)?.to).toBe("/users-roles")
    expect(
      navigationItems.find((item) => item.to === "/masters/products")?.permission,
    ).toBe("products.read")
    expect(
      navigationItems.find((item) => item.to === "/masters/suppliers")?.permission,
    ).toBe("suppliers.read")
    expect(
      navigationItems.find((item) => item.to === "/masters/shops")?.permission,
    ).toBe("shops.read")
    expect(
      navigationItems.find((item) => item.to === "/masters/locations")?.permission,
    ).toBe("locations.read")
    expect(
      navigationItems.find((item) => item.to === "/masters/vehicles")?.permission,
    ).toBe("vehicles.view")
    expect(findNavigationItem("/masters/products")?.title).toBe("Products")
    expect(findNavigationItem("/masters")?.title).toBe("Master data")
  })
})

describe("master data filters", () => {
  it("matches a name fragment and an active status", () => {
    expect(matchesSearch("so", ["Soap", null])).toBe(true)
    expect(matchesSearch("missing", ["Soap"])).toBe(false)
    expect(matchesStatus("inactive", false)).toBe(true)
    expect(matchesStatus("active", false)).toBe(false)
  })
})

describe("master data forms", () => {
  it("accepts a product without a category or supplier", () => {
    const parsed = productSchema.parse({
      name: "  Soap  ",
      sku: " SOAP-1 ",
      categoryId: "",
      supplierId: "",
    })
    expect(parsed).toEqual({
      name: "Soap",
      sku: "SOAP-1",
      categoryId: "",
      supplierId: "",
    })
  })

  it("rejects a blank category name and an oversized code", () => {
    expect(categorySchema.safeParse({ name: "  ", description: "" }).success).toBe(
      false,
    )
    expect(zoneSchema.safeParse({ code: "", name: "Zone", description: "" }).success).toBe(
      false,
    )
    expect(
      crateSchema.safeParse({ code: "A".repeat(41), name: "", description: "" }).success,
    ).toBe(false)
  })

  it("rejects a short phone and an invalid supplier email", () => {
    expect(
      supplierSchema.safeParse({ name: "Acme", phone: "123", email: "" }).success,
    ).toBe(false)
    expect(
      supplierSchema.safeParse({ name: "Acme", phone: "", email: "not-an-email" })
        .success,
    ).toBe(false)
    expect(
      shopSchema.safeParse({ name: "Shop", phone: "+91 9000000000", address: "" })
        .success,
    ).toBe(true)
  })

  it("accepts an informational vehicle without capacity", () => {
    const parsed = vehicleSchema.parse({
      registrationNumber: "KL 07 AB 1234",
      vehicleType: "van",
      displayName: "  Van 1  ",
      capacityCases: "",
      notes: "",
    })
    expect(parsed.displayName).toBe("Van 1")
    expect(parsed.capacityCases).toBe("")
  })
})