import { describe, expect, it } from "vitest"
import { cutoverBlocksDispatch, isStaleDispatchVersion } from "@/lib/dispatch/rules"

describe("dispatch rules", () => {
  it("blocks dispatch while dual-write is off", () => {
    expect(
      cutoverBlocksDispatch({ dual_write_enabled: false, aggregate_only_blocked: false }),
    ).toMatch(/dual-write/)
    expect(
      cutoverBlocksDispatch({ dual_write_enabled: true, aggregate_only_blocked: true }),
    ).toBeNull()
  })

  it("treats PT409 as a stale dispatch version", () => {
    expect(isStaleDispatchVersion({ message: "nope", code: "PT409" })).toBe(true)
    expect(isStaleDispatchVersion({ message: "dispatch was changed by someone else" })).toBe(true)
    expect(isStaleDispatchVersion({ message: "insufficient unreserved stock" })).toBe(false)
  })
})
