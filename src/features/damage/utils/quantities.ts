import type { DamageHoldRow, DamageReportDetail } from "@/lib/damage/api"

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
