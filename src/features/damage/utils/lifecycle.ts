import { damageQuantityBreakdown } from "@/features/damage/utils/quantities"
import type { DamageReportDetail } from "@/lib/damage/api"

export type DamageLifecycleStageId =
  | "draft"
  | "submitted"
  | "returned"
  | "rejected"
  | "custody_confirmed"
  | "stock_isolated"
  | "evidence_finalized"
  | "verified"
  | "ordinary_writeoff"
  | "quarantined"
  | "exceptional_requested"
  | "exceptional_approved"
  | "exceptional_posted"
  | "disposition_pending"
  | "resolved"

export type DamageLifecycleStage = {
  id: DamageLifecycleStageId
  label: string
  description: string
  applicable: boolean
  complete: boolean
  /** Persisted backend timestamp only. Null when the stage is incomplete. */
  at: string | null
}

function eventAt(
  report: DamageReportDetail,
  ...actions: string[]
): string | null {
  const match = (report.events ?? []).find((event) =>
    actions.includes(event.action),
  )
  return match?.created_at ?? null
}

/**
 * Conceptual milestones mapped from persisted report, hold, evidence, and
 * event rows. Clicking a UI action never marks a stage complete.
 */
export function damageLifecycleStages(
  report: DamageReportDetail,
): DamageLifecycleStage[] {
  const breakdown = damageQuantityBreakdown(report)
  const isShopReturn = report.scenario === "shop_return"
  const submitted =
    report.status !== "draft" && report.status !== "cancelled"
      ? true
      : Boolean(eventAt(report, "submit", "submitted"))
  const submittedAt =
    eventAt(report, "submit", "submitted") ??
    (submitted && report.status !== "draft"
      ? (report.updated_at ?? null)
      : null)
  const custodyAt = report.physical_custody_confirmed_at ?? null
  const isolated = (report.holds ?? []).length > 0
  const isolatedAt =
    eventAt(report, "isolate", "isolated", "stock_isolated") ??
    report.holds?.find((hold) => hold.created_at)?.created_at ??
    null
  const evidenceRow = (report.evidence ?? []).find((row) => row.finalized)
  const verified = report.status === "verified"
  const quarantined = breakdown.quarantinedCases > 0
  const quarantinedAt =
    eventAt(report, "quarantine_transferred") ??
    report.holds?.find(
      (hold) =>
        hold.hold_kind === "quarantine_intake" ||
        hold.location_role === "quarantine",
    )?.created_at ??
    null
  const exceptionalRows = report.exceptional_requests ?? []
  const exceptionalOpen = exceptionalRows.some((row) =>
    ["requested", "approved"].includes(row.status),
  )
  const exceptionalRequested = exceptionalRows.find(
    (row) =>
      row.status === "requested" ||
      row.status === "approved" ||
      row.status === "posted" ||
      row.status === "rejected",
  )
  const exceptionalApproved = exceptionalRows.find(
    (row) => row.status === "approved" || row.status === "posted",
  )
  const exceptionalPosted = exceptionalRows.find(
    (row) => row.status === "posted",
  )
  const remainingIsolation =
    breakdown.heldCases > 0 || breakdown.quarantinedCases > 0
  const ordinaryPostedAt = eventAt(report, "ordinary_writeoff")
  const ordinaryPosted = Boolean(ordinaryPostedAt)
  const writtenOff = breakdown.writtenOffCases > 0
  const rejected = report.status === "rejected"
  const cancelled = report.status === "cancelled"
  // Exceptional destroy also sets hold status written_off. Ordinary completion
  // is the persisted ordinary_writeoff event, not that hold status.
  const resolved =
    cancelled ||
    ((ordinaryPosted || Boolean(exceptionalPosted) || writtenOff) &&
      !remainingIsolation) ||
    (verified && !remainingIsolation && !exceptionalOpen)

  return [
    {
      id: "draft",
      label: "Draft",
      description: "Report created in the authorized godown.",
      applicable: true,
      complete: true,
      at: report.created_at,
    },
    {
      id: "submitted",
      label: "Submitted",
      description: "Report left the editable draft or returned state.",
      applicable: true,
      complete: submitted || verified || rejected,
      at: submitted || verified || rejected ? submittedAt : null,
    },
    {
      id: "returned",
      label: "Returned",
      description: "Returned for correction. The reporter can edit again.",
      applicable: report.status === "returned",
      complete: report.status === "returned",
      at:
        report.status === "returned"
          ? (eventAt(report, "returned") ??
            report.returned_at ??
            report.updated_at ??
            null)
          : null,
    },
    {
      id: "rejected",
      label: "Rejected",
      description:
        "Formal rejection. Shop-return quarantine intake is not released.",
      applicable: report.status === "rejected",
      complete: report.status === "rejected",
      at:
        report.status === "rejected"
          ? (eventAt(report, "rejected") ??
            report.rejected_at ??
            report.updated_at ??
            null)
          : null,
    },
    {
      id: "custody_confirmed",
      label: "Custody confirmed",
      description: "Physical goods confirmed present at the receiving godown.",
      applicable: isShopReturn,
      complete: Boolean(report.physical_custody_confirmed),
      at: custodyAt,
    },
    {
      id: "stock_isolated",
      label: "Stock isolated",
      description: "Trusted isolation created a hold. Not a physical move.",
      applicable: true,
      complete: isolated,
      at: isolated ? isolatedAt : null,
    },
    {
      id: "evidence_finalized",
      label: "Evidence finalized",
      description: "At least one photograph passed trusted byte verification.",
      applicable: true,
      complete: Boolean(evidenceRow),
      at: evidenceRow?.uploaded_at ?? null,
    },
    {
      id: "verified",
      label: "Verified",
      description: "Godown Manager accepted quantities and evidence.",
      applicable: true,
      complete: verified,
      at: verified
        ? (eventAt(report, "verify", "verified") ??
          report.verified_at ??
          report.updated_at ??
          null)
        : null,
    },
    {
      id: "ordinary_writeoff",
      label: "Ordinary write-off posted",
      description:
        "Trusted ledger adjustment consumed remaining isolated cases. Separate from verification.",
      applicable:
        ordinaryPosted ||
        (verified && remainingIsolation && !exceptionalOpen && !exceptionalPosted),
      complete: ordinaryPosted,
      at: ordinaryPosted ? ordinaryPostedAt : null,
    },
    {
      id: "quarantined",
      label: "Quarantined",
      description:
        "Quantity sits on a quarantine crate or a shop-return intake hold.",
      applicable: true,
      complete: quarantined,
      at: quarantined ? quarantinedAt : null,
    },
    {
      id: "exceptional_requested",
      label: "Exceptional requested",
      description:
        "A Godown Manager requested return-to-supplier or destroy. Stock is unchanged.",
      applicable: Boolean(exceptionalRequested),
      complete: Boolean(exceptionalRequested),
      at:
        exceptionalRequested?.requested_at ??
        eventAt(report, "exceptional_requested") ??
        null,
    },
    {
      id: "exceptional_approved",
      label: "Exceptional approved",
      description:
        "Admin authorized the disposition. Inventory has not been posted.",
      applicable: Boolean(exceptionalRequested),
      complete: Boolean(exceptionalApproved),
      at:
        exceptionalApproved?.decided_at ??
        eventAt(report, "exceptional_approved") ??
        null,
    },
    {
      id: "exceptional_posted",
      label: "Exceptional posted",
      description:
        "Trusted ledger posting consumed remaining isolated cases. Saleable stock is not restored. Physical destruction or supplier handover is not independently recorded.",
      applicable: Boolean(exceptionalRequested),
      complete: Boolean(exceptionalPosted),
      at:
        exceptionalPosted?.posted_at ??
        eventAt(report, "exceptional_posted") ??
        null,
    },
    {
      id: "disposition_pending",
      label: "Disposition pending",
      description: rejected
        ? "Rejected shop-return stock stays quarantined until authorized resolution."
        : ordinaryPosted
          ? "Ordinary write-off posted. Remaining isolation is shown separately."
          : exceptionalPosted
            ? "Exceptional posting completed. Remaining isolation is shown separately."
            : "Verified holds await write-off, return, or destroy posting.",
      applicable: remainingIsolation || exceptionalOpen || rejected,
      complete: remainingIsolation || exceptionalOpen,
      at:
        remainingIsolation || exceptionalOpen
          ? (report.exceptional_requests?.find((row) => row.requested_at)
              ?.requested_at ??
            quarantinedAt ??
            isolatedAt)
          : null,
    },
    {
      id: "resolved",
      label: rejected ? "Rejected" : cancelled ? "Cancelled" : "Disposed",
      description: rejected
        ? remainingIsolation
          ? "Report rejected. Quarantined quantity is still unavailable."
          : "Report rejected with no remaining isolation."
        : "Terminal resolution with no remaining active isolation.",
      applicable: true,
      complete: resolved || rejected || cancelled,
      at:
        resolved || rejected || cancelled
          ? (eventAt(report, "reject", "rejected", "cancel", "cancelled") ??
            report.updated_at ??
            null)
          : null,
    },
  ]
}

export function rejectedShopReturnStillQuarantined(
  report: Pick<DamageReportDetail, "scenario" | "status" | "holds" | "lines">,
) {
  if (report.scenario !== "shop_return" || report.status !== "rejected") {
    return false
  }
  return damageQuantityBreakdown(report).quarantinedCases > 0
}
