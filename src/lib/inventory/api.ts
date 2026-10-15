import { callRpc } from "@/lib/masters/api"

export type StockBalance = {
  godown_id: string
  godown_code: string
  godown_name: string
  zone_id: string
  zone_code: string
  zone_name: string
  crate_id: string
  crate_code: string
  crate_name: string | null
  product_id: string
  product_sku: string
  product_name: string
  quantity: number
}

export type StockTransaction = {
  transaction_id: string
  reference_number: string
  transaction_type: "OPENING_STOCK" | "CRATE_TRANSFER"
  product_id: string
  product_sku: string
  product_name: string
  source_crate_id: string | null
  source_crate_code: string | null
  source_zone_code: string | null
  destination_crate_id: string
  destination_crate_code: string
  destination_zone_code: string
  quantity: number
  actor_id: string
  actor_name: string | null
  posted_at: string
  notes: string | null
}

export type PostedStock = {
  id: string
  reference_number: string
}

export function listStockBalances() {
  return callRpc<StockBalance[]>("list_stock_balances", {})
}

export function listStockTransactions() {
  return callRpc<StockTransaction[]>("list_stock_transactions", {})
}

export function postOpeningStock(args: {
  target_product: string
  target_crate: string
  carton_quantity: number
  idempotency_key: string
  posting_notes: string | null
}) {
  return callRpc<PostedStock>("post_opening_stock", args)
}

export function postCrateTransfer(args: {
  target_product: string
  source_crate: string
  destination_crate: string
  carton_quantity: number
  idempotency_key: string
  posting_notes: string | null
}) {
  return callRpc<PostedStock>("post_crate_transfer", args)
}
