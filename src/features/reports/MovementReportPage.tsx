import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { ExportButton } from "@/features/reports/ExportButton"
import { BranchFilterNote, ReportBranchSelect } from "@/features/reports/BranchFilterNote"
import { ReportDateField, ReportSelect } from "@/features/reports/ReportControls"
import { ReportLinks } from "@/features/reports/ReportLinks"
import { ReportTable } from "@/features/reports/ReportTable"
import { useReportBranchFilter } from "@/features/reports/use-report-branch-filter"
import { formatUtc, utcDayEndExclusive, utcDayStart } from "@/lib/reports/format"
import { useAuth } from "@/hooks/use-auth"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { listStockMovementReport, reportKeys } from "@/lib/reports/api"

export function MovementReportPage() {
  useDocumentTitle("Stock movement report")
  const { session } = useAuth()
  const { branchId, setBranchId, branches } = useReportBranchFilter()
  const [movementType, setMovementType] = useState("")
  const [fromDate, setFromDate] = useState("")
  const [toDate, setToDate] = useState("")
  const [page, setPage] = useState(1)
  const filters = {
    movement_type: movementType || null,
    posted_from: utcDayStart(fromDate),
    posted_to: utcDayEndExclusive(toDate),
    filter_branch: branchId || null,
    page,
    page_size: 50,
  }
  const report = useQuery({
    queryKey: reportKeys.movements(session?.user.id, filters),
    queryFn: () => listStockMovementReport(filters),
  })
  const summary = report.data?.summary

  return (
    <section>
      <PageHeader
        title="Stock movement report"
        description="One row per posted document. Transfers are counted once. Current on-hand is not the sum of this list."
        action={<ExportButton reportKind="movements" filters={{ ...filters, page: undefined, page_size: undefined }} />}
      />
      <ReportLinks />
      {report.isLoading ? <LoadingBlock label="Loading movements" /> : null}
      {report.error ? (
        <p role="alert" className="text-sm text-destructive">
          {report.error.message}
        </p>
      ) : null}
      <div className="mb-4 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        <ReportBranchSelect
          value={branchId}
          onChange={(value) => {
            setBranchId(value)
            setPage(1)
          }}
          branches={branches}
        />
        <ReportSelect
          label="Movement type"
          value={movementType}
          onChange={(value) => {
            setMovementType(value)
            setPage(1)
          }}
        >
          <option value="">All types</option>
          <option value="OPENING_STOCK">Opening stock</option>
          <option value="RECEIPT">Receipt</option>
          <option value="CRATE_TRANSFER">Transfer</option>
          <option value="ADJUSTMENT">Adjustment</option>
          <option value="DISPATCH">Dispatch</option>
        </ReportSelect>
        <ReportDateField
          label="From (UTC)"
          value={fromDate}
          onChange={(value) => {
            setFromDate(value)
            setPage(1)
          }}
        />
        <ReportDateField
          label="To (UTC, inclusive calendar day)"
          value={toDate}
          onChange={(value) => {
            setToDate(value)
            setPage(1)
          }}
        />
      </div>
      <div className="mb-4">
        <BranchFilterNote />
      </div>
      {summary ? (
        <dl className="mb-4 grid gap-3 text-sm md:grid-cols-5">
          <SummaryChip label="Opening" value={summary.opening_cartons} />
          <SummaryChip label="Receipts" value={summary.receipt_cartons} />
          <SummaryChip label="Transfers" value={summary.transfer_cartons} />
          <SummaryChip label="Adjustments" value={summary.adjustment_cartons} />
          <SummaryChip label="Dispatch" value={summary.dispatch_cartons} />
        </dl>
      ) : null}
      {report.data ? (
        <ReportTable
          columns={["Reference", "Type", "Product", "Cartons", "Source", "Destination", "Actor", "Posted UTC"]}
          emptyTitle="No movements"
          emptyDescription="Posted stock documents in the selected UTC window will appear here."
          page={report.data.page}
          pageSize={report.data.page_size}
          total={report.data.total_count}
          onPage={setPage}
        >
          {report.data.rows.map((row) => (
            <tr key={row.transaction_id} className="border-t border-slate-100">
              <td className="px-4 py-3 font-medium">{row.reference_number}</td>
              <td className="px-4 py-3">{row.transaction_type}</td>
              <td className="px-4 py-3">
                {row.product_name}
                <span className="ml-2 text-muted-foreground">{row.product_sku}</span>
              </td>
              <td className="px-4 py-3 text-right">{row.quantity}</td>
              <td className="px-4 py-3">{row.source_crate_code ?? "—"}</td>
              <td className="px-4 py-3">{row.destination_crate_code ?? "—"}</td>
              <td className="px-4 py-3">{row.actor_name ?? "Unknown"}</td>
              <td className="px-4 py-3">{formatUtc(row.posted_at)}</td>
            </tr>
          ))}
        </ReportTable>
      ) : null}
    </section>
  )
}

function SummaryChip({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-xl bg-white px-4 py-3 ring-1 ring-slate-200">
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="mt-1 font-semibold">{value ?? 0}</dd>
    </div>
  )
}
