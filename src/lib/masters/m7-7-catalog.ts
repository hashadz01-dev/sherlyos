/**
 * M7.7 catalogue invariants used by Vitest.
 * Source rows live in scripts/m7-7-catalog.mjs so the local importer and tests share one list.
 */

export const PRODUCT_SKU_MAX = 40

export const SOURCE_CLASSES = [
  "CONFIRMED_DISTRIBUTION",
  "CONFIRMED_PRODUCT",
  "MANUFACTURER_CATALOGUE_ONLY",
] as const

export type SourceClass = (typeof SOURCE_CLASSES)[number]

/**
 * Insertable rows must have a SKU, a positive case pack, and a billing unit.
 * Staged rows must not invent a case pack of 1.
 */
export function assertImportableProduct(row: {
  sku: string | null
  disposition: string
  unitsPerCase: number | null
  billingUnit: string | null
  sourceClass: string
}) {
  if (row.disposition === "INSERT") {
    if (!row.sku) throw new Error(`${row.sourceClass} insertable row is missing a SKU`)
    if (row.sku.length > PRODUCT_SKU_MAX) {
      throw new Error(`${row.sku} exceeds the 40-character SKU limit`)
    }
    if (row.unitsPerCase == null || row.unitsPerCase <= 0) {
      throw new Error(`${row.sku} cannot insert without a catalogue case pack`)
    }
    if (!row.billingUnit) {
      throw new Error(`${row.sku} cannot insert without a billing unit`)
    }
    return
  }
  if (row.unitsPerCase === 1) {
    throw new Error("unknown case packs must not default to 1")
  }
}
