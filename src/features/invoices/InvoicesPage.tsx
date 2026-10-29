import { useState } from "react"
import { Link } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { FilterSelect, FilterToolbar, SearchField } from "@/features/masters/MasterControls"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import {
  invoiceKeys,
  listInvoiceEligibleDispatches,
  listInvoiceNotes,
  prepareInvoiceNote,
} from "@/lib/invoices/api"
import {
  INVOICE_DRAFT_WATERMARK,
  formatInr,
  invoiceNoteStatusLabel,
  invoiceNoteStatusTone,
  invoiceNoteStatuses,
} from "@/lib/invoices/rules"
import { matchesSearch } from "@/lib/masters/filters"
import { notify } from "@/lib/utilities/notify"

export function InvoicesPage() {
  useDocumentTitle("Invoice notes")
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const canPrepare = can("invoice_notes.prepare")
  const [search, setSearch] = useState("")
  const [status, setStatus] = useState("all")

  const notes = useQuery({
    queryKey: invoiceKeys.list(status, "all", "all"),
    queryFn: () => listInvoiceNotes({ status }),
  })
  const eligible = useQuery({
    queryKey: invoiceKeys.eligible,
    queryFn: listInvoiceEligibleDispatches,
    enabled: canPrepare,
  })

  const prepare = useMutation({
    mutationFn: (dispatchId: string) =>
      prepareInvoiceNote({
        dispatchId,
        idempotencyKey: `prepare-${dispatchId}`,
        expectedVersion: 1,
      }),
    onSuccess: async (note) => {
      notify.success(`Draft ${note.note_number} prepared. This is not a tax invoice.`)
      await queryClient.invalidateQueries({ queryKey: ["invoice-notes"] })
      await queryClient.invalidateQueries({ queryKey: invoiceKeys.eligible })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const rows = (notes.data ?? []).filter((row) =>
    matchesSearch(search, [row.note_number, row.shop_name, row.status]),
  )

  return (
    <section className="min-w-0">
      <PageHeader
        title="Invoice notes"
        description="Priced drafts from confirmed dispatch. GST tax invoices are blocked until accountant rules are approved."
      />
      <p
        role="note"
        className="mb-4 max-w-3xl text-sm leading-6 text-muted-foreground"
      >
        {INVOICE_DRAFT_WATERMARK}. Statutory numbering, GST, and legal seal are not available.
      </p>

      <FilterToolbar>
        <SearchField label="Search invoice notes" value={search} onChange={setSearch} />
        <FilterSelect label="Status" value={status} onChange={setStatus}>
          <option value="all">All statuses</option>
          {invoiceNoteStatuses.map((value) => (
            <option key={value} value={value}>
              {invoiceNoteStatusLabel[value]}
            </option>
          ))}
        </FilterSelect>
      </FilterToolbar>

      {canPrepare ? (
        <div className="mb-6 rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
          <h2 className="text-sm font-semibold">Prepare from confirmed dispatch</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            Quantity is the posted DISPATCH consume, not the delivery-note ordered quantity.
          </p>
          {eligible.isLoading ? <LoadingBlock label="Loading eligible dispatches" /> : null}
          {(eligible.data ?? []).length === 0 && !eligible.isLoading ? (
            <p className="mt-3 text-sm text-muted-foreground">
              No confirmed dispatches are waiting for an invoice-note draft.
            </p>
          ) : (
            <ul className="mt-3 divide-y divide-slate-200/80">
              {(eligible.data ?? []).map((row) => (
                <li
                  key={row.dispatch_id}
                  className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center sm:justify-between"
                >
                  <span className="text-sm">
                    <span className="font-medium">{row.dispatch_number}</span>
                    <span className="text-muted-foreground">
                      {` · ${row.order_number} · ${row.shop_name}`}
                    </span>
                  </span>
                  <Button
                    type="button"
                    onClick={() => prepare.mutate(row.dispatch_id)}
                    disabled={prepare.isPending}
                  >
                    Prepare draft
                  </Button>
                </li>
              ))}
            </ul>
          )}
        </div>
      ) : null}

      {notes.isLoading ? <LoadingBlock label="Loading invoice notes" /> : null}
      {notes.error ? (
        <p role="alert" className="text-sm text-destructive">
          {notes.error.message}
        </p>
      ) : null}
      {!notes.isLoading && rows.length === 0 ? (
        <EmptyState
          title="No invoice notes"
          description="Drafts appear here after a Godown Manager prepares one from a confirmed dispatch."
        />
      ) : (
        <ul className="divide-y divide-slate-200/80 rounded-2xl bg-white ring-1 ring-slate-200/80">
          {rows.map((row) => (
            <li key={row.id}>
              <Link
                to={`/invoices/${row.id}`}
                className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
              >
                <span>
                  <span className="block text-sm font-medium">{row.note_number}</span>
                  <span className="text-xs text-muted-foreground">
                    {row.shop_name} · {row.billed_cases} cases · {formatInr(row.grand_total)}
                  </span>
                </span>
                <StatusBadge tone={invoiceNoteStatusTone[row.status]}>
                  {invoiceNoteStatusLabel[row.status]}
                </StatusBadge>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
