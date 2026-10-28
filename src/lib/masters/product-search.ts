import { toUserRpcMessage } from "@/lib/rpc/user-error"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"

export type ProductSearchRow = {
  id: string
  sku: string
  name: string
  is_active: boolean
  expiry_policy: "expiry_controlled" | "non_expiring" | null
  category_id: string | null
  supplier_id: string | null
  billing_unit?: string | null
  billed_units_per_case?: number | string | null
}

function client() {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) {
    throw new Error("Supabase is not configured.")
  }
  return supabase
}

/** Stable picker label. SKU disambiguates duplicate names. */
export function productSearchLabel(row: Pick<ProductSearchRow, "sku" | "name">) {
  return `${row.sku} · ${row.name}`
}

/**
 * Server-side catalog search. Empty query returns the first page by name/sku/id
 * so small godowns still browse; a SKU query finds rows beyond PostgREST's 1000.
 */
export async function searchProducts(options: {
  query: string
  limit?: number
  offset?: number
  activeOnly?: boolean
  supplierId?: string | null
}): Promise<ProductSearchRow[]> {
  const result = await client().rpc("search_products", {
    product_query: options.query,
    result_limit: options.limit ?? 50,
    result_offset: options.offset ?? 0,
    active_only: options.activeOnly ?? true,
    filter_supplier: options.supplierId ?? null,
  })
  if (result.error) {
    throw new Error(toUserRpcMessage(result.error))
  }
  return (result.data ?? []) as ProductSearchRow[]
}

/** Single-row fetch through products RLS for a selected id not on the current page. */
export async function getProduct(productId: string): Promise<ProductSearchRow | null> {
  if (!productId) return null
  const result = await client()
    .from("products")
    .select(
      "id, sku, name, is_active, expiry_policy, category_id, supplier_id, billing_unit, billed_units_per_case",
    )
    .eq("id", productId)
    .maybeSingle()
  if (result.error) {
    throw new Error(toUserRpcMessage(result.error))
  }
  return (result.data as ProductSearchRow | null) ?? null
}
