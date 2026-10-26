import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { DamageReadinessBanner } from "@/features/damage/components/DamageReadinessBanner"
import { useDamageAccess } from "@/features/damage/hooks/use-damage-access"
import {
  formatCases,
  formatDamageScenario,
  formatDate,
} from "@/features/damage/utils/labels"
import { useStockLocations } from "@/features/inventory/location-options"
import { useDocumentTitle } from "@/hooks/use-document-title"
import {
  getDamageStockHoldReadyStatus,
  listExceptionalDamageRequests,
} from "@/lib/damage/api"
import {
  exceptionalDispositionKinds,
  formatExceptionalKind,
  formatExceptionalStatus,
} from "@/lib/damage/rules"

type ExceptionalFilterState = {
  search: string
  status: string
  kind: string
  scenario: string
  godownId: string
  fromDate: string
  toDate: string
}

const emptyFilters: ExceptionalFilterState = {
  search: "",
  status: "all",
  kind: "all",
  scenario: "all",
  godownId: "all",
  fromDate: "",
  toDate: "",
}

export function DamageExceptionalApprovalsPage() {
  useDocumentTitle("Exceptional approvals")
  const access = useDamageAccess()
  const locations = useStockLocations()
  const [filters, setFilters] = useState<ExceptionalFilterState>(emptyFilters)
  const [page, setPage] = useState(1)
  const pageSize = 25

  const ready = useQuery({
    queryKey: ["damage-ready-status"],
    queryFn: getDamageStockHoldReadyStatus,
    enabled: access.canViewExceptionalQueue,
  })

  const list = useQuery({
    queryKey: ["damage-exceptional", page, pageSize, filters],
    queryFn: () =>
      listExceptionalDamageRequests({
        page,
        pageSize,
        targetGodown: filters.godownId === "all" ? null : filters.godownId,
        status: filters.status === "all" ? null : filters.status,
        kind: filters.kind === "all" ? null : filters.kind,
        scenario: filters.scenario === "all" ? null : filters.scenario,
        search: filters.search.trim() || null,
        fromDate: filters.fromDate || null,
        toDate: filters.toDate || null,
      }),
    enabled: access.canViewExceptionalQueue,
  })

  const rows = list.data?.items ?? []
  const total = list.data?.total ?? 0
  const totalPages = Math.max(1, Math.ceil(total / pageSize))

  return (
    <section className="min-w-0">
      <PageHeader
        title="Exceptional approvals"
        description="Server-filtered return-to-supplier and destroy requests. Approval does not post stock."
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

      <div className="mb-4 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        <label className="grid gap-2 text-sm font-medium">
          Search
          <input
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={filters.search}
            onChange={(event) => {
              setFilters({ ...filters, search: event.target.value })
              setPage(1)
            }}
            aria-label="Search exceptional requests"
          />
        </label>
        <label className="grid gap-2 text-sm font-medium">
          Status
          <select
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={filters.status}
            onChange={(event) => {
              setFilters({ ...filters, status: event.target.value })
              setPage(1)
            }}
            aria-label="Exceptional status filter"
          >
            <option value="all">All statuses</option>
            <option value="requested">Requested</option>
            <option value="approved">Approved — pending execution</option>
            <option value="rejected">Rejected</option>
            <option value="posted">Posted — ledger complete</option>
          </select>
        </label>
        <label className="grid gap-2 text-sm font-medium">
          Disposition
          <select
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={filters.kind}
            onChange={(event) => {
              setFilters({ ...filters, kind: event.target.value })
              setPage(1)
            }}
            aria-label="Exceptional kind filter"
          >
            <option value="all">All kinds</option>
            {exceptionalDispositionKinds.map((kind) => (
              <option key={kind} value={kind}>
                {formatExceptionalKind(kind)}
              </option>
            ))}
          </select>
        </label>
        <label className="grid gap-2 text-sm font-medium">
          Godown
          <select
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={filters.godownId}
            onChange={(event) => {
              setFilters({ ...filters, godownId: event.target.value })
              setPage(1)
            }}
            aria-label="Exceptional godown filter"
          >
            <option value="all">All authorized godowns</option>
            {(locations.branches.data ?? []).map((branch) => (
              <option key={branch.id} value={branch.id}>
                {branch.name}
              </option>
            ))}
          </select>
        </label>
      </div>

      {list.isLoading ? (
        <LoadingBlock label="Loading exceptional requests" />
      ) : null}
      {list.error ? (
        <p role="alert" className="text-sm text-destructive">
          {list.error.message}
        </p>
      ) : null}

      {list.data && rows.length === 0 ? (
        <EmptyState
          title="No exceptional requests"
          description="No authorized requests match the current filters."
        />
      ) : null}

      <div className="hidden overflow-x-auto md:block">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b text-left text-muted-foreground">
              <th className="py-2 pr-3">Report</th>
              <th className="py-2 pr-3">Disposition</th>
              <th className="py-2 pr-3">Status</th>
              <th className="py-2 pr-3">Scenario</th>
              <th className="py-2 pr-3">Godown</th>
              <th className="py-2 pr-3">Requested</th>
              <th className="py-2 pr-3">Cases</th>
              <th className="py-2 pr-3">Remaining</th>
              <th className="py-2 pr-3">Action</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.id} className="border-b last:border-0">
                <td className="py-2 pr-3">
                  <Link
                    className="font-medium underline-offset-2 hover:underline"
                    to={`/damage/${row.damage_report_id}`}
                  >
                    {row.report_number}
                  </Link>
                </td>
                <td className="py-2 pr-3">{formatExceptionalKind(row.kind)}</td>
                <td className="py-2 pr-3">
                  <StatusBadge
                    tone={
                      row.status === "posted"
                        ? "success"
                        : row.status === "approved"
                          ? "info"
                          : row.status === "rejected"
                            ? "danger"
                            : "warning"
                    }
                  >
                    {formatExceptionalStatus(row.status)}
                  </StatusBadge>
                </td>
                <td className="py-2 pr-3">
                  {formatDamageScenario(row.scenario)}
                </td>
                <td className="py-2 pr-3">{row.godown_name}</td>
                <td className="py-2 pr-3">{formatDate(row.requested_at)}</td>
                <td className="py-2 pr-3">{formatCases(row.total_cases ?? 0)}</td>
                <td className="py-2 pr-3">
                  {formatCases(row.remaining_hold_cases ?? 0)}
                </td>
                <td className="py-2 pr-3">
                  <Button asChild size="sm" variant="outline">
                    <Link to={`/damage/${row.damage_report_id}`}>Inspect</Link>
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <ul className="grid gap-3 md:hidden">
        {rows.map((row) => (
          <li
            key={row.id}
            className="rounded-2xl bg-card p-4 ring-1 ring-border"
          >
            <p className="font-medium">{row.report_number}</p>
            <p className="text-sm text-muted-foreground">
              {formatExceptionalKind(row.kind)} ·{" "}
              {formatExceptionalStatus(row.status)}
            </p>
            <Button asChild className="mt-3" size="sm" variant="outline">
              <Link to={`/damage/${row.damage_report_id}`}>Inspect</Link>
            </Button>
          </li>
        ))}
      </ul>

      {total > pageSize ? (
        <div className="mt-4 flex items-center justify-between text-sm">
          <Button
            type="button"
            variant="outline"
            disabled={page <= 1}
            onClick={() => setPage((current) => Math.max(1, current - 1))}
          >
            Previous
          </Button>
          <p>
            Page {page} of {totalPages}
          </p>
          <Button
            type="button"
            variant="outline"
            disabled={page >= totalPages}
            onClick={() => setPage((current) => current + 1)}
          >
            Next
          </Button>
        </div>
      ) : null}
    </section>
  )
}
