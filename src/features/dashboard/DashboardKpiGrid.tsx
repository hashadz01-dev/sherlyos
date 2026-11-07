import { Package, PackageCheck, ShoppingCart, Truck } from "lucide-react"
import { DashboardKpiCard } from "@/features/dashboard/DashboardKpiCard"
import {
  availablePickDisplay,
  kpiNumber,
} from "@/features/dashboard/kpi-display"
import { DASHBOARD_DESTINATIONS } from "@/features/dashboard/metric-map"
import type { OperationsDashboard } from "@/lib/reports/api"

/**
 * Executive snapshot KPIs. Unauthorized groups are omitted entirely — not painted
 * as zero or em dash. Authorized-but-N/A values (e.g. ATP) keep the em dash.
 */
export function DashboardKpiGrid({ data }: { data: OperationsDashboard }) {
  const cards = []

  if (data.inventory.visible) {
    const pick = availablePickDisplay(data.inventory.available_to_pick, true)
    cards.push(
      <DashboardKpiCard
        key="on-hand"
        label="Cartons on hand"
        icon={Package}
        hint="Aggregate crate balances · snapshot"
        accent="navy"
        to={DASHBOARD_DESTINATIONS.inventory}
        {...kpiNumber(data.inventory.total_cartons_on_hand, true)}
      />,
      <DashboardKpiCard
        key="atp"
        label="Available to pick"
        icon={PackageCheck}
        hint={pick.hint}
        accent="brand"
        value={pick.value}
        unavailable={pick.unavailable}
        to={DASHBOARD_DESTINATIONS.inventory}
      />,
      <DashboardKpiCard
        key="reserved"
        label="Reserved cases"
        icon={PackageCheck}
        hint="Reservations are not stock deductions"
        accent="warning"
        to={DASHBOARD_DESTINATIONS.packing}
        {...kpiNumber(data.inventory.active_reserved_cartons, true)}
      />,
    )
  }

  if (data.orders.visible) {
    cards.push(
      <DashboardKpiCard
        key="verified"
        label="Verified orders"
        icon={ShoppingCart}
        hint="Verified, not cancelled"
        accent="success"
        to={DASHBOARD_DESTINATIONS.orderVerification}
        {...kpiNumber(data.orders.verified, true)}
      />,
    )
  }

  if (data.picking.visible) {
    cards.push(
      <DashboardKpiCard
        key="ready"
        label="Ready for dispatch"
        icon={PackageCheck}
        hint="Packing handoff complete. Not a stock deduction."
        accent="brand"
        to={DASHBOARD_DESTINATIONS.dispatch}
        {...kpiNumber(data.picking.ready_for_dispatch, true)}
      />,
    )
  }

  if (data.dispatch.visible || data.deliveries.visible) {
    const delivered = data.dispatch.visible
      ? kpiNumber(data.dispatch.delivered, true)
      : kpiNumber(data.deliveries.delivered, true)
    const deliveredHint = data.dispatch.visible
      ? "Customer proof of delivery. Not delivery-note acknowledgement."
      : "Assigned proof of delivery"
    cards.push(
      <DashboardKpiCard
        key="delivered"
        label="Delivered"
        icon={Truck}
        hint={deliveredHint}
        accent="success"
        to={DASHBOARD_DESTINATIONS.deliveries}
        value={delivered.value}
        unavailable={delivered.unavailable}
      />,
    )
  }

  if (cards.length === 0) return null

  return (
    <section className="mb-4" aria-label="Executive snapshot">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
        {cards}
      </div>
    </section>
  )
}
