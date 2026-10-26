import { useEffect, useRef, useState } from "react"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { DamageDispositionEligibility } from "@/features/damage/components/DamageDispositionEligibility"
import { DamageExceptionalRequestDialog } from "@/features/damage/components/DamageExceptionalRequestDialog"
import { useDamageAccess } from "@/features/damage/hooks/use-damage-access"
import { formatCases } from "@/features/damage/utils/labels"
import { damageQuantityBreakdown } from "@/features/damage/utils/quantities"
import {
  mapDamageMutationError,
  reportHasCompletedOrdinaryWriteoff,
} from "@/features/damage/utils/submit"
import {
  requestExceptionalDamageDisposition,
  type DamageReportDetail,
} from "@/lib/damage/api"
import {
  collectExceptionalRequestBlockers,
  formatExceptionalKind,
  formatExceptionalStatus,
  type ExceptionalDispositionKind,
} from "@/lib/damage/rules"
import { notify } from "@/lib/utilities/notify"

function newRequestKey() {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return `exreq-${crypto.randomUUID()}`
  }
  return `exreq-${Date.now()}`
}

export function DamageExceptionalRequestPanel({
  report,
  onChanged,
}: {
  report: DamageReportDetail
  onChanged: () => void
}) {
  const access = useDamageAccess()
  const breakdown = damageQuantityBreakdown(report)
  const openRequest = (report.exceptional_requests ?? []).find((row) =>
    ["requested", "approved"].includes(row.status),
  )
  const postedRequest = (report.exceptional_requests ?? []).find(
    (row) => row.status === "posted",
  )
  const blockers = collectExceptionalRequestBlockers({
    status: report.status,
    scenario: report.scenario,
    canVerify: access.canVerify,
    hasFinalizedEvidence: (report.evidence ?? []).some((row) => row.finalized),
    remainingHoldCases: breakdown.remainingHoldCases,
    ordinaryPosted: reportHasCompletedOrdinaryWriteoff(report),
    exceptionalOpen: Boolean(openRequest),
    exceptionalPosted: Boolean(postedRequest),
    godownActive: report.godown_active,
  })
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [kind, setKind] = useState<ExceptionalDispositionKind>("destroy")
  const [reason, setReason] = useState("")
  const [idempotencyKey, setIdempotencyKey] = useState(newRequestKey)
  const pendingRecovery = useRef(false)

  useEffect(() => {
    if (!pendingRecovery.current || !openRequest) return
    pendingRecovery.current = false
    notify.success("Exceptional request submitted")
    setOpen(false)
    setError(null)
    setIdempotencyKey(newRequestKey())
  }, [openRequest])

  if (!access.canVerify && !access.canMonitor && !access.canDispose) return null

  async function submit() {
    setBusy(true)
    setError(null)
    try {
      await requestExceptionalDamageDisposition({
        targetReport: report.id,
        expectedVersion: report.version,
        dispositionKind: kind,
        requestReason: reason,
        idempotencyKey,
      })
      notify.success("Exceptional request submitted")
      setOpen(false)
      setReason("")
      setIdempotencyKey(newRequestKey())
      onChanged()
    } catch (caught) {
      pendingRecovery.current = true
      setError(mapDamageMutationError(caught, "exceptional-request"))
      onChanged()
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="rounded-2xl bg-card p-4 ring-1 ring-border">
      <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold">Exceptional disposition</h2>
          <p className="text-xs text-muted-foreground">
            Request return to supplier or destroy. Admin approval is required
            before any ledger posting.
          </p>
        </div>
        <StatusBadge
          tone={
            postedRequest
              ? "success"
              : openRequest?.status === "approved"
                ? "info"
                : openRequest
                  ? "warning"
                  : "neutral"
          }
        >
          {postedRequest
            ? formatExceptionalStatus("posted")
            : openRequest
              ? formatExceptionalStatus(openRequest.status)
              : "No open request"}
        </StatusBadge>
      </div>

      <dl className="mb-3 grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-3">
        <div>
          <dt className="text-muted-foreground">Remaining isolated</dt>
          <dd>{formatCases(breakdown.remainingHoldCases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Returned to supplier</dt>
          <dd>{formatCases(breakdown.returnedSupplierCases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Open kind</dt>
          <dd>
            {openRequest ? formatExceptionalKind(openRequest.kind) : "—"}
          </dd>
        </div>
      </dl>

      <DamageDispositionEligibility
        blockers={blockers}
        emptyLabel="This report is eligible for an exceptional disposition request."
      />

      {access.canVerify ? (
        <div className="mt-4">
          <Button
            type="button"
            disabled={blockers.length > 0 || busy}
            onClick={() => setOpen(true)}
          >
            Request exceptional disposition
          </Button>
        </div>
      ) : null}

      {error ? (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {error}
        </p>
      ) : null}

      <DamageExceptionalRequestDialog
        report={report}
        open={open}
        busy={busy}
        eligibleCases={breakdown.remainingHoldCases}
        kind={kind}
        reason={reason}
        onKindChange={setKind}
        onReasonChange={setReason}
        onOpenChange={setOpen}
        onConfirm={() => void submit()}
      />
    </section>
  )
}
