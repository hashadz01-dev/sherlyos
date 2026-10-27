import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import { toUserRpcMessage } from "@/lib/rpc/user-error"
import {
  parseShipmentSummary,
  type ShipmentSummary,
} from "@/lib/shipments/rules"

export class ShipmentRpcError extends Error {
  readonly code: string

  constructor(message: string, code = "") {
    super(message)
    this.name = "ShipmentRpcError"
    this.code = code
  }
}

export const shipmentKeys = {
  detail: (id: string) => ["shipment", id] as const,
}

async function shipmentRpc<T>(name: string, args: Record<string, unknown> = {}) {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) {
    throw new ShipmentRpcError("Supabase is not configured.", "PGRST000")
  }
  const result = await supabase.rpc(name, args)
  if (result.error) {
    throw new ShipmentRpcError(toUserRpcMessage(result.error), result.error.code)
  }
  return result.data as T
}

export function getShipment(targetShipment: string) {
  return shipmentRpc<ShipmentSummary>("get_shipment", {
    target_shipment: targetShipment,
  }).then((row) => parseShipmentSummary(row))
}

export function createShortShipment(input: {
  target_request: string
  expected_picking_version: number
  idempotency_key: string
}) {
  return shipmentRpc<ShipmentSummary>("create_short_shipment", input).then(
    (row) => parseShipmentSummary(row),
  )
}

export function confirmShortShipmentQuantities(input: {
  target_shipment: string
  expected_version: number
  idempotency_key: string
}) {
  return shipmentRpc<ShipmentSummary>("confirm_short_shipment_quantities", input).then(
    (row) => parseShipmentSummary(row),
  )
}

export function approveShortShipment(input: {
  target_shipment: string
  expected_version: number
  lot_quantities: { shipment_lot_id: string; approved_cases: number }[] | null
  idempotency_key: string
}) {
  return shipmentRpc<ShipmentSummary>("approve_short_shipment", input).then(
    (row) => parseShipmentSummary(row),
  )
}

export function cancelShortShipment(input: {
  target_shipment: string
  expected_version: number
  cancel_reason: string
  idempotency_key: string
}) {
  return shipmentRpc<ShipmentSummary>("cancel_short_shipment", input).then(
    (row) => parseShipmentSummary(row),
  )
}
