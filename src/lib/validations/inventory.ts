import { z } from "zod"

const requiredId = z.string().uuid("Choose a record.")

const cartonQuantity = z
  .string()
  .trim()
  .regex(/^[1-9]\d{0,6}$/, "Enter a whole number of carton cases.")
  .refine((value) => Number(value) <= 1_000_000, "Quantity is too large.")

const notes = z.string().trim().max(500, "Notes are too long.")

const optionalDate = z
  .string()
  .trim()
  .refine((value) => value === "" || /^\d{4}-\d{2}-\d{2}$/.test(value), "Use YYYY-MM-DD.")

export const openingStockSchema = z
  .object({
    branchId: requiredId,
    zoneId: requiredId,
    crateId: requiredId,
    productId: requiredId,
    quantity: cartonQuantity,
    notes,
    manufacturerLotCode: z.string().trim().max(80),
    manufacturedOn: optionalDate,
    expiryDate: optionalDate,
    dualWriteEnabled: z.boolean(),
    expiryPolicy: z.enum(["expiry_controlled", "non_expiring"]).nullable(),
  })
  .superRefine((values, ctx) => {
    if (!values.dualWriteEnabled) return
    if (!values.expiryPolicy) {
      ctx.addIssue({
        code: "custom",
        path: ["productId"],
        message: "Classify this product expiry policy before lot-aware opening.",
      })
      return
    }
    if (values.expiryPolicy === "expiry_controlled" && !values.expiryDate) {
      ctx.addIssue({
        code: "custom",
        path: ["expiryDate"],
        message: "Expiry date is required for expiry-controlled products.",
      })
    }
    if (values.expiryPolicy === "non_expiring" && values.expiryDate) {
      ctx.addIssue({
        code: "custom",
        path: ["expiryDate"],
        message: "Non-expiring products must not have an expiry date.",
      })
    }
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
    dualWriteEnabled: z.boolean(),
    lotMoves: z.array(
      z.object({
        lotId: z.string().uuid(),
        quantity: z.string().trim().regex(/^[1-9]\d{0,6}$/, "Enter a positive quantity."),
      }),
    ),
  })
  .refine((values) => values.sourceCrateId !== values.destinationCrateId, {
    path: ["destinationCrateId"],
    message: "Choose a different crate.",
  })
  .superRefine((values, ctx) => {
    if (!values.dualWriteEnabled) return
    if (values.lotMoves.length < 1) {
      ctx.addIssue({
        code: "custom",
        path: ["lotMoves"],
        message: "Select at least one lot quantity to transfer.",
      })
      return
    }
    const total = values.lotMoves.reduce((sum, move) => sum + Number(move.quantity), 0)
    if (total !== Number(values.quantity)) {
      ctx.addIssue({
        code: "custom",
        path: ["lotMoves"],
        message: "Lot quantities must equal the transfer total.",
      })
    }
  })

export type OpeningStockValues = z.infer<typeof openingStockSchema>
export type TransferStockValues = z.infer<typeof transferStockSchema>
