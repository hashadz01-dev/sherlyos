import { callRpc } from "@/lib/masters/api"

export const statutoryKeys = {
  sellers: ["statutory-seller-identities"] as const,
  shops: (shopId: string) => ["statutory-shop-tax", shopId] as const,
  hsn: (productId: string) => ["statutory-hsn", productId] as const,
  rates: ["statutory-tax-schedules"] as const,
  policies: ["statutory-policies"] as const,
  readiness: ["statutory-readiness"] as const,
}

export type StatutorySellerIdentity = {
  id: string
  ownership_code: string
  version: number
  status: string
  legal_name: string
  registered_address: string
  state_name: string | null
  state_code: string | null
  gstin: string | null
  pan: string | null
  fssai_license: string | null
  msme_registration: string | null
  contact_phone: string | null
  contact_email: string | null
  bank_account_name: string | null
  bank_account_number: string | null
  bank_ifsc: string | null
  bank_name: string | null
  signature_caption: string | null
  seal_caption: string | null
  effective_from: string
  effective_to: string | null
  verified_at: string | null
}

export type ShopTaxIdentity = {
  id: string
  shop_id: string
  shop_name?: string
  version: number
  status: string
  billing_name: string
  billing_address: string
  shipping_address: string | null
  state_name: string | null
  state_code: string | null
  gstin: string | null
  registration_status: string
  effective_from: string
  effective_to: string | null
  verified_at: string | null
}

export type ProductHsnClassification = {
  id: string
  product_id: string
  sku?: string
  product_name?: string
  version: number
  status: string
  classification_kind: "hsn" | "sac"
  hsn_sac_code: string
  effective_from: string
  effective_to: string | null
  verified_at: string | null
}

export type TaxRateSchedule = {
  id: string
  schedule_code: string
  version: number
  status: string
  hsn_sac_code: string | null
  cgst_rate: number | string | null
  sgst_rate: number | string | null
  igst_rate: number | string | null
  treatment: string
  effective_from: string
  effective_to: string | null
  verified_at: string | null
}

export type StatutoryPolicy = {
  id: string
  policy_kind: string
  version: number
  status: string
  payload: Record<string, unknown>
  effective_from: string
  effective_to: string | null
  verified_at: string | null
}

export function listStatutorySellerIdentities() {
  return callRpc<StatutorySellerIdentity[]>("list_statutory_seller_identities", {})
}

export function upsertStatutorySellerIdentity(args: Record<string, unknown>) {
  return callRpc<StatutorySellerIdentity>("upsert_statutory_seller_identity", args)
}

export function submitStatutorySellerIdentity(id: string, expectedVersion: number) {
  return callRpc<StatutorySellerIdentity>("submit_statutory_seller_identity", {
    p_id: id,
    p_expected_version: expectedVersion,
  })
}

export function verifyStatutorySellerIdentity(id: string, expectedVersion: number) {
  return callRpc<StatutorySellerIdentity>("verify_statutory_seller_identity", {
    p_id: id,
    p_expected_version: expectedVersion,
  })
}

export function listShopTaxIdentities(shopId?: string) {
  return callRpc<ShopTaxIdentity[]>("list_shop_tax_identities", {
    p_shop_id: shopId || null,
  })
}

export function upsertShopTaxIdentity(args: Record<string, unknown>) {
  return callRpc<ShopTaxIdentity>("upsert_shop_tax_identity", args)
}

export function submitShopTaxIdentity(id: string, expectedVersion: number) {
  return callRpc<ShopTaxIdentity>("submit_shop_tax_identity", {
    p_id: id,
    p_expected_version: expectedVersion,
  })
}

export function verifyShopTaxIdentity(id: string, expectedVersion: number) {
  return callRpc<ShopTaxIdentity>("verify_shop_tax_identity", {
    p_id: id,
    p_expected_version: expectedVersion,
  })
}

export function listProductHsnClassifications(productId?: string) {
  return callRpc<ProductHsnClassification[]>("list_product_hsn_classifications", {
    p_product_id: productId || null,
  })
}

export function upsertProductHsnClassification(args: Record<string, unknown>) {
  return callRpc<ProductHsnClassification>("upsert_product_hsn_classification", args)
}

export function submitProductHsnClassification(id: string, expectedVersion: number) {
  return callRpc<ProductHsnClassification>("submit_product_hsn_classification", {
    p_id: id,
    p_expected_version: expectedVersion,
  })
}

export function verifyProductHsnClassification(id: string, expectedVersion: number) {
  return callRpc<ProductHsnClassification>("verify_product_hsn_classification", {
    p_id: id,
    p_expected_version: expectedVersion,
  })
}

export function listTaxRateSchedules() {
  return callRpc<TaxRateSchedule[]>("list_tax_rate_schedules", {})
}

export function upsertTaxRateSchedule(args: Record<string, unknown>) {
  return callRpc<TaxRateSchedule>("upsert_tax_rate_schedule", args)
}

export function submitTaxRateSchedule(id: string, expectedVersion: number) {
  return callRpc<TaxRateSchedule>("submit_tax_rate_schedule", {
    p_id: id,
    p_expected_version: expectedVersion,
  })
}

export function verifyTaxRateSchedule(id: string, expectedVersion: number) {
  return callRpc<TaxRateSchedule>("verify_tax_rate_schedule", {
    p_id: id,
    p_expected_version: expectedVersion,
  })
}

export function listStatutoryPolicies() {
  return callRpc<StatutoryPolicy[]>("list_statutory_policies", {})
}

export function upsertStatutoryPolicy(args: Record<string, unknown>) {
  return callRpc<StatutoryPolicy>("upsert_statutory_policy", args)
}

export function submitStatutoryPolicy(id: string, expectedVersion: number) {
  return callRpc<StatutoryPolicy>("submit_statutory_policy", {
    p_id: id,
    p_expected_version: expectedVersion,
  })
}

export function verifyStatutoryPolicy(id: string, expectedVersion: number) {
  return callRpc<StatutoryPolicy>("verify_statutory_policy", {
    p_id: id,
    p_expected_version: expectedVersion,
  })
}
