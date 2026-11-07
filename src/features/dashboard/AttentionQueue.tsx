import { Link } from "react-router"
import {
  AlertTriangle,
  ClipboardCheck,
  PackageCheck,
  ShieldAlert,
  ShoppingCart,
  TriangleAlert,
  Truck,
  type LucideIcon,
} from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { StatusBadge } from "@/components/shared/StatusBadge"
import {
  DASHBOARD_DESTINATIONS,
  queueSeverity,
  type AttentionItem,
} from "@/features/dashboard/metric-map"
import type { DamageDashboard } from "@/lib/damage/api"
import type { OperationsDashboard } from "@/lib/reports/api"
import { cn } from "cn"

const ICONS: Record<string, LucideIcon> = {
  "orders-held": ShoppingCart,
  "orders-awaiting-packing": PackageCheck,
  "packing-blocked": TriangleAlert,
  "packing-exceptions": AlertTriangle,
  "dispatch-exception": Truck,
  "pending-pod": ClipboardCheck,
  "assigned-exceptions": Truck,
  "pending-receiving": PackageCheck,
  "pending-adjustments": ShieldAlert,
  "pending-verification": ClipboardCheck,
  "pending-returns": Truck,
  "unclassified-products": TriangleAlert,
  "damage-verify": ShieldAlert,
  "damage-holds": ShieldAlert,
  "damage-quarantine": ShieldAlert,
  "damage-exceptional": AlertTriangle,
}

/** Build authorized attention rows from snapshot ops + optional damage dashboard. */
export function buildAttentionItems(
  data: OperationsDashboard,
  damage?: DamageDashboard | null,
): AttentionItem[] {
  const items: AttentionItem[] = []

  if (data.orders.visible) {
    pushIfCount(items, {
      id: "orders-held",
      name: "Held orders",
      count: data.orders.held ?? 0,
      severity: queueSeverity("held"),
      explanation: "Orders held before verification or packing.",
      to: DASHBOARD_DESTINATIONS.orders,
    })
    pushIfCount(items, {
      id: "orders-awaiting-packing",
      name: "Orders awaiting packing",
      count: data.orders.awaiting_picking ?? 0,
      severity: queueSeverity("work"),
      explanation: "Verified orders with no active packing request.",
      to: DASHBOARD_DESTINATIONS.packing,
    })
  }

  if (data.picking.visible) {
    pushIfCount(items, {
      id: "packing-blocked",
      name: "Packing blocked",
      count: data.picking.blocked ?? 0,
      severity: queueSeverity("blocked"),
      explanation: "Packing requests that cannot continue.",
      to: DASHBOARD_DESTINATIONS.packingExceptions,
    })
    pushIfCount(items, {
      id: "packing-exceptions",
      name: "Packing exception rows",
      count: data.picking.exception_rows ?? 0,
      severity: queueSeverity("exception"),
      explanation: "Exception lines on packing requests.",
      to: DASHBOARD_DESTINATIONS.packingExceptions,
    })
  }

  if (data.dispatch.visible) {
    pushIfCount(items, {
      id: "dispatch-exception",
      name: "Delivery exceptions",
      count: data.dispatch.exception ?? 0,
      severity: queueSeverity("exception"),
      explanation: "Failed delivery. Stock stays deducted.",
      to: DASHBOARD_DESTINATIONS.dispatch,
    })
    pushIfCount(items, {
      id: "pending-pod",
      name: "Pending proof of delivery",
      count: data.dispatch.pending_proof_of_delivery ?? 0,
      severity: queueSeverity("work"),
      explanation: "Consumed dispatches still awaiting delivery proof.",
      to: DASHBOARD_DESTINATIONS.deliveries,
    })
  }

  if (data.deliveries.visible) {
    pushIfCount(items, {
      id: "assigned-exceptions",
      name: "Assigned delivery exceptions",
      count: data.deliveries.exception ?? 0,
      severity: queueSeverity("exception"),
      explanation: "Failed runs assigned to the signed-in driver.",
      to: DASHBOARD_DESTINATIONS.deliveries,
    })
  }

  if (data.operations.visible) {
    pushIfCount(items, {
      id: "pending-receiving",
      name: "Pending receiving",
      count: data.operations.pending_receiving ?? 0,
      severity: queueSeverity("work"),
      explanation: "Draft, submitted, or held receipts.",
      to: DASHBOARD_DESTINATIONS.receiving,
    })
    pushIfCount(items, {
      id: "pending-adjustments",
      name: "Open stock adjustments",
      count: data.operations.pending_adjustments ?? 0,
      severity: queueSeverity("work"),
      explanation: "Adjustment requests still in workflow.",
      to: DASHBOARD_DESTINATIONS.adjustments,
    })
    pushIfCount(items, {
      id: "pending-verification",
      name: "Pending stock counts",
      count: data.operations.pending_verification ?? 0,
      severity: queueSeverity("work"),
      explanation: "Daily verification sessions that are not closed.",
      to: DASHBOARD_DESTINATIONS.stockVerification,
    })
    pushIfCount(items, {
      id: "pending-returns",
      name: "Pending physical returns",
      count: data.operations.pending_physical_returns ?? 0,
      severity: queueSeverity("work"),
      explanation: "Physical returns awaiting verification.",
      to: DASHBOARD_DESTINATIONS.deliveries,
    })
    pushIfCount(items, {
      id: "unclassified-products",
      name: "Missing expiry policy",
      count: data.operations.unclassified_products ?? 0,
      severity: queueSeverity("policy"),
      explanation: "Master data gap. Not a stock movement.",
      to: DASHBOARD_DESTINATIONS.inventory,
    })
  }

  if (damage) {
    pushIfCount(items, {
      id: "damage-verify",
      name: "Damage awaiting verification",
      count: damage.totals.pending_verification,
      severity: queueSeverity("work"),
      explanation: "Submitted damage reports waiting for a verifier.",
      to: DASHBOARD_DESTINATIONS.damageVerification,
    })
    pushIfCount(items, {
      id: "damage-holds",
      name: "Active damage holds",
      count: damage.totals.active_hold_cases,
      severity: queueSeverity("blocked"),
      explanation: "Cases currently unavailable under damage holds.",
      to: DASHBOARD_DESTINATIONS.damageQuarantine,
    })
    pushIfCount(items, {
      id: "damage-quarantine",
      name: "Quarantined cases",
      count: damage.totals.quarantined_cases,
      severity: queueSeverity("blocked"),
      explanation: "Cases held in quarantine locations.",
      to: DASHBOARD_DESTINATIONS.damageQuarantine,
    })
    pushIfCount(items, {
      id: "damage-exceptional",
      name: "Pending exceptional damage",
      count: damage.totals.pending_exceptional,
      severity: queueSeverity("exception"),
      explanation: "Exceptional disposition still awaiting approval.",
      to: DASHBOARD_DESTINATIONS.damage,
    })
  }

  return items
}

function pushIfCount(items: AttentionItem[], item: AttentionItem) {
  if (item.count > 0) items.push(item)
}

/** One consolidated attention panel — compact rows, not a wall of cards. */
export function AttentionQueue({ items }: { items: AttentionItem[] }) {
  return (
    <section
      className="flex h-full min-h-0 flex-col rounded-2xl bg-white ring-1 ring-slate-200/80"
      aria-labelledby="attention-heading"
    >
      <div className="border-b border-slate-100 px-4 py-3">
        <h2
          id="attention-heading"
          className="text-sm font-semibold text-slate-900"
        >
          Needs Your Attention
        </h2>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Severity follows operational rules, not count alone.
        </p>
      </div>

      {items.length === 0 ? (
        <div className="flex flex-1 items-center px-2 py-6">
          <EmptyState
            title="All clear"
            description="Authorized exception and backlog queues are empty for this filter."
          />
        </div>
      ) : (
        <ul className="max-h-[22rem] divide-y divide-slate-100 overflow-y-auto">
          {items.map((item) => {
            const Icon = ICONS[item.id] ?? TriangleAlert
            return (
              <li key={item.id}>
                <Link
                  to={item.to}
                  title={item.explanation}
                  className="flex items-center gap-3 px-4 py-2.5 transition hover:bg-slate-50 focus-visible:bg-slate-50 focus-visible:outline-none"
                >
                  <span
                    className={cn(
                      "inline-flex size-8 shrink-0 items-center justify-center rounded-lg",
                      item.severity === "danger"
                        ? "bg-[var(--status-danger-bg)] text-[var(--status-danger)]"
                        : item.severity === "warning"
                          ? "bg-[var(--status-warning-bg)] text-[var(--status-warning)]"
                          : "bg-[var(--status-info-bg)] text-[var(--status-info)]",
                    )}
                  >
                    <Icon className="size-3.5" aria-hidden="true" />
                  </span>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-medium text-slate-900">
                      {item.name}
                    </p>
                    <p className="truncate text-[11px] text-muted-foreground">
                      {item.explanation}
                    </p>
                  </div>
                  <span className="text-base font-semibold tabular-nums text-slate-950">
                    {item.count}
                  </span>
                  <StatusBadge tone={item.severity}>
                    {item.severity === "danger"
                      ? "Critical"
                      : item.severity === "warning"
                        ? "Attention"
                        : "Queue"}
                  </StatusBadge>
                </Link>
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}
