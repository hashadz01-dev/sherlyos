import type { DamageReportDetail } from "@/lib/damage/api"
import {
  isEditableDamageStatus,
  scenarioMaySubmitWithoutHold,
  scenarioRequiresStockHold,
  type DamageScenario,
} from "@/lib/damage/rules"

export type SubmitBlocker = {
  code:
    | "lines"
    | "evidence"
    | "isolation"
    | "custody"
    | "locked"
    | "source"
    | "validation"
  message: string
}

export type DamageMutationKind =
  | "save"
  | "submit"
  | "upload"
  | "finalize"
  | "network"
  | "custody"
  | "transfer"
  | "verify"
  | "return"
  | "reject"
  | "writeoff"

/**
 * Frontend submit gates. Isolation and custody remain backend-enforced.
 * Evidence before Submit is an operational UX policy; submit_damage_report
 * does not require photos. GM verify still does.
 */
export function collectSubmitBlockers(input: {
  scenario: DamageScenario | ""
  stockHoldReady: boolean
  linesValid: boolean
  sourceSelected: boolean
  finalizedEvidence: number
  custodyConfirmed: boolean
  status?: string
}): SubmitBlocker[] {
  const blockers: SubmitBlocker[] = []
  if (input.status && !isEditableDamageStatus(input.status as never)) {
    blockers.push({
      code: "locked",
      message:
        "This report is locked. Only draft or returned reports can be submitted.",
    })
    return blockers
  }
  if (!input.scenario) {
    blockers.push({
      code: "source",
      message: "Select a damage scenario.",
    })
  }
  if (!input.sourceSelected) {
    blockers.push({
      code: "source",
      message: "Select an authorized source for this scenario.",
    })
  }
  if (!input.linesValid) {
    blockers.push({
      code: "lines",
      message: "Correct the damage lines before submitting.",
    })
  }
  if (input.finalizedEvidence < 1) {
    blockers.push({
      code: "evidence",
      message:
        "Attach finalized photographic evidence before submitting. Godown verification also requires it.",
    })
  }
  if (
    input.scenario &&
    scenarioRequiresStockHold(input.scenario) &&
    !input.stockHoldReady
  ) {
    blockers.push({
      code: "isolation",
      message:
        "Stock isolation is not ready. Storage, loading, and shop-return reports cannot be submitted until operations enables isolation.",
    })
  }
  if (input.scenario === "shop_return" && !input.custodyConfirmed) {
    blockers.push({
      code: "custody",
      message:
        "Confirm physical custody at the receiving godown before submitting this shop-return report.",
    })
  }
  return blockers
}

export function scenarioSubmitHint(
  scenario: DamageScenario | "",
  stockHoldReady: boolean,
) {
  if (!scenario) return null
  if (scenarioMaySubmitWithoutHold(scenario)) {
    return "Inbound and transit reports may submit while stock isolation is inactive. Isolation-required scenarios stay blocked."
  }
  if (!stockHoldReady) {
    return "This scenario requires on-hand isolation. Submission stays blocked until isolation is ready."
  }
  return null
}

export function mapDamageMutationError(
  error: unknown,
  kind: DamageMutationKind = "save",
) {
  const raw =
    error instanceof Error
      ? error.message
      : typeof error === "string"
        ? error
        : ""

  if (/session has ended|jwt expired|not authenticated/i.test(raw)) {
    return "Your session has ended. Sign in again."
  }
  if (/changed by someone else|stale version|this record changed/i.test(raw)) {
    return "This record changed. Refresh and try again."
  }
  if (/damage stock isolation is not ready/i.test(raw)) {
    return "Stock isolation is not ready. This scenario cannot be submitted."
  }
  if (/shop-return damage requires confirmed physical custody/i.test(raw)) {
    return "Shop-return physical custody is not confirmed."
  }
  if (/quarantine transfer requires verified storage damage/i.test(raw)) {
    return "Only verified storage damage can be transferred to quarantine."
  }
  if (/no isolated damage quantity remains/i.test(raw)) {
    return "No isolated damage quantity remains to transfer. Refresh the report."
  }
  if (/godown is inactive/i.test(raw)) {
    return "This godown is inactive. Operational transfers are not allowed."
  }
  if (
    /duplicate key|already posted|idempotency/i.test(raw) &&
    kind === "transfer"
  ) {
    return "This quarantine transfer was already posted. Refresh the report."
  }
  if (/the reporter cannot verify this damage report/i.test(raw)) {
    return "The reporter cannot verify or reject this damage report."
  }
  if (/damage report cannot be verified/i.test(raw)) {
    return "This report cannot be verified in its current status."
  }
  if (/submitted shop-return damage cannot return to draft/i.test(raw)) {
    return "Submitted shop-return damage cannot return to draft."
  }
  if (/damage report cannot be returned/i.test(raw)) {
    return "This report cannot be returned in its current status."
  }
  if (/damage report cannot be rejected/i.test(raw)) {
    return "This report cannot be rejected in its current status."
  }
  if (/this damage report has no on-hand stock to post/i.test(raw)) {
    return "This damage report has no on-hand stock to write off."
  }
  if (/an exceptional disposition is already open/i.test(raw)) {
    return "An exceptional disposition is already open."
  }
  if (/a reason is required/i.test(raw)) {
    return "A reason is required."
  }
  if (/photographic evidence is required/i.test(raw)) {
    return "Finalized photographic evidence is required."
  }
  if (/photo content could not be verified/i.test(raw)) {
    return "The photo could not be verified. Upload did not finalize."
  }
  if (/already submitted|cannot be submitted|cannot be changed/i.test(raw)) {
    return raw
  }
  if (/failed to fetch|networkerror|load failed|aborted/i.test(raw)) {
    if (
      kind === "submit" ||
      kind === "transfer" ||
      kind === "custody" ||
      kind === "verify" ||
      kind === "return" ||
      kind === "reject" ||
      kind === "writeoff"
    ) {
      return "The request may have been received. Refresh the report before retrying."
    }
    return "The connection was interrupted. Refresh and try again."
  }
  if (!raw) {
    if (
      kind === "submit" ||
      kind === "transfer" ||
      kind === "custody" ||
      kind === "verify" ||
      kind === "return" ||
      kind === "reject" ||
      kind === "writeoff"
    ) {
      return "The request may have been received. Refresh the report before retrying."
    }
    return "The request could not be completed. Try again or ask an administrator."
  }
  return raw
}

export function reportHasFinalizedEvidence(report: DamageReportDetail | null) {
  return (report?.evidence ?? []).some((row) => row.finalized)
}

/**
 * Identify a completed ordinary write-off from the trusted report payload.
 * Used after an ambiguous mutation failure so the UI does not post again.
 */
export function reportHasCompletedOrdinaryWriteoff(
  report: DamageReportDetail | null | undefined,
) {
  if (!report) return false
  const holds = report.holds ?? []
  const remaining = holds.filter(
    (hold) => hold.status === "active" || hold.status === "transferred",
  )
  const written = holds.some((hold) => hold.status === "written_off")
  const event = (report.events ?? []).some(
    (row) => row.action === "ordinary_writeoff",
  )
  return event || (written && remaining.length === 0)
}
