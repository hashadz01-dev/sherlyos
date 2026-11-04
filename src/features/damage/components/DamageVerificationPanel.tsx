import { useState } from "react"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { DamageDecisionReasonDialog } from "@/features/damage/components/DamageDecisionReasonDialog"
import { DamageVerificationDialog } from "@/features/damage/components/DamageVerificationDialog"
import { DamageVerificationEligibility } from "@/features/damage/components/DamageVerificationEligibility"
import { useDamageAccess } from "@/features/damage/hooks/use-damage-access"
import { formatTimestamp } from "@/features/damage/utils/labels"
import { damageQuantityBreakdown } from "@/features/damage/utils/quantities"
import { mapDamageMutationError } from "@/features/damage/utils/submit"
import { useAuth } from "@/hooks/use-auth"
import {
  rejectDamageReport,
  returnDamageReport,
  verifyDamageReport,
  type DamageReportDetail,
} from "@/lib/damage/api"
import {
  collectRejectBlockers,
  collectReturnBlockers,
  collectVerificationBlockers,
} from "@/lib/damage/rules"
import { notify } from "@/lib/utilities/notify"

export function DamageVerificationPanel({
  report,
  onChanged,
}: {
  report: DamageReportDetail
  onChanged: () => void
}) {
  const access = useDamageAccess()
  const { session } = useAuth()
  const userId = session?.user.id
  const breakdown = damageQuantityBreakdown(report)
  const evidenceCount = (report.evidence ?? []).filter(
    (row) => row.finalized,
  ).length
  // Prefer header fields; fall back to the verified event for report-keeping.
  const verifiedEvent = (report.events ?? []).find(
    (row) => row.action === "verified",
  )
  const verifierName =
    report.verifier_name?.trim() ||
    verifiedEvent?.actor_name?.trim() ||
    null
  const verifiedAt = report.verified_at || verifiedEvent?.created_at || null
  const verifyInput = {
    status: report.status,
    scenario: report.scenario,
    canVerify: access.canVerify,
    isReporter: report.reporter_user_id === userId,
    hasFinalizedEvidence: evidenceCount > 0,
    reportedCases: breakdown.reportedCases,
    isolatedCases: breakdown.remainingHoldCases,
    godownActive: report.godown_active,
    custodyConfirmed: Boolean(report.physical_custody_confirmed),
  }
  const verifyBlockers = collectVerificationBlockers(verifyInput)
  const returnBlockers = collectReturnBlockers({
    status: report.status,
    scenario: report.scenario,
    canVerify: access.canVerify,
    godownActive: report.godown_active,
  })
  const rejectBlockers = collectRejectBlockers({
    status: report.status,
    canVerify: access.canVerify,
    isReporter: report.reporter_user_id === userId,
    godownActive: report.godown_active,
  })
  const [verifyOpen, setVerifyOpen] = useState(false)
  const [returnOpen, setReturnOpen] = useState(false)
  const [rejectOpen, setRejectOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [reason, setReason] = useState("")
  const [error, setError] = useState<string | null>(null)

  if (!access.canVerify && !access.canMonitor) return null

  // Terminal / non-submitted reports are read-only here. Re-showing verify
  // blockers ("Only submitted…") and decision buttons after verify/reject is noise.
  const decisionsOpen = report.status === "submitted"

  async function run(
    kind: "verify" | "return" | "reject",
    work: () => Promise<unknown>,
    success: string,
  ) {
    setBusy(true)
    setError(null)
    try {
      await work()
      notify.success(success)
      setVerifyOpen(false)
      setReturnOpen(false)
      setRejectOpen(false)
      setReason("")
      onChanged()
    } catch (caught) {
      setError(mapDamageMutationError(caught, kind))
      // Verify/return/reject are not idempotent. Refresh so a received
      // request is visible; do not retry the mutation automatically.
      onChanged()
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="rounded-2xl bg-card p-4 ring-1 ring-border">
      <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold">Godown verification</h2>
          <p className="text-xs text-muted-foreground">
            Inspection does not post stock. Custody confirmation is a separate
            milestone.
          </p>
        </div>
        <StatusBadge
          tone={
            report.status === "verified"
              ? "success"
              : report.status === "rejected"
                ? "danger"
                : report.status === "submitted"
                  ? "info"
                  : "neutral"
          }
        >
          {report.status === "verified"
            ? "Verified"
            : report.status === "rejected"
              ? "Rejected"
              : report.status === "submitted"
                ? "Awaiting verification"
                : "Not verified"}
        </StatusBadge>
      </div>

      <dl className="mb-3 grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-3">
        <div>
          <dt className="text-muted-foreground">
            {report.status === "rejected" ? "Rejected by" : "Verifier"}
          </dt>
          <dd>
            {report.status === "verified"
              ? (verifierName ?? "Verified (name unavailable)")
              : report.status === "rejected"
                ? (report.rejected_by_name ?? "Rejected (name unavailable)")
                : "Pending verification"}
          </dd>
        </div>
        <div>
          <dt className="text-muted-foreground">
            {report.status === "rejected" ? "Rejected at" : "Verified at"}
          </dt>
          <dd>
            {report.status === "verified"
              ? formatTimestamp(verifiedAt)
              : report.status === "rejected"
                ? formatTimestamp(report.rejected_at)
                : "Pending verification"}
          </dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Finalized photos</dt>
          <dd>{evidenceCount}</dd>
        </div>
      </dl>

      {report.status === "returned" && report.return_reason ? (
        <p className="mb-3 text-sm">
          Returned: {report.return_reason}
          {report.returned_by_name ? ` · ${report.returned_by_name}` : ""}
        </p>
      ) : null}
      {report.status === "rejected" && report.rejection_reason ? (
        <p className="mb-3 text-sm">
          Rejected: {report.rejection_reason}
          {report.rejected_by_name ? ` · ${report.rejected_by_name}` : ""}
        </p>
      ) : null}

      {decisionsOpen ? (
        <>
          <DamageVerificationEligibility
            blockers={verifyBlockers}
            emptyLabel="This report is eligible for Godown Manager verification."
          />

          {access.canVerify ? (
            <div className="mt-4 flex flex-wrap gap-2">
              <Button
                type="button"
                disabled={verifyBlockers.length > 0 || busy}
                onClick={() => setVerifyOpen(true)}
              >
                Verify
              </Button>
              <Button
                type="button"
                variant="outline"
                disabled={returnBlockers.length > 0 || busy}
                onClick={() => {
                  setReason("")
                  setReturnOpen(true)
                }}
              >
                Return for correction
              </Button>
              <Button
                type="button"
                variant="outline"
                disabled={rejectBlockers.length > 0 || busy}
                onClick={() => {
                  setReason("")
                  setRejectOpen(true)
                }}
              >
                Reject
              </Button>
            </div>
          ) : (
            <p className="mt-3 text-sm text-muted-foreground">
              Oversight accounts can review history but cannot verify, return, or
              reject.
            </p>
          )}

          {error ? (
            <p role="alert" className="mt-3 text-sm text-destructive">
              {error}
            </p>
          ) : null}

          <DamageVerificationDialog
            report={report}
            open={verifyOpen}
            busy={busy}
            reportedCases={breakdown.reportedCases}
            isolatedCases={breakdown.remainingHoldCases}
            evidenceCount={evidenceCount}
            onOpenChange={setVerifyOpen}
            onConfirm={() =>
              void run(
                "verify",
                () => verifyDamageReport(report.id, report.version),
                "Damage report verified",
              )
            }
          />
          <DamageDecisionReasonDialog
            title="Return for correction"
            description="The reporter can edit the returned report. Logical on-hand holds are released. Shop-return quarantine intake is not returned this way."
            confirmLabel="Return report"
            ariaLabel="Confirm return for correction"
            open={returnOpen}
            busy={busy}
            reason={reason}
            onReasonChange={setReason}
            onOpenChange={setReturnOpen}
            onConfirm={() =>
              void run(
                "return",
                () => returnDamageReport(report.id, report.version, reason),
                "Damage report returned",
              )
            }
          />
          <DamageDecisionReasonDialog
            title="Reject damage report"
            description="Rejection is a terminal report status. Shop-return quarantine intake stays unavailable until authorized disposition."
            confirmLabel="Reject report"
            ariaLabel="Confirm damage rejection"
            open={rejectOpen}
            busy={busy}
            reason={reason}
            onReasonChange={setReason}
            onOpenChange={setRejectOpen}
            onConfirm={() =>
              void run(
                "reject",
                () => rejectDamageReport(report.id, report.version, reason),
                "Damage report rejected",
              )
            }
          />
        </>
      ) : report.status === "verified" ? (
        <p className="text-sm text-muted-foreground">
          Verification is complete. No further Godown decision is available on
          this report.
        </p>
      ) : report.status === "rejected" ? (
        <p className="text-sm text-muted-foreground">
          This report was rejected. Verify, return, and reject are closed.
        </p>
      ) : null}
    </section>
  )
}
