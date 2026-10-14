import { describe, expect, it } from "vitest"
import { findNavigationItem, navigationItems } from "@/app/navigation"

const requiredPaths = [
  "/",
  "/orders",
  "/deliveries",
  "/damage",
  "/receiving",
  "/stock-verification",
  "/refill",
  "/inventory",
  "/masters",
  "/reports",
  "/settings",
]

describe("navigation", () => {
  it("registers every Phase 1 route", () => {
    expect(navigationItems.map((item) => item.to)).toEqual(requiredPaths)
  })

  it("matches the overview route only at the root", () => {
    expect(findNavigationItem("/")?.label).toBe("Overview")
    expect(findNavigationItem("/orders")?.title).toBe("Orders")
  })
})
