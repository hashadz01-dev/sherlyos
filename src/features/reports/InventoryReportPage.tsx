import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { ExportButton } from "@/features/reports/ExportButton"
import { ReportLinks } from "@/features/reports/ReportLinks"
import { BranchFilterNote, ReportBranchSelect } from "@/features/reports/BranchFilterNote"
import { ReportSelect } from "@/features/reports/ReportControls"
import { ReportTable } from "@/features/reports/ReportTable"
import { useReportBranchFilter } from "@/features/reports/use-report-branch-filter"
import { useAuth } from "@/hooks/use-auth"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { listInventoryReport, reportKeys } from "@/lib/reports/api"

export function InventoryReportPage() {
  useDocumentTitle("Inventory report")
  const { session } = useAuth()
  const { branchId, setBranchId, branches } = useReportBranchFilter()
  const [grain, setGrain] = useState("crate")
  const [page, setPage] = useState(1)
  const filters = {
    grain,
    filter_branch: branchId || null,
    page,
    page_size: 50,
  }
  const report = useQuery({
    queryKey: reportKeys.inventory(session?.user.id, filters),
    queryFn: () => listInventoryReport(filters),
  })

  return (
    <section>
      <PageHeader
        title="Inventory report"
        description="Aggregate crate balances. This is not available-to-pick while lot-aware allocation is inactive."
        action={<ExportButton reportKind="inventory" filters={{ ...filters, page: undefined, page_size: undefined }} />}
      />
      <ReportLinks />
      {report.isLoading ? <LoadingBlock label="Loading inventory report" /> : null}
      {report.error ? (
        <p role="alert" className="text-sm text-destructive">
          {report.error.message}
        </p>
      ) : null}
      <div className="mb-4 grid gap-3 md:grid-cols-2">
        <ReportSelect
          label="Grain"
          value={grain}
          onChange={(value) => {
            setGrain(value)
            setPage(1)
          }}
        >
          <option value="crate">Crate and product</option>
          <option value="zone">Zone</option>
          <option value="godown">Godown</option>
          <option value="product">Product</option>
        </ReportSelect>
        <ReportBranchSelect
          value={branchId}
          onChange={(value) => {
            setBranchId(value)
            setPage(1)
          }}
          branches={branches}
        />
      </div>
      <div className="mb-4">
        <BranchFilterNote />
      </div>
      {report.data ? (
        <ReportTable
          columns={["Godown", "Zone", "Crate", "Product", "Cartons"]}
          emptyTitle="No inventory rows"
          emptyDescription="Aggregate balances for godowns you can work at will appear here."
          page={report.data.page}
          pageSize={report.data.page_size}
          total={report.data.total_count}
          onPage={setPage}
        >
          {report.data.rows.map((row) => (
            <tr key={row.row_key} className="border-t border-slate-100">
              <td className="px-4 py-3">{row.branch_name}</td>
              <td className="px-4 py-3">{row.zone_code ?? "—"}</td>
              <td className="px-4 py-3">{row.crate_code ?? "—"}</td>
              <td className="px-4 py-3">
                {row.product_name ?? "—"}
                {row.product_sku ? (
                  <span className="ml-2 text-muted-foreground">{row.product_sku}</span>
                ) : null}
              </td>
              <td className="px-4 py-3 text-right">{row.quantity}</td>
            </tr>
          ))}
        </ReportTable>
      ) : null}
    </section>
  )
}
