export function stockTransactionLabel(transactionType: string) {
  if (transactionType === "OPENING_STOCK") return "Opening stock"
  if (transactionType === "CRATE_TRANSFER") return "Transfer"
  if (transactionType === "RECEIPT") return "Receipt"
  return transactionType
}

export function stockMovementLabel(input: {
  transactionType: string
  sourceCrateCode: string | null
  destinationCrateCode: string
}) {
  if (input.transactionType === "CRATE_TRANSFER") {
    return `${input.sourceCrateCode ?? "Source"} → ${input.destinationCrateCode}`
  }
  return input.destinationCrateCode
}
