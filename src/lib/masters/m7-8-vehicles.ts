/**
 * M7.8 vehicle-catalogue invariants used by Vitest.
 * Source rows live in scripts/m7-8-vehicles.mjs so the importer and tests share one list.
 */

export const VEHICLE_REGISTRATION_MAX = 32
export const VEHICLE_NORMALIZED_MAX = 20

export const VEHICLE_TYPES = ["truck", "van", "two_wheeler", "other"] as const

/**
 * Insertable fleet rows need a plate and a type. Godown stays null:
 * assignment happens on the delivery run. Capacity is not invented.
 */
export function assertImportableVehicle(row: {
  displayName: string
  registrationNumber: string
  registrationNormalized: string
  optional: boolean
  branchId: string | null
  vehicleType: string | null
  capacityCases: number | null
  disposition: string
}) {
  if (!row.displayName.trim()) throw new Error("vehicle display name is required")
  if (row.registrationNumber.length < 4 || row.registrationNumber.length > VEHICLE_REGISTRATION_MAX) {
    throw new Error(`${row.registrationNumber} fails display length`)
  }
  if (
    row.registrationNormalized.length < 4 ||
    row.registrationNormalized.length > VEHICLE_NORMALIZED_MAX
  ) {
    throw new Error(`${row.registrationNumber} fails normalized length`)
  }
  if (row.disposition === "INSERT") {
    if (row.branchId) {
      throw new Error(`${row.displayName} must not invent a home godown`)
    }
    if (!row.vehicleType || !VEHICLE_TYPES.includes(row.vehicleType as (typeof VEHICLE_TYPES)[number])) {
      throw new Error(`${row.displayName} cannot INSERT without a valid vehicle type`)
    }
    if (row.capacityCases != null) {
      throw new Error(`${row.displayName} must not invent capacity`)
    }
    return
  }
  if (row.vehicleType) {
    throw new Error(`${row.displayName} is staged but already has a vehicle type`)
  }
  if (row.branchId) {
    throw new Error(`${row.displayName} is staged but already has a godown`)
  }
}
