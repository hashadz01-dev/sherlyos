import type { LucideIcon } from "lucide-react"

export function MetricCard({
  label,
  icon: Icon,
  hint,
  value,
  unavailable,
}: {
  label: string
  icon: LucideIcon
  hint: string
  value?: number | string | null
  unavailable?: boolean
}) {
  const showUnavailable = unavailable || value === null || value === undefined

  return (
    <article className="rounded-2xl bg-white px-5 py-4 shadow-[0_1px_2px_rgba(15,23,42,0.04)] ring-1 ring-slate-200/80">
      <div className="flex items-start justify-between gap-3">
        <h2 className="text-sm font-medium text-slate-500">{label}</h2>
        <Icon className="size-4 text-slate-400" aria-hidden="true" />
      </div>
      <p className="mt-5 text-4xl font-semibold tracking-tight text-slate-950">
        {showUnavailable ? (
          <>
            <span aria-hidden="true">—</span>
            <span className="sr-only">Not available</span>
          </>
        ) : (
          <span>{value}</span>
        )}
      </p>
      <p className="mt-2 text-xs text-slate-500">{hint}</p>
    </article>
  )
}
