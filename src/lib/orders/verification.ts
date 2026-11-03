import type { AvailabilitySnapshot } from "@/lib/orders/availability"
import { matchesSearch } from "@/lib/masters/filters"
import type { StatusTone } from "@/components/shared/StatusBadge"

/** Queue row shape from list_orders. Case totals are joined separately. */
export type QueueOrder = {
  id: string
  order_number: string
  shop_id: string
  branch_id: string
  source: string
  status: string
  submitted_at: string | null
  created_at: string
}

/** Client page size for the verification queue. list_orders is already scoped by RLS. */
export const VERIFICATION_PAGE_SIZE = 20

export const SUBMITTED_SCOPE_LABEL = "Submitted"

export const SUBMITTED_SCOPE_HINT = "Awaiting Accounts verification"

export type VerificationBlockKind =
  | "eligible"
  | "order_not_found"
  | "not_authorized"
  | "missing_godown_assignment"
  | "wrong_godown"
  | "blocked_by_stock"
  | "blocked_by_cutover"
  | "rpc_failed"

export type VerificationBlock = {
  kind: VerificationBlockKind
  label: string
  message: string
}

export function verificationStatusLabel(status: string) {
  switch (status) {
    case "submitted":
      return "Submitted / Awaiting Verification"
    case "verified":
      return "Verified"
    case "held":
      return "Held"
    case "draft":
      return "Draft"
    case "cancelled":
      return "Cancelled"
    default:
      return status
  }
}

export function verificationStatusTone(status: string): StatusTone {
  switch (status) {
    case "submitted":
      return "info"
    case "verified":
      return "success"
    case "held":
      return "warning"
    case "cancelled":
      return "danger"
    default:
      return "neutral"
  }
}

export function formatOrderTimestamp(value: string | null | undefined) {
  if (!value) return "—"
  return `${value.replace("T", " ").slice(0, 16)} UTC`
}

/**
 * Why verification cannot proceed. Does not invent stock or bypass site RLS.
 * RPC failure never implies the order became verified.
 */
export function describeVerificationBlock(input: {
  orderFound: boolean
  canVerify: boolean
  assignedBranchCount: number
  orderBranchId?: string | null
  assignedBranchIds?: string[]
  godownName?: string | null
  availability?: AvailabilitySnapshot | null
  rpcError?: string | null
}): VerificationBlock {
  if (!input.orderFound) {
    return {
      kind: "order_not_found",
      label: "Order not found",
      message: "This order is not available in the connected database.",
    }
  }

  if (input.availability && input.availability.picking_operational === false) {
    const extra = (input.availability.cutover_blockers ?? []).join(" ").trim()
    return {
      kind: "blocked_by_cutover",
      label: "Blocked by Stock",
      message: extra
        ? `Lot-aware packing is not operational. ${extra}`
        : "Lot-aware packing is not operational. Verification stays fail-closed until dual-write cutover.",
    }
  }

  const shortages = (input.availability?.lines ?? []).filter(
    (line) => line.shortfall_cases > 0 || !line.eligible,
  )
  if (shortages.length > 0) {
    return {
      kind: "blocked_by_stock",
      label: "Blocked by Stock",
      message:
        "Verification cannot proceed because packing-eligible stock is insufficient. The order stays submitted.",
    }
  }

  if (input.rpcError) {
    return {
      kind: "rpc_failed",
      label: "Blocked by Stock",
      message: input.rpcError,
    }
  }

  return {
    kind: "eligible",
    label: "Eligible",
    message: "This order can be verified with the authorized verify_order action.",
  }
}

/** Map get_order / list failures without naming a hidden order. */
export function describeOrderLoadFailure(input: {
  errorMessage: string
  canVerify: boolean
  assignedBranchCount: number
}): VerificationBlock {
  const unauthorized = /not authorized|do not have permission|permission denied/i.test(
    input.errorMessage,
  )
  if (unauthorized) {
    return {
      kind: "not_authorized",
      label: "Blocked by Access",
      message: "You are not authorized to view this order.",
    }
  }
  return {
    kind: "order_not_found",
    label: "Order not found",
    message: input.errorMessage || "This order is not available.",
  }
}

export function filterOrderQueueRows(
  rows: QueueOrder[],
  input: {
    search: string
    shopId: string
    branchId: string
    shopName: Map<string, string>
    branchName: Map<string, string>
  },
) {
  return rows.filter((row) => {
    if (input.shopId !== "all" && row.shop_id !== input.shopId) return false
    if (input.branchId !== "all" && row.branch_id !== input.branchId) return false
    return matchesSearch(input.search, [
      row.order_number,
      input.shopName.get(row.shop_id) ?? "",
      input.branchName.get(row.branch_id) ?? "",
      row.status,
      row.source,
    ])
  })
}

export function paginateRows<T>(rows: T[], page: number, pageSize = VERIFICATION_PAGE_SIZE) {
  const last = Math.max(1, Math.ceil(rows.length / pageSize) || 1)
  const safePage = Math.min(Math.max(page, 1), last)
  const start = (safePage - 1) * pageSize
  return {
    page: safePage,
    last,
    total: rows.length,
    rows: rows.slice(start, start + pageSize),
  }
}

export function verificationActionLabel(status: string) {
  return status === "submitted" ? "Review to verify" : "View details"
}

const UUID_SHAPE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/**
 * Show a human site name. Never fall back to a raw UUID when the catalog
 * row is missing from the current RLS scope.
 */
export function readableSiteLabel(name: string | null | undefined, fallback: string) {
  const trimmed = name?.trim() ?? ""
  if (trimmed && !UUID_SHAPE.test(trimmed)) return trimmed
  return fallback
}

export type OrderWorkflowMode = "capture" | "verification"

/** Capture list stays on /orders/:id. Approval opens the verification detail. */
export function orderRecordPath(mode: OrderWorkflowMode, orderId: string) {
  return mode === "verification" ? `/orders/verification/${orderId}` : `/orders/${orderId}`
}

/** New Order belongs on the capture module only, and only with orders.capture. */
export function shouldShowNewOrderAction(input: {
  mode: OrderWorkflowMode
  canCapture: boolean
}) {
  return input.mode === "capture" && input.canCapture
}

/**
 * Verification is a history of Accounts review, not only the submitted inbox.
 * Defaulting to submitted hid already-verified orders that still need a DN.
 */
export const VERIFICATION_DEFAULT_STATUS_FILTER = "all"

export const VERIFICATION_STATUS_FILTERS = [
  "all",
  "submitted",
  "held",
  "verified",
  "cancelled",
] as const

export function verificationQueueEmptyCopy(status: string) {
  switch (status) {
    case "submitted":
      return {
        title: "No submitted orders",
        description:
          "Submitted salesperson orders appear here for Accounts review. Sample rows are not listed.",
      }
    case "verified":
      return {
        title: "No verified orders",
        description:
          "Orders remain listed here after Accounts verifies them. Sample rows are not listed.",
      }
    case "held":
      return {
        title: "No held orders",
        description: "Held shop orders appear here until Accounts verifies or cancels them.",
      }
    case "cancelled":
      return {
        title: "No cancelled orders",
        description: "Cancelled verification records appear here. Sample rows are not listed.",
      }
    default:
      return {
        title: "No orders in verification",
        description:
          "Submitted, held, verified, and cancelled orders authorized for Accounts appear here.",
      }
  }
}
