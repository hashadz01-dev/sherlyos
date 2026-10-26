import { useState } from "react"
import { Button } from "@/components/ui/button"
import { DamageHoldDetails } from "@/features/damage/components/DamageHoldDetails"
import { DamageQuarantineTransferDialog } from "@/features/damage/components/DamageQuarantineTransferDialog"
import { useDamageAccess } from "@/features/damage/hooks/use-damage-access"
import { formatCases } from "@/features/damage/utils/labels"
import { damageQuantityBreakdown } from "@/features/damage/utils/quantities"
import { mapDamageMutationError } from "@/features/damage/utils/submit"
import {
  transferVerifiedDamageToQuarantine,
  type DamageHoldRow,
  type DamageReportDetail,
} from "@/lib/damage/api"
import { canTransferVerifiedDamage } from "@/lib/damage/rules"
import { notify } from "@/lib/utilities/notify"

function newTransferKey() {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID()
  }
  return `xfer-${Date.now()}`
}

export function DamageHoldsPanel({
  report,
  onTransferred,
}: {
  report: DamageReportDetail
  onTransferred?: () => void
}) {
  const access = useDamageAccess()
  const breakdown = damageQuantityBreakdown(report)
  const holds = report.holds ?? []
  const activeOnHand = holds.filter(
    (hold: DamageHoldRow) =>
      hold.status === "active" && hold.hold_kind === "on_hand_deduction",
  )
  const eligible = canTransferVerifiedDamage({
    scenario: report.scenario,
    status: report.status,
    canVerify: access.canVerify,
    activeOnHandHolds: activeOnHand.length,
  })
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [idempotencyKey, setIdempotencyKey] = useState(newTransferKey)

  async function transfer() {
    setBusy(true)
    setError(null)
    try {
      await transferVerifiedDamageToQuarantine(
        report.id,
        report.version,
        idempotencyKey,
      )
      notify.success("Verified damage transferred to quarantine")
      setOpen(false)
      setIdempotencyKey(newTransferKey())
      onTransferred?.()
    } catch (caught) {
      setError(mapDamageMutationError(caught, "transfer"))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="grid gap-4">
      <dl className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <div className="rounded-xl bg-muted/40 p-3">
          <dt className="text-xs text-muted-foreground">Reported</dt>
          <dd className="text-lg font-semibold">
            {formatCases(breakdown.reportedCases)}
          </dd>
        </div>
        <div className="rounded-xl bg-muted/40 p-3">
          <dt className="text-xs text-muted-foreground">Held</dt>
          <dd className="text-lg font-semibold">
            {formatCases(breakdown.heldCases)}
          </dd>
          <p className="mt-1 text-xs text-muted-foreground">
            Unavailable logical stock. Not a physical quarantine move.
          </p>
        </div>
        <div className="rounded-xl bg-muted/40 p-3">
          <dt className="text-xs text-muted-foreground">Quarantined</dt>
          <dd className="text-lg font-semibold">
            {formatCases(breakdown.quarantinedCases)}
          </dd>
          <p className="mt-1 text-xs text-muted-foreground">
            Physically segregated unavailable stock.
          </p>
        </div>
        <div className="rounded-xl bg-muted/40 p-3">
          <dt className="text-xs text-muted-foreground">
            Reservation converted
          </dt>
          <dd className="text-lg font-semibold">
            {formatCases(breakdown.reservationConvertedCases)}
          </dd>
        </div>
        <div className="rounded-xl bg-muted/40 p-3">
          <dt className="text-xs text-muted-foreground">Transferred</dt>
          <dd className="text-lg font-semibold">
            {formatCases(breakdown.transferredCases)}
          </dd>
        </div>
        <div className="rounded-xl bg-muted/40 p-3">
          <dt className="text-xs text-muted-foreground">Written off</dt>
          <dd className="text-lg font-semibold">
            {formatCases(breakdown.writtenOffCases)}
          </dd>
        </div>
      </dl>

      <DamageHoldDetails holds={holds} />

      {eligible ? (
        <div>
          <Button type="button" onClick={() => setOpen(true)}>
            Transfer verified damage to quarantine
          </Button>
        </div>
      ) : null}

      {error ? (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      ) : null}

      <DamageQuarantineTransferDialog
        report={report}
        open={open}
        busy={busy}
        sourceCases={activeOnHand.reduce(
          (sum, hold) => sum + Number(hold.quantity_cases || 0),
          0,
        )}
        onOpenChange={setOpen}
        onConfirm={() => void transfer()}
      />
    </div>
  )
}
