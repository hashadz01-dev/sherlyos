import { callRpc, loadRows } from "@/lib/masters/api"
import {
  parseAvailabilitySnapshot,
  shortageLinesFromErrorDetails,
  type AvailabilityLine,
  type AvailabilitySnapshot,
  type OpenDeliveryNoteSummary,
} from "@/lib/orders/availability"
import {
  parsePickingFulfilment,
  type PickingFulfilment,
  type PickingRequestStatus,
} from "@/lib/picking/rules"
import {
  parseShipmentSummary,
  type ShipmentSummary,
} from "@/lib/shipments/rules"
import { toUserRpcMessage } from "@/lib/rpc/user-error"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"

export type {
  AvailabilityLine,
  AvailabilitySnapshot,
  OpenDeliveryNoteSummary,
} from "@/lib/orders/availability"

/** @deprecated Use AvailabilityLine. Kept for existing shortage-row call sites. */
export type AvailabilityRow = AvailabilityLine

export type OrderStatus = "draft" | "submitted" | "held" | "verified" | "cancelled"

export type OrderSource = "salesperson" | "accounts" | "telecalling" | "enquiry" | "backorder"

export type OrderFulfilmentStatus = "open" | "partially_fulfilled" | "fulfilled"

export type OrderLineInput = {
  product_id: string
  requested_cases: number
}

export type OrderRow = {
  id: string
  order_number: string
  shop_id: string
  branch_id: string
  source: OrderSource
  source_reference: string | null
  notes: string | null
  created_by: string
  status: OrderStatus
  fulfilment_status?: OrderFulfilmentStatus
  parent_order_id?: string | null
  originating_shipment_id?: string | null
  version: number
  submitted_at: string | null
  verified_at: string | null
  held_at: string | null
  cancelled_at: string | null
  cancellation_reason: string | null
  created_at: string
  updated_at: string
}

export type OrderLine = {
  id: string
  order_id: string
  product_id: string
  requested_cases: number
  created_at: string
}

export type OrderEvent = {
  id: string
  order_id: string
  event_type: string
  from_status: string | null
  to_status: string
  actor_id: string
  note: string | null
  version: number
  line_snapshot: OrderLineInput[]
  availability_snapshot: AvailabilitySnapshot | AvailabilityLine[] | null
  created_at: string
}

export type OpenPickingSummary = {
  id: string
  request_number: string
  status: PickingRequestStatus
  version: number
  fulfilment: PickingFulfilment
}

export type OrderPickingCutover = {
  dual_write_enabled: boolean
  aggregate_only_blocked: boolean
  blockers: string[]
}

export type LinkedBackorderSummary = {
  id: string
  order_number: string
  status: OrderStatus
  fulfilment_status: OrderFulfilmentStatus
  source: OrderSource
}

export type OrderDetail = {
  order: OrderRow
  lines: OrderLine[]
  events: OrderEvent[]
  open_delivery_note: OpenDeliveryNoteSummary | null
  open_picking_request: OpenPickingSummary | null
  open_shipment: ShipmentSummary | null
  linked_backorder: LinkedBackorderSummary | null
  picking_cutover: OrderPickingCutover | null
}

export type OrderCatalogShop = {
  id: string
  name: string
  is_active: boolean
}

export type OrderCatalogBranch = {
  id: string
  code: string
  name: string
  is_active: boolean
}

export type OrderCatalogProduct = {
  id: string
  sku: string
  name: string
  is_active: boolean
}

export class InsufficientStockError extends Error {
  shortages: AvailabilityLine[]

  constructor(shortages: AvailabilityLine[]) {
    super("Verification cannot be completed because the following products have insufficient picking-eligible stock.")
    this.name = "InsufficientStockError"
    this.shortages = shortages
  }
}

function client() {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) {
    throw new Error("Supabase is not configured.")
  }
  return supabase
}

async function callOrderRpc<T>(name: string, args: Record<string, unknown>) {
  const result = await client().rpc(name, args)
  if (result.error) {
    if (
      result.error.message === "insufficient stock" ||
      result.error.message.toLowerCase().includes("insufficient stock")
    ) {
      throw new InsufficientStockError(shortageLinesFromErrorDetails(result.error.details))
    }
    throw new Error(toUserRpcMessage(result.error))
  }
  return result.data as T
}

export function listOrders(statusFilter?: string | null) {
  return callRpc<OrderRow[]>("list_orders", {
    status_filter: statusFilter && statusFilter !== "all" ? statusFilter : null,
  })
}

function parseOpenPicking(raw: OrderDetail["open_picking_request"]): OrderDetail["open_picking_request"] {
  if (!raw) return null
  return {
    ...raw,
    fulfilment: parsePickingFulfilment(raw.fulfilment),
  }
}

function parsePickingCutover(raw: OrderDetail["picking_cutover"]): OrderDetail["picking_cutover"] {
  if (!raw || typeof raw !== "object") return null
  const blockers = Array.isArray(raw.blockers) ? raw.blockers.map((item) => String(item)) : []
  return {
    dual_write_enabled: raw.dual_write_enabled === true,
    aggregate_only_blocked: raw.aggregate_only_blocked === true,
    blockers,
  }
}

export function getOrder(orderId: string) {
  return callRpc<OrderDetail>("get_order", { target_order: orderId }).then((detail) => ({
    ...detail,
    open_delivery_note: detail.open_delivery_note ?? null,
    open_picking_request: parseOpenPicking(detail.open_picking_request),
    open_shipment: parseShipmentSummary(detail.open_shipment),
    linked_backorder: detail.linked_backorder ?? null,
    picking_cutover: parsePickingCutover(detail.picking_cutover),
  }))
}

export async function checkOrderAvailability(orderId: string) {
  const raw = await callRpc<unknown>("check_order_availability", {
    target_order: orderId,
  })
  return parseAvailabilitySnapshot(raw)
}

export function createOrder(input: {
  shopId: string
  branchId: string
  source: OrderSource
  sourceReference?: string
  notes?: string
  lines: OrderLineInput[]
  idempotencyKey: string
}) {
  return callOrderRpc<OrderDetail>("create_order", {
    target_shop: input.shopId,
    target_branch: input.branchId,
    order_source: input.source,
    source_reference: input.sourceReference?.trim() || null,
    order_notes: input.notes?.trim() || null,
    order_lines: input.lines,
    idempotency_key: input.idempotencyKey,
  })
}

export function setOrder(input: {
  orderId: string
  expectedVersion: number
  shopId: string
  branchId: string
  source: OrderSource
  sourceReference?: string
  notes?: string
  lines: OrderLineInput[]
  idempotencyKey: string
}) {
  return callOrderRpc<OrderDetail>("set_order", {
    target_order: input.orderId,
    expected_version: input.expectedVersion,
    target_shop: input.shopId,
    target_branch: input.branchId,
    order_source: input.source,
    source_reference: input.sourceReference?.trim() || null,
    order_notes: input.notes?.trim() || null,
    order_lines: input.lines,
    idempotency_key: input.idempotencyKey,
  })
}

export function submitOrder(orderId: string, expectedVersion: number, idempotencyKey: string) {
  return callOrderRpc<OrderDetail>("submit_order", {
    target_order: orderId,
    expected_version: expectedVersion,
    idempotency_key: idempotencyKey,
  })
}

export function holdOrder(
  orderId: string,
  expectedVersion: number,
  holdNote: string,
  idempotencyKey: string,
) {
  return callOrderRpc<OrderDetail>("hold_order", {
    target_order: orderId,
    expected_version: expectedVersion,
    hold_note: holdNote,
    idempotency_key: idempotencyKey,
  })
}

export function verifyOrder(orderId: string, expectedVersion: number, idempotencyKey: string) {
  return callOrderRpc<OrderDetail>("verify_order", {
    target_order: orderId,
    expected_version: expectedVersion,
    idempotency_key: idempotencyKey,
  })
}

export function cancelOrder(
  orderId: string,
  expectedVersion: number,
  cancellationReason: string | null,
  idempotencyKey: string,
) {
  return callOrderRpc<OrderDetail>("cancel_order", {
    target_order: orderId,
    expected_version: expectedVersion,
    cancellation_reason: cancellationReason?.trim() || null,
    idempotency_key: idempotencyKey,
  })
}

export function loadOrderShops() {
  return loadRows<OrderCatalogShop>("shops", "id, name, is_active", "name")
}

export function loadOrderBranches() {
  return loadRows<OrderCatalogBranch>("branches", "id, code, name, is_active", "name")
}

export function loadOrderProducts() {
  return loadRows<OrderCatalogProduct>("products", "id, sku, name, is_active", "name")
}
