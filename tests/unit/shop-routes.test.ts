import { describe, expect, it } from "vitest"
import {
  SALES_ROUTE_CATALOG,
  catalogRoutesAsRows,
  groupShopsByRoute,
  weekdayLabel,
} from "@/lib/masters/shop-routes"
import { proposedShopKey as keyFromLegacy } from "@/lib/masters/m8-2a-shops"

describe("sales route catalog", () => {
  it("lists fourteen geographic routes and does not attach salespersons", () => {
    expect(SALES_ROUTE_CATALOG).toHaveLength(14)
    expect(SALES_ROUTE_CATALOG.map((row) => row.code)).toContain("chullikkal")
    expect(SALES_ROUTE_CATALOG.every((row) => !("salesperson" in row))).toBe(true)
    expect(weekdayLabel(null)).toBe("Weekday unconfirmed")
  })
})

describe("shop route grouping", () => {
  const routes = catalogRoutesAsRows()
  const thevara = routes.find((row) => row.code === "thevara")!
  const kaloor = routes.find((row) => row.code === "kaloor")!
  const shops = [
    { id: "s1", name: "PRIME", phone: null, address: null, is_active: true },
    { id: "s2", name: "PRIME", phone: null, address: null, is_active: true },
    { id: "s3", name: "Family Supermarket", phone: null, address: null, is_active: true },
    { id: "s4", name: "Unassigned Mart", phone: null, address: null, is_active: false },
  ]

  it("keeps the same name on two routes as two shops", () => {
    expect(keyFromLegacy("Thevara", "PRIME")).not.toBe(keyFromLegacy("Kaloor", "PRIME"))
    const groups = groupShopsByRoute({
      shops,
      routes,
      memberships: [
        { shop_id: "s1", route_id: thevara.id, visit_sequence: 1 },
        { shop_id: "s2", route_id: kaloor.id, visit_sequence: 4 },
      ],
      search: "",
      status: "all",
      routeId: "all",
      weekday: "all",
    })
    const thevaraGroup = groups.find((group) => group.routeCode === "thevara")
    const kaloorGroup = groups.find((group) => group.routeCode === "kaloor")
    expect(thevaraGroup?.shopCount).toBe(1)
    expect(kaloorGroup?.shopCount).toBe(1)
    expect(thevaraGroup?.shops[0]?.id).toBe("s1")
    expect(kaloorGroup?.shops[0]?.id).toBe("s2")
  })

  it("filters by route, weekday, search, and status without dropping later pages", () => {
    const groups = groupShopsByRoute({
      shops,
      routes,
      memberships: [
        { shop_id: "s1", route_id: thevara.id, visit_sequence: 2 },
        { shop_id: "s3", route_id: thevara.id, visit_sequence: 1 },
      ],
      search: "family",
      status: "active",
      routeId: thevara.id,
      weekday: "monday",
    })
    expect(groups).toHaveLength(1)
    expect(groups[0]?.shops.map((shop) => shop.name)).toEqual(["Family Supermarket"])
    expect(groups[0]?.shops[0]?.visitSequence).toBe(1)
  })

  it("places shops with no membership under Unassigned route", () => {
    const groups = groupShopsByRoute({
      shops,
      routes,
      memberships: [],
      search: "",
      status: "all",
      routeId: "all",
      weekday: "all",
    })
    expect(groups).toHaveLength(1)
    expect(groups[0]?.routeCode).toBe("unassigned")
    expect(groups[0]?.shopCount).toBe(4)
  })
})
