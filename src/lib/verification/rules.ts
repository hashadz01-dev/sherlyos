export const verificationStatuses = [
  "draft",
  "counting",
  "submitted",
  "recount",
  "review",
  "closed",
] as const

export type VerificationStatus = (typeof verificationStatuses)[number]

export const closureResults = [
  "matched",
  "variance_recorded",
  "correction_requested",
] as const

export type ClosureResult = (typeof closureResults)[number]

export const photoUploadStatuses = [
  "idle",
  "selected",
  "uploading",
  "attached",
  "error",
] as const

export type PhotoUploadStatus = (typeof photoUploadStatuses)[number]

const maxCases = 1_000_000

export function parseCaseCount(value: string) {
  const trimmed = value.trim()
  if (!/^\d+$/.test(trimmed) || trimmed.length > 7 || Number(trimmed) > maxCases) {
    return {
      ok: false as const,
      message: "quantity must be a whole number of carton cases",
    }
  }
  return { ok: true as const, cases: Number(trimmed) }
}

export function countStatus(line: {
  countedCases: number | null
  recountCases: number | null
  recountRequested: boolean
}) {
  if (line.countedCases === null) return "uncounted"
  if (line.recountRequested) return "recount requested"
  if (line.recountCases !== null) return "recounted"
  return "counted"
}

export function reconciledExpected(expectedCases: number, movementCases: number) {
  return expectedCases + movementCases
}

export function finalVariance(physicalCases: number | null, reconciledCases: number) {
  if (physicalCases === null) return null
  return physicalCases - reconciledCases
}

export function recountRequired(varianceCases: number | null, recountCases: number | null) {
  return varianceCases !== null && varianceCases !== 0 && recountCases === null
}

export function sameIdSet(left: string[], right: string[]) {
  if (left.length !== right.length) return false
  const pending = [...right]
  return left.every((id) => {
    const index = pending.indexOf(id)
    if (index < 0) return false
    pending.splice(index, 1)
    return true
  })
}

export function verificationActions(input: {
  canVerify: boolean
  canCount: boolean
  canReport: boolean
  status: VerificationStatus
}) {
  const open = input.status !== "closed"
  const reviewing =
    input.status === "submitted" || input.status === "recount" || input.status === "review"
  return {
    canStart: input.canVerify,
    canSaveCount: (input.canVerify || input.canCount) && open,
    canSubmit: input.canVerify && input.status === "counting",
    canReport: input.canVerify && input.canReport && reviewing,
    canRequestRecount: input.canVerify && reviewing,
    canSaveRecount: (input.canVerify || input.canCount) && input.status === "recount",
    canReview: input.canVerify && reviewing,
    canReviewInactive: input.canVerify && open,
    canUpload: (input.canVerify || input.canCount) && open,
    canClose: input.canVerify && reviewing,
    readOnly: !input.canVerify && !input.canCount,
  }
}

export function canCloseVerification(input: {
  canVerify: boolean
  status: VerificationStatus
  blockers: string[]
}) {
  return verificationActions({
    canVerify: input.canVerify,
    canCount: false,
    canReport: false,
    status: input.status,
  }).canClose && input.blockers.length === 0
}

export function suggestedClosureResult(varianceCount: number): ClosureResult {
  return varianceCount === 0 ? "matched" : "variance_recorded"
}

export function startVerificationIssues(input: {
  godownId: string
  businessDate: string
  zoneIds: string[]
  crateIds: string[]
}) {
  const issues: string[] = []
  if (!input.godownId) issues.push("Select a godown.")
  if (!/^\d{4}-\d{2}-\d{2}$/.test(input.businessDate)) issues.push("Enter a business date.")
  if (input.zoneIds.length === 0) issues.push("Select at least one zone.")
  if (input.crateIds.length === 0) issues.push("Select at least one crate.")
  return issues
}

export function scopeSelectionReady(input: {
  zoneIds: string[]
  crateIds: string[]
  crates: { id: string; zone_id: string }[]
}) {
  if (input.zoneIds.length === 0 || input.crateIds.length === 0) return false
  const zones = new Set(input.zoneIds)
  const selected = input.crates.filter((crate) => input.crateIds.includes(crate.id))
  if (selected.length !== input.crateIds.length) return false
  if (selected.some((crate) => !zones.has(crate.zone_id))) return false
  return input.zoneIds.every((zoneId) => selected.some((crate) => crate.zone_id === zoneId))
}

export type PhotoUploadState = {
  status: PhotoUploadStatus
  message: string | null
}

export function photoUploadTransition(
  state: PhotoUploadState,
  event:
    | { type: "select" }
    | { type: "invalid"; message: string }
    | { type: "start" }
    | { type: "fail"; message: string }
    | { type: "finish" }
    | { type: "reset" },
): PhotoUploadState {
  if (event.type === "reset") return { status: "idle", message: null }
  if (event.type === "select") return { status: "selected", message: null }
  if (event.type === "invalid" || event.type === "fail") {
    return { status: "error", message: event.message }
  }
  if (event.type === "start") {
    if (state.status === "error") return state
    return { status: "uploading", message: "Uploading photo" }
  }
  if (state.status !== "uploading") return state
  return { status: "attached", message: null }
}

export function evidenceSatisfiesClosure(evidence: { verifiedAt: string | null }[]) {
  return evidence.some((item) => item.verifiedAt !== null)
}

export function verificationErrorMessage(error: unknown) {
  if (error instanceof Error && error.message.trim()) return error.message
  return "The verification could not be saved."
}
