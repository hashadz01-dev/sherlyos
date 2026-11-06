import { describe, expect, it } from "vitest"
import {
  crateCapacityPath,
  godownZonesPath,
  matchLocation,
  zoneCratesPath,
} from "@/lib/warehouse/paths"

const godowns = [
  { id: "798bacf9-2212-43fc-9cbb-2fe1e7367a93", code: "gd_1" },
  { id: "g7", code: "gd_7" },
]
const zones = [
  { id: "dfc57626-e137-413c-836a-47338b9152bf", code: "A" },
  { id: "z-q", code: "QRN" },
]
const crates = [
  { id: "ee3434be-db4f-43ba-9760-a832c7fe15f1", code: "A-01" },
  { id: "c2", code: "A-02" },
]

describe("warehouse addresses", () => {
  it("uses the codes in the path and still opens an id", () => {
    expect(crateCapacityPath(godowns[0], godowns, zones[0], zones, crates[0], crates)).toBe(
      "/godowns/gd_1/zones/A/crates/A-01",
    )
    expect(matchLocation(godowns, "798bacf9-2212-43fc-9cbb-2fe1e7367a93")?.code).toBe("gd_1")
    expect(matchLocation(godowns, "GD_1")?.id).toBe(godowns[0].id)
    expect(matchLocation(zones, "a")?.code).toBe("A")
    expect(matchLocation(crates, "a-01")?.code).toBe("A-01")
  })

  it("keeps the id when two records share a code", () => {
    const twins = [
      { id: "one", code: "A" },
      { id: "two", code: "a" },
    ]
    expect(zoneCratesPath(godowns[0], godowns, twins[0], twins)).toBe(
      `/godowns/gd_1/zones/${twins[0].id}/crates`,
    )
    expect(matchLocation(twins, "A")).toBeNull()
    expect(godownZonesPath(godowns[1], godowns)).toBe("/godowns/gd_7/zones")
  })
})
