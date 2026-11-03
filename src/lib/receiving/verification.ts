import type { ReceiptSummary } from "@/lib/receiving/api"
import type { ReceiptStatus } from "@/lib/receiving/rules"

/**
 * Godown Manager inbound queue. Daily crate counts stay on /stock-verification.
 * Submitted receipts already exist on list_stock_receipts; this is the missing
 * inbox so they are not mistaken for physical stock verification.
 */
export type ReceiptWorkflowMode = "capture" | "verification"

/**
 * Open on the full verification history. Submitted stays available as a
 * filter so the Godown Manager can still isolate work to post.
 */
export const RECEIPT_VERIFICATION_DEFAULT_STATUS: ReceiptStatus | "all" =
  "all"

export const RECEIPT_VERIFICATION_STATUSES = [
  "all",
  "submitted",
  "held",
  "posted",
  "cancelled",
] as const

export function isAwaitingReceiptVerification(status: string) {
  return status === "submitted" || status === "held"
}

export function awaitingReceiptVerification(rows: ReceiptSummary[]) {
  return rows.filter((row) => isAwaitingReceiptVerification(row.status))
}

/** Drafts belong on Receiving capture. Verification lists submitted, held, posted, and cancelled. */
export function isReceiptVerificationRecord(status: string) {
  return status !== "draft"
}

export function receiptVerificationRows(rows: ReceiptSummary[], status: string) {
  return rows.filter((row) => {
    if (!isReceiptVerificationRecord(row.status)) return false
    if (status !== "all" && row.status !== status) return false
    return true
  })
}

/** Keep GM review under /receiving/verification so Receiving does not stay highlighted. */
export function receiptRecordPath(mode: ReceiptWorkflowMode, receiptId: string) {
  return mode === "verification"
    ? `/receiving/verification/${receiptId}`
    : `/receiving/${receiptId}`
}

export function receiptVerificationEmptyCopy(status: string) {
  if (status === "submitted") {
    return {
      title: "No submitted receipts",
      description:
        "Store Keeper submissions appear here for Godown Manager review. Verifying posts accepted cartons.",
    }
  }
  if (status === "held") {
    return {
      title: "No held receipts",
      description: "Receipts returned for correction appear here until the store keeper resubmits.",
    }
  }
  if (status === "posted") {
    return {
      title: "No posted receipts",
      description: "Verified receipts stay here after accepted cartons are posted.",
    }
  }
  return {
    title: "No receipts",
    description:
      "Submitted, held, and previously verified receipts appear here. Store Keeper drafts stay on Receiving.",
  }
}
