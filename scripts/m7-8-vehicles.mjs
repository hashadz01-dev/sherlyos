/**
 * M7.8 Sherlys Distributors vehicle source.
 * Plates come from Vehicle.docx. They are a shared fleet: no home godown.
 * vehicle_type is required by the table; source did not classify type, so
 * imported rows use "other" until the owner names truck/van/two-wheeler.
 */
export const CATALOGUE_VERSION = "m7.8"

/** Matches app_private.normalize_vehicle_registration: lowercase alphanumeric only. */
export function normalizeRegistration(raw) {
  return String(raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "")
}

function v(partial) {
  const registrationNumber = partial.registrationNumber
  return {
    optional: false,
    branchId: null,
    vehicleType: "other",
    capacityCases: null,
    disposition: "INSERT",
    reviewFlags: ["UNCLASSIFIED_VEHICLE_TYPE"],
    notes:
      "Shared fleet. Assigned to a godown only when a delivery run starts. Type not in Vehicle.docx; stored as other.",
    ...partial,
    registrationNumber,
    registrationNormalized: normalizeRegistration(registrationNumber),
  }
}

export const VEHICLES = [
  v({ ref: "BENZ_B", displayName: "Benz (B)", registrationNumber: "KL-43-F-948" }),
  v({ ref: "BENZ_S", displayName: "Benz (S)", registrationNumber: "KL-43-K-3458" }),
  v({ ref: "NEW_SML", displayName: "New SML", registrationNumber: "KL-43-T-5764" }),
  v({ ref: "MAHINDRA", displayName: "Mahindra", registrationNumber: "KL-43-N-3241" }),
  v({
    ref: "BADA_DOST",
    displayName: "Bada Dost (Malayalam Motors)",
    registrationNumber: "KL-43-P-0012",
  }),
  v({ ref: "TATA", displayName: "Tata", registrationNumber: "KL-43-P-7981" }),
  v({ ref: "MAHINDRA_NEW", displayName: "Mahindra New", registrationNumber: "KL-43-Q-1561" }),
  v({ ref: "SML", displayName: "SML", registrationNumber: "KL-43-R-1543" }),
  v({ ref: "BIG_BENZ", displayName: "Big Benz", registrationNumber: "KL-43-R-5470" }),
  v({ ref: "VEERO", displayName: "Veero", registrationNumber: "KL-43-S-7528" }),
  v({
    ref: "BOLERO",
    displayName: "Bolero",
    registrationNumber: "KL-43-R-6725",
    optional: true,
    reviewFlags: ["UNCLASSIFIED_VEHICLE_TYPE", "OPTIONAL_FLEET"],
    notes:
      "Source marked optional. Created inactive so it is in the master but not offered on a delivery run until the owner activates it.",
  }),
]

export function insertableVehicles() {
  return VEHICLES.filter((row) => row.disposition === "INSERT" && row.vehicleType)
}

export function stagedVehicles() {
  return VEHICLES.filter((row) => row.disposition === "STAGE")
}
