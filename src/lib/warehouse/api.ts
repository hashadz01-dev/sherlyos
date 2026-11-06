import { listStockBalances, listStockLotBalances } from "@/lib/inventory/api"
import { toUserRpcMessage } from "@/lib/rpc/user-error"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"

export type WarehouseZone = {
  id: string
  branch_id: string
  code: string
  name: string
  location_role: string | null
  is_active: boolean
}

export type WarehouseCrate = {
  id: string
  zone_id: string
  code: string
  name: string | null
  location_role: string | null
  is_active: boolean
  /** Stored visual target. Stock above this value is overflow, not invalid. */
  capacity_cases?: number | null
}

export type VisibleReservation = {
  id: string
  crate_id: string
  product_id: string
  lot_id: string | null
  reserved_cases: number
  status: string
}

export type VisibleHold = {
  id: string
  crate_id: string
  product_id: string
  lot_id: string | null
  quantity_cases: number
  hold_kind: string
  status: string
}

function client() {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) throw new Error("Supabase is not configured.")
  return supabase
}

export async function listWarehouseZones() {
  const result = await client()
    .from("zones")
    .select("id, branch_id, code, name, location_role, is_active")
    .order("code")
  if (result.error) throw new Error(toUserRpcMessage(result.error))
  return (result.data ?? []) as WarehouseZone[]
}

export async function listWarehouseCrates() {
  const result = await client()
    .from("crates")
    .select("id, zone_id, code, name, location_role, is_active, capacity_cases")
    .order("code")
  if (result.error) throw new Error(toUserRpcMessage(result.error))
  return (result.data ?? []) as WarehouseCrate[]
}

/**
 * Reservations are visible only through picking-request RLS.
 * An empty list means none are visible to this account, not that none exist.
 */
export async function listVisibleReservations() {
  const result = await client()
    .from("stock_reservations")
    .select("id, crate_id, product_id, lot_id, reserved_cases, status")
    .eq("status", "active")
  if (result.error) {
    return { visible: false as const, rows: [] as VisibleReservation[] }
  }
  return {
    visible: true as const,
    rows: (result.data ?? []) as VisibleReservation[],
  }
}

export async function listVisibleHolds() {
  const result = await client()
    .from("damage_stock_holds")
    .select("id, crate_id, product_id, lot_id, quantity_cases, hold_kind, status")
    .in("status", ["active", "transferred"])
  if (result.error) {
    return { visible: false as const, rows: [] as VisibleHold[] }
  }
  return { visible: true as const, rows: (result.data ?? []) as VisibleHold[] }
}

export function listWarehouseBalances() {
  return listStockBalances()
}

export function listWarehouseLots() {
  return listStockLotBalances()
}
