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
  routeId: z.string().trim().optional(),
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

/** Vehicle types are informational labels. Capacity is not enforced against a load. */
export const vehicleTypes = ["truck", "van", "two_wheeler", "other"] as const

/** Shared fleet: godown is chosen on the delivery run, not on this form. */
export const vehicleSchema = z.object({
  registrationNumber: z
    .string()
    .trim()
    .min(4, "Enter a registration number.")
    .max(32, "Registration number is too long."),
  vehicleType: z.enum(vehicleTypes),
  displayName: requiredName,
  capacityCases: z
    .string()
    .trim()
    .refine(
      (value) => value.length === 0 || (/^[0-9]+$/.test(value) && Number(value) >= 1),
      "Capacity must be a whole number of cases.",
    ),
  notes: optionalText(500, "Notes are too long."),
})

export type CategoryValues = z.infer<typeof categorySchema>
export type SupplierValues = z.infer<typeof supplierSchema>
export type ProductValues = z.infer<typeof productSchema>
export type ShopValues = z.infer<typeof shopSchema>
export type ZoneValues = z.infer<typeof zoneSchema>
export type CrateValues = z.infer<typeof crateSchema>
export type VehicleValues = z.infer<typeof vehicleSchema>

export function emptyToNull(value: string) {
  const trimmed = value.trim()
  return trimmed.length === 0 ? null : trimmed
}