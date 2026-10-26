import { AppModal } from "@/components/shared/AppModal"
import { Button } from "@/components/ui/button"
import { formatCases } from "@/features/damage/utils/labels"
import type { DamageReportDetail } from "@/lib/damage/api"

export function DamageCustodyConfirmDialog({
  report,
  open,
  busy,
  onOpenChange,
  onConfirm,
}: {
  report: DamageReportDetail
  open: boolean
  busy: boolean
  onOpenChange: (open: boolean) => void
  onConfirm: () => void
}) {
  const cases = report.lines.reduce(
    (sum, line) => sum + Number(line.quantity_cases || 0),
    0,
  )

  return (
    <AppModal
      open={open}
      onOpenChange={onOpenChange}
      title="Confirm physical custody"
      description="This records that the returned goods are physically present at the receiving godown. It does not submit the report and does not post stock."
      footer={
        <>
          <Button
            type="button"
            variant="outline"
            disabled={busy}
            onClick={() => onOpenChange(false)}
          >
            Cancel
          </Button>
          <Button
            type="button"
            disabled={busy}
            onClick={onConfirm}
            aria-label="Confirm physical custody now"
          >
            {busy ? "Confirming…" : "Confirm custody"}
          </Button>
        </>
      }
    >
      <dl className="grid gap-2 text-sm">
        <div>
          <dt className="text-muted-foreground">Report</dt>
          <dd>{report.report_number}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Receiving godown</dt>
          <dd>{report.godown_name}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Returned quantity</dt>
          <dd>{formatCases(cases)}</dd>
        </div>
      </dl>
    </AppModal>
  )
}
