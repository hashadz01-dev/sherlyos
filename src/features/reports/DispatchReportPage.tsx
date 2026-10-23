import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { ExportButton } from "@/features/reports/ExportButton"
import { ReportSelect } from "@/features/reports/ReportControls"
import { ReportLinks } from "@/features/reports/ReportLinks"
import { ReportTable } from "@/features/reports/ReportTable"
import { formatUtc } from "@/lib/reports/format"
import { useAuth } from "@/hooks/use-auth"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { listDispatchDeliveryReport, reportKeys } from "@/lib/reports/api"

export function DispatchReportPage() {
  useDocumentTitle("Dispatch and delivery report")
  const { session } = useAuth()
  const [status, setStatus] = useState("")
  const [page, setPage] = useState(1)
  const filters = {
    dispatch_status: status || null,
    page,
    page_size: 50,
  }
  const report = useQuery({
    queryKey: reportKeys.dispatch(session?.user.id, filters),
    queryFn: () => listDispatchDeliveryReport(filters),
  })

  return (
    <section>
      <PageHeader
        title="Dispatch and delivery report"
        description="Dispatched cartons come from the DISPATCH ledger. Preparing documents are not stock dispatched. Delivery-note acknowledgement is paperwork, not customer POD."
        action={<ExportButton reportKind="dispatch" filters={{ ...filters, page: undefined, page_size: undefined }} />}
      />
      <ReportLinks />
      {report.isLoading ? <LoadingBlock label="Loading dispatch report" /> : null}
      {report.error ? (
        <p role="alert" className="text-sm text-destructive">
          {report.error.message}
        </p>
      ) : null}
      <div className="mb-4 max-w-xs">
        <ReportSelect
          label="Dispatch status"
          value={status}
          onChange={(value) => {
            setStatus(value)
            setPage(1)
          }}
        >
          <option value="">All statuses</option>
          <option value="preparing">Preparing</option>
          <option value="dispatched">Dispatched</option>
          <option value="in_transit">In transit</option>
          <option value="delivered">Delivered</option>
          <option value="exception">Exception</option>
          <option value="cancelled">Cancelled</option>
        </ReportSelect>
      </div>
      {report.data ? (
        <ReportTable
          columns={[
            "Request",
            "Status",
            "Consumed",
            "Cartons",
            "Order",
            "Assignee",
            "Turnaround",
            "Created UTC",
          ]}
          emptyTitle="No dispatch rows"
          emptyDescription="Dispatch documents in your authorized branches will appear here."
          page={report.data.page}
          pageSize={report.data.page_size}
          total={report.data.total_count}
          onPage={setPage}
        >
          {report.data.rows.map((row) => (
            <tr key={row.dispatch_id} className="border-t border-slate-100">
              <td className="px-4 py-3 font-medium">{row.request_number}</td>
              <td className="px-4 py-3">{row.status}</td>
              <td className="px-4 py-3">{row.stock_consumed ? "Yes" : "No"}</td>
              <td className="px-4 py-3 text-right">{row.dispatched_cartons}</td>
              <td className="px-4 py-3">{row.order_number}</td>
              <td className="px-4 py-3">{row.assigned_to_name ?? "—"}</td>
              <td className="px-4 py-3">
                {row.turnaround_seconds == null ? "—" : `${Math.round(row.turnaround_seconds / 60)} min`}
              </td>
              <td className="px-4 py-3">{formatUtc(row.created_at)}</td>
            </tr>
          ))}
        </ReportTable>
      ) : null}
    </section>
  )
}
