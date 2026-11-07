import { OPERATIONS_PERIOD_RPC_ENABLED } from "@/lib/reports/api"
import { PERIOD_METRIC_LABELS } from "@/features/dashboard/period-metrics"
import type { PreparedPeriodMetric } from "@/features/dashboard/period-metrics"

/**
 * Historical activity panel. Stays dormant while the period RPC flag is off.
 * When enabled later, pass prepared metrics from getOperationsDashboardPeriod only —
 * never invent stock balances or zero-fill unauthorized series.
 */
export function PeriodActivityPanel({
  metrics,
  loading = false,
  error = null,
}: {
  metrics?: PreparedPeriodMetric[] | null
  loading?: boolean
  error?: string | null
}) {
  if (!OPERATIONS_PERIOD_RPC_ENABLED) {
    return (
      <section
        className="mb-4 rounded-xl bg-slate-50 px-3 py-2 text-xs leading-5 text-slate-700 ring-1 ring-slate-200/80"
        aria-labelledby="period-activity-heading"
      >
        <h2 id="period-activity-heading" className="font-semibold text-slate-900">
          Historical activity
        </h2>
        <p className="mt-1" role="status">
          Showing <span className="font-semibold">Current Snapshot</span>. Period
          metrics ({Object.values(PERIOD_METRIC_LABELS).join(", ")}) stay
          unavailable until{" "}
          <code className="rounded bg-white px-1 py-0.5 text-[10px] ring-1 ring-slate-200">
            get_operations_dashboard_period
          </code>{" "}
          is approved and enabled. Snapshot KPIs remain authoritative.
        </p>
      </section>
    )
  }

  if (loading) {
    return (
      <p className="mb-4 text-sm text-muted-foreground" role="status">
        Loading period activity…
      </p>
    )
  }

  if (error) {
    return (
      <div
        className="mb-4 rounded-xl bg-amber-50 px-4 py-3 text-sm text-amber-950 ring-1 ring-amber-200"
        role="alert"
      >
        Period metrics could not load: {error}
      </div>
    )
  }

  const ready = (metrics ?? []).filter((metric) => metric.state === "ready")
  if (ready.length === 0) {
    return (
      <p className="mb-4 text-sm text-muted-foreground" role="status">
        No authorized period metrics for this window.
      </p>
    )
  }

  return (
    <section className="mb-4 rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
      <h2 className="text-sm font-semibold text-slate-900">Historical activity</h2>
      <p className="mt-0.5 text-xs text-muted-foreground">
        Event counts only · UTC half-open windows · not inventory balances
      </p>
      <ul className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-5">
        {ready.map((metric) => (
          <li
            key={metric.key}
            className="rounded-xl bg-slate-50 px-3 py-2 ring-1 ring-slate-200/70"
          >
            <p className="text-[11px] font-medium text-slate-500">{metric.label}</p>
            <p className="mt-1 text-xl font-semibold tabular-nums text-slate-950">
              {metric.total}
            </p>
            <p className="mt-0.5 text-[10px] text-slate-400">
              {metric.series?.length ?? 0} UTC days
            </p>
          </li>
        ))}
      </ul>
    </section>
  )
}
