import { useState } from "react"
import { Link, useParams } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { AppModal } from "@/components/shared/AppModal"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { CreditAdjustmentDocument } from "@/features/invoices/CreditAdjustmentDocument"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { toUserRpcMessage } from "@/lib/rpc/user-error"
import {
  getCreditAdjustment,
  invoiceKeys,
  reviewCreditAdjustment,
} from "@/lib/invoices/api"
import { downloadCreditAdjustmentPdf } from "@/lib/invoices/credit-adjustment-pdf"
import {
  CREDIT_ADJUSTMENT_WATERMARK,
  creditAdjustmentStatusLabel,
  creditAdjustmentStatusTone,
  formatInr,
  invoiceEventLabel,
  isCreditAdjustmentStatus,
  isValidCreditAdjustmentReviewReason,
} from "@/lib/invoices/rules"
import { notify } from "@/lib/utilities/notify"

export function CreditAdjustmentPreviewPage() {
  const { adjustmentId = "" } = useParams()
  const queryClient = useQueryClient()
  const [decision, setDecision] = useState<"approve" | "reject" | null>(null)
  const [reason, setReason] = useState("")
  const [actionError, setActionError] = useState<string | null>(null)

  const detail = useQuery({
    queryKey: invoiceKeys.creditAdjustment(adjustmentId),
    queryFn: () => getCreditAdjustment(adjustmentId),
    enabled: adjustmentId !== "",
  })
  const row = detail.data
  const status = row && isCreditAdjustmentStatus(row.status) ? row.status : "preview"
  const canReview = row?.status === "preview"
  const reconcil = row?.reconciliation
  const taxReadiness = row?.tax_readiness
  const reasonValid = isValidCreditAdjustmentReviewReason(reason)

  useDocumentTitle(row ? `Credit adjustment ${row.adjustment_number}` : "Credit adjustment")

  const review = useMutation({
    mutationFn: () =>
      reviewCreditAdjustment({
        adjustmentId,
        decision: decision ?? "reject",
        reason,
        expectedVersion: row?.version ?? 1,
      }),
    onSuccess: async () => {
      notify.success(
        decision === "approve"
          ? "Approved for internal reconciliation. This is not a GST credit note."
          : "Credit adjustment rejected. This is not a GST credit note.",
      )
      setDecision(null)
      setReason("")
      setActionError(null)
      await queryClient.invalidateQueries({ queryKey: invoiceKeys.creditAdjustment(adjustmentId) })
      await queryClient.invalidateQueries({ queryKey: ["credit-adjustments"] })
    },
    onError: (error: Error) => {
      setActionError(toUserRpcMessage(error))
    },
  })

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
            {canReview ? (
              <>
                <Button type="button" onClick={() => setDecision("approve")}>
                  Approve for internal reconciliation
                </Button>
                <Button type="button" variant="outline" onClick={() => setDecision("reject")}>
                  Reject
                </Button>
              </>
            ) : null}
          </>
        ) : null}
      </div>

      {detail.isLoading ? <LoadingBlock label="Loading credit-adjustment preview" /> : null}
      {detail.error ? (
        <p role="alert" className="text-sm text-destructive">
          {detail.error.message}
        </p>
      ) : null}
      {actionError ? (
        <p role="alert" className="mb-4 text-sm text-destructive">
          {actionError}
        </p>
      ) : null}
      {row ? (
        <>
          <p
            role="note"
            className="mx-auto mb-4 max-w-[210mm] rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-950 ring-1 ring-amber-200 print:hidden"
          >
            {CREDIT_ADJUSTMENT_WATERMARK}. Internal review does not issue, finalize, post to
            accounts, or allocate a GST credit note.
          </p>

          <aside className="mx-auto mb-4 grid max-w-[210mm] gap-4 print:hidden">
            <div className="rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <StatusBadge tone={creditAdjustmentStatusTone[status]}>
                  {creditAdjustmentStatusLabel[status]}
                </StatusBadge>
                <p className="text-xs text-muted-foreground">
                  Reviewer: {row.reviewer_name?.trim() || "—"}
                  {row.reviewed_at ? ` · ${row.reviewed_at.replace("T", " ").slice(0, 19)}` : ""}
                </p>
              </div>
              {row.review_reason ? (
                <p className="mt-2 text-sm">Reason: {row.review_reason}</p>
              ) : null}
            </div>

            {reconcil ? (
              <div className="rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
                <h2 className="text-sm font-semibold">Quantity reconciliation</h2>
                <p className="mt-1 text-xs text-muted-foreground">
                  Whole-case arithmetic from the reviewed invoice-note snapshot. Live product
                  prices are not used.
                </p>
                <dl className="mt-3 grid gap-2 text-sm sm:grid-cols-3">
                  <div>
                    <dt className="text-xs text-muted-foreground">Billed cases</dt>
                    <dd>{reconcil.billed_cases}</dd>
                  </div>
                  <div>
                    <dt className="text-xs text-muted-foreground">Dispatched cases</dt>
                    <dd>{reconcil.dispatched_cases}</dd>
                  </div>
                  <div>
                    <dt className="text-xs text-muted-foreground">Returned cases</dt>
                    <dd>{reconcil.returned_cases}</dd>
                  </div>
                  <div>
                    <dt className="text-xs text-muted-foreground">Prepared cases</dt>
                    <dd>{reconcil.prepared_cases}</dd>
                  </div>
                  <div>
                    <dt className="text-xs text-muted-foreground">Approved cases</dt>
                    <dd>{reconcil.approved_cases}</dd>
                  </div>
                  <div>
                    <dt className="text-xs text-muted-foreground">Remaining eligible</dt>
                    <dd>{reconcil.remaining_eligible_cases}</dd>
                  </div>
                </dl>
                <table className="mt-3 w-full text-left text-xs">
                  <thead>
                    <tr className="border-b border-slate-200 text-muted-foreground">
                      <th className="py-1 pr-2">Product</th>
                      <th className="py-1 pr-2">Billed</th>
                      <th className="py-1 pr-2">Returned</th>
                      <th className="py-1 pr-2">This adj.</th>
                      <th className="py-1 pr-2">Remaining</th>
                      <th className="py-1">Snapshot price</th>
                    </tr>
                  </thead>
                  <tbody>
                    {(reconcil.lines ?? []).map((line) => (
                      <tr key={line.invoice_note_line_id} className="border-b border-slate-100">
                        <td className="py-1 pr-2">{line.product_name}</td>
                        <td className="py-1 pr-2">{line.billed_cases}</td>
                        <td className="py-1 pr-2">{line.returned_cases}</td>
                        <td className="py-1 pr-2">{line.this_adjustment_cases}</td>
                        <td className="py-1 pr-2">{line.remaining_eligible_cases}</td>
                        <td className="py-1">{formatInr(line.unit_amount)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
                {(reconcil.discrepancies ?? []).length > 0 ? (
                  <ul className="mt-3 list-disc space-y-1 pl-4 text-xs text-amber-900">
                    {reconcil.discrepancies.map((item) => (
                      <li key={item.code}>{item.message}</li>
                    ))}
                  </ul>
                ) : null}
              </div>
            ) : null}

            {taxReadiness ? (
              <div className="rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
                <h2 className="text-sm font-semibold">GST credit-note readiness</h2>
                <p className="mt-1 text-xs text-muted-foreground">
                  ready={String(taxReadiness.ready)}. Legal issuance remains blocked. Accountant
                  policy is not invented.
                </p>
                <ul className="mt-3 list-disc space-y-1 pl-4 text-xs">
                  {(taxReadiness.blockers ?? []).map((blocker) => (
                    <li key={blocker.code}>{blocker.message}</li>
                  ))}
                </ul>
              </div>
            ) : null}

            {(row.events ?? []).length > 0 ? (
              <div className="rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
                <h2 className="text-sm font-semibold">Review history</h2>
                <ol className="mt-2 space-y-1 text-xs">
                  {(row.events ?? []).map((event) => (
                    <li key={event.id}>
                      {invoiceEventLabel(event.event_type)} ·{" "}
                      {event.created_at.replace("T", " ").slice(0, 19)}
                    </li>
                  ))}
                </ol>
              </div>
            ) : null}
          </aside>

          <CreditAdjustmentDocument row={row} />
        </>
      ) : null}

      <AppModal
        open={decision !== null}
        onOpenChange={(open) => {
          if (!open) {
            setDecision(null)
            setReason("")
          }
        }}
        title={
          decision === "approve"
            ? "Approve for internal reconciliation"
            : "Reject credit adjustment"
        }
        description="This decision stays internal. It does not issue a GST credit note, post accounts, or allocate a legal number."
        footer={
          <>
            <Button
              type="button"
              variant="outline"
              disabled={review.isPending}
              onClick={() => {
                setDecision(null)
                setReason("")
              }}
            >
              Cancel
            </Button>
            <Button
              type="button"
              disabled={review.isPending || !reasonValid}
              onClick={() => review.mutate()}
            >
              {review.isPending ? "Saving…" : "Confirm"}
            </Button>
          </>
        }
      >
        <label className="grid gap-2 text-sm font-medium">
          Reason
          <textarea
            className="min-h-24 rounded-lg border border-input bg-transparent px-2.5 py-2 text-sm font-normal"
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            maxLength={500}
            aria-label="Review reason"
          />
        </label>
        {!reasonValid ? (
          <p className="mt-2 text-sm text-destructive">
            Enter a reason between 1 and 500 characters.
          </p>
        ) : null}
      </AppModal>
    </section>
  )
}
