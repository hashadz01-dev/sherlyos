import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import {
  ClipboardCheck,
  Package,
  PackageCheck,
  ShoppingCart,
  TriangleAlert,
  Truck,
} from "lucide-react"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { MetricCard } from "@/components/shared/MetricCard"
import { PageHeader } from "@/components/shared/PageHeader"
import { BranchFilterNote, ReportBranchSelect } from "@/features/reports/BranchFilterNote"
import { useReportBranchFilter } from "@/features/reports/use-report-branch-filter"
import { useAuth } from "@/hooks/use-auth"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import {
  canAny,
  dispatchReportPermissions,
  inventoryReportPermissions,
  operationsReportPermissions,
  orderReportPermissions,
} from "@/lib/reports/access"
import {
  getOperationsDashboard,
  reportKeys,
  type KpiValue,
  type OperationsDashboard,
} from "@/lib/reports/api"

function kpiNumber(value: number | undefined, visible: boolean) {
  if (!visible) return { value: null as number | null, unavailable: true }
  return { value: value ?? 0, unavailable: false }
}

function availablePickDisplay(metric: KpiValue | undefined, visible: boolean) {
  if (!visible || !metric) {
    return { value: null as number | string | null, unavailable: true, hint: "Not authorized" }
  }
  if (metric.state === "not_applicable") {
    return {
      value: null as number | string | null,
      unavailable: true,
      hint: "Lot-aware allocation is inactive. Aggregate on-hand is not available-to-pick.",
    }
  }
  return { value: metric.value, unavailable: false, hint: "Lot-available carton cases" }
}

export function DashboardPage() {
  useDocumentTitle("Operations Overview")
  const access = useAccess()
  const { session } = useAuth()
  const { branchId, setBranchId, branches } = useReportBranchFilter()
  const dashboard = useQuery({
    queryKey: reportKeys.dashboard(session?.user.id, branchId),
    queryFn: () => getOperationsDashboard(branchId || null),
    enabled: canAny(access, operationsReportPermissions),
  })
  const data = dashboard.data

  return (
    <section>
      <PageHeader
        title="Operations Overview"
        description="Authoritative operational counts from the database. Figures stay hidden when a metric is not authorized or not applicable."
      />
      {canAny(access, operationsReportPermissions) ? null : (
        <p className="mb-4 text-sm text-muted-foreground">
          Signed in, but this account has no operational reporting permission.
        </p>
      )}
      {dashboard.isLoading ? <LoadingBlock label="Loading operations overview" /> : null}
      {dashboard.error ? (
        <p role="alert" className="text-sm text-destructive">
          {dashboard.error.message}
        </p>
      ) : null}
      {data ? (
        <DashboardBody
          data={data}
          branchId={branchId}
          onBranch={setBranchId}
          branches={branches}
        />
      ) : null}
    </section>
  )
}

function DashboardBody({
  data,
  branchId,
  onBranch,
  branches,
}: {
  data: OperationsDashboard
  branchId: string
  onBranch: (value: string) => void
  branches: { id: string; name: string; code?: string; is_active: boolean }[]
}) {
  const access = useAccess()
  const pick = availablePickDisplay(data.inventory.available_to_pick, data.inventory.visible)
  const cutoverOff = !data.cutover.dual_write_enabled

  return (
    <>
      <div className="mb-6 grid gap-3 md:grid-cols-[16rem_minmax(0,1fr)]">
        <ReportBranchSelect value={branchId} onChange={onBranch} branches={branches} />
        <p className="self-end text-sm text-muted-foreground">
          Timezone UTC.
          {cutoverOff
            ? " Operational lot cutover is inactive: lot-attributed stock and available-to-pick stay empty or not applicable."
            : " Lot-aware dual-write is on."}
        </p>
      </div>
      <div className="mb-6">
        <BranchFilterNote />
      </div>

      {data.inventory.visible ? (
        <DashboardGroup title="Inventory">
          <MetricCard
            label="Cartons on hand"
            icon={Package}
            hint="Aggregate crate balances"
            {...kpiNumber(data.inventory.total_cartons_on_hand, true)}
          />
          <MetricCard
            label="Products with stock"
            icon={Package}
            hint="Positive aggregate balances"
            {...kpiNumber(data.inventory.products_with_positive_stock, true)}
          />
          <MetricCard
            label="Lot-attributed cartons"
            icon={Package}
            hint={cutoverOff ? "No operational lots while cutover is inactive" : "Sum of lot balances"}
            {...kpiNumber(data.inventory.lot_attributed_cartons, true)}
          />
          <MetricCard
            label="Active reserved cartons"
            icon={PackageCheck}
            hint="Reservations are not stock deductions"
            {...kpiNumber(data.inventory.active_reserved_cartons, true)}
          />
          <MetricCard label="Available to pick" icon={PackageCheck} hint={pick.hint} value={pick.value} unavailable={pick.unavailable} />
        </DashboardGroup>
      ) : null}

      {data.inventory.visible && (data.inventory.stock_by_godown?.length ?? 0) > 0 ? (
        <section className="mb-6 overflow-hidden rounded-2xl bg-white ring-1 ring-slate-200/80">
          <div className="border-b border-slate-200 px-5 py-4">
            <h2 className="text-base font-semibold">Stock by godown</h2>
          </div>
          <ul className="divide-y divide-slate-100">
            {data.inventory.stock_by_godown?.map((row) => {
              const listed = branches.find((branch) => branch.id === row.branch_id)
              const inactive = listed ? !listed.is_active : !data.authorized_branches.some((branch) => branch.id === row.branch_id)
              return (
                <li key={row.branch_id} className="flex items-center justify-between px-5 py-3 text-sm">
                  <span>
                    {row.branch_name}
                    <span className="ml-2 text-muted-foreground">{row.branch_code}</span>
                    {inactive ? (
                      <span className="ml-2 text-muted-foreground">Inactive (historical)</span>
                    ) : null}
                  </span>
                  <span className="font-medium">{row.cartons}</span>
                </li>
              )
            })}
          </ul>
        </section>
      ) : null}

      {data.orders.visible ? (
        <DashboardGroup title="Orders">
          <MetricCard label="Draft" icon={ShoppingCart} hint="Capture drafts" {...kpiNumber(data.orders.draft, true)} />
          <MetricCard label="Submitted" icon={ShoppingCart} hint="Awaiting verification" {...kpiNumber(data.orders.submitted, true)} />
          <MetricCard label="Held" icon={ShoppingCart} hint="Held orders" {...kpiNumber(data.orders.held, true)} />
          <MetricCard label="Verified" icon={ShoppingCart} hint="Verified, not cancelled" {...kpiNumber(data.orders.verified, true)} />
          <MetricCard
            label="Awaiting picking"
            icon={ShoppingCart}
            hint="Verified with no active picking request"
            {...kpiNumber(data.orders.awaiting_picking, true)}
          />
          <MetricCard label="Cancelled" icon={ShoppingCart} hint="Cancelled orders" {...kpiNumber(data.orders.cancelled, true)} />
        </DashboardGroup>
      ) : null}

      {data.picking.visible ? (
        <DashboardGroup title="Picking">
          <MetricCard label="Allocated" icon={PackageCheck} hint="Reserved, not started" {...kpiNumber(data.picking.allocated, true)} />
          <MetricCard label="Picking" icon={PackageCheck} hint="In progress" {...kpiNumber(data.picking.picking, true)} />
          <MetricCard label="Picked" icon={PackageCheck} hint="Warehouse picked" {...kpiNumber(data.picking.picked, true)} />
          <MetricCard
            label="Ready for dispatch"
            icon={PackageCheck}
            hint="Handoff complete. Not a stock deduction."
            {...kpiNumber(data.picking.ready_for_dispatch, true)}
          />
          <MetricCard label="Blocked" icon={TriangleAlert} hint="Picking blockers" {...kpiNumber(data.picking.blocked, true)} />
        </DashboardGroup>
      ) : null}

      {data.dispatch.visible ? (
        <DashboardGroup title="Dispatch">
          <MetricCard
            label="Preparing"
            icon={Truck}
            hint="Unconsumed paperwork. Stock has not left."
            {...kpiNumber(data.dispatch.preparing, true)}
          />
          <MetricCard
            label="Dispatched"
            icon={Truck}
            hint="Consumed DISPATCH ledger"
            {...kpiNumber(data.dispatch.dispatched, true)}
          />
          <MetricCard label="In transit" icon={Truck} hint="Assigned run started" {...kpiNumber(data.dispatch.in_transit, true)} />
          <MetricCard
            label="Delivered"
            icon={Truck}
            hint="Customer proof of delivery. Not delivery-note acknowledgement."
            {...kpiNumber(data.dispatch.delivered, true)}
          />
          <MetricCard
            label="Delivery exceptions"
            icon={TriangleAlert}
            hint="Failed delivery. Stock stays deducted."
            {...kpiNumber(data.dispatch.exception, true)}
          />
          <MetricCard
            label="Pending proof of delivery"
            icon={ClipboardCheck}
            hint="Consumed, not yet delivered"
            {...kpiNumber(data.dispatch.pending_proof_of_delivery, true)}
          />
        </DashboardGroup>
      ) : null}

      {data.deliveries.visible ? (
        <DashboardGroup title="Assigned deliveries">
          <MetricCard label="Open runs" icon={Truck} hint="Assigned dispatched or in transit" {...kpiNumber(data.deliveries.assigned_open, true)} />
          <MetricCard label="Delivered" icon={Truck} hint="Assigned proof of delivery" {...kpiNumber(data.deliveries.delivered, true)} />
          <MetricCard label="Exceptions" icon={TriangleAlert} hint="Assigned failed deliveries" {...kpiNumber(data.deliveries.exception, true)} />
        </DashboardGroup>
      ) : null}

      {data.operations.visible ? (
        <DashboardGroup title="Operations">
          <MetricCard
            label="Pending receiving"
            icon={ClipboardCheck}
            hint="Draft, submitted, or held receipts"
            {...kpiNumber(data.operations.pending_receiving, true)}
          />
          <MetricCard
            label="Pending adjustments"
            icon={ClipboardCheck}
            hint="Open adjustment requests"
            {...kpiNumber(data.operations.pending_adjustments, true)}
          />
          <MetricCard
            label="Pending verification"
            icon={ClipboardCheck}
            hint="Open stock counts"
            {...kpiNumber(data.operations.pending_verification, true)}
          />
          <MetricCard
            label="Unclassified products"
            icon={TriangleAlert}
            hint="Expiry policy not set"
            {...kpiNumber(data.operations.unclassified_products, true)}
          />
        </DashboardGroup>
      ) : null}

      <p className="mt-2 text-sm">
        {canAny(access, inventoryReportPermissions) ? (
          <Link className="mr-4 underline" to="/reports/inventory">
            Inventory report
          </Link>
        ) : null}
        {canAny(access, orderReportPermissions) ? (
          <Link className="mr-4 underline" to="/reports/orders-picking">
            Orders and picking
          </Link>
        ) : null}
        {canAny(access, dispatchReportPermissions) ? (
          <Link className="underline" to="/reports/dispatch">
            Dispatch and delivery
          </Link>
        ) : null}
      </p>
    </>
  )
}

function DashboardGroup({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="mb-6">
      <h2 className="mb-3 text-base font-semibold">{title}</h2>
      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">{children}</div>
    </section>
  )
}
