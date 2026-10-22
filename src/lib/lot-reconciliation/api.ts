import { loadRows } from "@/lib/masters/api"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
import type {
  ExpiryPolicy,
  LotCondition,
  LotEvidenceRpc,
  LotReconciliationStatus,
} from "@/lib/lot-reconciliation/rules"

export class LotReconciliationRpcError extends Error {
  readonly code: string

  constructor(message: string, code = "") {
    super(message)
    this.name = "LotReconciliationRpcError"
    this.code = code
  }
}

export type LotReconciliationListRpc = {
  id: string
  session_number: string
  godown_id: string
  status: LotReconciliationStatus
  version: number
  created_at: string
  submitted_at: string | null
  unmatched_lines: number
}

/** List RPC fields plus RLS-backed display enrichment. Names are not invented on the RPC. */
export type LotReconciliationListRow = LotReconciliationListRpc & {
  godown_name: string
  crate_count: number
  created_by: string | null
  updated_at: string | null
}

export type LotReconciliationCrate = {
  crate_id: string
  crate_code: string
  crate_name: string | null
  zone_id: string
  zone_code: string
  holds_scope: boolean
}

export type LotReconciliationLot = {
  id: string
  manufacturer_lot_code: string | null
  expiry_date: string | null
  expiry_unknown: boolean
  identity_unknown: boolean
  quantity: number
  condition: LotCondition
}

export type LotReconciliationLine = {
  id: string
  crate_id: string
  product_id: string
  sku: string
  product_name: string
  expiry_policy: ExpiryPolicy
  expected_quantity: number
  counted_quantity: number | null
  is_found_product: boolean
  counted_by: string | null
  counted_at: string | null
  lots: LotReconciliationLot[]
}

export type LotReconciliationEvent = {
  id: string
  event_type: string
  actor_id: string | null
  from_status: string | null
  to_status: string | null
  session_version: number
  payload: Record<string, unknown> | null
  created_at: string
}

export type LotReconciliationDiscrepancy = {
  uncounted_lines: number
  unmatched_lines: number
  found_product_lines: number
  unidentified_cases: number
  unclassified_products: number
}

export type LotReconciliationDetail = {
  id: string
  session_number: string
  godown_id: string
  status: LotReconciliationStatus
  version: number
  notes: string | null
  created_by: string | null
  submitted_by: string | null
  submitted_at: string | null
  reviewed_by: string | null
  reviewed_at: string | null
  rejection_reason: string | null
  review_notes: string | null
  cancelled_by: string | null
  cancelled_at: string | null
  cancellation_reason: string | null
  expected_frozen_at: string | null
  created_at: string
  updated_at: string
  discrepancy: LotReconciliationDiscrepancy
  crates: LotReconciliationCrate[]
  lines: LotReconciliationLine[]
  events: LotReconciliationEvent[]
}

export const lotReconciliationKeys = {
  list: ["lot-reconciliations"] as const,
  detail: (id: string) => ["lot-reconciliation", id] as const,
}

/**
 * Preserve PostgREST `code` so PT409 can be distinguished from other failures.
 * Shared `callRpc` only throws `Error(message)`.
 */
async function reconRpc<T>(name: string, args: Record<string, unknown>) {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) {
    throw new LotReconciliationRpcError("Supabase is not configured.", "PGRST000")
  }
  const result = await supabase.rpc(name, args)
  if (result.error) {
    throw new LotReconciliationRpcError(result.error.message, result.error.code)
  }
  return result.data as T
}

function asList(data: unknown): LotReconciliationListRpc[] {
  return Array.isArray(data) ? (data as LotReconciliationListRpc[]) : []
}

function asDetail(data: unknown): LotReconciliationDetail {
  const payload = data as LotReconciliationDetail
  return {
    ...payload,
    crates: payload.crates ?? [],
    lines: (payload.lines ?? []).map((line) => ({ ...line, lots: line.lots ?? [] })),
    events: payload.events ?? [],
    discrepancy: payload.discrepancy ?? {
      uncounted_lines: 0,
      unmatched_lines: 0,
      found_product_lines: 0,
      unidentified_cases: 0,
      unclassified_products: 0,
    },
  }
}

/**
 * The list RPC is the authorization boundary. Extra SELECT is display-only for
 * IDs already returned, using RLS on tables the client may read but not write.
 */
async function enrichList(rows: LotReconciliationListRpc[]): Promise<LotReconciliationListRow[]> {
  if (rows.length === 0) return []

  const godownNames = new Map<string, string>()
  const crateCounts = new Map<string, number>()
  const headers = new Map<string, { created_by: string | null; updated_at: string | null }>()
  const supabase = getSupabaseBrowserClient()

  try {
    const branches = await loadRows<{ id: string; code: string; name: string }>(
      "branches",
      "id, code, name",
      "name",
    )
    for (const branch of branches) {
      godownNames.set(branch.id, `${branch.name} (${branch.code})`)
    }
  } catch {
    // List remains usable without names.
  }

  if (supabase) {
    const ids = rows.map((row) => row.id)
    const scopes = await supabase
      .from("stock_lot_reconciliation_scope_crates")
      .select("session_id")
      .in("session_id", ids)
    if (!scopes.error) {
      for (const row of scopes.data ?? []) {
        const sessionId = (row as { session_id: string }).session_id
        crateCounts.set(sessionId, (crateCounts.get(sessionId) ?? 0) + 1)
      }
    }
    const sessions = await supabase
      .from("stock_lot_reconciliations")
      .select("id, created_by, updated_at")
      .in("id", ids)
    if (!sessions.error) {
      for (const row of (sessions.data ?? []) as {
        id: string
        created_by: string | null
        updated_at: string | null
      }[]) {
        headers.set(row.id, { created_by: row.created_by, updated_at: row.updated_at })
      }
    }
  }

  return rows.map((row) => ({
    ...row,
    godown_name: godownNames.get(row.godown_id) ?? row.godown_id,
    crate_count: crateCounts.get(row.id) ?? 0,
    created_by: headers.get(row.id)?.created_by ?? null,
    updated_at: headers.get(row.id)?.updated_at ?? null,
  }))
}

export async function listLotReconciliations() {
  const rows = asList(await reconRpc<unknown>("list_lot_reconciliations", {}))
  return enrichList(rows)
}

export async function getLotReconciliation(sessionId: string) {
  return asDetail(await reconRpc<unknown>("get_lot_reconciliation", { target_session: sessionId }))
}

export async function createLotReconciliation(input: {
  target_godown: string
  crate_ids: string[]
  idempotency_key: string
  session_notes?: string | null
}) {
  return asDetail(
    await reconRpc<unknown>("create_lot_reconciliation", {
      target_godown: input.target_godown,
      crate_ids: input.crate_ids,
      idempotency_key: input.idempotency_key,
      session_notes: input.session_notes ?? null,
    }),
  )
}

export async function saveLotReconciliationCount(input: {
  target_session: string
  expected_version: number
  target_crate: string
  target_product: string
  counted_quantity: number
}) {
  return asDetail(
    await reconRpc<unknown>("save_lot_reconciliation_count", {
      target_session: input.target_session,
      expected_version: input.expected_version,
      target_crate: input.target_crate,
      target_product: input.target_product,
      counted_quantity: input.counted_quantity,
    }),
  )
}

export async function saveLotReconciliationLots(input: {
  target_session: string
  expected_version: number
  target_line: string
  lots: LotEvidenceRpc[]
}) {
  return asDetail(
    await reconRpc<unknown>("save_lot_reconciliation_lots", {
      target_session: input.target_session,
      expected_version: input.expected_version,
      target_line: input.target_line,
      lots: input.lots,
    }),
  )
}

export async function addLotReconciliationFoundProduct(input: {
  target_session: string
  expected_version: number
  target_crate: string
  target_product: string
}) {
  return asDetail(
    await reconRpc<unknown>("add_lot_reconciliation_found_product", {
      target_session: input.target_session,
      expected_version: input.expected_version,
      target_crate: input.target_crate,
      target_product: input.target_product,
    }),
  )
}

export async function refreshLotReconciliationExpected(input: {
  target_session: string
  expected_version: number
}) {
  return asDetail(
    await reconRpc<unknown>("refresh_lot_reconciliation_expected", {
      target_session: input.target_session,
      expected_version: input.expected_version,
    }),
  )
}

export async function submitLotReconciliation(input: {
  target_session: string
  expected_version: number
  idempotency_key: string
}) {
  return asDetail(
    await reconRpc<unknown>("submit_lot_reconciliation", {
      target_session: input.target_session,
      expected_version: input.expected_version,
      idempotency_key: input.idempotency_key,
    }),
  )
}

export async function approveLotReconciliation(input: {
  target_session: string
  expected_version: number
  review_notes?: string | null
  idempotency_key: string
}) {
  return asDetail(
    await reconRpc<unknown>("approve_lot_reconciliation", {
      target_session: input.target_session,
      expected_version: input.expected_version,
      review_notes: input.review_notes ?? null,
      idempotency_key: input.idempotency_key,
    }),
  )
}

export async function rejectLotReconciliation(input: {
  target_session: string
  expected_version: number
  reject_reason: string
  idempotency_key: string
}) {
  return asDetail(
    await reconRpc<unknown>("reject_lot_reconciliation", {
      target_session: input.target_session,
      expected_version: input.expected_version,
      reject_reason: input.reject_reason,
      idempotency_key: input.idempotency_key,
    }),
  )
}

export async function reopenLotReconciliation(input: {
  target_session: string
  expected_version: number
  idempotency_key: string
}) {
  return asDetail(
    await reconRpc<unknown>("reopen_lot_reconciliation", {
      target_session: input.target_session,
      expected_version: input.expected_version,
      idempotency_key: input.idempotency_key,
    }),
  )
}

export async function cancelLotReconciliation(input: {
  target_session: string
  expected_version: number
  cancel_reason: string
  idempotency_key: string
}) {
  return asDetail(
    await reconRpc<unknown>("cancel_lot_reconciliation", {
      target_session: input.target_session,
      expected_version: input.expected_version,
      cancel_reason: input.cancel_reason,
      idempotency_key: input.idempotency_key,
    }),
  )
}
