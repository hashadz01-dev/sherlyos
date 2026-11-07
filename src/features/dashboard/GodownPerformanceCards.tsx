import { Link } from "react-router"
import type { DashboardBranchStock } from "@/lib/reports/api"
import type { ReportBranchOption } from "@/lib/branches/operational"
import { DASHBOARD_DESTINATIONS } from "@/features/dashboard/metric-map"

/**
 * Per-godown snapshot cards. Utilization is omitted: configured capacity is not
 * authoritative on get_operations_dashboard, and planned crates must not inflate it.
 */
export function GodownPerformanceCards({
  rows,
  branches,
  canOpenGodowns,
}: {
  rows: DashboardBranchStock[]
  branches: ReportBranchOption[]
  canOpenGodowns: boolean
}) {
  if (rows.length === 0) return null

  return (
    <section className="rounded-2xl bg-white p-5 ring-1 ring-slate-200/80">
      <div className="mb-4">
        <h3 className="text-base font-semibold text-slate-900">
          Godown stock cards
        </h3>
        <p className="mt-1 text-sm text-muted-foreground">
          Current on-hand cases by authorized godown. Capacity utilization is not
          shown without an authoritative configured capacity source.
        </p>
      </div>
      <ul className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        {rows.map((row) => {
          const listed = branches.find((branch) => branch.id === row.branch_id)
          const inactive = listed ? !listed.is_active : false
          const to = canOpenGodowns
            ? `/godowns/${row.branch_id}/zones`
            : DASHBOARD_DESTINATIONS.inventory
          return (
            <li key={row.branch_id}>
              <Link
                to={to}
                className="block rounded-2xl bg-slate-50 p-4 ring-1 ring-slate-200/80 transition hover:bg-white hover:ring-slate-300 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand"
              >
                <p className="text-sm font-semibold text-slate-900">
                  {row.branch_name}
                  <span className="ml-2 font-normal text-muted-foreground">
                    {row.branch_code}
                  </span>
                </p>
                {inactive ? (
                  <p className="mt-1 text-xs text-muted-foreground">
                    Inactive (historical)
                  </p>
                ) : null}
                <p className="mt-3 text-2xl font-semibold tabular-nums text-slate-950">
                  {row.cartons}
                </p>
                <p className="mt-1 text-xs text-muted-foreground">
                  Cartons on hand
                </p>
              </Link>
            </li>
          )
        })}
      </ul>
    </section>
  )
}
