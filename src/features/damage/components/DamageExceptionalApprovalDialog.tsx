import { AppModal } from "@/components/shared/AppModal"
import { Button } from "@/components/ui/button"
import { formatCases } from "@/features/damage/utils/labels"
import type { DamageExceptionalRequest, DamageReportDetail } from "@/lib/damage/api"
import { formatExceptionalKind } from "@/lib/damage/rules"

export function DamageExceptionalApprovalDialog({
  report,
  request,
  open,
  busy,
  eligibleCases,
  onOpenChange,
  onConfirm,
}: {
  report: DamageReportDetail
  request: DamageExceptionalRequest
  open: boolean
  busy: boolean
  eligibleCases: number
  onOpenChange: (open: boolean) => void
  onConfirm: () => void
}) {
  return (
    <AppModal
      open={open}
      onOpenChange={onOpenChange}
      title="Approve exceptional disposition"
      description="Approval is an authorization event. It does not post stock or consume holds."
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
            aria-label="Confirm exceptional approval"
          >
            {busy ? "Approving…" : "Approve"}
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
          <dt className="text-muted-foreground">Disposition</dt>
          <dd>{formatExceptionalKind(request.kind)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Requested by</dt>
          <dd>{request.requested_by_name ?? "—"}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Reason</dt>
          <dd>{request.request_reason ?? "—"}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Remaining isolated</dt>
          <dd>{formatCases(eligibleCases)}</dd>
        </div>
      </dl>
    </AppModal>
  )
}
