import { useQuery } from "@tanstack/react-query"
import { toUserRpcMessage } from "@/lib/rpc/user-error"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import {
  listVisibleHolds,
  listVisibleReservations,
  listWarehouseBalances,
  listWarehouseCrates,
  listWarehouseLots,
  listWarehouseZones,
} from "@/lib/warehouse/api"
import type { GodownRecord } from "@/lib/warehouse/model"

async function listGodownRecords() {
  const supabase = getSupabaseBrowserClient()
  const result = await supabase
    ?.from("branches")
    .select("id, code, name, is_active")
    .order("name")
  if (result?.error) throw new Error(toUserRpcMessage(result.error))
  return (result?.data ?? []) as GodownRecord[]
}

/** Shared warehouse reads. Stock RPCs stay authoritative for quantities. */
export function useWarehouseSnapshot() {
  const godowns = useQuery({
    queryKey: ["branches"],
    queryFn: listGodownRecords,
  })
  const zones = useQuery({
    queryKey: ["warehouse-zones"],
    queryFn: listWarehouseZones,
  })
  const crates = useQuery({
    queryKey: ["warehouse-crates"],
    queryFn: listWarehouseCrates,
  })
  const balances = useQuery({
    queryKey: ["warehouse-balances"],
    queryFn: listWarehouseBalances,
  })
  const lots = useQuery({
    queryKey: ["warehouse-lots"],
    queryFn: listWarehouseLots,
  })
  const reservations = useQuery({
    queryKey: ["warehouse-reservations"],
    queryFn: listVisibleReservations,
  })
  const holds = useQuery({
    queryKey: ["warehouse-holds"],
    queryFn: listVisibleHolds,
  })
  const structureLoading = godowns.isLoading || zones.isLoading || crates.isLoading
  const structureError = godowns.error ?? zones.error ?? crates.error
  const ready =
    godowns.data && zones.data && crates.data && reservations.data && holds.data
      ? {
          godowns: godowns.data,
          zones: zones.data,
          crates: crates.data,
          balances: balances.data ?? [],
          lots: lots.data ?? [],
          reservations: reservations.data.rows,
          holds: holds.data.rows,
          reservationsVisible: reservations.data.visible,
          holdsVisible: holds.data.visible,
        }
      : null
  return {
    godowns,
    zones,
    crates,
    balances,
    lots,
    reservations,
    holds,
    structureLoading,
    structureError,
    ready,
  }
}
