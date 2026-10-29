import { Link, useParams } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { CreditAdjustmentDocument } from "@/features/invoices/CreditAdjustmentDocument"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { getCreditAdjustment, invoiceKeys } from "@/lib/invoices/api"
import { downloadCreditAdjustmentPdf } from "@/lib/invoices/credit-adjustment-pdf"
import { CREDIT_ADJUSTMENT_WATERMARK } from "@/lib/invoices/rules"

export function CreditAdjustmentPreviewPage() {
  const { adjustmentId = "" } = useParams()
  const detail = useQuery({
    queryKey: invoiceKeys.creditAdjustment(adjustmentId),
    queryFn: () => getCreditAdjustment(adjustmentId),
    enabled: adjustmentId !== "",
  })
  const row = detail.data

  useDocumentTitle(row ? `Credit adjustment ${row.adjustment_number}` : "Credit adjustment")

  return (
    <section className="credit-adjustment min-w-0 bg-background px-4 py-6 text-foreground sm:px-8">
      <div className="mb-6 flex flex-wrap items-center gap-3 print:hidden">
        <Button asChild variant="outline">
          <Link to="/credit-adjustments">Back</Link>
        </Button>
        {row ? (
          <>
            <Button type="button" variant="outline" onClick={() => window.print()}>
              Print A4
            </Button>
            <Button type="button" onClick={() => downloadCreditAdjustmentPdf(row)}>
              Download PDF
            </Button>
          </>
        ) : null}
      </div>

      {detail.isLoading ? <LoadingBlock label="Loading credit-adjustment preview" /> : null}
      {detail.error ? (
        <p role="alert" className="text-sm text-destructive">
          {detail.error.message}
        </p>
      ) : null}
      {row ? (
        <>
          <p
            role="note"
            className="mx-auto mb-4 max-w-[210mm] rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-950 ring-1 ring-amber-200 print:hidden"
          >
            {CREDIT_ADJUSTMENT_WATERMARK}. This screen cannot issue, finalize, post, or allocate a
            GST credit note.
          </p>
          <CreditAdjustmentDocument row={row} />
        </>
      ) : null}
    </section>
  )
}
