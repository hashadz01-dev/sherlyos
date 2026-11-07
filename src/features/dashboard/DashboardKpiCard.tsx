import { Link } from "react-router"
import type { LucideIcon } from "lucide-react"
import { cn } from "cn"

/**
 * Compact executive KPI. Unauthorized or missing values stay an em dash.
 * Optional navigation is path-only — destination pages keep their own filters.
 */
export function DashboardKpiCard({
  label,
  icon: Icon,
  hint,
  value,
  unavailable,
  to,
  accent = "brand",
  dense = false,
}: {
  label: string
  icon: LucideIcon
  hint: string
  value?: number | string | null
  unavailable?: boolean
  to?: string
  accent?: "brand" | "navy" | "success" | "warning"
  dense?: boolean
}) {
  // Unauthorized cards are omitted by callers. Here: zero stays numeric; N/A is em dash.
  const showUnavailable = unavailable || value === null || value === undefined
  const metricState = showUnavailable
    ? "unavailable"
    : value === 0
      ? "zero"
      : "value"
  const accentClass = {
    brand: "bg-brand/10 text-brand",
    navy: "bg-navy/10 text-navy",
    success: "bg-[var(--status-success-bg)] text-[var(--status-success)]",
    warning: "bg-[var(--status-warning-bg)] text-[var(--status-warning)]",
  }[accent]

  const body = (
    <article
      title={hint}
      data-metric-state={metricState}
      className={cn(
        "h-full rounded-2xl bg-white ring-1 ring-slate-200/80 shadow-[0_1px_2px_rgba(15,23,42,0.04)] transition hover:ring-slate-300",
        dense ? "px-3.5 py-3" : "px-4 py-3.5",
      )}
    >
      <div className="flex items-start justify-between gap-2">
        <h3 className="text-xs font-medium text-slate-500">{label}</h3>
        <span
          className={cn(
            "inline-flex size-7 shrink-0 items-center justify-center rounded-lg",
            accentClass,
          )}
        >
          <Icon className="size-3.5" aria-hidden="true" />
        </span>
      </div>
      <p
        className={cn(
          "mt-2 font-semibold tracking-tight tabular-nums",
          dense ? "text-2xl" : "text-[1.75rem] leading-none",
          showUnavailable ? "text-slate-400" : "text-slate-950",
        )}
      >
        {showUnavailable ? (
          <>
            <span aria-hidden="true">—</span>
            <span className="sr-only">Unavailable</span>
          </>
        ) : (
          value
        )}
      </p>
      <p className="mt-1.5 line-clamp-2 text-[11px] leading-4 text-slate-500">
        {hint}
      </p>
    </article>
  )

  if (!to) return body

  return (
    <Link
      to={to}
      className="block h-full rounded-2xl focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand"
      aria-label={`Open ${label}`}
    >
      {body}
    </Link>
  )
}
