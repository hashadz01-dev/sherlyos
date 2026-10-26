import { callRpc } from "@/lib/masters/api"
import type { DamageScenario, DamageStatus } from "@/lib/damage/rules"

export type DamageReportLineInput = {
  product_id: string
  quantity_cases: number
  damage_reason: string
  crate_id?: string | null
  lot_id?: string | null
  notes?: string | null
  receipt_line_id?: string | null
}

export type DamageReportSummary = {
  id: string
  report_number: string
  scenario: DamageScenario
  godown_id: string
  godown_name: string
  status: DamageStatus
  version: number
  reporter_name: string | null
  created_at: string
}

export type DamageReportDetail = DamageReportSummary & {
  receipt_id: string | null
  picking_request_id: string | null
  dispatch_id: string | null
  order_id: string | null
  shop_id: string | null
  notes: string | null
  lines: {
    id: string
    product_id: string
    product_sku: string
    product_name: string
    crate_id: string | null
    crate_code: string | null
    lot_id: string | null
    quantity_cases: number
    damage_reason: string
    notes: string | null
    receipt_line_id: string | null
  }[]
  events: {
    action: string
    actor_name: string | null
    previous_status: string | null
    next_status: string
    created_at: string
    metadata: Record<string, unknown>
  }[]
  evidence: {
    id: string
    finalized: boolean
    mime_type: string | null
    uploaded_at: string
  }[]
}

export function listDamageReports(page = 1, pageSize = 50, targetGodown?: string | null) {
  return callRpc<{ items: DamageReportSummary[]; total: number }>("list_damage_reports", {
    page,
    page_size: pageSize,
    target_godown: targetGodown ?? null,
  })
}

export function getDamageReport(targetReport: string) {
  return callRpc<DamageReportDetail>("get_damage_report", { target_report: targetReport })
}

export function createDamageReport(input: {
  scenario: DamageScenario
  targetGodown: string
  reportLines: DamageReportLineInput[]
  idempotencyKey: string
  notes?: string | null
  receiptId?: string | null
  pickingRequestId?: string | null
  dispatchId?: string | null
  orderId?: string | null
  shopId?: string | null
}) {
  return callRpc<DamageReportDetail>("create_damage_report", {
    scenario: input.scenario,
    target_godown: input.targetGodown,
    report_lines: input.reportLines,
    idempotency_key: input.idempotencyKey,
    notes: input.notes ?? null,
    receipt_id: input.receiptId ?? null,
    picking_request_id: input.pickingRequestId ?? null,
    dispatch_id: input.dispatchId ?? null,
    order_id: input.orderId ?? null,
    shop_id: input.shopId ?? null,
  })
}
