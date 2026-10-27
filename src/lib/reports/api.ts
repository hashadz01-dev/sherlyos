import { callRpc } from "@/lib/masters/api"

export type ReportPage<T> = {
  timezone: "UTC"
  page: number
  page_size: number
  total_count: number
  rows: T[]
  grain?: string
  summary?: Record<string, number>
  near_expiry_warning_days?: number
  interval?: string
}

export type KpiValue =
  | { state: "available"; value: number }
  | { state: "not_applicable"; reason: string; value: null }

export type DashboardBranchStock = {
  branch_id: string
  branch_code: string
  branch_name: string
  cartons: number
}

export type OperationsDashboard = {
  timezone: "UTC"
  filter_branch: string | null
  authorized_branches: { id: string; code: string; name: string }[]
  cutover: {
    dual_write_enabled: boolean
    aggregate_only_blocked: boolean
  }
  inventory: {
    visible: boolean
    total_cartons_on_hand?: number
    products_with_positive_stock?: number
    stock_by_godown?: DashboardBranchStock[]
    lot_attributed_cartons?: number
    legacy_unattributed_cartons?: number
    active_reserved_cartons?: number
    available_to_pick?: KpiValue
  }
  orders: {
    visible: boolean
    draft?: number
    submitted?: number
    held?: number
    verified?: number
    cancelled?: number
    awaiting_picking?: number
  }
  picking: {
    visible: boolean
    allocated?: number
    picking?: number
    picked?: number
    ready_for_dispatch?: number
    blocked?: number
    active_reserved_cartons?: number
    exception_rows?: number
  }
  dispatch: {
    visible: boolean
    preparing?: number
    dispatched?: number
    in_transit?: number
    delivered?: number
    exception?: number
    pending_proof_of_delivery?: number
    dispatched_cartons?: number
  }
  deliveries: {
    visible: boolean
    assigned_open?: number
    delivered?: number
    exception?: number
  }
  operations: {
    visible: boolean
    pending_receiving?: number
    pending_adjustments?: number
    pending_verification?: number
    unclassified_products?: number
    pending_physical_returns?: number
  }
}

export type InventoryReportRow = {
  row_key: string
  branch_id: string
  branch_code: string
  branch_name: string
  zone_id: string | null
  zone_code: string | null
  crate_id: string | null
  crate_code: string | null
  product_id: string | null
  product_sku: string | null
  product_name: string | null
  quantity: number
  grain_rows: number
}

export type LotStockReportRow = {
  lot_id: string
  lot_status: string
  origin: string
  manufacturer_lot_code: string | null
  expiry_date: string | null
  received_on: string | null
  product_id: string
  product_sku: string
  product_name: string
  expiry_policy: string | null
  branch_id: string
  branch_code: string
  crate_id: string
  crate_code: string
  quantity: number
  expiry_bucket: "expired" | "approaching" | "unknown_expiry" | "none"
}

export type MovementReportRow = {
  transaction_id: string
  reference_number: string
  transaction_type: string
  posted_at: string
  quantity: number
  product_sku: string
  product_name: string
  source_crate_code: string | null
  destination_crate_code: string | null
  branch_code: string | null
  actor_name: string | null
  dispatch_number: string | null
  order_number: string | null
  lot_references: string | null
}

export type OrderPickingReportRow = {
  order_id: string
  order_number: string
  order_status: string
  shop_name: string
  branch_name: string
  salesperson_name: string | null
  created_at: string
  verified_at: string | null
  age_days: number
  picking_number: string | null
  picking_status: string | null
  active_reserved_cases: number
  stock_dispatched: boolean
  awaiting_allocation: boolean
}

export type DispatchReportRow = {
  dispatch_id: string
  request_number: string
  status: string
  stock_consumed: boolean
  branch_name: string
  order_number: string
  assigned_to_name: string | null
  created_at: string
  dispatched_at: string | null
  delivered_at: string | null
  physical_return_status: string | null
  dispatched_cartons: number
  turnaround_seconds: number | null
}

export type ExceptionReportRow = {
  kind: string
  href: string
  item_id: string
  label: string
  detail: string | null
  branch_id: string | null
  occurred_at: string
}

export type ExportPayload = {
  timezone: "UTC"
  report_kind: string
  row_count: number
  total_count: number
  truncated: boolean
  csv: string
}

function reportViewer(userId: string | undefined) {
  return userId ?? "signed-out"
}

export const reportKeys = {
  dashboard: (userId: string | undefined, branch: string) =>
    ["operations-dashboard", reportViewer(userId), branch] as const,
  inventory: (userId: string | undefined, filters: Record<string, unknown>) =>
    ["inventory-report", reportViewer(userId), filters] as const,
  lots: (userId: string | undefined, filters: Record<string, unknown>) =>
    ["lot-stock-report", reportViewer(userId), filters] as const,
  movements: (userId: string | undefined, filters: Record<string, unknown>) =>
    ["movement-report", reportViewer(userId), filters] as const,
  orders: (userId: string | undefined, filters: Record<string, unknown>) =>
    ["order-picking-report", reportViewer(userId), filters] as const,
  dispatch: (userId: string | undefined, filters: Record<string, unknown>) =>
    ["dispatch-report", reportViewer(userId), filters] as const,
  exceptions: (userId: string | undefined, filters: Record<string, unknown>) =>
    ["exception-report", reportViewer(userId), filters] as const,
  refill: (userId: string | undefined, filters: Record<string, unknown>) =>
    ["refill-report", reportViewer(userId), filters] as const,
}

export function getOperationsDashboard(filter_branch?: string | null) {
  return callRpc<OperationsDashboard>("get_operations_dashboard", {
    filter_branch: filter_branch || null,
  })
}

export function listInventoryReport(args: Record<string, unknown>) {
  return callRpc<ReportPage<InventoryReportRow>>("list_inventory_report", args)
}

export function listLotStockReport(args: Record<string, unknown>) {
  return callRpc<ReportPage<LotStockReportRow>>("list_lot_stock_report", args)
}

export function listStockMovementReport(args: Record<string, unknown>) {
  return callRpc<ReportPage<MovementReportRow>>("list_stock_movement_report", args)
}

export function listOrderPickingReport(args: Record<string, unknown>) {
  return callRpc<ReportPage<OrderPickingReportRow>>("list_order_picking_report", args)
}

export function listDispatchDeliveryReport(args: Record<string, unknown>) {
  return callRpc<ReportPage<DispatchReportRow>>("list_dispatch_delivery_report", args)
}

export function listOperationsExceptions(args: Record<string, unknown>) {
  return callRpc<ReportPage<ExceptionReportRow>>("list_operations_exceptions", args)
}

export function exportOperationsReport(args: Record<string, unknown>) {
  return callRpc<ExportPayload>("export_operations_report", args)
}

/** Trigger a UTF-8 CSV download from a server-built payload. */
export function downloadReportCsv(filename: string, csv: string) {
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8" })
  const url = URL.createObjectURL(blob)
  const link = document.createElement("a")
  link.href = url
  link.download = filename
  link.click()
  URL.revokeObjectURL(url)
}
