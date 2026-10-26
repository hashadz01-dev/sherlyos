import { AppModal } from "@/components/shared/AppModal"
import { Button } from "@/components/ui/button"
import { formatCases } from "@/features/damage/utils/labels"
import type { DamageReportDetail } from "@/lib/damage/api"

export function DamageQuarantineTransferDialog({
  report,
  open,
  busy,
  sourceCases,
  onOpenChange,
  onConfirm,
}: {
  report: DamageReportDetail
  open: boolean
  busy: boolean
  sourceCases: number
  onOpenChange: (open: boolean) => void
  onConfirm: () => void
}) {
  return (
    <AppModal
      open={open}
      onOpenChange={onOpenChange}
      title="Transfer verified damage to quarantine"
      description="This posts a trusted crate transfer of the full active on-hand hold onto the godown quarantine crate. Quantity cannot be partial. The action is not retried automatically after an ambiguous failure."
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
            aria-label="Post quarantine transfer"
          >
            {busy ? "Transferring…" : "Transfer to quarantine"}
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
          <dt className="text-muted-foreground">Source hold</dt>
          <dd>{formatCases(sourceCases)} on-hand isolation</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Destination</dt>
          <dd>
            Authorized quarantine crate at {report.godown_name}. The crate is
            selected by the backend.
          </dd>
        </div>
      </dl>
    </AppModal>
  )
}
