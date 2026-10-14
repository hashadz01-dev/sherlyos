import {
  ClipboardCheck,
  ShoppingCart,
  TriangleAlert,
  Truck,
} from "lucide-react"
import { DataTable } from "@/components/shared/DataTable"
import { createAppColumnHelper } from "@/components/shared/table-columns"
import { MetricCard } from "@/components/shared/MetricCard"
import { PageHeader } from "@/components/shared/PageHeader"
import { useDocumentTitle } from "@/hooks/use-document-title"

type RecentOrder = {
  order: string
  shop: string
  status: string
}

const recentOrders: RecentOrder[] = []
const recentOrderHelper = createAppColumnHelper<RecentOrder>()
const recentOrderColumns = recentOrderHelper.columns([
  recentOrderHelper.accessor("order", { header: "Order" }),
  recentOrderHelper.accessor("shop", { header: "Shop" }),
  recentOrderHelper.accessor("status", { header: "Status" }),
])

const metrics = [
  { label: "Orders Today", icon: ShoppingCart },
  { label: "Pending Delivery", icon: Truck },
  { label: "Stock Alerts", icon: TriangleAlert },
  { label: "Pending Approvals", icon: ClipboardCheck },
]

export function DashboardPage() {
  useDocumentTitle("Operations Overview")

  return (
    <section>
      <PageHeader
        title="Operations Overview"
        description="Live operational figures are not connected yet."
      />
      <div className="grid gap-4 md:grid-cols-2">
        {metrics.map((metric) => (
          <MetricCard
            key={metric.label}
            label={metric.label}
            icon={metric.icon}
            hint="Not connected"
          />
        ))}
      </div>
      <section className="mt-6 overflow-hidden rounded-2xl bg-white ring-1 ring-slate-200/80">
        <div className="border-b border-slate-200 px-5 py-4">
          <h2 className="text-base font-semibold">Recent Orders</h2>
        </div>
        <DataTable
          columns={recentOrderColumns}
          data={recentOrders}
          emptyTitle="No orders to show"
          emptyDescription="Orders will appear here after the orders module is connected. Sample rows are not listed."
        />
      </section>
    </section>
  )
}
