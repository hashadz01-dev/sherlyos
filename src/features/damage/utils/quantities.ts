import type { DamageHoldRow, DamageReportDetail } from "@/lib/damage/api"

/**
 * Inbound remaining must use receipt damaged_cases minus other open claims.
 * already_reported from list_damage_report_sources includes this draft, so
 * subtract ownQuantity to avoid double-counting while editing.
 */
export function inboundReceiptAvailability(input: {
  damagedCases: number
  alreadyReported: number
  ownQuantity: number
}) {
  const damagedCases = Math.max(0, input.damagedCases)
  const ownQuantity = Math.max(0, input.ownQuantity)
  const claimedByOthers = Math.max(0, input.alreadyReported - ownQuantity)
  return {
    damagedCases,
    claimedByOthers,
    ownQuantity,
    remaining: Math.max(0, damagedCases - claimedByOthers),
  }
}

export type DamageQuantityBreakdown = {
  reportedCases: number
  heldCases: number
  quarantinedCases: number
  reservationConvertedCases: number
  transferredCases: number
  writtenOffCases: number
  returnedSupplierCases: number
  remainingHoldCases: number
}

function sumHolds(
  holds: DamageHoldRow[] | undefined,
  predicate: (hold: DamageHoldRow) => boolean,
) {
  return (holds ?? [])
    .filter(predicate)
    .reduce((sum, hold) => sum + Number(hold.quantity_cases || 0), 0)
}

/** Distinguish reported vs held vs quarantined vs written-off carton cases. */
export function damageQuantityBreakdown(
  report: Pick<DamageReportDetail, "lines" | "holds">,
): DamageQuantityBreakdown {
  const reportedCases = (report.lines ?? []).reduce(
    (sum, line) => sum + Number(line.quantity_cases || 0),
    0,
  )
  // Logical hold: active isolation that has not moved onto a quarantine crate.
  const heldCases = sumHolds(
    report.holds,
    (hold) =>
      hold.status === "active" &&
      hold.hold_kind !== "quarantine_intake" &&
      hold.location_role !== "quarantine",
  )
  // Physical quarantine is quarantine_intake or a hold already moved onto a quarantine crate.
  const quarantinedCases = sumHolds(
    report.holds,
    (hold) =>
      (hold.status === "active" || hold.status === "transferred") &&
      (hold.hold_kind === "quarantine_intake" ||
        hold.location_role === "quarantine"),
  )
  const writtenOffCases = sumHolds(
    report.holds,
    (hold) => hold.status === "written_off",
  )
  const reservationConvertedCases = sumHolds(
    report.holds,
    (hold) =>
      hold.status === "active" && hold.hold_kind === "reservation_conversion",
  )
  const transferredCases = sumHolds(
    report.holds,
    (hold) => hold.status === "transferred",
  )
  const remainingHoldCases = sumHolds(
    report.holds,
    (hold) => hold.status === "active" || hold.status === "transferred",
  )
  const returnedSupplierCases = sumHolds(
    report.holds,
    (hold) => hold.status === "returned_supplier",
  )

  return {
    reportedCases,
    heldCases,
    quarantinedCases,
    reservationConvertedCases,
    transferredCases,
    writtenOffCases,
    returnedSupplierCases,
    remainingHoldCases,
  }
}
