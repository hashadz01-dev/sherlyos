import { RefreshCw, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { ReportBranchSelect } from "@/features/reports/BranchFilterNote"
import type { ReportBranchOption } from "@/lib/branches/operational"
import { formatUtc } from "@/lib/reports/format"

/**
 * Single compact command-centre header: title, refresh, and godown filter.
 * Historical period selection stays disabled until Phase 3 reporting is approved.
 */
export function DashboardHeader({
  email,
  roles,
  dataUpdatedAt,
  refreshing,
  onRefresh,
  showFilters,
  branchId,
  onBranch,
  branches,
  onClear,
  cutoverOff,
}: {
  email?: string | null
  roles: string[]
  dataUpdatedAt?: number
  refreshing: boolean
  onRefresh: () => void
  showFilters: boolean
  branchId: string
  onBranch: (value: string) => void
  branches: ReportBranchOption[]
  onClear: () => void
  cutoverOff: boolean
}) {
  const roleLabel =
    roles.length > 0 ? roles.map(formatRole).join(", ") : "No assigned role"
  const refreshed =
    dataUpdatedAt && dataUpdatedAt > 0
      ? formatUtc(new Date(dataUpdatedAt).toISOString())
      : "—"
  const filtersActive = Boolean(branchId)

  return (
    <header className="mb-4 rounded-2xl bg-white p-4 ring-1 ring-slate-200/80 sm:p-5">
      <div className="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
        <div className="min-w-0">
          <h1 className="text-xl font-semibold tracking-tight text-slate-950 sm:text-2xl">
            Operations Dashboard
          </h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Your warehouse operations at a glance.
          </p>
          <p className="mt-2 text-xs text-slate-500">
            <span className="font-medium text-slate-700">
              {email ?? "Signed in"}
            </span>
            <span className="mx-1.5 text-slate-300" aria-hidden="true">
              ·
            </span>
            <span>{roleLabel}</span>
            <span className="mx-1.5 text-slate-300" aria-hidden="true">
              ·
            </span>
            <span>
              Refreshed{" "}
              <time
                dateTime={
                  dataUpdatedAt
                    ? new Date(dataUpdatedAt).toISOString()
                    : undefined
                }
              >
                {refreshed}
              </time>{" "}
              UTC
            </span>
          </p>
        </div>

        <div className="flex flex-wrap items-end gap-2">
          {showFilters ? (
            <>
              <div className="min-w-[11rem]">
                <ReportBranchSelect
                  value={branchId}
                  onChange={onBranch}
                  branches={branches}
                />
              </div>
              <label className="grid gap-1 text-sm font-medium text-slate-500">
                Reporting period
                <select
                  className="h-10 cursor-not-allowed rounded-lg border border-input bg-slate-50 px-2.5 text-sm font-normal text-slate-500"
                  value="snapshot"
                  disabled
                  aria-disabled="true"
                  title="Historical period reporting is not enabled yet"
                >
                  <option value="snapshot">Current Snapshot</option>
                </select>
              </label>
              {filtersActive ? (
                <Button type="button" variant="ghost" size="sm" onClick={onClear}>
                  <X className="mr-1 size-3.5" aria-hidden="true" />
                  Clear godown
                </Button>
              ) : null}
            </>
          ) : null}
          <Button
            type="button"
            variant="outline"
            size="sm"
            className="h-10"
            onClick={onRefresh}
            disabled={refreshing}
          >
            <RefreshCw
              className={`mr-2 size-3.5 ${refreshing ? "animate-spin" : ""}`}
              aria-hidden="true"
            />
            {refreshing ? "Refreshing" : "Refresh"}
          </Button>
        </div>
      </div>

      {showFilters ? (
        <div className="mt-3 flex flex-wrap items-center gap-2 text-[11px]">
          <span className="rounded-full bg-blue-50 px-2 py-0.5 font-medium text-blue-900 ring-1 ring-blue-200/70">
            Current Snapshot
          </span>
          <span className="rounded-full bg-slate-100 px-2 py-0.5 font-medium text-slate-600">
            Historical period unavailable
          </span>
          {branchId ? (
            <span className="rounded-full bg-blue-50 px-2 py-0.5 font-medium text-blue-900 ring-1 ring-blue-200/70">
              Godown filter active
            </span>
          ) : null}
          {cutoverOff ? (
            <span className="text-slate-500">
              Lot cutover inactive — available-to-pick stays not applicable.
            </span>
          ) : null}
          <span className="text-slate-500">
            “All authorized godowns” can include inactive godown stock.
          </span>
        </div>
      ) : null}
    </header>
  )
}

function formatRole(code: string) {
  return code
    .split("_")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ")
}
