/**
 * Planned warehouse capacity for the visual godown screens.
 * These numbers are a display target. They do not constrain stock posting.
 */

export const CASES_PER_CRATE = 50
export const TARGET_CRATES_PER_ZONE = 4
export const TARGET_ZONES_PER_GODOWN = 6
export const PLANNED_ZONE_CAPACITY = CASES_PER_CRATE * TARGET_CRATES_PER_ZONE
export const PLANNED_GODOWN_CAPACITY =
  PLANNED_ZONE_CAPACITY * TARGET_ZONES_PER_GODOWN
export const PLANNED_NORMAL_CAPACITY = PLANNED_ZONE_CAPACITY * 5
export const PLANNED_QUARANTINE_CAPACITY = PLANNED_ZONE_CAPACITY
export const CASE_GRID_COLUMNS = 10
export const CASE_GRID_ROWS = 5

export const TARGET_ZONE_KEYS = ["A", "B", "C", "D", "E", "F"] as const
export type TargetZoneKey = (typeof TARGET_ZONE_KEYS)[number]

/** Isolation holds that reduce saleable availability. Quarantine intake does not. */
export const SALEABLE_HOLD_KINDS = [
  "on_hand_deduction",
  "reservation_conversion",
] as const

export function isQuarantineRole(role: string | null | undefined) {
  return role === "quarantine"
}

export function configuredCapacity(crateCount: number) {
  return Math.max(0, crateCount) * CASES_PER_CRATE
}

/**
 * Stored target from crates.capacity_cases.
 * A missing value keeps the 50-case plan. Stock above the target stays valid.
 */
export function crateCapacityCases(crate: { capacity_cases?: number | null } | null | undefined) {
  const value = crate?.capacity_cases
  if (value == null || !Number.isFinite(value) || value < 1) return CASES_PER_CRATE
  return value
}

export function configuredCapacityFromCrates(
  crates: { capacity_cases?: number | null }[],
) {
  return crates.reduce((sum, crate) => sum + crateCapacityCases(crate), 0)
}

export function occupancyRatio(onHand: number, capacity: number) {
  if (capacity <= 0) return null
  return onHand / capacity
}

export function freePhysicalCapacity(onHand: number, capacity: number) {
  if (capacity <= 0) return null
  return Math.max(0, capacity - onHand)
}

export function overCapacityCases(onHand: number, capacity: number) {
  if (capacity <= 0) return 0
  return Math.max(0, onHand - capacity)
}

/**
 * Available-to-pick is saleable on-hand minus visible reservations and
 * saleable isolation holds. Quarantine on-hand is excluded from saleableOnHand
 * by the caller, so it is not subtracted again.
 */
export function availableToPick(input: {
  saleableOnHand: number
  visibleReserved: number
  visibleSaleableHolds: number
}) {
  return Math.max(
    0,
    input.saleableOnHand -
      Math.max(0, input.visibleReserved) -
      Math.max(0, input.visibleSaleableHolds),
  )
}

export function formatCases(value: number | null) {
  if (value === null) return "—"
  return `${value.toLocaleString("en-IN")} cases`
}

export function formatPercent(ratio: number | null) {
  if (ratio === null) return "—"
  return `${Math.round(ratio * 100)}%`
}

export type CapacitySlice = {
  sku: string
  productName: string
  lotId: string | null
  lotCode: string | null
  expiryDate: string | null
  quantity: number
}

export type VisualSlotStatus =
  | "available"
  | "occupied"
  | "reserved"
  | "quarantined"
  | "unavailable"

export type VisualSlot = {
  position: number
  label: string
  status: VisualSlotStatus
  slice: CapacitySlice | null
}

function slotLabel(position: number) {
  return String(position).padStart(2, "0")
}

function compareSlices(left: CapacitySlice, right: CapacitySlice) {
  const sku = left.sku.localeCompare(right.sku)
  if (sku !== 0) return sku
  return (left.lotId ?? "").localeCompare(right.lotId ?? "")
}

/**
 * Fill slots 1–50 in a stable product/lot order.
 * Positions are a capacity picture. They are not stored case identities.
 */
export function visualizeCaseSlots(input: {
  inactive: boolean
  quarantine: boolean
  onHand: number
  visibleReserved: number
  slices: CapacitySlice[]
}) {
  const slots: VisualSlot[] = []
  const onHand = Math.max(0, input.onHand)
  const occupiedCount = Math.min(CASES_PER_CRATE, onHand)
  const slices = [...input.slices]
    .filter((slice) => slice.quantity > 0)
    .sort(compareSlices)
  const sliceTotal = slices.reduce((sum, slice) => sum + slice.quantity, 0)
  const canAssign = sliceTotal === onHand && onHand > 0
  const queue: CapacitySlice[] = []
  if (canAssign) {
    for (const slice of slices) {
      for (let index = 0; index < slice.quantity; index += 1) {
        queue.push(slice)
      }
    }
  }
  const reservedMarks = input.quarantine
    ? 0
    : Math.min(Math.max(0, input.visibleReserved), occupiedCount)

  for (let position = 1; position <= CASES_PER_CRATE; position += 1) {
    if (input.inactive) {
      slots.push({
        position,
        label: slotLabel(position),
        status: "unavailable",
        slice: null,
      })
      continue
    }
    if (position > occupiedCount) {
      slots.push({
        position,
        label: slotLabel(position),
        status: "available",
        slice: null,
      })
      continue
    }
    const reserved = position > occupiedCount - reservedMarks
    slots.push({
      position,
      label: slotLabel(position),
      status: reserved
        ? "reserved"
        : input.quarantine
          ? "quarantined"
          : "occupied",
      slice: canAssign ? (queue[position - 1] ?? null) : null,
    })
  }

  return {
    slots,
    overflow: Math.max(0, onHand - CASES_PER_CRATE),
    assigned: canAssign,
  }
}
