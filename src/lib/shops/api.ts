/**
 * Shop statement reads. The RPC refuses payment posting and does not
 * allocate statutory invoice numbers.
 */
import { callRpc } from "@/lib/masters/api"
import type { ShopListRow } from "@/lib/masters/shop-routes"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import {
  PAYMENT_UNAVAILABLE_REASON,
  SHOP_STATEMENT_WATERMARK,
  billedMoney,
  creditAdjustmentParticulars,
  creditAdjustmentStatusLabel,
  dedupeStatementEntries,
  deliveryNoteParticulars,
  invoiceNoteParticulars,
  invoiceNoteStatusLabel,
  summarizeStatement,
  unavailableMoney,
  type ShopStatementEntry,
  type ShopStatementSummary,
  type StatementSourceType,
} from "@/lib/shops/rules"

export const shopKeys = {
  list: ["shops"] as const,
  detail: (id: string) => ["shop", id] as const,
  statement: (id: string, from: string, to: string, search: string) =>
    ["shop-statement", id, from, to, search] as const,
}

export type ShopStatementPayload = {
  shop: ShopListRow
  watermark: string
  payment_accounting: {
    available: boolean
    received_available: boolean
    outstanding_available: boolean
    reason: string
  }
  entries: Array<{
    source_type: StatementSourceType
    source_id: string
    transaction_date: string
    particulars: string
    reference_number: string
    bill_amount: number | string | null
    bill_amount_available: boolean
    amount_received: number | string | null
    amount_received_available: boolean
    running_balance: number | string | null
    running_balance_available: boolean
    acknowledgement: string | null
    remarks: string | null
    status: string
    status_label: string
    href: string | null
  }>
  summary: {
    invoice_note_count: number
    delivery_note_count: number
    credit_adjustment_count: number
    reviewed_note_total: number | string | null
    submitted_note_total: number | string | null
    draft_note_total: number | string | null
    credit_adjustment_preview_total: number | string | null
  }
}

export type ShopStatementView = {
  shop: ShopListRow
  watermark: string
  paymentReason: string
  entries: ShopStatementEntry[]
  summary: ShopStatementSummary
}

/** Map the RPC payload and force payment fields off even if a row is malformed. */
export function parseShopStatement(payload: ShopStatementPayload): ShopStatementView {
  const entries = dedupeStatementEntries(
    (payload.entries ?? []).map((row) => ({
      id: `${row.source_type}:${row.source_id}`,
      sourceType: row.source_type,
      sourceId: row.source_id,
      transactionDate: row.transaction_date,
      particulars:
        row.particulars ||
        (row.source_type === "invoice_note"
          ? invoiceNoteParticulars()
          : row.source_type === "credit_adjustment"
            ? creditAdjustmentParticulars()
            : deliveryNoteParticulars()),
      referenceNumber: row.reference_number,
      billAmount:
        row.bill_amount_available === false
          ? billedMoney(null)
          : billedMoney(row.bill_amount),
      amountReceived: unavailableMoney(),
      runningBalance: unavailableMoney(),
      acknowledgement: row.acknowledgement,
      remarks: row.remarks,
      status: row.status,
      statusLabel:
        row.status_label ||
        (row.source_type === "invoice_note"
          ? invoiceNoteStatusLabel(row.status)
          : row.source_type === "credit_adjustment"
            ? creditAdjustmentStatusLabel(row.status)
            : row.status),
      href: row.href,
    })),
  )

  return {
    shop: payload.shop,
    watermark: payload.watermark || SHOP_STATEMENT_WATERMARK,
    paymentReason: payload.payment_accounting?.reason || PAYMENT_UNAVAILABLE_REASON,
    entries,
    summary: {
      ...summarizeStatement(entries),
      amountReceived: unavailableMoney(),
      outstanding: unavailableMoney(),
    },
  }
}

export async function getShop(shopId: string): Promise<ShopListRow | null> {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) throw new Error("Supabase is not configured.")
  const result = await supabase
    .from("shops")
    .select("id, name, phone, address, is_active")
    .eq("id", shopId)
    .maybeSingle()
  if (result.error) throw new Error(result.error.message)
  return result.data
}

export function getShopSalesStatement(options: {
  shopId: string
  from?: string
  to?: string
  search?: string
}) {
  return callRpc<ShopStatementPayload>("get_shop_sales_statement", {
    p_shop_id: options.shopId,
    p_from: options.from || null,
    p_to: options.to || null,
    p_search: options.search?.trim() || null,
  }).then(parseShopStatement)
}
