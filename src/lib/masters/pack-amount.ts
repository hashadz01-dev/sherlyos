/**
 * Catalogue billed qty is not stock. Show it only when a real case pack exists.
 */
export function formatPackAmount(
  billedUnitsPerCase?: number | string | null,
  billingUnit?: string | null,
) {
  const units = Number(billedUnitsPerCase)
  if (!Number.isFinite(units) || units <= 0) return null
  const unit = billingUnit?.trim() || "nos"
  return `${units} ${unit} / case`
}
