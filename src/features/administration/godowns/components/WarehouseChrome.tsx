import { ArrowLeft } from "lucide-react"
import { Link } from "react-router"
import { Button } from "@/components/ui/button"
import { formatPercent } from "@/lib/warehouse/capacity"

/** Shared hit target so the whole warehouse card navigates, not only a text link. */
export const warehouseCardLinkClass =
  "block cursor-pointer rounded-2xl bg-white p-4 ring-1 ring-slate-200 transition hover:bg-slate-50 hover:ring-slate-400 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-slate-900"

/** Sits in the page header action slot, which is the top-right on desktop. */
export function WarehouseBackLink({ to, label }: { to: string; label: string }) {
  return (
    <Button asChild variant="outline" size="sm">
      <Link to={to}>
        <ArrowLeft aria-hidden="true" />
        {label}
      </Link>
    </Button>
  )
}

export function WarehouseBreadcrumbs({
  items,
}: {
  items: { label: string; to?: string }[]
}) {
  return (
    <nav aria-label="Warehouse" className="mb-4 text-sm text-muted-foreground">
      <ol className="flex flex-wrap items-center gap-1">
        {items.map((item, index) => (
          <li key={`${item.label}-${index}`} className="flex items-center gap-1">
            {index > 0 ? <span aria-hidden="true">/</span> : null}
            {item.to ? (
              <Link to={item.to} className="hover:text-foreground">
                {item.label}
              </Link>
            ) : (
              <span className="text-foreground">{item.label}</span>
            )}
          </li>
        ))}
      </ol>
    </nav>
  )
}

export function CapacityProgress({
  ratio,
  over,
}: {
  ratio: number | null
  over: boolean
}) {
  const width = ratio === null ? 0 : Math.min(100, Math.round(ratio * 100))
  return (
    <div>
      <div className="mb-1 flex justify-between text-xs text-muted-foreground">
        <span>Occupancy of configured capacity</span>
        <span>{formatPercent(ratio)}</span>
      </div>
      <div className="h-1.5 overflow-hidden rounded-full bg-slate-100">
        <div
          className={over ? "h-full bg-amber-500" : "h-full bg-emerald-600"}
          style={{ width: `${width}%` }}
        />
      </div>
    </div>
  )
}

export function StockStatusLegend() {
  const items = [
    ["bg-emerald-600", "Occupied"],
    ["border border-slate-300 bg-white", "Empty"],
    ["bg-sky-600", "Reserved"],
    ["bg-orange-500", "Quarantined"],
    ["bg-slate-400", "Unavailable"],
  ] as const
  return (
    <ul className="flex flex-wrap gap-3 text-xs text-muted-foreground">
      {items.map(([swatch, label]) => (
        <li key={label} className="flex items-center gap-1.5">
          <span className={`size-3 rounded-sm ${swatch}`} aria-hidden="true" />
          {label}
        </li>
      ))}
    </ul>
  )
}

export function Metric({
  label,
  value,
}: {
  label: string
  value: string
}) {
  return (
    <div>
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="text-sm font-medium">{value}</dd>
    </div>
  )
}
