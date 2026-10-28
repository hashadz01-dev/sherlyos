import { useState } from "react"
import { Link, useParams } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { getInvoiceNotePreview } from "@/lib/invoices/api"
import {
  INVOICE_DRAFT_WATERMARK,
  INVOICE_NO_LEGAL_SEAL,
  formatInr,
  invoicePreviewCopyLabel,
  invoicePreviewCopies,
  type InvoicePreviewCopy,
} from "@/lib/invoices/rules"

export function InvoiceNotePreviewPage() {
  const { noteId = "" } = useParams()
  const [copy, setCopy] = useState<InvoicePreviewCopy>("accounts")
  const preview = useQuery({
    queryKey: ["invoice-note-preview", noteId, copy],
    queryFn: () => getInvoiceNotePreview(noteId, copy),
    enabled: noteId !== "",
  })
  const note = preview.data
  useDocumentTitle(note ? `Preview ${note.note_number}` : "Preview invoice note")

  return (
    <section className="min-w-0 bg-background px-4 py-6 text-foreground sm:px-8">
      <div className="mb-6 flex flex-wrap items-center gap-3 print:hidden">
        <Button asChild variant="outline">
          <Link to={`/invoices/${noteId}`}>Back</Link>
        </Button>
        <label className="grid gap-1 text-sm font-medium">
          Copy
          <select
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={copy}
            onChange={(event) => setCopy(event.target.value as InvoicePreviewCopy)}
            aria-label="Invoice copy"
          >
            {invoicePreviewCopies.map((value) => (
              <option key={value} value={value}>
                {invoicePreviewCopyLabel[value]}
              </option>
            ))}
          </select>
        </label>
        <Button type="button" onClick={() => window.print()}>
          Print draft
        </Button>
      </div>

      {preview.isLoading ? <LoadingBlock label="Loading preview" /> : null}
      {preview.error ? (
        <p role="alert" className="text-sm text-destructive">
          {preview.error.message}
        </p>
      ) : null}

      {note ? (
        <article className="relative mx-auto max-w-3xl overflow-hidden rounded-2xl bg-white p-6 ring-1 ring-slate-200/80">
          <div
            aria-hidden="true"
            className="pointer-events-none absolute inset-0 flex items-center justify-center"
          >
            <p className="rotate-[-24deg] text-center text-3xl font-semibold tracking-widest text-red-500/20 uppercase">
              {note.watermark || INVOICE_DRAFT_WATERMARK}
            </p>
          </div>

          <header className="relative mb-6 border-b border-border pb-4">
            <p className="text-xs tracking-[0.2em] text-muted-foreground uppercase">
              {note.copy_label ?? invoicePreviewCopyLabel[copy]}
            </p>
            <h1 className="mt-2 text-2xl font-semibold">
              {note.company.legal_name ?? "Company identity not configured"}
            </h1>
            {note.company.registered_address ? (
              <p className="mt-2 whitespace-pre-wrap text-sm text-muted-foreground">
                {note.company.registered_address}
              </p>
            ) : null}
            <p className="mt-3 text-sm font-medium text-red-700">
              {note.legal_seal_caption ?? INVOICE_NO_LEGAL_SEAL}
            </p>
          </header>

          <dl className="relative mb-6 grid gap-3 sm:grid-cols-2 text-sm">
            <div>
              <dt className="text-muted-foreground">Draft number</dt>
              <dd className="font-medium">{note.note_number}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Shop</dt>
              <dd className="font-medium">{note.shop.name}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Dispatch</dt>
              <dd>{note.dispatch_number}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Date</dt>
              <dd>{note.as_of_date}</dd>
            </div>
          </dl>

          <table className="relative w-full text-left text-sm">
            <thead className="border-b border-border text-xs text-muted-foreground">
              <tr>
                <th className="py-2">SKU</th>
                <th className="py-2">Product</th>
                <th className="py-2">Qty</th>
                <th className="py-2">Rate</th>
                <th className="py-2">Amount</th>
              </tr>
            </thead>
            <tbody>
              {note.lines.map((line) => (
                <tr key={line.id} className="border-b border-slate-100">
                  <td className="py-2">{line.product_sku}</td>
                  <td className="py-2">{line.product_name}</td>
                  <td className="py-2">
                    {String(line.billed_quantity)} {line.billing_unit}
                  </td>
                  <td className="py-2">{formatInr(line.unit_amount)}</td>
                  <td className="py-2">{formatInr(line.line_amount)}</td>
                </tr>
              ))}
            </tbody>
          </table>

          <p className="relative mt-4 text-sm font-medium">
            Total {formatInr(note.grand_total)} · Tax pending accountant
          </p>
          <p className="relative mt-1 text-sm text-muted-foreground">{note.amount_in_words}</p>
          <p className="relative mt-6 text-xs text-muted-foreground">
            {note.signature_block?.reason ??
              "Signature and seal appear only on a finalized tax invoice."}
          </p>
        </article>
      ) : null}
    </section>
  )
}
