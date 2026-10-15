import { useQuery } from "@tanstack/react-query"
import { loadRows } from "@/lib/masters/api"

export type BranchOption = { id: string; code: string; name: string; is_active: boolean }
export type ZoneOption = {
  id: string
  branch_id: string
  code: string
  name: string
  is_active: boolean
}
export type CrateOption = {
  id: string
  zone_id: string
  code: string
  name: string | null
  is_active: boolean
}
export type ProductOption = { id: string; sku: string; name: string; is_active: boolean }

export function useStockLocations() {
  const branches = useQuery({
    queryKey: ["branches"],
    queryFn: () => loadRows<BranchOption>("branches", "id, code, name, is_active", "name"),
  })
  const zones = useQuery({
    queryKey: ["zones"],
    queryFn: () =>
      loadRows<ZoneOption>("zones", "id, branch_id, code, name, is_active", "code"),
  })
  const crates = useQuery({
    queryKey: ["crates"],
    queryFn: () =>
      loadRows<CrateOption>("crates", "id, zone_id, code, name, is_active", "code"),
  })
  const products = useQuery({
    queryKey: ["products"],
    queryFn: () => loadRows<ProductOption>("products", "id, sku, name, is_active", "name"),
  })

  return { branches, zones, crates, products }
}
