import { callRpc } from "@/lib/masters/api"

export type ReceivingOptions = {
  godowns: { id: string; code: string; name: string }[]
  suppliers: { id: string; name: string }[]
  products: { id: string; sku: string; name: string }[]
  zones: { id: string; branch_id: string; code: string; name: string }[]
  crates: { id: string; zone_id: string; code: string; name: string | null }[]
}

export type ReceiptLine = {
  id: string
  product_id: string
  product_sku: string
  product_name: string
  zone_id: string
  zone_code: string
  destination_crate_id: string
  crate_code: string
  document_cases: number
  counted_cases: number
  damaged_cases: number
  accepted_cases: number
}

export type ReceiptAudit = {
  action: string
  actor_name: string | null
  occurred_at: string
  metadata: Record<string, unknown>
}

export type ReceiptTransaction = {
  id: string
  reference_number: string
  receipt_line_id: string
  quantity: number
}

export type StockReceipt = {
  id: string
  receipt_number: string
  godown_id: string
  godown_code: string
  godown_name: string
  supplier_id: string
  supplier_name: string
  document_reference: string
  received_date: string
  status: "draft" | "submitted" | "held" | "posted" | "cancelled"
  notes: string | null
  hold_reason: string | null
  created_by: string
  creator_name: string | null
  created_at: string
  updated_at: string
  verified_by: string | null
  verifier_name: string | null
  verified_at: string | null
  posted_at: string | null
  cancelled_by: string | null
  canceller_name: string | null
  cancelled_at: string | null
  cancellation_reason: string | null
  lines: ReceiptLine[]
  transactions: ReceiptTransaction[]
  audit: ReceiptAudit[]
}

export type ReceiptSummary = {
  id: string
  receipt_number: string
  godown_id: string
  godown_code: string
  godown_name: string
  supplier_name: string
  document_reference: string
  received_date: string
  status: StockReceipt["status"]
  creator_name: string | null
  created_by: string
  verified_at: string | null
  posted_at: string | null
}

export type ReceiptLinePayload = {
  product_id: string
  destination_crate_id: string
  document_cases: number
  counted_cases: number
  damaged_cases: number
}

export function listReceivingOptions() {
  return callRpc<ReceivingOptions>("list_receiving_options", {})
}

export function listStockReceipts() {
  return callRpc<ReceiptSummary[]>("list_stock_receipts", {})
}

export function getStockReceipt(targetReceipt: string) {
  return callRpc<StockReceipt>("get_stock_receipt", { target_receipt: targetReceipt })
}

export function createStockReceipt(args: {
  target_godown: string
  target_supplier: string
  supplier_document: string
  received_on: string
  receipt_notes: string | null
  line_items: ReceiptLinePayload[]
}) {
  return callRpc<StockReceipt>("create_stock_receipt", args)
}

export function updateStockReceipt(args: {
  target_receipt: string
  target_godown: string
  target_supplier: string
  supplier_document: string
  received_on: string
  receipt_notes: string | null
  line_items: ReceiptLinePayload[]
}) {
  return callRpc<StockReceipt>("update_stock_receipt", args)
}

export function submitStockReceipt(targetReceipt: string) {
  return callRpc<StockReceipt>("submit_stock_receipt", { target_receipt: targetReceipt })
}

export function holdStockReceipt(targetReceipt: string, reason: string) {
  return callRpc<StockReceipt>("hold_stock_receipt", {
    target_receipt: targetReceipt,
    reason,
  })
}

export function releaseStockReceipt(targetReceipt: string) {
  return callRpc<StockReceipt>("release_stock_receipt", { target_receipt: targetReceipt })
}

export function cancelStockReceipt(targetReceipt: string, reason: string) {
  return callRpc<StockReceipt>("cancel_stock_receipt", {
    target_receipt: targetReceipt,
    reason,
  })
}

export function verifyStockReceipt(targetReceipt: string, idempotencyKey: string) {
  return callRpc<StockReceipt>("verify_stock_receipt", {
    target_receipt: targetReceipt,
    idempotency_key: idempotencyKey,
  })
}
