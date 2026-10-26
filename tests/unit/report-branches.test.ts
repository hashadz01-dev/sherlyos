import { describe, expect, it } from "vitest"
import {
  activeOperationalBranches,
  partitionReportBranches,
} from "@/lib/branches/operational"

const rows = [
  { id: "a", name: "Main", code: "G1", is_active: true },
  { id: "b", name: "Closed godown", code: "G0", is_active: false },
]

describe("report branch partition", () => {
  it("keeps inactive godowns in the historical group only", () => {
    expect(partitionReportBranches(rows)).toEqual({
      active: [rows[0]],
      inactive: [rows[1]],
    })
  })

  it("hides inactive godowns from operational selectors", () => {
    expect(activeOperationalBranches(rows).map((row) => row.id)).toEqual(["a"])
    expect(activeOperationalBranches(undefined)).toEqual([])
  })
})
