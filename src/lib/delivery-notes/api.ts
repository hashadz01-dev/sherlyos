import { callRpc } from "@/lib/masters/api"
import { toUserRpcMessage } from "@/lib/rpc/user-error"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"

export type DeliveryNoteStatus =
  | "draft"
  | "generated"
  | "sent"
  | "acknowledged"
  | "voided"

export type DeliveryNoteRow = {
  id: string
  delivery_note_number: string
  order_id: string
  shop_id: string
  branch_id: string
  status: DeliveryNoteStatus
  version: number
  idempotency_key: string
  created_by: string
  generated_at: string | null
  generated_by: string | null
  sent_at: string | null
  sent_by: string | null
  acknowledged_at: string | null
  acknowledged_by: string | null
  voided_at: string | null
  voided_by: string | null
  void_reason: string | null
  created_at: string
  updated_at: string
  order_number?: string
  total_cases?: number
}

export type DeliveryNoteLine = {
  id: string
  product_id: string
  requested_cases: number
  sku: string
  product_name: string
  created_at: string
}

export type DeliveryNoteEvent = {
  id: string
  delivery_note_id: string
  event_type: string
  from_status: string | null
  to_status: string
  actor_id: string
  note: string | null
  version: number
  line_snapshot: unknown
  created_at: string
}

export type DeliveryNoteDetail = {
  delivery_note: DeliveryNoteRow
  order: {
    id: string
    order_number: string
    status: string
    shop_id: string
    branch_id: string
  }
  shop: {
    id: string
    name: string
    phone: string | null
    address: string | null
  }
  godown: {
    id: string
    code: string
    name: string
  }
  lines: DeliveryNoteLine[]
  events: DeliveryNoteEvent[]
}

export type CompanyPrintIdentity = {
  ready: boolean
  legal_name: string | null
  registered_address: string | null
  tax_id: string | null
}

export type DeliveryNotePrintPayload = {
  print_ready: boolean
  company: CompanyPrintIdentity
  delivery_note: DeliveryNoteRow
  order: DeliveryNoteDetail["order"]
  shop: DeliveryNoteDetail["shop"]
  godown: DeliveryNoteDetail["godown"]
  lines: DeliveryNoteLine[]
  total_cases: number
  created_by_name: string | null
  generated_by_name: string | null
}

export type VerifiedOrderWithoutDn = {
  id: string
  order_number: string
  shop_id: string
  branch_id: string
  status: string
  verified_at: string | null
  created_at: string
}

function client() {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) {
    throw new Error("Supabase is not configured.")
  }
  return supabase
}

async function callDnRpc<T>(name: string, args: Record<string, unknown> = {}) {
  const result = await client().rpc(name, args)
  if (result.error) {
    throw new Error(toUserRpcMessage(result.error))
  }
  return result.data as T
}

export function listDeliveryNotes(input?: {
  status?: string | null
  shopId?: string | null
  branchId?: string | null
}) {
  return callRpc<DeliveryNoteRow[]>("list_delivery_notes", {
    status_filter: input?.status && input.status !== "all" ? input.status : null,
    shop_filter: input?.shopId && input.shopId !== "all" ? input.shopId : null,
    branch_filter: input?.branchId && input.branchId !== "all" ? input.branchId : null,
  })
}

export function getDeliveryNote(noteId: string) {
  return callRpc<DeliveryNoteDetail>("get_delivery_note", { target_note: noteId })
}

export function listVerifiedOrdersWithoutDn() {
  return callRpc<VerifiedOrderWithoutDn[]>("list_verified_orders_without_dn", {})
}

export function getCompanyPrintIdentity() {
  return callRpc<CompanyPrintIdentity>("get_company_print_identity", {})
}

export function getDeliveryNotePrint(noteId: string) {
  return callDnRpc<DeliveryNotePrintPayload>("get_delivery_note_print", {
    target_note: noteId,
  })
}

export function createDeliveryNote(orderId: string, idempotencyKey: string) {
  return callDnRpc<DeliveryNoteDetail>("create_delivery_note", {
    target_order: orderId,
    idempotency_key: idempotencyKey,
  })
}

export function generateDeliveryNote(
  noteId: string,
  expectedVersion: number,
  idempotencyKey: string,
) {
  return callDnRpc<DeliveryNoteDetail>("generate_delivery_note", {
    target_note: noteId,
    expected_version: expectedVersion,
    idempotency_key: idempotencyKey,
  })
}

export function voidDeliveryNote(
  noteId: string,
  expectedVersion: number,
  voidReason: string,
  idempotencyKey: string,
) {
  return callDnRpc<DeliveryNoteDetail>("void_delivery_note", {
    target_note: noteId,
    expected_version: expectedVersion,
    void_reason: voidReason,
    idempotency_key: idempotencyKey,
  })
}

export function sendDeliveryNote(
  noteId: string,
  expectedVersion: number,
  idempotencyKey: string,
) {
  return callDnRpc<DeliveryNoteDetail>("send_delivery_note", {
    target_note: noteId,
    expected_version: expectedVersion,
    idempotency_key: idempotencyKey,
  })
}

export function acknowledgeDeliveryNote(
  noteId: string,
  expectedVersion: number,
  idempotencyKey: string,
) {
  return callDnRpc<DeliveryNoteDetail>("acknowledge_delivery_note", {
    target_note: noteId,
    expected_version: expectedVersion,
    idempotency_key: idempotencyKey,
  })
}
