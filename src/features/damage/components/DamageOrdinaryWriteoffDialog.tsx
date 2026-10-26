import { AppModal } from "@/components/shared/AppModal"
import { Button } from "@/components/ui/button"
import { formatCases } from "@/features/damage/utils/labels"
import type { DamageReportDetail } from "@/lib/damage/api"

export function DamageOrdinaryWriteoffDialog({
  report,
  open,
  busy,
  eligibleCases,
  crateLabel,
  onOpenChange,
  onConfirm,
}: {
  report: DamageReportDetail
  open: boolean
  busy: boolean
  eligibleCases: number
  crateLabel: string
  onOpenChange: (open: boolean) => void
  onConfirm: () => void
}) {
  return (
    <AppModal
      open={open}
      onOpenChange={onOpenChange}
      title="Post ordinary damage write-off"
      description="This trusted adjustment removes remaining isolated damage from on-hand stock and writes an audit and ledger entry. Quantity is recalculated by the backend. Do not retry after an ambiguous failure — refresh first."
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
            aria-label="Confirm ordinary write-off"
          >
            {busy ? "Posting…" : "Post write-off"}
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
          <dt className="text-muted-foreground">Product</dt>
          <dd>
            {report.lines[0]
              ? `${report.lines[0].product_sku} · ${report.lines[0].product_name}`
              : "—"}
          </dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Lot</dt>
          <dd className="font-mono text-xs">
            {report.lines[0]?.lot_id?.slice(0, 8) ?? "—"}
          </dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Eligible quantity</dt>
          <dd>{formatCases(eligibleCases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Location</dt>
          <dd>{crateLabel}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Ledger category</dt>
          <dd>ADJUSTMENT · ordinary_writeoff</dd>
        </div>
      </dl>
    </AppModal>
  )
}
