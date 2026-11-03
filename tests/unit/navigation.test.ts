import { describe, expect, it } from "vitest"
import { findNavigationItem, navigationItems } from "@/app/navigation"

const requiredPaths = [
  "/",
  "/orders",
  "/picking",
  "/dispatch",
  "/delivery-runs",
  "/deliveries",
  "/damage",
  "/receiving",
  "/receiving/verification",
  "/stock-verification",
  "/stock-lot-reconciliation",
  "/refill",
  "/inventory",
  "/masters",
  "/reports",
  "/settings",
]

describe("navigation", () => {
  it("registers every Phase 1 route", () => {
    const paths = navigationItems.map((item) => item.to)
    for (const path of requiredPaths) {
      expect(paths).toContain(path)
    }
  })

  it("gates administration screens on database permissions", () => {
    expect(
      navigationItems.find((item) => item.to === "/employees")?.permission,
    ).toBe("employees.read")
    expect(
      navigationItems.find((item) => item.to === "/godowns")?.label,
    ).toBe("Godowns")
    expect(
      navigationItems.find((item) => item.to === "/audit")?.permission,
    ).toBe("audit.read")
    expect(navigationItems.at(-1)?.to).toBe("/users-roles")
    expect(navigationItems.at(-1)?.label).toBe("Users & role")
  })

  it("matches the overview route only at the root", () => {
    expect(findNavigationItem("/")?.label).toBe("Overview")
    expect(findNavigationItem("/orders")?.title).toBe("Orders")
    expect(findNavigationItem("/orders/verification")?.label).toBe("Order verification")
    expect(findNavigationItem("/orders/verification/abc")?.label).toBe("Order verification")
    expect(findNavigationItem("/receiving/verification")?.label).toBe(
      "Receipt verification",
    )
    expect(findNavigationItem("/receiving/verification/abc")?.label).toBe(
      "Receipt verification",
    )
  })

  it("gates the Accounts verification queue on orders.verify", () => {
    expect(
      navigationItems.find((item) => item.to === "/orders/verification")?.permission,
    ).toBe("orders.verify")
    expect(
      navigationItems.find((item) => item.to === "/orders/verification")?.label,
    ).toBe("Order verification")
  })
})
