import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { ExportButton } from "@/features/reports/ExportButton"
import { BranchFilterNote, ReportBranchSelect } from "@/features/reports/BranchFilterNote"
import { ReportSelect } from "@/features/reports/ReportControls"
import { ReportLinks } from "@/features/reports/ReportLinks"
import { ReportTable } from "@/features/reports/ReportTable"
import { useReportBranchFilter } from "@/features/reports/use-report-branch-filter"
import { formatUtc } from "@/lib/reports/format"
import { useAuth } from "@/hooks/use-auth"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { listOrderPickingReport, reportKeys } from "@/lib/reports/api"

export function OrderPickingReportPage() {
  useDocumentTitle("Orders and packing report")
  const { session } = useAuth()
  const { branchId, setBranchId, branches } = useReportBranchFilter()
  const [orderStatus, setOrderStatus] = useState("")
  const [pickingStatus, setPickingStatus] = useState("")
  const [page, setPage] = useState(1)
  const filters = {
    order_status: orderStatus || null,
    picking_status: pickingStatus || null,
    filter_branch: branchId || null,
    page,
    page_size: 50,
  }
  const report = useQuery({
    queryKey: reportKeys.orders(session?.user.id, filters),
    queryFn: () => listOrderPickingReport(filters),
  })

  return (
    <section>
      <PageHeader
        title="Orders and packing report"
        description="Stock dispatched is true only after a consumed DISPATCH transaction. Ready-for-dispatch packing is not a stock movement."
        action={<ExportButton reportKind="orders_picking" filters={{ ...filters, page: undefined, page_size: undefined }} />}
      />
      <ReportLinks />
      {report.isLoading ? <LoadingBlock label="Loading orders and packing" /> : null}
      {report.error ? (
        <p role="alert" className="text-sm text-destructive">
          {report.error.message}
        </p>
      ) : null}
      <div className="mb-4 grid gap-3 md:grid-cols-3">
        <ReportBranchSelect
          value={branchId}
          onChange={(value) => {
            setBranchId(value)
            setPage(1)
          }}
          branches={branches}
        />
        <ReportSelect
          label="Order status"
          value={orderStatus}
          onChange={(value) => {
            setOrderStatus(value)
            setPage(1)
          }}
        >
          <option value="">All order statuses</option>
          <option value="draft">Draft</option>
          <option value="submitted">Submitted</option>
          <option value="held">Held</option>
          <option value="verified">Verified</option>
          <option value="cancelled">Cancelled</option>
        </ReportSelect>
        <ReportSelect
          label="Packing status"
          value={pickingStatus}
          onChange={(value) => {
            setPickingStatus(value)
            setPage(1)
          }}
        >
          <option value="">All packing statuses</option>
          <option value="none">None</option>
          <option value="allocated">Allocated</option>
          <option value="picking">Packing</option>
          <option value="picked">Picked</option>
          <option value="ready_for_dispatch">Ready for dispatch</option>
          <option value="blocked">Blocked</option>
          <option value="cancelled">Cancelled</option>
        </ReportSelect>
      </div>
      <div className="mb-4">
        <BranchFilterNote />
      </div>
      {report.data ? (
        <ReportTable
          columns={[
            "Order",
            "Status",
            "Shop",
            "Age (days)",
            "Packing",
            "Reserved",
            "Stock dispatched",
          ]}
          emptyTitle="No orders"
          emptyDescription="Orders you are allowed to view will appear here."
          page={report.data.page}
          pageSize={report.data.page_size}
          total={report.data.total_count}
          onPage={setPage}
        >
          {report.data.rows.map((row) => (
            <tr key={row.order_id} className="border-t border-slate-100">
              <td className="px-4 py-3 font-medium">{row.order_number}</td>
              <td className="px-4 py-3">{row.order_status}</td>
              <td className="px-4 py-3">{row.shop_name}</td>
              <td className="px-4 py-3">{row.age_days}</td>
              <td className="px-4 py-3">{row.picking_status ?? "none"}</td>
              <td className="px-4 py-3 text-right">{row.active_reserved_cases}</td>
              <td className="px-4 py-3">{row.stock_dispatched ? "Yes" : "No"}</td>
            </tr>
          ))}
        </ReportTable>
      ) : null}
      {report.data?.rows[0] ? (
        <p className="mt-2 text-xs text-muted-foreground">Created {formatUtc(report.data.rows[0].created_at)} UTC.</p>
      ) : null}
    </section>
  )
}
