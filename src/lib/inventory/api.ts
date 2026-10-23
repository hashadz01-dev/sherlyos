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

export type StockLotBalance = {
  lot_id: string
  product_id: string
  product_sku: string
  product_name: string
  expiry_policy: "expiry_controlled" | "non_expiring" | null
  lot_status: string
  lot_origin: string
  manufacturer_lot_code: string | null
  manufactured_on: string | null
  expiry_date: string | null
  received_on: string | null
  godown_id: string
  godown_code: string
  crate_id: string
  crate_code: string
  quantity: number
}

export type StockTransaction = {
  transaction_id: string
  reference_number: string
  transaction_type: string
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

export type StockLotCutoverState = {
  dual_write_enabled: boolean
  aggregate_only_blocked: boolean
}

export function getStockLotCutoverState() {
  return callRpc<StockLotCutoverState>("get_stock_lot_cutover_state", {})
}

export function listStockBalances() {
  return callRpc<StockBalance[]>("list_stock_balances", {})
}

export function listStockLotBalances(args?: {
  filter_branch?: string | null
  filter_crate?: string | null
  filter_product?: string | null
}) {
  return callRpc<StockLotBalance[]>("list_stock_lot_balances", {
    filter_branch: args?.filter_branch ?? null,
    filter_crate: args?.filter_crate ?? null,
    filter_product: args?.filter_product ?? null,
  })
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
  manufacturer_lot_code?: string | null
  manufactured_on?: string | null
  expiry_date?: string | null
}) {
  return callRpc<PostedStock>("post_opening_stock", {
    target_product: args.target_product,
    target_crate: args.target_crate,
    carton_quantity: args.carton_quantity,
    idempotency_key: args.idempotency_key,
    posting_notes: args.posting_notes,
    manufacturer_lot_code: args.manufacturer_lot_code ?? null,
    manufactured_on: args.manufactured_on ?? null,
    expiry_date: args.expiry_date ?? null,
  })
}

export function postCrateTransfer(args: {
  target_product: string
  source_crate: string
  destination_crate: string
  carton_quantity: number
  idempotency_key: string
  posting_notes: string | null
  lot_moves?: { lot_id: string; quantity: number }[] | null
}) {
  return callRpc<PostedStock>("post_crate_transfer", {
    target_product: args.target_product,
    source_crate: args.source_crate,
    destination_crate: args.destination_crate,
    carton_quantity: args.carton_quantity,
    idempotency_key: args.idempotency_key,
    posting_notes: args.posting_notes,
    lot_moves: args.lot_moves ?? null,
  })
}
