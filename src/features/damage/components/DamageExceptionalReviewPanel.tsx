import { useState } from "react"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { DamageDispositionEligibility } from "@/features/damage/components/DamageDispositionEligibility"
import { DamageExceptionalApprovalDialog } from "@/features/damage/components/DamageExceptionalApprovalDialog"
import { DamageExceptionalRejectionDialog } from "@/features/damage/components/DamageExceptionalRejectionDialog"
import { useDamageAccess } from "@/features/damage/hooks/use-damage-access"
import { formatCases, formatTimestamp } from "@/features/damage/utils/labels"
import { damageQuantityBreakdown } from "@/features/damage/utils/quantities"
import { mapDamageMutationError } from "@/features/damage/utils/submit"
import {
  approveExceptionalDamageDisposition,
  rejectExceptionalDamageDisposition,
  type DamageReportDetail,
} from "@/lib/damage/api"
import {
  collectExceptionalApproveBlockers,
  collectExceptionalRejectBlockers,
  formatExceptionalKind,
  formatExceptionalStatus,
} from "@/lib/damage/rules"
import { notify } from "@/lib/utilities/notify"

export function DamageExceptionalReviewPanel({
  report,
  onChanged,
}: {
  report: DamageReportDetail
  onChanged: () => void
}) {
  const access = useDamageAccess()
  const breakdown = damageQuantityBreakdown(report)
  const latest = [...(report.exceptional_requests ?? [])].at(-1)
  const approveBlockers = collectExceptionalApproveBlockers({
    canDispose: access.canDispose,
    requestStatus: latest?.status,
  })
  const rejectBlockers = collectExceptionalRejectBlockers({
    canDispose: access.canDispose,
    requestStatus: latest?.status,
  })
  const [approveOpen, setApproveOpen] = useState(false)
  const [rejectOpen, setRejectOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [reason, setReason] = useState("")
  const [error, setError] = useState<string | null>(null)

  if (!access.canDispose && !access.canMonitor) return null
  if (!latest) return null

  async function run(
    kind: "exceptional-approve" | "exceptional-reject",
    work: () => Promise<unknown>,
    success: string,
  ) {
    setBusy(true)
    setError(null)
    try {
      await work()
      notify.success(success)
      setApproveOpen(false)
      setRejectOpen(false)
      setReason("")
      onChanged()
    } catch (caught) {
      setError(mapDamageMutationError(caught, kind))
      onChanged()
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="rounded-2xl bg-card p-4 ring-1 ring-border">
      <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold">Admin review</h2>
          <p className="text-xs text-muted-foreground">
            Approval authorizes execution. It does not post stock.
          </p>
        </div>
        <StatusBadge
          tone={
            latest.status === "posted"
              ? "success"
              : latest.status === "approved"
                ? "info"
                : latest.status === "rejected"
                  ? "danger"
                  : "warning"
          }
        >
          {formatExceptionalStatus(latest.status)}
        </StatusBadge>
      </div>

      <dl className="mb-3 grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-3">
        <div>
          <dt className="text-muted-foreground">Disposition</dt>
          <dd>{formatExceptionalKind(latest.kind)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Requested by</dt>
          <dd>{latest.requested_by_name ?? "—"}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Requested at</dt>
          <dd>{formatTimestamp(latest.requested_at)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Remaining isolated</dt>
          <dd>{formatCases(breakdown.remainingHoldCases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Decision</dt>
          <dd>
            {latest.decided_by_name
              ? `${latest.decided_by_name} · ${formatTimestamp(latest.decided_at)}`
              : "—"}
          </dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Request reason</dt>
          <dd>{latest.request_reason ?? "—"}</dd>
        </div>
      </dl>

      {latest.decision_reason ? (
        <p className="mb-3 text-sm">Rejection: {latest.decision_reason}</p>
      ) : null}

      <DamageDispositionEligibility
        blockers={approveBlockers}
        emptyLabel="This request is eligible for Admin approval."
      />

      {access.canDispose ? (
        <div className="mt-4 flex flex-wrap gap-2">
          <Button
            type="button"
            disabled={approveBlockers.length > 0 || busy}
            onClick={() => setApproveOpen(true)}
          >
            Approve
          </Button>
          <Button
            type="button"
            variant="outline"
            disabled={rejectBlockers.length > 0 || busy}
            onClick={() => setRejectOpen(true)}
          >
            Reject
          </Button>
        </div>
      ) : null}

      {error ? (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {error}
        </p>
      ) : null}

      <DamageExceptionalApprovalDialog
        report={report}
        request={latest}
        open={approveOpen}
        busy={busy}
        eligibleCases={breakdown.remainingHoldCases}
        onOpenChange={setApproveOpen}
        onConfirm={() =>
          void run(
            "exceptional-approve",
            () =>
              approveExceptionalDamageDisposition(latest.id, latest.version),
            "Exceptional request approved",
          )
        }
      />
      <DamageExceptionalRejectionDialog
        open={rejectOpen}
        busy={busy}
        reason={reason}
        onReasonChange={setReason}
        onOpenChange={setRejectOpen}
        onConfirm={() =>
          void run(
            "exceptional-reject",
            () =>
              rejectExceptionalDamageDisposition(
                latest.id,
                latest.version,
                reason,
              ),
            "Exceptional request rejected",
          )
        }
      />
    </section>
  )
}
