import { describe, expect, it } from "vitest"
import { SHORT_SHIPMENT_OPERATIONAL } from "@/lib/picking/rules"
import {
  EXPECTED_SOURCE_ENTRIES,
  STATED_SOURCE_ENTRIES,
  isAmbiguousGlobalNameMatch,
  normalizeShopName,
  proposedShopKey,
} from "@/lib/masters/m8-2a-shops"
// @ts-expect-error catalogue is a local ESM module consumed by Node and Vitest
import * as catalog from "../../scripts/m8-2a-shops.mjs"

describe("M8.2A shop route catalogue", () => {
  it("keeps fourteen route-area lists and flags the 574 vs 575 count gap", () => {
    expect(STATED_SOURCE_ENTRIES).toBe(574)
    expect(EXPECTED_SOURCE_ENTRIES).toBe(575)
    expect(catalog.EXPECTED_ROUTE_AREAS).toHaveLength(14)
    expect(catalog.SOURCE_ENTRIES).toHaveLength(0)
  })

  it("preserves abbreviations and does not expand them", () => {
    expect(normalizeShopName("  K K D  ")).toBe("K K D")
    expect(normalizeShopName("K C R Stores")).toBe("K C R Stores")
    expect(normalizeShopName("A J Stores")).toBe("A J Stores")
    expect(normalizeShopName("S S Traders")).toBe("S S Traders")
    expect(normalizeShopName("M B Menon")).toBe("M B Menon")
  })

  it("does not treat the same name in two areas as one shop", () => {
    const thevara = proposedShopKey("THEVARA", "PRIME")
    const kaloor = proposedShopKey("KALOOR", "PRIME")
    expect(thevara).not.toBe(kaloor)
    expect(isAmbiguousGlobalNameMatch(thevara, [kaloor])).toBe(true)
  })

  it("leaves short-shipment operationally off", () => {
    expect(SHORT_SHIPMENT_OPERATIONAL).toBe(false)
  })
})
