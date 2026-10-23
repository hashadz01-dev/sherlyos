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
      navigationItems.find((item) => item.to === "/audit")?.permission,
    ).toBe("audit.read")
    expect(navigationItems.at(-1)?.to).toBe("/users-roles")
    expect(navigationItems.at(-1)?.label).toBe("Users & role")
  })

  it("matches the overview route only at the root", () => {
    expect(findNavigationItem("/")?.label).toBe("Overview")
    expect(findNavigationItem("/orders")?.title).toBe("Orders")
  })
})
