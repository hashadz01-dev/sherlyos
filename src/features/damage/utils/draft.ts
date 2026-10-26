import type { DamageReportLineInput, DamageSourceItem } from "@/lib/damage/api"
import type { DamageScenario } from "@/lib/damage/rules"

export type DraftLine = {
  key: string
  product_id: string
  product_sku: string
  product_name: string
  quantity_cases: string
  damage_reason: string
  crate_id: string
  crate_code: string
  lot_id: string
  notes: string
  receipt_line_id: string
}

export type SourceRefs = {
  receiptId: string | null
  pickingRequestId: string | null
  dispatchId: string | null
  orderId: string | null
  shopId: string | null
}

const CREATE_KEY_PREFIX = "sherlyos.damage.create-key."
const SUBMIT_KEY_PREFIX = "sherlyos.damage.submit-key."

function durableStore() {
  try {
    return window.localStorage
  } catch {
    return null
  }
}

/** Positive whole carton cases. Fractional or zero values are invalid. */
export function parseCartonQuantity(value: string | number) {
  if (typeof value === "number") {
    if (!Number.isInteger(value) || value < 1) return null
    return value
  }
  const trimmed = value.trim()
  if (!/^[1-9]\d*$/.test(trimmed)) return null
  const parsed = Number(trimmed)
  if (!Number.isSafeInteger(parsed) || parsed < 1) return null
  return parsed
}

export function lineGrain(
  line: Pick<
    DraftLine,
    "product_id" | "crate_id" | "lot_id" | "receipt_line_id"
  >,
) {
  return [
    line.product_id,
    line.crate_id || "",
    line.lot_id || "",
    line.receipt_line_id || "",
  ].join("|")
}

export function emptyDraftLine(): DraftLine {
  return {
    key: crypto.randomUUID(),
    product_id: "",
    product_sku: "",
    product_name: "",
    quantity_cases: "1",
    damage_reason: "",
    crate_id: "",
    crate_code: "",
    lot_id: "",
    notes: "",
    receipt_line_id: "",
  }
}

export function emptySourceRefs(): SourceRefs {
  return {
    receiptId: null,
    pickingRequestId: null,
    dispatchId: null,
    orderId: null,
    shopId: null,
  }
}

/**
 * Map a picker row onto the exact source columns validate_damage_sources
 * accepts. Extra document ids from the catalog (order, picking on transit)
 * must not be posted.
 */
export function sourceRefsForScenario(
  scenario: DamageScenario,
  item: Pick<
    DamageSourceItem,
    | "id"
    | "receipt_id"
    | "picking_request_id"
    | "dispatch_id"
    | "order_id"
    | "shop_id"
  >,
): SourceRefs {
  const empty = emptySourceRefs()
  if (scenario === "refill_supply" || scenario === "unloading") {
    return { ...empty, receiptId: item.receipt_id ?? item.id }
  }
  if (scenario === "storage") {
    return empty
  }
  if (scenario === "loading") {
    return {
      ...empty,
      pickingRequestId: item.picking_request_id ?? item.id,
      dispatchId: item.dispatch_id ?? null,
    }
  }
  if (scenario === "transit") {
    return { ...empty, dispatchId: item.dispatch_id ?? item.id }
  }
  return {
    ...empty,
    shopId: item.shop_id ?? item.id,
    orderId: item.order_id ?? null,
  }
}

/**
 * Client-side line checks that match replace_damage_lines constraints.
 * The RPC remains the source of truth.
 */
export function validateDraftLines(
  scenario: DamageScenario | "",
  lines: DraftLine[],
) {
  const errors: string[] = []
  if (lines.length < 1) {
    errors.push("Add at least one damage line.")
    return errors
  }

  const grains = new Map<string, number>()
  lines.forEach((line, index) => {
    const label = `Line ${index + 1}`
    if (!line.product_id) errors.push(`${label}: select a product.`)
    const qty = parseCartonQuantity(line.quantity_cases)
    if (qty === null) {
      errors.push(`${label}: quantity must be a whole number of carton cases.`)
    }
    const reason = line.damage_reason.trim()
    if (reason.length < 1 || reason.length > 80) {
      errors.push(`${label}: damage reason is required (1–80 characters).`)
    }
    if (
      (scenario === "refill_supply" || scenario === "unloading") &&
      !line.receipt_line_id
    ) {
      errors.push(`${label}: inbound damage requires a receipt line.`)
    }
    if ((scenario === "storage" || scenario === "loading") && !line.crate_id) {
      errors.push(`${label}: a crate in this godown is required.`)
    }
    const grain = lineGrain(line)
    if (line.product_id && grains.has(grain)) {
      errors.push(`${label}: duplicate product/crate/lot/receipt combination.`)
    } else if (line.product_id) {
      grains.set(grain, index)
    }
  })
  return errors
}

export function toReportLineInputs(
  lines: DraftLine[],
): DamageReportLineInput[] {
  return lines.map((line) => ({
    product_id: line.product_id,
    quantity_cases: parseCartonQuantity(line.quantity_cases) ?? 0,
    damage_reason: line.damage_reason.trim(),
    crate_id: line.crate_id || null,
    lot_id: line.lot_id || null,
    notes: line.notes.trim() || null,
    receipt_line_id: line.receipt_line_id || null,
  }))
}

export function totalDraftCases(lines: DraftLine[]) {
  return lines.reduce((sum, line) => {
    const qty = parseCartonQuantity(line.quantity_cases)
    return sum + (qty ?? 0)
  }, 0)
}

/**
 * Durable create key so refresh and extra tabs replay the same RPC key.
 * Backend idempotency_key + fingerprint remain authoritative.
 */
export function createIdempotencyKey(userId?: string) {
  const store = durableStore()
  const storageKey = `${CREATE_KEY_PREFIX}${userId || "anon"}`
  const existing = store?.getItem(storageKey)
  if (existing) return existing
  const next = crypto.randomUUID()
  store?.setItem(storageKey, next)
  return next
}

export function clearCreateIdempotencyKey(userId?: string) {
  durableStore()?.removeItem(`${CREATE_KEY_PREFIX}${userId || "anon"}`)
}

export function submitIdempotencyKey(reportId: string) {
  const store = durableStore()
  const storageKey = `${SUBMIT_KEY_PREFIX}${reportId}`
  const existing = store?.getItem(storageKey)
  if (existing) return existing
  const next = crypto.randomUUID()
  store?.setItem(storageKey, next)
  return next
}
