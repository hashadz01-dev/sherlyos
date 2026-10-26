import { useState } from "react"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { DamageCustodyConfirmDialog } from "@/features/damage/components/DamageCustodyConfirmDialog"
import { useDamageAccess } from "@/features/damage/hooks/use-damage-access"
import {
  formatCases,
  formatDamageStatus,
  formatTimestamp,
} from "@/features/damage/utils/labels"
import { mapDamageMutationError } from "@/features/damage/utils/submit"
import {
  confirmShopReturnCustody,
  type DamageReportDetail,
} from "@/lib/damage/api"
import { canConfirmShopReturnCustody } from "@/lib/damage/rules"
import { notify } from "@/lib/utilities/notify"

export function DamageCustodyPanel({
  report,
  onConfirmed,
}: {
  report: DamageReportDetail
  onConfirmed: () => void
}) {
  const access = useDamageAccess()
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (report.scenario !== "shop_return") return null

  const eligible = canConfirmShopReturnCustody({
    scenario: report.scenario,
    status: report.status,
    alreadyConfirmed: Boolean(report.physical_custody_confirmed),
    canRecord: access.canRecord,
    canVerify: access.canVerify,
  })
  const returnedCases = report.lines.reduce(
    (sum, line) => sum + Number(line.quantity_cases || 0),
    0,
  )

  async function confirm() {
    setBusy(true)
    setError(null)
    try {
      await confirmShopReturnCustody(report.id, report.version)
      notify.success("Physical custody confirmed")
      setOpen(false)
      onConfirmed()
    } catch (caught) {
      setError(mapDamageMutationError(caught, "custody"))
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="rounded-2xl bg-card p-4 ring-1 ring-border">
      <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold">Shop-return custody</h2>
          <p className="text-xs text-muted-foreground">
            Confirmation is an authorized RPC. A checkbox is never proof of
            physical presence.
          </p>
        </div>
        <StatusBadge
          tone={report.physical_custody_confirmed ? "success" : "warning"}
        >
          {report.physical_custody_confirmed
            ? "Custody confirmed"
            : "Custody outstanding"}
        </StatusBadge>
      </div>

      <dl className="grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-3">
        <div>
          <dt className="text-muted-foreground">Report</dt>
          <dd>{report.report_number}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Shop</dt>
          <dd>{report.shop_name ?? report.shop_id?.slice(0, 8) ?? "—"}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Product</dt>
          <dd>
            {report.lines[0]
              ? `${report.lines[0].product_sku} · ${report.lines[0].product_name}`
              : "—"}
            {report.lines.length > 1
              ? ` +${report.lines.length - 1} more`
              : null}
          </dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Returned cases</dt>
          <dd>{formatCases(returnedCases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Receiving godown</dt>
          <dd>{report.godown_name}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Report status</dt>
          <dd>{formatDamageStatus(report.status)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Confirmed by</dt>
          <dd>
            {report.physical_custody_confirmed
              ? (report.physical_custody_confirmed_by_name ?? "—")
              : "Not confirmed"}
          </dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Confirmed at</dt>
          <dd>{formatTimestamp(report.physical_custody_confirmed_at)}</dd>
        </div>
      </dl>

      {eligible ? (
        <div className="mt-4">
          <Button type="button" onClick={() => setOpen(true)}>
            Confirm physical custody
          </Button>
        </div>
      ) : null}

      {error ? (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {error}
        </p>
      ) : null}

      <DamageCustodyConfirmDialog
        report={report}
        open={open}
        busy={busy}
        onOpenChange={setOpen}
        onConfirm={() => void confirm()}
      />
    </section>
  )
}
