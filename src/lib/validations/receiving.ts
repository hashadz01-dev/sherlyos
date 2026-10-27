import { z } from "zod"

const requiredId = z.string().uuid("Choose a record.")

const wholeCases = z
  .string()
  .trim()
  .regex(/^(0|[1-9]\d{0,6})$/, "Enter a whole number of carton cases.")
  .refine((value) => Number(value) <= 1_000_000, "Quantity is too large.")

export const receiptLineSchema = z
  .object({
    productId: requiredId,
    zoneId: requiredId,
    crateId: requiredId,
    documentCases: wholeCases,
    countedCases: wholeCases,
    damagedCases: wholeCases,
  })
  .refine((line) => Number(line.damagedCases) <= Number(line.countedCases), {
    path: ["damagedCases"],
    message: "Damaged cases cannot exceed counted cases.",
  })

export const receiptFormSchema = z.object({
  godownId: requiredId,
  supplierId: requiredId,
  /** Empty keeps ordinary unlinked Branch 03 receiving. */
  refillRequestId: z.union([z.literal(""), requiredId]).optional(),
  documentReference: z
    .string()
    .trim()
    .min(1, "Enter the supplier document reference.")
    .max(80, "Document reference is too long."),
  receivedDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Enter a received date."),
  notes: z.string().trim().max(500, "Notes are too long."),
  lines: z.array(receiptLineSchema).min(1, "Add at least one line.").max(100),
})

export type ReceiptFormValues = z.infer<typeof receiptFormSchema>
export type ReceiptLineValues = z.infer<typeof receiptLineSchema>
