import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import {
  DamageReportFilters,
  type DamageFilterState,
} from "@/features/damage/components/DamageReportFilters"
import { useDamageAccess } from "@/features/damage/hooks/use-damage-access"
import {
  damageStatusTone,
  formatCases,
  formatDamageScenario,
  formatDamageStatus,
  formatDate,
  sourceReferenceLabel,
} from "@/features/damage/utils/labels"
import { useStockLocations } from "@/features/inventory/location-options"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { listDamageReports, type DamageReportSummary } from "@/lib/damage/api"
import type { DamageStatus } from "@/lib/damage/rules"

const emptyFilters: DamageFilterState = {
  search: "",
  status: "all",
  scenario: "all",
  godownId: "all",
  fromDate: "",
  toDate: "",
}

function ReportCard({ row }: { row: DamageReportSummary }) {
  return (
    <Link
      to={`/damage/${row.id}`}
      className="block rounded-2xl bg-card p-4 ring-1 ring-border"
    >
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-medium">{row.report_number}</p>
          <p className="text-sm text-muted-foreground">
            {formatDamageScenario(row.scenario)} · {row.godown_name}
          </p>
        </div>
        <StatusBadge tone={damageStatusTone[row.status]}>
          {formatDamageStatus(row.status)}
        </StatusBadge>
      </div>
      <dl className="mt-3 grid grid-cols-2 gap-2 text-sm">
        <div>
          <dt className="text-muted-foreground">Reporter</dt>
          <dd>{row.reporter_name ?? "—"}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Date</dt>
          <dd>{formatDate(row.created_at)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Affected</dt>
          <dd>{formatCases(row.total_cases)}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Source</dt>
          <dd>{sourceReferenceLabel(row)}</dd>
        </div>
      </dl>
    </Link>
  )
}

export function DamageReportsPage() {
  useDocumentTitle("Damage reports")
  const access = useDamageAccess()
  const locations = useStockLocations()
  const [filters, setFilters] = useState<DamageFilterState>(emptyFilters)
  const [page, setPage] = useState(1)
  const pageSize = 25

  const list = useQuery({
    queryKey: [
      "damage-reports",
      page,
      pageSize,
      filters.status,
      filters.scenario,
      filters.godownId,
      filters.search,
      filters.fromDate,
      filters.toDate,
    ],
    queryFn: () =>
      listDamageReports({
        page,
        pageSize,
        targetGodown: filters.godownId === "all" ? null : filters.godownId,
        status: filters.status === "all" ? null : filters.status,
        scenario: filters.scenario === "all" ? null : filters.scenario,
        search: filters.search.trim() || null,
        fromDate: filters.fromDate || null,
        toDate: filters.toDate || null,
      }),
    enabled: access.canOpenDamage,
  })

  const rows = list.data?.items ?? []
  const total = list.data?.total ?? 0
  const totalPages = Math.max(1, Math.ceil(total / pageSize))

  return (
    <section className="min-w-0">
      <PageHeader
        title="Damage reports"
        description="Server-filtered damage history for godowns and transit assignments you are authorized to see."
        action={
          <div className="flex flex-wrap gap-2">
            {access.canCreate ? (
              <Button asChild>
                <Link to="/damage/new">New report</Link>
              </Button>
            ) : null}
            <Button asChild variant="outline">
              <Link to="/damage">Dashboard</Link>
            </Button>
            {access.canViewQuarantine ? (
              <Button asChild variant="outline">
                <Link to="/damage/quarantine">Quarantine</Link>
              </Button>
            ) : null}
          </div>
        }
      />

      <DamageReportFilters
        value={filters}
        onChange={(next) => {
          setFilters(next)
          setPage(1)
        }}
        godowns={(locations.branches.data ?? []).map((branch) => ({
          id: branch.id,
          name: branch.name,
        }))}
        onClear={() => {
          setFilters(emptyFilters)
          setPage(1)
        }}
        onRefresh={() => void list.refetch()}
      />

      {list.isLoading ? <LoadingBlock label="Loading damage reports" /> : null}
      {list.error ? (
        <p role="alert" className="text-sm text-destructive">
          {list.error.message}
        </p>
      ) : null}

      {list.data && rows.length === 0 ? (
        <EmptyState
          title="No damage reports"
          description="No authorized reports match the current filters."
        />
      ) : null}

      <div className="grid gap-3 md:hidden">
        {rows.map((row) => (
          <ReportCard key={row.id} row={row} />
        ))}
      </div>

      <div className="hidden overflow-x-auto md:block">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b text-left text-muted-foreground">
              <th className="py-2 pr-3">Report</th>
              <th className="py-2 pr-3">Scenario</th>
              <th className="py-2 pr-3">Source</th>
              <th className="py-2 pr-3">Godown</th>
              <th className="py-2 pr-3">Reporter</th>
              <th className="py-2 pr-3">Date</th>
              <th className="py-2 pr-3">Status</th>
              <th className="py-2 pr-3">Cases</th>
              <th className="py-2 pr-3">Holds</th>
              <th className="py-2 pr-3">Exceptional</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.id} className="border-b last:border-0">
                <td className="py-2 pr-3">
                  <Link
                    className="font-medium underline-offset-2 hover:underline"
                    to={`/damage/${row.id}`}
                  >
                    {row.report_number}
                  </Link>
                </td>
                <td className="py-2 pr-3">
                  {formatDamageScenario(row.scenario)}
                </td>
                <td className="py-2 pr-3">{sourceReferenceLabel(row)}</td>
                <td className="py-2 pr-3">{row.godown_name}</td>
                <td className="py-2 pr-3">{row.reporter_name ?? "—"}</td>
                <td className="py-2 pr-3">{formatDate(row.created_at)}</td>
                <td className="py-2 pr-3">
                  <StatusBadge
                    tone={damageStatusTone[row.status as DamageStatus]}
                  >
                    {formatDamageStatus(row.status)}
                  </StatusBadge>
                </td>
                <td className="py-2 pr-3">{formatCases(row.total_cases)}</td>
                <td className="py-2 pr-3">
                  {formatCases(row.active_hold_cases)}
                </td>
                <td className="py-2 pr-3">
                  {row.exceptional_open ? "Open" : "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {list.data && total > 0 ? (
        <div className="mt-4 flex items-center justify-between gap-3">
          <p className="text-sm text-muted-foreground">
            Page {page} of {totalPages} · {total} report{total === 1 ? "" : "s"}
          </p>
          <div className="flex gap-2">
            <Button
              type="button"
              variant="outline"
              disabled={page <= 1}
              onClick={() => setPage((current) => Math.max(1, current - 1))}
            >
              Previous
            </Button>
            <Button
              type="button"
              variant="outline"
              disabled={page >= totalPages}
              onClick={() => setPage((current) => current + 1)}
            >
              Next
            </Button>
          </div>
        </div>
      ) : null}
    </section>
  )
}
