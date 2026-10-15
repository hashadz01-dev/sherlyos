export type ReceiptLineDraft = {
  key: string
  productId: string
  zoneId: string
  crateId: string
  documentCases: string
  countedCases: string
  damagedCases: string
}

export type ReceiptDraft = {
  godownId: string
  supplierId: string
  documentReference: string
  receivedDate: string
  notes: string
  lines: ReceiptLineDraft[]
}

export function emptyReceiptLine(): ReceiptLineDraft {
  return {
    key: crypto.randomUUID(),
    productId: "",
    zoneId: "",
    crateId: "",
    documentCases: "0",
    countedCases: "0",
    damagedCases: "0",
  }
}
