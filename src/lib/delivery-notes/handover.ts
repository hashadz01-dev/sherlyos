/**
 * Accounts delivery-note handover helpers.
 * Queue and create stay aligned with list_verified_orders_without_dn and
 * assert_delivery_note_issuer: verified, no active note, assigned godown.
 */
import type { OpenDeliveryNoteSummary } from "@/lib/orders/availability"
import type { VerifiedOrderWithoutDn } from "@/lib/delivery-notes/api"

export const HANDOVER_QUEUE_TITLE = "Verified Orders Awaiting Delivery Note"

export type HandoverQueueState =
  | "loading"
  | "error"
  | "unauthorized"
  | "no_site_assignment"
  | "empty"
  | "ready"

export type HandoverQueueView = {
  state: HandoverQueueState
  title: string
  message: string
}

/**
 * Empty, error, unauthorized, and missing-assignment are distinct. An empty
 * RPC result is not "no orders" when the caller has no godown grant.
 */
export function describeHandoverQueue(input: {
  canIssue: boolean
  loading: boolean
  errorMessage?: string | null
  assignedBranchCount: number
  queueLength: number
  companyWideGodownAccess?: boolean
}): HandoverQueueView {
  if (!input.canIssue) {
    return {
      state: "unauthorized",
      title: "Not authorized",
      message: "Only Accounts can create delivery notes from verified orders.",
    }
  }
  if (input.loading) {
    return {
      state: "loading",
      title: "Loading verified orders",
      message: "Checking verified orders that still need a delivery note.",
    }
  }
  if (input.errorMessage) {
    return {
      state: "error",
      title: "Could not load verified orders",
      message: input.errorMessage,
    }
  }
  // The issue RPC already applied can_work_at_branch. Do not hide those rows
  // if the assignment table read is empty or still catching up.
  if (input.queueLength > 0) {
    return {
      state: "ready",
      title: HANDOVER_QUEUE_TITLE,
      message: "Create a draft delivery note. Quantities copy from the verified order and do not change stock.",
    }
  }
  if (!input.companyWideGodownAccess && input.assignedBranchCount < 1) {
    return {
      state: "no_site_assignment",
      title: "No godown assignment",
      message:
        "You are not assigned to a godown. Delivery notes can only be issued for godowns you are assigned to. Contact an administrator to request access.",
    }
  }
  return {
    state: "empty",
    title: "No verified orders waiting",
    message:
      "Orders appear here after Accounts verifies them and before a non-voided delivery note exists.",
  }
}

export function isActiveDeliveryNote(note: OpenDeliveryNoteSummary | null | undefined) {
  return Boolean(note && note.status !== "voided")
}

/**
 * Matches create_delivery_note: issue permission, verified, no open note,
 * and the caller can work at the order godown.
 */
export function canIssueDeliveryNoteForOrder(input: {
  canIssue: boolean
  orderStatus?: string | null
  hasActiveDeliveryNote: boolean
  orderBranchId?: string | null
  assignedBranchIds: string[]
  listedInHandoverQueue: boolean
  companyWideGodownAccess?: boolean
}) {
  if (!input.canIssue) return false
  if (input.orderStatus !== "verified") return false
  if (input.hasActiveDeliveryNote) return false
  if (input.listedInHandoverQueue || input.companyWideGodownAccess) return true
  if (!input.orderBranchId) return false
  return input.assignedBranchIds.includes(input.orderBranchId)
}

export function describeDeliveryNoteFormBlock(input: {
  canIssue: boolean
  orderId: string
  orderFound: boolean
  loadError?: string | null
  loading?: boolean
  orderStatus?: string | null
  hasActiveDeliveryNote: boolean
  activeNoteNumber?: string | null
  assignedBranchCount: number
  listedInHandoverQueue: boolean
  companyWideGodownAccess?: boolean
  canCreate: boolean
}) {
  if (!input.canIssue) {
    return "Only Accounts can create delivery notes."
  }
  if (!input.orderId) {
    return "Select a verified order."
  }
  if (input.loading) return null
  if (input.loadError) {
    return input.loadError
  }
  if (!input.orderFound) {
    return "This order is not available."
  }
  if (input.orderStatus !== "verified") {
    return "A delivery note can only be created from a verified order."
  }
  if (input.hasActiveDeliveryNote) {
    return input.activeNoteNumber
      ? `This order already has an active delivery note (${input.activeNoteNumber}). A second note cannot be created.`
      : "This order already has an active delivery note. A second note cannot be created."
  }
  if (input.canCreate) return null
  if (!input.companyWideGodownAccess && input.assignedBranchCount < 1) {
    return "You are not assigned to a godown. Contact an administrator to request access before issuing a delivery note."
  }
  if (!input.listedInHandoverQueue) {
    return "This order is not in your assigned godowns, so a delivery note cannot be created."
  }
  return "This order is not eligible for a new delivery note."
}

/** Keep the deep-linked order visible in the selector even if the queue omitted it. */
export function mergeHandoverOrderOptions(
  queue: VerifiedOrderWithoutDn[],
  selected?: {
    id: string
    order_number: string
    shop_id: string
    branch_id: string
    status: string
    verified_at: string | null
    created_at: string
  } | null,
) {
  const rows = [...queue]
  if (selected && !rows.some((row) => row.id === selected.id)) {
    rows.unshift({
      id: selected.id,
      order_number: selected.order_number,
      shop_id: selected.shop_id,
      branch_id: selected.branch_id,
      status: selected.status,
      verified_at: selected.verified_at,
      created_at: selected.created_at,
    })
  }
  return rows
}

export type OrderLineSummary = {
  cases: number
  lines: number
}

export function summarizeOrderLines(
  rows: { order_id: string; requested_cases: number }[],
) {
  const totals = new Map<string, OrderLineSummary>()
  for (const row of rows) {
    const current = totals.get(row.order_id) ?? { cases: 0, lines: 0 }
    current.cases += Number(row.requested_cases ?? 0)
    current.lines += 1
    totals.set(row.order_id, current)
  }
  return totals
}
