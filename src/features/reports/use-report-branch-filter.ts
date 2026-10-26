import { useState } from "react"
import { useStockLocations } from "@/features/inventory/location-options"

/** RLS branch list, including inactive sites an admin may report on. */
export function useReportBranchFilter() {
  const locations = useStockLocations()
  const [branchId, setBranchId] = useState("")
  return {
    branchId,
    setBranchId,
    branches: locations.branches.data ?? [],
    filterBranch: branchId || null,
  }
}
