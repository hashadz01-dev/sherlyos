import { z } from "zod"

const requiredName = z
  .string()
  .trim()
  .min(1, "Enter a name.")
  .max(160, "Name is too long.")

const requiredCode = z
  .string()
  .trim()
  .min(1, "Enter a code.")
  .max(40, "Code is too long.")

const optionalText = (max: number, message: string) =>
  z.string().trim().max(max, message)

const optionalReference = z.string().trim()

export const categorySchema = z.object({
  name: requiredName,
  description: optionalText(500, "Description is too long."),
})

export const supplierSchema = z.object({
  name: requiredName,
  phone: z
    .string()
    .trim()
    .refine(
      (value) => value.length === 0 || (value.length >= 7 && value.length <= 24),
      "Enter a phone number of 7 to 24 characters.",
    ),
  email: z
    .string()
    .trim()
    .refine(
      (value) => value.length === 0 || z.email().safeParse(value).success,
      "Enter a valid email address.",
    ),
})

export const productSchema = z.object({
  name: requiredName,
  sku: requiredCode,
  categoryId: optionalReference,
  supplierId: optionalReference,
})

export const shopSchema = z.object({
  name: requiredName,
  phone: supplierSchema.shape.phone,
  address: optionalText(400, "Address is too long."),
})

export const zoneSchema = z.object({
  code: requiredCode,
  name: requiredName,
  description: optionalText(500, "Description is too long."),
})

export const crateSchema = z.object({
  code: requiredCode,
  name: optionalText(160, "Name is too long."),
  description: optionalText(500, "Description is too long."),
})

export type CategoryValues = z.infer<typeof categorySchema>
export type SupplierValues = z.infer<typeof supplierSchema>
export type ProductValues = z.infer<typeof productSchema>
export type ShopValues = z.infer<typeof shopSchema>
export type ZoneValues = z.infer<typeof zoneSchema>
export type CrateValues = z.infer<typeof crateSchema>

export function emptyToNull(value: string) {
  const trimmed = value.trim()
  return trimmed.length === 0 ? null : trimmed
}