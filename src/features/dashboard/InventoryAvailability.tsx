import { Package, PackageCheck } from "lucide-react"
import { DashboardKpiCard } from "@/features/dashboard/DashboardKpiCard"
import {
  availablePickDisplay,
  kpiNumber,
} from "@/features/dashboard/kpi-display"
import { DASHBOARD_DESTINATIONS } from "@/features/dashboard/metric-map"
import type { OperationsDashboard } from "@/lib/reports/api"

/**
 * Compact 2×2 availability panel. Measures are separate — never stacked or summed.
 */
export function InventoryAvailability({
  inventory,
  cutoverOff,
}: {
  inventory: OperationsDashboard["inventory"]
  cutoverOff: boolean
}) {
  if (!inventory.visible) return null

  const pick = availablePickDisplay(inventory.available_to_pick, true)

  return (
    <section
      className="flex h-full min-h-0 flex-col rounded-2xl bg-white ring-1 ring-slate-200/80"
      aria-labelledby="availability-heading"
    >
      <div className="border-b border-slate-100 px-4 py-3">
        <h2
          id="availability-heading"
          className="text-sm font-semibold text-slate-900"
        >
          Inventory Availability
        </h2>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Separate measures · reserved is not a deduction from on-hand
        </p>
      </div>
      <div className="grid flex-1 grid-cols-2 gap-2.5 p-3">
        <DashboardKpiCard
          dense
          label="On hand"
          icon={Package}
          hint="Aggregate crate balances"
          accent="navy"
          to={DASHBOARD_DESTINATIONS.inventory}
          {...kpiNumber(inventory.total_cartons_on_hand, true)}
        />
        <DashboardKpiCard
          dense
          label="Reserved"
          icon={PackageCheck}
          hint="Reservations are not stock deductions"
          accent="warning"
          to={DASHBOARD_DESTINATIONS.packing}
          {...kpiNumber(inventory.active_reserved_cartons, true)}
        />
        <DashboardKpiCard
          dense
          label="Available to pick"
          icon={PackageCheck}
          hint={pick.hint}
          accent="brand"
          value={pick.value}
          unavailable={pick.unavailable}
          to={DASHBOARD_DESTINATIONS.inventory}
        />
        <DashboardKpiCard
          dense
          label="Lot-attributed"
          icon={Package}
          hint={
            cutoverOff
              ? "No operational lots while cutover is inactive"
              : "Sum of lot balances"
          }
          accent="success"
          to={DASHBOARD_DESTINATIONS.inventory}
          {...kpiNumber(inventory.lot_attributed_cartons, true)}
        />
      </div>
    </section>
  )
}
