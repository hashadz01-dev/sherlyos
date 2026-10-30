export const CATALOGUE_VERSION: string

export type CatalogueCategory = {
  code: string
  name: string
  description: string
}

export type CatalogueSupplier = {
  ref: string
  name: string
  formerNames?: string[]
  brands: string
  verification: string
  email: string | null
  phone: string | null
}

export type CatalogueProduct = {
  sku: string | null
  name: string
  categoryCode: string
  supplierRef: string
  brand: string
  packSize: string
  packagingType: string
  unitsPerCase: number | null
  billingUnit: string | null
  sourceClass: "CONFIRMED_DISTRIBUTION" | "CONFIRMED_PRODUCT" | "MANUFACTURER_CATALOGUE_ONLY"
  disposition: "INSERT" | "STAGE"
  reviewFlags: string[]
  notes: string
}

export const CATEGORIES: CatalogueCategory[]
export const SUPPLIERS: CatalogueSupplier[]
export const PRODUCTS: CatalogueProduct[]
export function insertableProducts(): CatalogueProduct[]
export function stagedProducts(): CatalogueProduct[]
export function skuList(): string[]
