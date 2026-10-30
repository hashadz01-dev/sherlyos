import { describe, expect, it } from "vitest"
import { formatPackAmount } from "@/lib/masters/pack-amount"

describe("formatPackAmount", () => {
  it("formats a catalogue case pack", () => {
    expect(formatPackAmount(20, "nos")).toBe("20 nos / case")
    expect(formatPackAmount("10.0000", "nos")).toBe("10 nos / case")
  })

  it("hides missing or invented packs", () => {
    expect(formatPackAmount(null, "nos")).toBeNull()
    expect(formatPackAmount(0, "nos")).toBeNull()
  })
})
