import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { ExportButton } from "@/features/reports/ExportButton"
import { ReportLinks } from "@/features/reports/ReportLinks"
import { ReportSelect } from "@/features/reports/ReportControls"
import { ReportTable } from "@/features/reports/ReportTable"
import { useAuth } from "@/hooks/use-auth"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { listLotStockReport, reportKeys } from "@/lib/reports/api"

export function LotStockReportPage() {
  useDocumentTitle("Lot stock report")
  const { session } = useAuth()
  const [bucket, setBucket] = useState("")
  const [status, setStatus] = useState("")
  const [page, setPage] = useState(1)
  const filters = {
    expiry_bucket: bucket || null,
    filter_lot_status: status || null,
    page,
    page_size: 50,
  }
  const report = useQuery({
    queryKey: reportKeys.lots(session?.user.id, filters),
    queryFn: () => listLotStockReport(filters),
  })

  return (
    <section>
      <PageHeader
        title="Lot stock report"
        description="Lot-attributed carton cases only. Unknown expiry stays unknown. Approaching uses the approved 90-day warning."
        action={<ExportButton reportKind="lots" filters={{ ...filters, page: undefined, page_size: undefined }} />}
      />
      <ReportLinks />
      {report.isLoading ? <LoadingBlock label="Loading lot stock" /> : null}
      {report.error ? (
        <p role="alert" className="text-sm text-destructive">
          {report.error.message}
        </p>
      ) : null}
      <p className="mb-4 text-sm text-muted-foreground">
        Near-expiry window: {report.data?.near_expiry_warning_days ?? 90} days (UTC dates).
      </p>
      <div className="mb-4 grid gap-3 md:grid-cols-2">
        <ReportSelect
          label="Expiry bucket"
          value={bucket}
          onChange={(value) => {
            setBucket(value)
            setPage(1)
          }}
        >
          <option value="">All buckets</option>
          <option value="expired">Expired</option>
          <option value="approaching">Approaching expiry</option>
          <option value="unknown_expiry">Unknown expiry</option>
          <option value="none">None</option>
        </ReportSelect>
        <ReportSelect
          label="Lot status"
          value={status}
          onChange={(value) => {
            setStatus(value)
            setPage(1)
          }}
        >
          <option value="">All statuses</option>
          <option value="available">Available</option>
          <option value="quarantined">Quarantined</option>
          <option value="expired_blocked">Expired blocked</option>
          <option value="legacy_unattributed">Legacy unattributed</option>
        </ReportSelect>
      </div>
      {report.data ? (
        <ReportTable
          columns={["Lot", "Status", "Expiry", "Bucket", "Product", "Crate", "Cartons"]}
          emptyTitle="No lot balances"
          emptyDescription="Lot rows appear only when real lot records exist. Operational cutover is currently inactive on development."
          page={report.data.page}
          pageSize={report.data.page_size}
          total={report.data.total_count}
          onPage={setPage}
        >
          {report.data.rows.map((row) => (
            <tr key={`${row.lot_id}:${row.crate_id}`} className="border-t border-slate-100">
              <td className="px-4 py-3">{row.manufacturer_lot_code ?? row.lot_id}</td>
              <td className="px-4 py-3">{row.lot_status}</td>
              <td className="px-4 py-3">{row.expiry_date ?? "Unknown"}</td>
              <td className="px-4 py-3">{row.expiry_bucket}</td>
              <td className="px-4 py-3">
                {row.product_name}
                <span className="ml-2 text-muted-foreground">{row.product_sku}</span>
              </td>
              <td className="px-4 py-3">{row.crate_code}</td>
              <td className="px-4 py-3 text-right">{row.quantity}</td>
            </tr>
          ))}
        </ReportTable>
      ) : null}
    </section>
  )
}
