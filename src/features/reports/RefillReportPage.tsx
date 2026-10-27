import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { RefillQueueFilters } from "@/features/refill/components/RefillQueueFilters"
import {
  emptyRefillQueueFilters,
  type RefillQueueFilterState,
} from "@/features/refill/utils/queue-filters"
import {
  formatCases,
  formatRefillAcknowledgement,
  formatRefillCommunication,
  formatRefillDispatch,
  formatRefillReceivingLabel,
  formatRefillStatus,
  formatTimestamp,
  refillAcknowledgementTone,
  refillCommunicationTone,
  refillDispatchTone,
  refillStatusTone,
} from "@/features/refill/utils/labels"
import { ReportLinks } from "@/features/reports/ReportLinks"
import { ReportTable } from "@/features/reports/ReportTable"
import { useAuth } from "@/hooks/use-auth"
import { useDocumentTitle } from "@/hooks/use-document-title"
import {
  downloadReportCsv,
  reportKeys,
} from "@/lib/reports/api"
import { utcDayEndExclusive, utcDayStart } from "@/lib/reports/format"
import {
  exportStockRefillReport,
  listStockRefillOptions,
  listStockRefillReport,
} from "@/lib/refill/api"

export function RefillReportPage() {
  useDocumentTitle("Refill report")
  const { session } = useAuth()
  const [filters, setFilters] = useState<RefillQueueFilterState>(emptyRefillQueueFilters)
  const [page, setPage] = useState(1)
  const [exportMessage, setExportMessage] = useState<string | null>(null)
  const [exporting, setExporting] = useState(false)
  const options = useQuery({
    queryKey: ["refill-options"],
    queryFn: listStockRefillOptions,
  })
  const queryFilters = {
    page,
    pageSize: 50,
    status: filters.status,
    godownId: filters.godownId,
    supplierId: filters.supplierId,
    search: filters.search,
    communication: filters.communication,
    acknowledgement: filters.acknowledgement,
    dispatch: filters.dispatch,
    receiving: filters.receiving,
    createdFrom: utcDayStart(filters.createdFrom),
    createdTo: utcDayEndExclusive(filters.createdTo),
  }
  const report = useQuery({
    queryKey: reportKeys.refill(session?.user.id, queryFilters),
    queryFn: () => listStockRefillReport(queryFilters),
  })

  async function onExport() {
    setExporting(true)
    setExportMessage(null)
    try {
      const payload = await exportStockRefillReport(queryFilters)
      downloadReportCsv("refill-utc.csv", payload.csv)
      setExportMessage(
        payload.truncated
          ? `Exported ${payload.row_count} of ${payload.total_count} authorized rows.`
          : `Exported ${payload.row_count} rows.`,
      )
    } catch (error) {
      setExportMessage(error instanceof Error ? error.message : "Export failed")
    } finally {
      setExporting(false)
    }
  }

  const summary = report.data?.summary

  return (
    <section>
      <PageHeader
        title="Refill report"
        description="Authorized supplier replenishment progress. Reserved cases are not accepted stock. This report does not post inventory or close requests."
        action={
          <div className="flex flex-col items-end gap-1">
            <Button type="button" variant="outline" disabled={exporting} onClick={() => void onExport()}>
              {exporting ? "Exporting" : "Export CSV"}
            </Button>
            {exportMessage ? (
              <p role="status" className="text-xs text-muted-foreground">
                {exportMessage}
              </p>
            ) : null}
          </div>
        }
      />
      <ReportLinks />
      {report.isLoading ? <LoadingBlock label="Loading refill report" /> : null}
      {report.error ? (
        <p role="alert" className="text-sm text-destructive">
          {report.error.message}
        </p>
      ) : null}
      <RefillQueueFilters
        value={filters}
        options={options.data}
        onChange={(next) => {
          setFilters(next)
          setPage(1)
        }}
      />
      <p className="mb-4 text-sm text-muted-foreground">
        Inactive godowns remain visible for historical reporting. New operational
        refill and receiving writes still require an active assigned godown.
      </p>
      {summary ? (
        <dl className="mb-4 grid gap-3 rounded-2xl bg-card p-4 text-sm ring-1 ring-border sm:grid-cols-2 lg:grid-cols-4">
          <div>
            <dt className="text-muted-foreground">Requested</dt>
            <dd>{formatCases(summary.requested_cases)}</dd>
          </div>
          <div>
            <dt className="text-muted-foreground">Reserved (not stock)</dt>
            <dd>{formatCases(summary.reserved_cases)}</dd>
          </div>
          <div>
            <dt className="text-muted-foreground">Draft reserved</dt>
            <dd>{formatCases(summary.draft_reserved_cases)}</dd>
          </div>
          <div>
            <dt className="text-muted-foreground">Verified accepted</dt>
            <dd>{formatCases(summary.accepted_cases)}</dd>
          </div>
          <div>
            <dt className="text-muted-foreground">Outstanding</dt>
            <dd>{formatCases(summary.outstanding_cases)}</dd>
          </div>
          <div>
            <dt className="text-muted-foreground">Pending verification</dt>
            <dd>{formatCases(summary.pending_receipt_cases)}</dd>
          </div>
          <div>
            <dt className="text-muted-foreground">Fully received requests</dt>
            <dd>{summary.fully_received_requests}</dd>
          </div>
        </dl>
      ) : null}
      {report.data ? (
        <ReportTable
          columns={[
            "Request",
            "Approval",
            "Supplier",
            "Godown",
            "Communication",
            "Acknowledgement",
            "Dispatch",
            "Receiving",
            "Requested",
            "Reserved",
            "Verified",
            "Outstanding",
            "Created",
          ]}
          emptyTitle="No refill rows"
          emptyDescription="Authorized refill requests for your godowns will appear here."
          page={report.data.page}
          pageSize={report.data.page_size}
          total={report.data.total_count}
          onPage={setPage}
        >
          {report.data.rows.map((row) => (
            <tr key={row.id} className="border-t border-slate-100">
              <td className="px-4 py-3">
                <Link className="font-medium underline-offset-2 hover:underline" to={`/refill/${row.id}`}>
                  {row.request_number}
                </Link>
              </td>
              <td className="px-4 py-3">
                <StatusBadge tone={refillStatusTone[row.status]}>
                  {formatRefillStatus(row.status)}
                </StatusBadge>
              </td>
              <td className="px-4 py-3">{row.supplier_name}</td>
              <td className="px-4 py-3">
                {row.godown_name}
                {row.godown_active ? "" : " (inactive)"}
              </td>
              <td className="px-4 py-3">
                <StatusBadge tone={refillCommunicationTone[row.communication_status ?? "not_sent"]}>
                  {formatRefillCommunication(row.communication_status ?? "not_sent")}
                </StatusBadge>
              </td>
              <td className="px-4 py-3">
                <StatusBadge tone={refillAcknowledgementTone[row.acknowledgement_status ?? "none"]}>
                  {formatRefillAcknowledgement(row.acknowledgement_status ?? "none")}
                </StatusBadge>
              </td>
              <td className="px-4 py-3">
                <StatusBadge tone={refillDispatchTone[row.dispatch_status ?? "not_recorded"]}>
                  {formatRefillDispatch(row.dispatch_status ?? "not_recorded")}
                </StatusBadge>
              </td>
              <td className="px-4 py-3">
                {formatRefillReceivingLabel(row.completion_label ?? "not_started")}
              </td>
              <td className="px-4 py-3 text-right">{row.total_requested_cases}</td>
              <td className="px-4 py-3 text-right">{row.reserved_cases ?? 0}</td>
              <td className="px-4 py-3 text-right">{row.accepted_cases ?? 0}</td>
              <td className="px-4 py-3 text-right">{row.outstanding_cases ?? 0}</td>
              <td className="px-4 py-3">{formatTimestamp(row.created_at)}</td>
            </tr>
          ))}
        </ReportTable>
      ) : null}
    </section>
  )
}
