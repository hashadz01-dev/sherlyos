import { AppModal } from "@/components/shared/AppModal"
import { Button } from "@/components/ui/button"
import { formatCases } from "@/features/damage/utils/labels"
import type { DamageReportDetail } from "@/lib/damage/api"
import {
  exceptionalDispositionKinds,
  formatExceptionalKind,
  isValidDecisionReason,
  type ExceptionalDispositionKind,
} from "@/lib/damage/rules"

export function DamageExceptionalRequestDialog({
  report,
  open,
  busy,
  eligibleCases,
  kind,
  reason,
  onKindChange,
  onReasonChange,
  onOpenChange,
  onConfirm,
}: {
  report: DamageReportDetail
  open: boolean
  busy: boolean
  eligibleCases: number
  kind: ExceptionalDispositionKind
  reason: string
  onKindChange: (kind: ExceptionalDispositionKind) => void
  onReasonChange: (value: string) => void
  onOpenChange: (open: boolean) => void
  onConfirm: () => void
}) {
  const valid = isValidDecisionReason(reason)
  return (
    <AppModal
      open={open}
      onOpenChange={onOpenChange}
      title="Request exceptional disposition"
      description="This creates an Admin review request. It does not post stock or consume holds."
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
            disabled={busy || !valid}
            onClick={onConfirm}
            aria-label="Confirm exceptional request"
          >
            {busy ? "Requesting…" : "Submit request"}
          </Button>
        </>
      }
    >
      <dl className="mb-4 grid gap-2 text-sm">
        <div>
          <dt className="text-muted-foreground">Report</dt>
          <dd>{report.report_number}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Godown</dt>
          <dd>{report.godown_name}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Remaining isolated</dt>
          <dd>{formatCases(eligibleCases)}</dd>
        </div>
      </dl>
      <label className="grid gap-2 text-sm font-medium">
        Disposition
        <select
          className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
          value={kind}
          onChange={(event) =>
            onKindChange(event.target.value as ExceptionalDispositionKind)
          }
          aria-label="Exceptional disposition kind"
        >
          {exceptionalDispositionKinds.map((row) => (
            <option key={row} value={row}>
              {formatExceptionalKind(row)}
            </option>
          ))}
        </select>
      </label>
      <label className="mt-3 grid gap-2 text-sm font-medium">
        Reason
        <textarea
          className="min-h-24 rounded-lg border border-input bg-transparent px-2.5 py-2 text-sm font-normal"
          value={reason}
          onChange={(event) => onReasonChange(event.target.value)}
          maxLength={500}
          aria-label="Exceptional request reason"
        />
      </label>
      {!valid ? (
        <p className="mt-2 text-sm text-destructive">
          Enter a reason between 1 and 500 characters.
        </p>
      ) : null}
    </AppModal>
  )
}
