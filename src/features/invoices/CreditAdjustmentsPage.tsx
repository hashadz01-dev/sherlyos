import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { FilterSelect, SearchField } from "@/features/masters/MasterControls"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { invoiceKeys, listCreditAdjustments } from "@/lib/invoices/api"
import {
  CREDIT_ADJUSTMENT_WATERMARK,
  formatInr,
} from "@/lib/invoices/rules"
import { matchesSearch } from "@/lib/masters/filters"

export function CreditAdjustmentsPage() {
  useDocumentTitle("Credit adjustments")
  const [search, setSearch] = useState("")
  const [status, setStatus] = useState("all")

  const rowsQuery = useQuery({
    queryKey: invoiceKeys.creditAdjustments(status, "all"),
    queryFn: () => listCreditAdjustments({ status }),
  })
  const rows = (rowsQuery.data ?? []).filter((row) =>
    matchesSearch(search, [
      row.adjustment_number,
      row.shop_name ?? "",
      row.return_number ?? "",
      row.invoice_note_number ?? "",
      row.status,
    ]),
  )

  return (
    <section className="min-w-0">
      <PageHeader
        title="Credit adjustments"
        description="Internal financial previews from verified customer returns. These are not GST credit notes."
      />
      <p
        role="note"
        className="mb-4 rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-900 ring-1 ring-amber-200"
      >
        {CREDIT_ADJUSTMENT_WATERMARK}. Viewing a preview does not issue a credit note, post
        stock, or allocate a legal number.
      </p>

      <div className="mb-4 grid gap-3 sm:grid-cols-2">
        <SearchField label="Search credit adjustments" value={search} onChange={setSearch} />
        <FilterSelect label="Status" value={status} onChange={setStatus}>
          <option value="all">All statuses</option>
          <option value="preview">Preview</option>
          <option value="blocked">Blocked</option>
        </FilterSelect>
      </div>

      {rowsQuery.isLoading ? <LoadingBlock label="Loading credit adjustments" /> : null}
      {rowsQuery.error ? (
        <p role="alert" className="text-sm text-destructive">
          {rowsQuery.error.message}
        </p>
      ) : null}
      {!rowsQuery.isLoading && rows.length === 0 ? (
        <EmptyState
          title="No credit-adjustment previews"
          description="Accounts can prepare a preview from a posted or closed-missing delivery return on a reviewed invoice note."
        />
      ) : (
        <ul className="divide-y divide-slate-200/80 rounded-2xl bg-white ring-1 ring-slate-200/80">
          {rows.map((row) => (
            <li key={row.id}>
              <Link
                to={`/credit-adjustments/${row.id}`}
                className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
              >
                <span>
                  <span className="block text-sm font-medium">{row.adjustment_number}</span>
                  <span className="text-xs text-muted-foreground">
                    {row.shop_name} · {row.credited_cases} cases · {formatInr(row.adjustment_total)}
                  </span>
                </span>
                <StatusBadge tone={row.status === "blocked" ? "warning" : "info"}>
                  {row.status}
                </StatusBadge>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
