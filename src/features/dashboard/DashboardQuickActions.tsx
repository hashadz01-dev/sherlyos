import { Link } from "react-router"
import { DASHBOARD_QUICK_ACTIONS } from "@/features/dashboard/metric-map"

/** Compact navigation shortcuts. Never posts stock or workflow mutations. */
export function DashboardQuickActions({
  can,
}: {
  can: (permission: string) => boolean
}) {
  const preferred = [
    "packing",
    "dispatch",
    "stock-verify",
    "damage",
    "inventory",
    "receiving",
  ]
  const actions = DASHBOARD_QUICK_ACTIONS.filter((action) =>
    preferred.includes(action.id) &&
    action.anyPermissions.some((permission) => can(permission)),
  )

  if (actions.length === 0) return null

  const labels: Record<string, string> = {
    packing: "Open packing",
    dispatch: "Review dispatches",
    "stock-verify": "Start daily count",
    damage: "Review damage",
    inventory: "Open inventory",
    receiving: "Review pending receipts",
  }

  return (
    <section className="mb-2" aria-labelledby="quick-actions-heading">
      <h2
        id="quick-actions-heading"
        className="mb-2 text-sm font-semibold text-slate-900"
      >
        Quick Actions
      </h2>
      <ul className="flex flex-wrap gap-2">
        {actions.map((action) => (
          <li key={action.id}>
            <Link
              to={action.to}
              className="inline-flex h-8 items-center rounded-lg bg-navy px-3 text-xs font-medium text-white transition hover:bg-navy/90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand"
            >
              {labels[action.id] ?? action.label}
            </Link>
          </li>
        ))}
      </ul>
    </section>
  )
}
