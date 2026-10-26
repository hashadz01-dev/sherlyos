import { AppModal } from "@/components/shared/AppModal"
import { Button } from "@/components/ui/button"
import { formatCases } from "@/features/damage/utils/labels"
import type { DamageReportDetail } from "@/lib/damage/api"

export function DamageVerificationDialog({
  report,
  open,
  busy,
  reportedCases,
  isolatedCases,
  evidenceCount,
  onOpenChange,
  onConfirm,
}: {
  report: DamageReportDetail
  open: boolean
  busy: boolean
  reportedCases: number
  isolatedCases: number
  evidenceCount: number
  onOpenChange: (open: boolean) => void
  onConfirm: () => void
}) {
  return (
    <AppModal
      open={open}
      onOpenChange={onOpenChange}
      title="Verify damage report"
      description="Verification records Godown Manager inspection. It does not post stock. The backend re-checks evidence, isolation, version, and self-verification."
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
            aria-label="Confirm damage verification"
          >
            {busy ? "Verifying…" : "Verify report"}
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
          <dt className="text-muted-foreground">Godown</dt>
          <dd>{report.godown_name}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Reported quantity</dt>
          <dd>{formatCases(reportedCases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Isolated quantity</dt>
          <dd>{formatCases(isolatedCases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Finalized evidence</dt>
          <dd>{evidenceCount}</dd>
        </div>
      </dl>
    </AppModal>
  )
}
