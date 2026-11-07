import { Link } from "react-router"
import {
  ArrowLeftRight,
  ClipboardCheck,
  Package,
  PackageCheck,
  ShieldAlert,
  Truck,
  type LucideIcon,
} from "lucide-react"
import { DASHBOARD_DESTINATIONS } from "@/features/dashboard/metric-map"
import type { DamageDashboard } from "@/lib/damage/api"
import type { OperationsDashboard } from "@/lib/reports/api"

type ModuleCard = {
  id: string
  title: string
  icon: LucideIcon
  pending?: number
  exception?: number
  to: string
}

function displayCount(value: number | undefined) {
  if (value === undefined) {
    return (
      <>
        <span aria-hidden="true">—</span>
        <span className="sr-only">Not available</span>
      </>
    )
  }
  return value
}

export function OperationsModuleGrid({
  data,
  damage,
  canAdjust,
  canTransfer,
}: {
  data: OperationsDashboard
  damage?: DamageDashboard | null
  canAdjust: boolean
  canTransfer: boolean
}) {
  const cards: ModuleCard[] = []

  if (data.operations.visible) {
    cards.push(
      {
        id: "receiving",
        title: "Receiving",
        icon: Package,
        pending: data.operations.pending_receiving,
        to: DASHBOARD_DESTINATIONS.receiving,
      },
      {
        id: "receipt-verify",
        title: "Receipt verification",
        icon: ClipboardCheck,
        pending: data.operations.pending_receiving,
        to: DASHBOARD_DESTINATIONS.receiptVerification,
      },
      {
        id: "daily-verify",
        title: "Daily stock verification",
        icon: ClipboardCheck,
        pending: data.operations.pending_verification,
        to: DASHBOARD_DESTINATIONS.stockVerification,
      },
    )
  }

  if (canAdjust && data.operations.visible) {
    cards.push({
      id: "adjustments",
      title: "Adjustments",
      icon: ShieldAlert,
      pending: data.operations.pending_adjustments,
      to: DASHBOARD_DESTINATIONS.adjustments,
    })
  }

  if (canTransfer) {
    cards.push({
      id: "transfers",
      title: "Stock transfers",
      icon: ArrowLeftRight,
      to: "/inventory/transfers",
    })
  }

  if (data.picking.visible) {
    cards.push({
      id: "packing",
      title: "Packing",
      icon: PackageCheck,
      pending: data.picking.picking,
      exception: data.picking.blocked,
      to: DASHBOARD_DESTINATIONS.packing,
    })
  }

  if (data.dispatch.visible) {
    cards.push({
      id: "dispatch",
      title: "Dispatch",
      icon: Truck,
      pending: data.dispatch.preparing,
      exception: data.dispatch.exception,
      to: DASHBOARD_DESTINATIONS.dispatch,
    })
  }

  if (damage) {
    cards.push({
      id: "damage",
      title: "Damage management",
      icon: ShieldAlert,
      pending: damage.totals.pending_verification,
      exception: damage.totals.pending_exceptional,
      to: DASHBOARD_DESTINATIONS.damage,
    })
  }

  if (cards.length === 0) return null

  return (
    <section
      className="mb-4 rounded-2xl bg-white p-4 ring-1 ring-slate-200/80"
      aria-labelledby="modules-heading"
    >
      <div className="mb-3">
        <h2 id="modules-heading" className="text-sm font-semibold text-slate-900">
          Operations by Module
        </h2>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Pending and exception counts from authorized snapshot data.
        </p>
      </div>
      <ul className="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
        {cards.map((card) => {
          const Icon = card.icon
          return (
            <li key={card.id}>
              <Link
                to={card.to}
                className="flex items-center gap-3 rounded-xl bg-slate-50 px-3 py-2.5 ring-1 ring-slate-200/70 transition hover:bg-white hover:ring-slate-300 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand"
              >
                <span className="inline-flex size-8 shrink-0 items-center justify-center rounded-lg bg-white text-navy ring-1 ring-slate-200/80">
                  <Icon className="size-3.5" aria-hidden="true" />
                </span>
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium text-slate-900">
                    {card.title}
                  </p>
                  <p className="mt-0.5 text-[11px] text-muted-foreground">
                    Pending{" "}
                    <span className="font-semibold tabular-nums text-slate-800">
                      {displayCount(card.pending)}
                    </span>
                    <span className="mx-1 text-slate-300">·</span>
                    Exc{" "}
                    <span className="font-semibold tabular-nums text-slate-800">
                      {displayCount(card.exception)}
                    </span>
                  </p>
                </div>
              </Link>
            </li>
          )
        })}
      </ul>
    </section>
  )
}
