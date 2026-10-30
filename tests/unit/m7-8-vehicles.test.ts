import { describe, expect, it } from "vitest"
import { SHORT_SHIPMENT_OPERATIONAL } from "@/lib/picking/rules"
import { assertImportableVehicle } from "@/lib/masters/m7-8-vehicles"
// Shared with scripts/m7-8-import-local.mjs. tsc -b does not attach a sibling .d.ts to this specifier.
// @ts-expect-error catalogue is a local ESM module consumed by Node and Vitest
import * as catalog from "../../scripts/m7-8-vehicles.mjs"

type Vehicle = {
  ref: string
  displayName: string
  registrationNumber: string
  registrationNormalized: string
  optional: boolean
  branchId: string | null
  vehicleType: string | null
  capacityCases: number | null
  disposition: string
}

const VEHICLES = catalog.VEHICLES as Vehicle[]
const insertableVehicles = catalog.insertableVehicles as () => Vehicle[]
const normalizeRegistration = catalog.normalizeRegistration as (raw: string) => string

describe("M7.8 vehicle catalogue", () => {
  it("keeps eleven unique fleet plates without inventing a home godown or capacity", () => {
    expect(VEHICLES).toHaveLength(11)
    const plates = VEHICLES.map((row) => row.registrationNormalized)
    expect(new Set(plates).size).toBe(plates.length)
    for (const row of VEHICLES) {
      assertImportableVehicle(row)
      expect(row.registrationNormalized).toBe(normalizeRegistration(row.registrationNumber))
      expect(row.branchId).toBeNull()
      expect(row.vehicleType).toBe("other")
      expect(row.capacityCases).toBeNull()
    }
    expect(insertableVehicles()).toHaveLength(11)
  })

  it("collapses spacing and punctuation in registration numbers", () => {
    expect(normalizeRegistration("KL-43-F-948")).toBe("kl43f948")
    expect(normalizeRegistration("KL 43 F 948")).toBe("kl43f948")
    expect(normalizeRegistration("kl43f948")).toBe("kl43f948")
  })

  it("keeps the Bolero optional so the importer can deactivate it after create", () => {
    const bolero = VEHICLES.find((row) => row.ref === "BOLERO")
    expect(bolero?.optional).toBe(true)
    expect(bolero?.disposition).toBe("INSERT")
    expect(bolero?.registrationNumber).toBe("KL-43-R-6725")
  })

  it("leaves short-shipment operationally off", () => {
    expect(SHORT_SHIPMENT_OPERATIONAL).toBe(false)
  })
})
