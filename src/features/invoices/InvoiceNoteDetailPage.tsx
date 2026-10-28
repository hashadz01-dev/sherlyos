import { useState } from "react"
import { Link, useParams } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import {
  cancelInvoiceNote,
  getInvoiceNote,
  invoiceKeys,
  reviewInvoiceNote,
  submitInvoiceNote,
} from "@/lib/invoices/api"
import {
  INVOICE_DRAFT_WATERMARK,
  TAX_PREVIEW_WATERMARK,
  formatInr,
  invoiceEventLabel,
  invoiceNoteStatusLabel,
  invoiceNoteStatusTone,
} from "@/lib/invoices/rules"
import { getInvoiceTaxPreview, previewInvoiceTax } from "@/lib/invoices/tax-preview"
import { notify } from "@/lib/utilities/notify"

export function InvoiceNoteDetailPage() {
  const { noteId = "" } = useParams()
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const [actionError, setActionError] = useState<string | null>(null)

  const detail = useQuery({
    queryKey: invoiceKeys.detail(noteId),
    queryFn: () => getInvoiceNote(noteId),
    enabled: noteId !== "",
  })
  const note = detail.data
  const taxPreview = useQuery({
    queryKey: invoiceKeys.taxPreview(noteId),
    queryFn: () => getInvoiceTaxPreview(noteId),
    enabled: noteId !== "" && note?.status === "reviewed",
  })
  useDocumentTitle(note ? note.note_number : "Invoice note")

  async function refresh() {
    await queryClient.invalidateQueries({ queryKey: invoiceKeys.detail(noteId) })
    await queryClient.invalidateQueries({ queryKey: ["invoice-notes"] })
    await queryClient.invalidateQueries({ queryKey: invoiceKeys.eligible })
  }

  const submit = useMutation({
    mutationFn: () => submitInvoiceNote(noteId, note?.version ?? 1),
    onSuccess: async () => {
      notify.success("Draft submitted for Accounts review.")
      setActionError(null)
      await refresh()
    },
    onError: (error: Error) => setActionError(error.message),
  })
  const review = useMutation({
    mutationFn: () => reviewInvoiceNote(noteId, note?.version ?? 1),
    onSuccess: async () => {
      notify.success("Draft reviewed. This is still not a tax invoice.")
      setActionError(null)
      await refresh()
    },
    onError: (error: Error) => setActionError(error.message),
  })
  const cancel = useMutation({
    mutationFn: () => cancelInvoiceNote(noteId, note?.version ?? 1),
    onSuccess: async () => {
      notify.success("Draft cancelled. A replacement can be prepared from the same dispatch.")
      setActionError(null)
      await refresh()
    },
    onError: (error: Error) => setActionError(error.message),
  })

  const canSubmit = can("invoice_notes.prepare") && note?.status === "draft"
  const canReview = can("invoices.review") && note?.status === "submitted"
  const taxPreviewMutation = useMutation({
    mutationFn: () => previewInvoiceTax(noteId, note?.version ?? 1),
    onSuccess: async () => {
      notify.success("Tax calculation preview refreshed. This is not a tax invoice.")
      await queryClient.invalidateQueries({ queryKey: invoiceKeys.taxPreview(noteId) })
    },
    onError: (error: Error) => setActionError(error.message),
  })
  const canCancel =
    note != null &&
    note.status !== "cancelled" &&
    ((can("invoice_notes.prepare") && (note.status === "draft" || note.status === "submitted")) ||
      (can("invoices.review") && (note.status === "submitted" || note.status === "reviewed")))

  return (
    <section className="min-w-0">
      <PageHeader
        title={note?.note_number ?? "Invoice note"}
        description="Priced invoice-note draft. GST is not calculated. Signature and seal are withheld."
        action={
          <div className="flex flex-wrap gap-2">
            <Button asChild variant="outline">
              <Link to="/invoices">Back</Link>
            </Button>
            {note ? (
              <Button asChild>
                <Link to={`/invoices/${note.id}/preview`}>Print preview</Link>
              </Button>
            ) : null}
          </div>
        }
      />

      {detail.isLoading ? <LoadingBlock label="Loading invoice note" /> : null}
      {detail.error ? (
        <p role="alert" className="text-sm text-destructive">
          {detail.error.message}
        </p>
      ) : null}

      {note ? (
        <div className="grid gap-4">
          <p
            role="status"
            className="rounded-2xl bg-amber-50 px-4 py-3 text-sm font-medium text-amber-900 ring-1 ring-amber-200"
          >
            {note.watermark || INVOICE_DRAFT_WATERMARK}
          </p>

          <div className="rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <StatusBadge tone={invoiceNoteStatusTone[note.status]}>
                {invoiceNoteStatusLabel[note.status]}
              </StatusBadge>
              <div className="flex flex-wrap gap-2">
                {canSubmit ? (
                  <Button type="button" onClick={() => submit.mutate()} disabled={submit.isPending}>
                    Submit for review
                  </Button>
                ) : null}
                {canReview ? (
                  <Button type="button" onClick={() => review.mutate()} disabled={review.isPending}>
                    Review draft
                  </Button>
                ) : null}
                {canCancel ? (
                  <Button
                    type="button"
                    variant="outline"
                    onClick={() => cancel.mutate()}
                    disabled={cancel.isPending}
                  >
                    Cancel draft
                  </Button>
                ) : null}
              </div>
            </div>
            {actionError ? (
              <p role="alert" className="mt-3 text-sm text-destructive">
                {actionError}
              </p>
            ) : null}
            <dl className="mt-4 grid gap-3 sm:grid-cols-2">
              <div>
                <dt className="text-xs text-muted-foreground">Dispatch</dt>
                <dd className="text-sm">{note.dispatch_number}</dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">Order</dt>
                <dd className="text-sm">{note.order_number}</dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">Shop</dt>
                <dd className="text-sm">{note.shop.name}</dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">As of dispatch date</dt>
                <dd className="text-sm">{note.as_of_date}</dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">Billed cases</dt>
                <dd className="text-sm">{note.billed_cases}</dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">Grand total</dt>
                <dd className="text-sm">{formatInr(note.grand_total)}</dd>
              </div>
            </dl>
            <p className="mt-3 text-sm text-muted-foreground">{note.amount_in_words}</p>
          </div>

          <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200/80">
            <table className="w-full text-left text-sm">
              <caption className="sr-only">Invoice-note lines</caption>
              <thead className="border-b border-slate-200 text-xs text-muted-foreground">
                <tr>
                  <th className="px-4 py-2">SKU</th>
                  <th className="px-4 py-2">Product</th>
                  <th className="px-4 py-2">Cases</th>
                  <th className="px-4 py-2">Billed qty</th>
                  <th className="px-4 py-2">Rate</th>
                  <th className="px-4 py-2">Amount</th>
                  <th className="px-4 py-2">Price</th>
                </tr>
              </thead>
              <tbody>
                {note.lines.map((line) => (
                  <tr key={line.id} className="border-b border-slate-100">
                    <td className="px-4 py-2">{line.product_sku}</td>
                    <td className="px-4 py-2">{line.product_name}</td>
                    <td className="px-4 py-2">{line.shipped_cases}</td>
                    <td className="px-4 py-2">
                      {String(line.billed_quantity)} {line.billing_unit}
                    </td>
                    <td className="px-4 py-2">{formatInr(line.unit_amount)}</td>
                    <td className="px-4 py-2">{formatInr(line.line_amount)}</td>
                    <td className="px-4 py-2">{line.price_scope}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
            <h2 className="text-sm font-semibold">Statutory readiness</h2>
            <p className="mt-1 text-sm font-semibold text-red-800">
              CONFIGURATION ONLY — TAX INVOICE ISSUANCE DISABLED
            </p>
            <p className="mt-1 text-sm text-muted-foreground">
              ready={String(note.statutory.ready)} · Tax preview cannot issue a tax invoice.
            </p>
            <ul className="mt-3 list-disc space-y-1 pl-5 text-sm">
              {(note.statutory.blockers ?? []).map((blocker) => (
                <li key={blocker.code}>{blocker.message}</li>
              ))}
            </ul>
          </div>

          {note.status === "reviewed" ? (
            <div className="rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
              <h2 className="text-sm font-semibold">GST calculation preview</h2>
              <p className="mt-1 text-sm font-semibold text-red-800">{TAX_PREVIEW_WATERMARK}</p>
              {(can("invoice_notes.prepare") || can("invoices.review")) ? (
                <Button
                  type="button"
                  className="mt-3"
                  onClick={() => taxPreviewMutation.mutate()}
                  disabled={taxPreviewMutation.isPending}
                >
                  Calculate tax preview
                </Button>
              ) : null}
              {taxPreview.data?.stale ? (
                <p className="mt-2 text-sm text-amber-800">
                  This preview is stale. Recalculate before relying on these figures.
                </p>
              ) : null}
              {taxPreview.data?.calculated ? (
                <dl className="mt-4 grid gap-3 sm:grid-cols-2 text-sm">
                  <div>
                    <dt className="text-xs text-muted-foreground">Treatment</dt>
                    <dd>{taxPreview.data.pricing_treatment}</dd>
                  </div>
                  <div>
                    <dt className="text-xs text-muted-foreground">Supply</dt>
                    <dd>{taxPreview.data.supply_kind}</dd>
                  </div>
                  <div>
                    <dt className="text-xs text-muted-foreground">Taxable</dt>
                    <dd>{formatInr(taxPreview.data.taxable_value ?? 0)}</dd>
                  </div>
                  <div>
                    <dt className="text-xs text-muted-foreground">Tax</dt>
                    <dd>{formatInr(taxPreview.data.tax_amount ?? 0)}</dd>
                  </div>
                </dl>
              ) : null}
              {(taxPreview.data?.blockers ?? []).length > 0 ? (
                <ul className="mt-3 list-disc space-y-1 pl-5 text-sm">
                  {taxPreview.data?.blockers?.map((blocker) => (
                    <li key={blocker.code}>{blocker.message}</li>
                  ))}
                </ul>
              ) : null}
            </div>
          ) : null}

          {(note.credit_note_candidates ?? []).length > 0 ? (
            <div className="rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
              <h2 className="text-sm font-semibold">Related returns</h2>
              <p className="mt-1 text-sm text-muted-foreground">
                Documented only. Credit notes are not issued in this phase.
              </p>
              <ul className="mt-3 space-y-2 text-sm">
                {note.credit_note_candidates.map((row) => (
                  <li key={row.return_id}>
                    {row.return_number} · {row.status} · not issuable
                  </li>
                ))}
              </ul>
            </div>
          ) : null}

          <div className="rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
            <h2 className="text-sm font-semibold">History</h2>
            <ol className="mt-3 space-y-2 text-sm">
              {note.events.map((event) => (
                <li key={event.id}>
                  {invoiceEventLabel(event.event_type)}
                  <span className="text-muted-foreground">
                    {` · ${event.created_at.slice(0, 19).replace("T", " ")}`}
                  </span>
                </li>
              ))}
            </ol>
          </div>
        </div>
      ) : null}
    </section>
  )
}
