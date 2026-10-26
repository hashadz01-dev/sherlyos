import { AppModal } from "@/components/shared/AppModal"
import { Button } from "@/components/ui/button"
import { formatCases } from "@/features/damage/utils/labels"
import type { DamageExceptionalRequest, DamageReportDetail } from "@/lib/damage/api"
import { formatExceptionalKind } from "@/lib/damage/rules"

export function DamageExceptionalExecutionDialog({
  report,
  request,
  open,
  busy,
  eligibleCases,
  crateLabel,
  onOpenChange,
  onConfirm,
}: {
  report: DamageReportDetail
  request: DamageExceptionalRequest
  open: boolean
  busy: boolean
  eligibleCases: number
  crateLabel: string
  onOpenChange: (open: boolean) => void
  onConfirm: () => void
}) {
  const kindLabel = formatExceptionalKind(request.kind)
  const holdStatus =
    request.kind === "return_supplier" ? "returned_supplier" : "written_off"
  return (
    <AppModal
      open={open}
      onOpenChange={onOpenChange}
      title={`Execute ${kindLabel.toLowerCase()}`}
      description="This trusted adjustment consumes remaining isolated quantity. It does not restore saleable stock. Physical destruction or supplier handover is not recorded here. Do not retry after an ambiguous failure — refresh first."
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
            aria-label="Confirm exceptional execution"
          >
            {busy ? "Posting…" : "Post disposition"}
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
          <dt className="text-muted-foreground">Approved disposition</dt>
          <dd>{kindLabel}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Approved by</dt>
          <dd>{request.decided_by_name ?? "—"}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Location</dt>
          <dd>{crateLabel}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Quantity</dt>
          <dd>{formatCases(eligibleCases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Expected ledger</dt>
          <dd>
            ADJUSTMENT · exceptional_writeoff · holds become {holdStatus}
          </dd>
        </div>
      </dl>
    </AppModal>
  )
}
