export const receiptStatuses = [
  "draft",
  "submitted",
  "held",
  "posted",
  "cancelled",
] as const

export type ReceiptStatus = (typeof receiptStatuses)[number]

export type ReceiptLineInput = {
  documentCases: number
  countedCases: number
  damagedCases: number
}

export function normalizeDocumentReference(value: string) {
  return value.trim().replace(/\s+/g, " ").toLowerCase()
}

export function acceptedCases(countedCases: number, damagedCases: number) {
  return countedCases - damagedCases
}

export function receiptTotals(lines: ReceiptLineInput[]) {
  return lines.reduce<ReceiptLineInput & { acceptedCases: number }>(
    (totals, line) => ({
      documentCases: totals.documentCases + line.documentCases,
      countedCases: totals.countedCases + line.countedCases,
      damagedCases: totals.damagedCases + line.damagedCases,
      acceptedCases:
        totals.acceptedCases + acceptedCases(line.countedCases, line.damagedCases),
    }),
    { documentCases: 0, countedCases: 0, damagedCases: 0, acceptedCases: 0 },
  )
}

export function receiptActions(input: {
  status: ReceiptStatus
  isCreator: boolean
  canExecute: boolean
  canVerify: boolean
}) {
  const open = input.status === "draft" || input.status === "submitted" || input.status === "held"
  return {
    canEdit: input.canExecute && input.isCreator && input.status === "draft",
    canSubmit: input.canExecute && input.isCreator && input.status === "draft",
    canCancelOwn: input.canExecute && input.isCreator && input.status === "draft",
    canHold: input.canVerify && (input.status === "draft" || input.status === "submitted"),
    canRelease:
      input.status === "held" &&
      (input.canVerify || (input.canExecute && input.isCreator)),
    canVerify: input.canVerify && input.status === "submitted",
    canCancelAsManager: input.canVerify && open,
  }
}

export function receivingErrorMessage(error: unknown) {
  if (error instanceof Error && error.message.trim()) {
    return error.message
  }
  return "The receipt could not be saved."
}
