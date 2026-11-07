import type { StatusTone } from "@/components/shared/StatusBadge"

export type MetricScope = "snapshot" | "period"

export type AttentionSeverity = StatusTone

export type AttentionItem = {
  id: string
  name: string
  count: number
  severity: AttentionSeverity
  explanation: string
  godown?: string
  to: string
}

/**
 * Severity follows operational meaning, not “nonzero = critical”.
 * Exceptions and blocked work are danger/warning. Ordinary open queues stay info.
 */
export function queueSeverity(
  kind: "exception" | "blocked" | "held" | "work" | "policy",
): AttentionSeverity {
  if (kind === "exception") return "danger"
  if (kind === "blocked" || kind === "held") return "warning"
  if (kind === "policy") return "warning"
  return "info"
}

export type QuickAction = {
  id: string
  label: string
  to: string
  /** Exact permission required, or any of these. */
  anyPermissions: string[]
}

export const DASHBOARD_QUICK_ACTIONS: QuickAction[] = [
  {
    id: "create-order",
    label: "Create order",
    to: "/orders/new",
    anyPermissions: ["orders.capture"],
  },
  {
    id: "packing",
    label: "Open packing queue",
    to: "/picking",
    anyPermissions: [
      "picking.allocate",
      "picking.manage",
      "picking.execute",
      "operations.monitor",
    ],
  },
  {
    id: "dispatch",
    label: "Review dispatches",
    to: "/dispatch",
    anyPermissions: [
      "dispatch.view",
      "dispatch.confirm",
      "operations.monitor",
    ],
  },
  {
    id: "stock-verify",
    label: "Start daily stock verification",
    to: "/stock-verification",
    anyPermissions: ["stock.verify", "stock.count_assist", "operations.monitor"],
  },
  {
    id: "damage",
    label: "Review damage reports",
    to: "/damage",
    anyPermissions: ["damage.read", "damage.record", "damage.verify"],
  },
  {
    id: "inventory",
    label: "Open inventory",
    to: "/inventory",
    anyPermissions: ["stock.read", "operations.monitor"],
  },
  {
    id: "receiving",
    label: "Review pending receipts",
    to: "/receiving",
    anyPermissions: ["receiving.execute", "receiving.verify", "operations.monitor"],
  },
  {
    id: "order-verify",
    label: "Open order verification",
    to: "/orders/verification",
    anyPermissions: ["orders.verify"],
  },
]

/** Path-only destinations. List pages keep their own filters in local state. */
export const DASHBOARD_DESTINATIONS = {
  inventory: "/inventory",
  orders: "/orders",
  orderVerification: "/orders/verification",
  packing: "/picking",
  packingExceptions: "/picking/exceptions",
  dispatch: "/dispatch",
  deliveries: "/delivery-runs",
  receiving: "/receiving",
  receiptVerification: "/receiving/verification",
  stockVerification: "/stock-verification",
  adjustments: "/stock-adjustments",
  damage: "/damage",
  damageVerification: "/damage/verification",
  damageQuarantine: "/damage/quarantine",
  godowns: "/godowns",
  reportsInventory: "/reports/inventory",
  reportsOrders: "/reports/orders-picking",
  reportsDispatch: "/reports/dispatch",
} as const
