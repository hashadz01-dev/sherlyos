import { z } from "zod"

const requiredId = z.string().uuid("Choose a record.")

const cartonQuantity = z
  .string()
  .trim()
  .regex(/^[1-9]\d{0,6}$/, "Enter a whole number of carton cases.")
  .refine((value) => Number(value) <= 1_000_000, "Quantity is too large.")

const notes = z.string().trim().max(500, "Notes are too long.")

export const openingStockSchema = z.object({
  branchId: requiredId,
  zoneId: requiredId,
  crateId: requiredId,
  productId: requiredId,
  quantity: cartonQuantity,
  notes,
})

export const transferStockSchema = z
  .object({
    branchId: requiredId,
    sourceZoneId: requiredId,
    sourceCrateId: requiredId,
    destinationZoneId: requiredId,
    destinationCrateId: requiredId,
    productId: requiredId,
    quantity: cartonQuantity,
    notes,
  })
  .refine((values) => values.sourceCrateId !== values.destinationCrateId, {
    path: ["destinationCrateId"],
    message: "Choose a different crate.",
  })

export type OpeningStockValues = z.infer<typeof openingStockSchema>
export type TransferStockValues = z.infer<typeof transferStockSchema>
