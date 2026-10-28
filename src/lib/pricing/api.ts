import { callRpc } from "@/lib/masters/api"

export const pricingKeys = {
  list: (productId: string, shopId: string, includeInactive: boolean) =>
    ["product-selling-prices", productId, shopId, includeInactive] as const,
}

export type ProductSellingPrice = {
  id: string
  product_id: string
  sku: string
  product_name: string
  shop_id: string | null
  shop_code: string | null
  shop_name: string | null
  currency_code: "INR"
  unit_amount: number | string
  effective_from: string
  effective_to: string | null
  is_active: boolean
}

export function listProductSellingPrices(options: {
  productId?: string | null
  shopId?: string | null
  includeInactive?: boolean
}) {
  return callRpc<ProductSellingPrice[]>("list_product_selling_prices", {
    p_product_id: options.productId || null,
    p_shop_id: options.shopId || null,
    p_include_inactive: options.includeInactive ?? false,
  })
}

export function upsertProductSellingPrice(options: {
  productId: string
  shopId: string | null
  unitAmount: number
  effectiveFrom: string
  effectiveTo?: string | null
  priceId?: string | null
}) {
  return callRpc<ProductSellingPrice>("upsert_product_selling_price", {
    p_product_id: options.productId,
    p_shop_id: options.shopId,
    p_unit_amount: options.unitAmount,
    p_effective_from: options.effectiveFrom,
    p_effective_to: options.effectiveTo ?? null,
    p_price_id: options.priceId ?? null,
  })
}

export function deactivateProductSellingPrice(priceId: string) {
  return callRpc<{ id: string; is_active: boolean }>(
    "deactivate_product_selling_price",
    { p_price_id: priceId },
  )
}

export function setProductBillingConversion(options: {
  productId: string
  billingUnit: string
  billedUnitsPerCase: number
}) {
  return callRpc<{
    product_id: string
    billing_unit: string
    billed_units_per_case: number | string
  }>("set_product_billing_conversion", {
    p_product_id: options.productId,
    p_billing_unit: options.billingUnit,
    p_billed_units_per_case: options.billedUnitsPerCase,
  })
}
