import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { ExportButton } from "@/features/reports/ExportButton"
import { BranchFilterNote, ReportBranchSelect } from "@/features/reports/BranchFilterNote"
import { ReportLinks } from "@/features/reports/ReportLinks"
import { ReportTable } from "@/features/reports/ReportTable"
import { useReportBranchFilter } from "@/features/reports/use-report-branch-filter"
import { formatUtc } from "@/lib/reports/format"
import { useAuth } from "@/hooks/use-auth"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { listOperationsExceptions, reportKeys } from "@/lib/reports/api"

const kindLabel: Record<string, string> = {
  picking_blocked: "Picking blocked",
  delivery_exception: "Delivery exception",
  pending_physical_return: "Pending physical return",
  unclassified_product: "Unclassified product",
  legacy_unattributed_lot: "Legacy unattributed lot",
  quarantined_lot: "Quarantined lot",
  expired_lot: "Expired lot",
  pending_adjustment: "Pending adjustment",
}

export function ExceptionsReportPage() {
  useDocumentTitle("Operational exceptions")
  const { session } = useAuth()
  const { branchId, setBranchId, branches } = useReportBranchFilter()
  const [page, setPage] = useState(1)
  const filters = { page, page_size: 50, filter_branch: branchId || null }
  const report = useQuery({
    queryKey: reportKeys.exceptions(session?.user.id, filters),
    queryFn: () => listOperationsExceptions(filters),
  })

  return (
    <section>
      <PageHeader
        title="Operational exceptions"
        description="Existing workflow owners. This screen does not resolve exceptions or change stock."
        action={<ExportButton reportKind="exceptions" filters={{ filter_branch: filters.filter_branch }} />}
      />
      <ReportLinks />
      {report.isLoading ? <LoadingBlock label="Loading exceptions" /> : null}
      {report.error ? (
        <p role="alert" className="text-sm text-destructive">
          {report.error.message}
        </p>
      ) : null}
      <div className="mb-4 max-w-xs">
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
          columns={["Kind", "Item", "Detail", "Opened"]}
          emptyTitle="No open exceptions"
          emptyDescription="Picking blockers, failed deliveries, unclassified products, and open adjustments appear here when they exist."
          page={report.data.page}
          pageSize={report.data.page_size}
          total={report.data.total_count}
          onPage={setPage}
        >
          {report.data.rows.map((row) => (
            <tr key={`${row.kind}:${row.item_id}`} className="border-t border-slate-100">
              <td className="px-4 py-3">{kindLabel[row.kind] ?? row.kind}</td>
              <td className="px-4 py-3">
                <Link className="underline" to={row.href}>
                  {row.label}
                </Link>
              </td>
              <td className="px-4 py-3">{row.detail ?? "—"}</td>
              <td className="px-4 py-3">{formatUtc(row.occurred_at)}</td>
            </tr>
          ))}
        </ReportTable>
      ) : null}
    </section>
  )
}
