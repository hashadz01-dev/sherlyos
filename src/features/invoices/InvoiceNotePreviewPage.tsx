import { Link, useParams, useSearchParams } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { InvoiceHandoverDocument } from "@/features/invoices/InvoiceHandoverDocument"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { getInvoiceNote, getInvoiceNotePreview, invoiceKeys } from "@/lib/invoices/api"
import { downloadInvoiceHandoverPdf } from "@/lib/invoices/handover-pdf"
import {
  INVOICE_PREVIEW_WATERMARK,
  invoiceAccountsPreviewPermissions,
  invoicePreviewCopyLabel,
  isInvoiceHandoverCopy,
  type InvoiceHandoverCopy,
} from "@/lib/invoices/rules"

export function InvoiceNotePreviewPage() {
  const { noteId = "" } = useParams()
  const { can } = useAccess()
  const [params, setParams] = useSearchParams()
  const requested = params.get("copy") ?? ""
  const copy = isInvoiceHandoverCopy(requested) ? requested : null
  const canAccounts = invoiceAccountsPreviewPermissions.some((permission) => can(permission))

  const note = useQuery({
    queryKey: invoiceKeys.detail(noteId),
    queryFn: () => getInvoiceNote(noteId),
    enabled: noteId !== "" && copy === null,
  })
  const preview = useQuery({
    queryKey: invoiceKeys.preview(noteId, copy ?? "driver"),
    queryFn: () => getInvoiceNotePreview(noteId, copy ?? "driver"),
    enabled: noteId !== "" && copy !== null,
  })

  useDocumentTitle(
    preview.data
      ? `${preview.data.copy_label ?? "Preview"} ${preview.data.note_number}`
      : note.data
        ? `Handover ${note.data.note_number}`
        : "Invoice handover",
  )

  function openCopy(next: InvoiceHandoverCopy) {
    setParams({ copy: next })
  }

  return (
    <section className="invoice-handover min-w-0 bg-background px-4 py-6 text-foreground sm:px-8">
      <div className="mb-6 flex flex-wrap items-center gap-3 print:hidden">
        <Button asChild variant="outline">
          <Link to={copy ? `/invoices/${noteId}/preview` : `/invoices/${noteId}`}>Back</Link>
        </Button>
        {copy && preview.data ? (
          <>
            <Button type="button" variant="outline" onClick={() => window.print()}>
              Print A4
            </Button>
            <Button type="button" onClick={() => downloadInvoiceHandoverPdf(preview.data)}>
              Download PDF
            </Button>
          </>
        ) : null}
      </div>

      {copy === null ? (
        <>
          {note.isLoading ? <LoadingBlock label="Loading handover" /> : null}
          {note.error ? (
            <p role="alert" className="text-sm text-destructive">
              {note.error.message}
            </p>
          ) : null}
          {note.data ? (
            <div className="mx-auto grid max-w-3xl gap-4">
              <p
                role="note"
                className="rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-950 ring-1 ring-amber-200"
              >
                {INVOICE_PREVIEW_WATERMARK}. Viewing or printing these copies does not dispatch
                goods, post stock, or issue a tax invoice.
              </p>
              <article className="rounded-2xl bg-white p-5 ring-1 ring-slate-200/80">
                <h1 className="text-lg font-semibold">Driver / delivery handover</h1>
                <p className="mt-2 text-sm text-muted-foreground">
                  Shop, dispatch, cases, and acknowledgement lines only. Prices and GST stay off
                  this copy.
                </p>
                <Button className="mt-4" type="button" onClick={() => openCopy("driver")}>
                  Open driver copy
                </Button>
              </article>
              <article className="rounded-2xl bg-white p-5 ring-1 ring-slate-200/80">
                <h1 className="text-lg font-semibold">Accounts / financial preview</h1>
                <p className="mt-2 text-sm text-muted-foreground">
                  Reviewed price snapshots and tax-preview figures when a current snapshot exists.
                  Still not a tax invoice.
                </p>
                {note.data.status !== "reviewed" ? (
                  <p className="mt-2 text-sm text-amber-900">
                    Available after Accounts review. Current status: {note.data.status}.
                  </p>
                ) : null}
                {canAccounts && note.data.status === "reviewed" ? (
                  <Button className="mt-4" type="button" onClick={() => openCopy("accounts")}>
                    Open accounts copy
                  </Button>
                ) : (
                  <p className="mt-2 text-sm text-muted-foreground">
                    Accounts financial preview requires invoice-note prepare or review permission
                    and a reviewed note.
                  </p>
                )}
              </article>
            </div>
          ) : null}
        </>
      ) : (
        <>
          {preview.isLoading ? <LoadingBlock label="Loading document" /> : null}
          {preview.error ? (
            <p role="alert" className="text-sm text-destructive">
              {preview.error.message}
            </p>
          ) : null}
          {preview.data ? (
            <>
              <p className="mb-3 text-center text-xs font-medium text-red-800 print:hidden">
                {invoicePreviewCopyLabel[copy]} · Print uses A4. Download PDF is a separate file
                export, not the browser print dialog.
              </p>
              <InvoiceHandoverDocument note={preview.data} />
            </>
          ) : null}
        </>
      )}
    </section>
  )
}
