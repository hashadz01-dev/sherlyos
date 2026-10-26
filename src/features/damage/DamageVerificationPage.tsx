import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { Button } from "@/components/ui/button"
import {
  DamageReportFilters,
  type DamageFilterState,
} from "@/features/damage/components/DamageReportFilters"
import { DamageReadinessBanner } from "@/features/damage/components/DamageReadinessBanner"
import { useDamageAccess } from "@/features/damage/hooks/use-damage-access"
import {
  formatCases,
  formatDamageScenario,
  formatDate,
  sourceReferenceLabel,
} from "@/features/damage/utils/labels"
import { useStockLocations } from "@/features/inventory/location-options"
import { useAuth } from "@/hooks/use-auth"
import { useDocumentTitle } from "@/hooks/use-document-title"
import {
  getDamageStockHoldReadyStatus,
  listDamageReports,
  type DamageReportSummary,
} from "@/lib/damage/api"
import {
  formatVerificationQueueState,
  verificationQueueState,
} from "@/lib/damage/rules"

const emptyFilters: DamageFilterState = {
  search: "",
  status: "all",
  scenario: "all",
  godownId: "all",
  fromDate: "",
  toDate: "",
}

function queueLabel(row: DamageReportSummary, currentUserId?: string) {
  return formatVerificationQueueState(
    verificationQueueState({
      status: row.status,
      scenario: row.scenario,
      reporterUserId: row.reporter_user_id,
      currentUserId,
      hasFinalizedEvidence: row.has_finalized_evidence,
      isolatedCases: row.active_hold_cases,
      reportedCases: row.total_cases,
    }),
  )
}

export function DamageVerificationPage() {
  useDocumentTitle("Damage verification")
  const access = useDamageAccess()
  const { session } = useAuth()
  const userId = session?.user.id
  const locations = useStockLocations()
  const [filters, setFilters] = useState<DamageFilterState>(emptyFilters)
  const [page, setPage] = useState(1)
  const pageSize = 25

  const ready = useQuery({
    queryKey: ["damage-ready-status"],
    queryFn: getDamageStockHoldReadyStatus,
    enabled: access.canViewVerification,
  })

  const list = useQuery({
    queryKey: ["damage-verification", page, pageSize, filters],
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
    enabled: access.canViewVerification,
  })

  const rows = list.data?.items ?? []
  const total = list.data?.total ?? 0
  const totalPages = Math.max(1, Math.ceil(total / pageSize))

  return (
    <section className="min-w-0">
      <PageHeader
        title="Damage verification"
        description="Server-filtered submitted reports. Evidence and isolation facts come from the authorized list RPC."
        action={
          <div className="flex flex-wrap gap-2">
            <Button asChild variant="outline">
              <Link to="/damage">Dashboard</Link>
            </Button>
            <Button asChild variant="outline">
              <Link to="/damage/reports">All reports</Link>
            </Button>
          </div>
        }
      />

      {ready.data ? (
        <div className="mb-4">
          <DamageReadinessBanner stockHoldReady={ready.data.stock_hold_ready} />
        </div>
      ) : null}

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

      {list.isLoading ? (
        <LoadingBlock label="Loading verification queue" />
      ) : null}
      {list.error ? (
        <p role="alert" className="text-sm text-destructive">
          {list.error.message}
        </p>
      ) : null}

      {list.data && rows.length === 0 ? (
        <EmptyState
          title="No reports in this queue"
          description="No authorized reports match the current filters."
        />
      ) : null}

      <div className="hidden overflow-x-auto md:block">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b text-left text-muted-foreground">
              <th className="py-2 pr-3">Report</th>
              <th className="py-2 pr-3">Scenario</th>
              <th className="py-2 pr-3">Source</th>
              <th className="py-2 pr-3">Godown</th>
              <th className="py-2 pr-3">Reporter</th>
              <th className="py-2 pr-3">Cases</th>
              <th className="py-2 pr-3">Submitted</th>
              <th className="py-2 pr-3">Evidence</th>
              <th className="py-2 pr-3">Isolation</th>
              <th className="py-2 pr-3">Eligibility</th>
              <th className="py-2 pr-3">Action</th>
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
                <td className="py-2 pr-3">
                  {row.godown_name}
                  {row.godown_active === false ? " (inactive)" : ""}
                </td>
                <td className="py-2 pr-3">{row.reporter_name ?? "—"}</td>
                <td className="py-2 pr-3">{formatCases(row.total_cases)}</td>
                <td className="py-2 pr-3">{formatDate(row.created_at)}</td>
                <td className="py-2 pr-3">
                  {row.has_finalized_evidence
                    ? `${row.finalized_evidence_count ?? 1} finalized`
                    : "Missing"}
                </td>
                <td className="py-2 pr-3">
                  {formatCases(row.active_hold_cases)}
                </td>
                <td className="py-2 pr-3">{queueLabel(row, userId)}</td>
                <td className="py-2 pr-3">
                  <Button asChild variant="outline" size="sm">
                    <Link to={`/damage/${row.id}`}>Inspect</Link>
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="grid gap-3 md:hidden">
        {rows.map((row) => (
          <Link
            key={row.id}
            to={`/damage/${row.id}`}
            className="block rounded-2xl bg-card p-4 ring-1 ring-border"
          >
            <p className="font-medium">{row.report_number}</p>
            <p className="text-sm text-muted-foreground">
              {formatDamageScenario(row.scenario)} · {queueLabel(row, userId)}
            </p>
          </Link>
        ))}
      </div>

      {list.data && total > 0 ? (
        <div className="mt-4 flex items-center justify-between gap-3">
          <p className="text-sm text-muted-foreground">
            Page {page} of {totalPages} · {total} report
            {total === 1 ? "" : "s"}
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
