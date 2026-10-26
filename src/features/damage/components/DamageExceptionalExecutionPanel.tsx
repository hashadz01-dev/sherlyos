import { useEffect, useRef, useState } from "react"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { DamageDispositionEligibility } from "@/features/damage/components/DamageDispositionEligibility"
import { DamageExceptionalExecutionDialog } from "@/features/damage/components/DamageExceptionalExecutionDialog"
import { useDamageAccess } from "@/features/damage/hooks/use-damage-access"
import { formatCases, formatTimestamp } from "@/features/damage/utils/labels"
import { damageQuantityBreakdown } from "@/features/damage/utils/quantities"
import {
  mapDamageMutationError,
  reportHasCompletedExceptionalDisposition,
} from "@/features/damage/utils/submit"
import {
  postExceptionalDamageDisposition,
  type DamageReportDetail,
} from "@/lib/damage/api"
import {
  collectExceptionalExecuteBlockers,
  formatExceptionalKind,
  formatExceptionalStatus,
} from "@/lib/damage/rules"
import { notify } from "@/lib/utilities/notify"

function newPostKey() {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return `expost-${crypto.randomUUID()}`
  }
  return `expost-${Date.now()}`
}

export function DamageExceptionalExecutionPanel({
  report,
  onPosted,
}: {
  report: DamageReportDetail
  onPosted: () => void
}) {
  const access = useDamageAccess()
  const breakdown = damageQuantityBreakdown(report)
  const request = [...(report.exceptional_requests ?? [])]
    .reverse()
    .find((row) => row.status === "approved" || row.status === "posted")
  const alreadyPosted = reportHasCompletedExceptionalDisposition(
    report,
    request?.id,
  )
  const blockers = collectExceptionalExecuteBlockers({
    canVerify: access.canVerify,
    requestStatus: request?.status,
    remainingHoldCases: breakdown.remainingHoldCases,
    godownActive: report.godown_active,
  })
  const remainingHolds = (report.holds ?? []).filter(
    (hold) => hold.status === "active" || hold.status === "transferred",
  )
  const crateLabel =
    remainingHolds
      .map((hold) => hold.crate_code)
      .filter(Boolean)
      .join(", ") || report.godown_name
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [idempotencyKey, setIdempotencyKey] = useState(newPostKey)
  const pendingRecovery = useRef(false)

  useEffect(() => {
    if (!pendingRecovery.current || !alreadyPosted) return
    pendingRecovery.current = false
    notify.success("Exceptional disposition posted")
    setOpen(false)
    setError(null)
    setIdempotencyKey(newPostKey())
  }, [alreadyPosted])

  if (!access.canVerify && !access.canMonitor) return null
  if (!request) return null

  async function post() {
    if (!request) return
    setBusy(true)
    setError(null)
    try {
      await postExceptionalDamageDisposition(
        request.id,
        request.version,
        idempotencyKey,
      )
      notify.success("Exceptional disposition posted")
      setOpen(false)
      setIdempotencyKey(newPostKey())
      onPosted()
    } catch (caught) {
      pendingRecovery.current = true
      setOpen(false)
      setError(mapDamageMutationError(caught, "exceptional-post"))
      onPosted()
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="rounded-2xl bg-card p-4 ring-1 ring-border">
      <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold">Execute disposition</h2>
          <p className="text-xs text-muted-foreground">
            Preview is informational. The trusted RPC recalculates quantity and
            posts the ledger adjustment exactly once per report.
          </p>
        </div>
        <StatusBadge tone={alreadyPosted ? "success" : "info"}>
          {formatExceptionalStatus(request.status)}
        </StatusBadge>
      </div>

      <dl className="mb-3 grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-3">
        <div>
          <dt className="text-muted-foreground">Disposition</dt>
          <dd>{formatExceptionalKind(request.kind)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Approved by</dt>
          <dd>
            {request.decided_by_name
              ? `${request.decided_by_name} · ${formatTimestamp(request.decided_at)}`
              : "—"}
          </dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Remaining isolated</dt>
          <dd>{formatCases(breakdown.remainingHoldCases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Location</dt>
          <dd>{crateLabel}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Ledger reference</dt>
          <dd className="font-mono text-xs">
            {request.posted_transaction_id
              ? request.posted_transaction_id.slice(0, 8)
              : "—"}
          </dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Posted by</dt>
          <dd>
            {request.posted_by_name
              ? `${request.posted_by_name} · ${formatTimestamp(request.posted_at)}`
              : "—"}
          </dd>
        </div>
      </dl>

      <DamageDispositionEligibility
        blockers={blockers}
        emptyLabel="This approved request is eligible for trusted ledger posting."
      />

      {access.canVerify ? (
        <div className="mt-4">
          <Button
            type="button"
            disabled={blockers.length > 0 || busy}
            onClick={() => setOpen(true)}
          >
            Execute {formatExceptionalKind(request.kind).toLowerCase()}
          </Button>
        </div>
      ) : null}

      {error ? (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {error}
        </p>
      ) : null}

      <DamageExceptionalExecutionDialog
        report={report}
        request={request}
        open={open}
        busy={busy}
        eligibleCases={breakdown.remainingHoldCases}
        crateLabel={crateLabel}
        onOpenChange={setOpen}
        onConfirm={() => void post()}
      />
    </section>
  )
}
