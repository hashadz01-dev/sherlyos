/**
 * M7.2 ATP snapshot helpers. Verification reads picking-eligible cases;
 * it does not reserve. Gross on-hand is informational only.
 */

export type AvailabilityLine = {
  product_id: string
  requested_cases: number
  on_hand_cases: number
  eligible_cases: number
  shortfall_cases: number
  eligible: boolean
  blockers: string[]
}

export type AvailabilitySnapshot = {
  reserves_stock: boolean
  picking_operational: boolean
  cutover_blockers: string[]
  lines: AvailabilityLine[]
}

export type OpenDeliveryNoteSummary = {
  id: string
  delivery_note_number: string
  status: string
  version: number
  acknowledged_at: string | null
  acknowledged_by: string | null
}

const emptySnapshot = (): AvailabilitySnapshot => ({
  reserves_stock: false,
  picking_operational: false,
  cutover_blockers: [],
  lines: [],
})

function asLine(raw: Record<string, unknown>): AvailabilityLine {
  const blockersRaw = raw.blockers
  const blockers = Array.isArray(blockersRaw)
    ? blockersRaw.map((item) => String(item))
    : []
  return {
    product_id: String(raw.product_id ?? ""),
    requested_cases: Number(raw.requested_cases ?? 0),
    on_hand_cases: Number(raw.on_hand_cases ?? 0),
    eligible_cases: Number(raw.eligible_cases ?? 0),
    shortfall_cases: Number(raw.shortfall_cases ?? 0),
    eligible: raw.eligible === true,
    blockers,
  }
}

/**
 * Accept the M7.2 snapshot object, a bare line array (legacy details payload),
 * or a truncated verify error details array.
 */
export function parseAvailabilitySnapshot(raw: unknown): AvailabilitySnapshot {
  if (!raw) return emptySnapshot()
  if (Array.isArray(raw)) {
    return {
      ...emptySnapshot(),
      lines: raw.map((row) => asLine((row ?? {}) as Record<string, unknown>)),
    }
  }
  if (typeof raw !== "object") return emptySnapshot()
  const record = raw as Record<string, unknown>
  const linesRaw = Array.isArray(record.lines) ? record.lines : []
  const cutover = Array.isArray(record.cutover_blockers)
    ? record.cutover_blockers.map((item) => String(item))
    : []
  return {
    reserves_stock: record.reserves_stock === true,
    picking_operational: record.picking_operational === true,
    cutover_blockers: cutover,
    lines: linesRaw.map((row) => asLine((row ?? {}) as Record<string, unknown>)),
  }
}

export function shortageLinesFromErrorDetails(details: string | undefined): AvailabilityLine[] {
  if (!details) return []
  try {
    return parseAvailabilitySnapshot(JSON.parse(details)).lines.filter(
      (line) => line.shortfall_cases > 0 || !line.eligible,
    )
  } catch {
    return []
  }
}

export function isAcknowledgedDeliveryNote(note: OpenDeliveryNoteSummary | null | undefined) {
  return note?.status === "acknowledged"
}

export function deliveryNoteHandoverLabel(status: string | null | undefined) {
  switch (status) {
    case "draft":
      return "Draft — not yet generated"
    case "generated":
      return "Generated — not yet sent to godown"
    case "sent":
      return "Sent — waiting for Godown Manager acknowledgement"
    case "acknowledged":
      return "Acknowledged — picking may start when other gates pass"
    case "voided":
      return "Voided"
    default:
      return "No delivery note yet"
  }
}
