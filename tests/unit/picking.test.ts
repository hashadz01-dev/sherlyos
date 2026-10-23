import { describe, expect, it } from "vitest"
import {
  cutoverBlocksPicking,
  isStalePickingVersion,
  remainingCases,
} from "@/lib/picking/rules"

describe("picking rules", () => {
  it("keeps remaining cases from going negative", () => {
    expect(remainingCases(10, 4)).toBe(6)
    expect(remainingCases(4, 4)).toBe(0)
    expect(remainingCases(4, 9)).toBe(0)
  })

  it("blocks allocation while dual-write is off", () => {
    expect(
      cutoverBlocksPicking({ dual_write_enabled: false, aggregate_only_blocked: false }),
    ).toMatch(/dual-write/)
    expect(
      cutoverBlocksPicking({ dual_write_enabled: true, aggregate_only_blocked: true }),
    ).toBeNull()
  })

  it("treats PT409 as a stale picking version", () => {
    expect(isStalePickingVersion({ message: "nope", code: "PT409" })).toBe(true)
    expect(isStalePickingVersion({ message: "picking was changed by someone else" })).toBe(true)
    expect(isStalePickingVersion({ message: "insufficient eligible stock" })).toBe(false)
  })
})
