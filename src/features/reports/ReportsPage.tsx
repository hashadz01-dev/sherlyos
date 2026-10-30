import { Link } from "react-router"
import { PageHeader } from "@/components/shared/PageHeader"
import { ReportLinks } from "@/features/reports/ReportLinks"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import {
  canAny,
  dispatchReportPermissions,
  inventoryReportPermissions,
  operationsReportPermissions,
  orderReportPermissions,
  refillReportPermissions,
} from "@/lib/reports/access"

const cards = [
  {
    to: "/reports/inventory",
    title: "Inventory",
    description: "Aggregate carton cases by crate, zone, godown, or product.",
    permissions: inventoryReportPermissions,
  },
  {
    to: "/reports/lots",
    title: "Lot stock",
    description: "Lot balances, expiry buckets, and unknown expiry. Empty while cutover is inactive.",
    permissions: inventoryReportPermissions,
  },
  {
    to: "/reports/movements",
    title: "Stock movements",
    description: "Posted documents: opening, receipt, transfer, adjustment, and DISPATCH consumption.",
    permissions: inventoryReportPermissions,
  },
  {
    to: "/reports/orders-picking",
    title: "Orders and packing",
    description: "Order status, ageing, reservations, and consumed dispatch — not ready-for-dispatch as stock left.",
    permissions: orderReportPermissions,
  },
  {
    to: "/reports/dispatch",
    title: "Dispatch and delivery",
    description: "Dispatch queue and history. Delivery-note acknowledgement is not customer proof of delivery.",
    permissions: dispatchReportPermissions,
  },
  {
    to: "/reports/exceptions",
    title: "Operational exceptions",
    description: "Existing blockers, failed deliveries, unclassified products, and open adjustments.",
    permissions: operationsReportPermissions,
  },
  {
    to: "/reports/refill",
    title: "Stock refill",
    description:
      "Supplier replenishment progress, reserved unverified cases, and outstanding requested quantity. Approval is not a stock receipt.",
    permissions: refillReportPermissions,
  },
]

export function ReportsPage() {
  useDocumentTitle("Reports")
  const access = useAccess()

  return (
    <section>
      <PageHeader
        title="Reports"
        description="Read-only operational intelligence. Exports use the same permission and godown scope as the on-screen report."
      />
      <ReportLinks />
      <div className="grid gap-4 md:grid-cols-2">
        {cards
          .filter((card) => canAny(access, card.permissions))
          .map((card) => (
            <Link
              key={card.to}
              to={card.to}
              className="rounded-2xl bg-white px-5 py-4 ring-1 ring-slate-200/80 hover:ring-slate-300"
            >
              <h2 className="text-base font-semibold">{card.title}</h2>
              <p className="mt-1.5 text-sm leading-6 text-muted-foreground">{card.description}</p>
            </Link>
          ))}
      </div>
    </section>
  )
}
