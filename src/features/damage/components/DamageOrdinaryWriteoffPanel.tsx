import { useEffect, useRef, useState } from "react"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { DamageOrdinaryWriteoffDialog } from "@/features/damage/components/DamageOrdinaryWriteoffDialog"
import { DamageVerificationEligibility } from "@/features/damage/components/DamageVerificationEligibility"
import { useDamageAccess } from "@/features/damage/hooks/use-damage-access"
import { formatCases } from "@/features/damage/utils/labels"
import { damageQuantityBreakdown } from "@/features/damage/utils/quantities"
import {
  mapDamageMutationError,
  reportHasCompletedOrdinaryWriteoff,
} from "@/features/damage/utils/submit"
import {
  postOrdinaryDamageWriteoff,
  type DamageReportDetail,
} from "@/lib/damage/api"
import { collectOrdinaryWriteoffBlockers } from "@/lib/damage/rules"
import { notify } from "@/lib/utilities/notify"

function newWriteoffKey() {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return `wo-${crypto.randomUUID()}`
  }
  return `wo-${Date.now()}`
}

export function DamageOrdinaryWriteoffPanel({
  report,
  onPosted,
}: {
  report: DamageReportDetail
  onPosted: () => void
}) {
  const access = useDamageAccess()
  const breakdown = damageQuantityBreakdown(report)
  const alreadyWrittenOff = reportHasCompletedOrdinaryWriteoff(report)
  const blockers = collectOrdinaryWriteoffBlockers({
    status: report.status,
    scenario: report.scenario,
    canVerify: access.canVerify,
    hasFinalizedEvidence: (report.evidence ?? []).some((row) => row.finalized),
    remainingHoldCases: breakdown.remainingHoldCases,
    exceptionalOpen: (report.exceptional_requests ?? []).some((row) =>
      ["requested", "approved"].includes(row.status),
    ),
    alreadyWrittenOff,
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
  const [idempotencyKey, setIdempotencyKey] = useState(newWriteoffKey)
  // After an ambiguous failure, identify completion from get_damage_report.
  // Never auto-retry the mutation; keep the original key until success.
  const pendingRecovery = useRef(false)

  useEffect(() => {
    if (!pendingRecovery.current || !alreadyWrittenOff) return
    pendingRecovery.current = false
    notify.success("Ordinary write-off posted")
    setOpen(false)
    setError(null)
    setIdempotencyKey(newWriteoffKey())
  }, [alreadyWrittenOff])

  if (!access.canVerify && !access.canMonitor) return null

  async function post() {
    setBusy(true)
    setError(null)
    try {
      await postOrdinaryDamageWriteoff(
        report.id,
        report.version,
        idempotencyKey,
      )
      notify.success("Ordinary write-off posted")
      setOpen(false)
      setIdempotencyKey(newWriteoffKey())
      onPosted()
    } catch (caught) {
      pendingRecovery.current = true
      setError(mapDamageMutationError(caught, "writeoff"))
      onPosted()
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="rounded-2xl bg-card p-4 ring-1 ring-border">
      <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold">Ordinary write-off</h2>
          <p className="text-xs text-muted-foreground">
            Preview is informational. The trusted RPC recalculates quantity and
            posts the ledger adjustment exactly once per report.
          </p>
        </div>
        <StatusBadge tone={alreadyWrittenOff ? "success" : "neutral"}>
          {alreadyWrittenOff ? "Written off" : "Not written off"}
        </StatusBadge>
      </div>

      <dl className="mb-3 grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-3">
        <div>
          <dt className="text-muted-foreground">Remaining isolated</dt>
          <dd>{formatCases(breakdown.remainingHoldCases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Already written off</dt>
          <dd>{formatCases(breakdown.writtenOffCases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Location</dt>
          <dd>{crateLabel}</dd>
        </div>
      </dl>

      <DamageVerificationEligibility
        blockers={blockers}
        emptyLabel="This report is eligible for an ordinary write-off of remaining isolated cases."
      />

      {access.canVerify ? (
        <div className="mt-4">
          <Button
            type="button"
            disabled={blockers.length > 0 || busy}
            onClick={() => setOpen(true)}
          >
            Post ordinary write-off
          </Button>
        </div>
      ) : null}

      {error ? (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {error}
        </p>
      ) : null}

      <DamageOrdinaryWriteoffDialog
        report={report}
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
