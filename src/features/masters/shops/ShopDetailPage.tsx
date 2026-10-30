import { useMemo, useState } from "react"
import { Link, useParams, useSearchParams } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { cn } from "cn"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge, type StatusTone } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { FilterToolbar, SearchField } from "@/features/masters/MasterControls"
import {
  AssignForm,
  ShopDialog,
  loadSalespeople,
  type ShopAssignment,
} from "@/features/masters/shops/shop-form"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAuth } from "@/hooks/use-auth"
import { useAccess } from "@/lib/access/use-access"
import { listDeliveryNotes, type DeliveryNoteStatus } from "@/lib/delivery-notes/api"
import { callRpc, loadRows, loadRowsIfPresent } from "@/lib/masters/api"
import {
  catalogRoutesAsRows,
  nextVisitSequence,
  weekdayLabel,
  type SalesRouteRow,
  type ShopListRow,
  type ShopRouteMembership,
} from "@/lib/masters/shop-routes"
import { listOrders, loadOrderBranches, type OrderStatus } from "@/lib/orders/api"
import { getShop, getShopSalesStatement, shopKeys, type ShopStatementView } from "@/lib/shops/api"
import {
  PAYMENT_UNAVAILABLE_REASON,
  SHOP_STATEMENT_PERMISSION,
  SHOP_STATEMENT_WATERMARK,
  isShopDetailTab,
  shopDetailTabs,
  type ShopDetailTab,
} from "@/lib/shops/rules"
import { downloadShopStatementPdf } from "@/lib/shops/statement-pdf"
import { notify } from "@/lib/utilities/notify"
import { emptyToNull, type ShopValues } from "@/lib/validations/masters"

const orderTone: Record<OrderStatus, StatusTone> = {
  draft: "neutral",
  submitted: "info",
  held: "warning",
  verified: "success",
  cancelled: "danger",
}

const deliveryTone: Record<DeliveryNoteStatus, StatusTone> = {
  draft: "neutral",
  generated: "info",
  sent: "warning",
  acknowledged: "success",
  voided: "danger",
}

const TAB_LABEL: Record<ShopDetailTab, string> = {
  overview: "Overview",
  orders: "Orders",
  deliveries: "Deliveries",
  statement: "Sales Statement",
  payments: "Payments",
}

export function ShopDetailPage() {
  const { shopId = "" } = useParams()
  const [params, setParams] = useSearchParams()
  const requested = params.get("tab") ?? "overview"
  const tab: ShopDetailTab = isShopDetailTab(requested) ? requested : "overview"
  const { can } = useAccess()
  const { session } = useAuth()
  const userId = session?.user.id
  const queryClient = useQueryClient()
  const canAssign = can("shops.assign")
  const canReadStatement = can(SHOP_STATEMENT_PERMISSION)
  const canReadOrders =
    can("orders.capture") || can("orders.verify") || can("operations.monitor")
  const canReadDeliveries =
    can("delivery_notes.issue") ||
    can("delivery_notes.acknowledge") ||
    can("operations.monitor")
  const [editing, setEditing] = useState(false)

  const shop = useQuery({
    queryKey: shopKeys.detail(shopId),
    queryFn: () => getShop(shopId),
    enabled: shopId !== "",
  })
  const assignments = useQuery({
    queryKey: ["shop-assignments"],
    queryFn: () =>
      loadRows<ShopAssignment>(
        "shop_salesperson_assignments",
        "id, shop_id, salesperson_id, is_active",
        "assigned_at",
      ),
  })
  const persistedRoutes = useQuery({
    queryKey: ["sales-routes"],
    queryFn: () =>
      loadRowsIfPresent<SalesRouteRow>(
        "sales_routes",
        "id, code, name, weekday, sort_order, is_active",
        "sort_order",
      ),
  })
  const memberships = useQuery({
    queryKey: ["shop-route-memberships"],
    queryFn: () =>
      loadRowsIfPresent<ShopRouteMembership>(
        "shop_sales_route_memberships",
        "shop_id, route_id, visit_sequence",
        "visit_sequence",
      ),
  })
  const salespeople = useQuery({
    queryKey: ["salesperson-options"],
    enabled: canAssign,
    queryFn: loadSalespeople,
  })

  const persisted = persistedRoutes.data
  const routes = useMemo(
    () => (persisted && persisted.length > 0 ? persisted : catalogRoutesAsRows()),
    [persisted],
  )
  const canPersistRoute = Boolean(canAssign && persisted && persisted.length > 0)
  const names = new Map((salespeople.data ?? []).map((person) => [person.id, person.name]))
  const row = shop.data
  useDocumentTitle(row ? row.name : "Shop")

  const save = useMutation({
    mutationFn: async (values: ShopValues) => {
      await callRpc("update_shop", {
        target_shop: shopId,
        shop_name: values.name,
        shop_phone: emptyToNull(values.phone),
        shop_address: emptyToNull(values.address),
      })
      if (canPersistRoute && values.routeId) {
        const existing = (memberships.data ?? []).find(
          (item) => item.shop_id === shopId && item.route_id === values.routeId,
        )
        await callRpc("set_shop_sales_route", {
          target_shop: shopId,
          target_route: values.routeId,
          visit_sequence:
            existing?.visit_sequence ??
            nextVisitSequence(memberships.data ?? [], values.routeId),
        })
      }
    },
    onSuccess: async () => {
      setEditing(false)
      notify.success("Shop saved")
      await queryClient.invalidateQueries({ queryKey: ["shops"] })
      await queryClient.invalidateQueries({ queryKey: shopKeys.detail(shopId) })
      await queryClient.invalidateQueries({ queryKey: ["shop-route-memberships"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const assign = useMutation({
    mutationFn: (salespersonId: string) =>
      callRpc("assign_shop_salesperson", {
        target_shop: shopId,
        target_salesperson: salespersonId,
      }),
    onSuccess: async () => {
      notify.success("Salesperson assigned")
      await queryClient.invalidateQueries({ queryKey: ["shop-assignments"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const revoke = useMutation({
    mutationFn: (salespersonId: string) =>
      callRpc("revoke_shop_salesperson", {
        target_shop: shopId,
        target_salesperson: salespersonId,
      }),
    onSuccess: async () => {
      notify.success("Assignment revoked")
      await queryClient.invalidateQueries({ queryKey: ["shop-assignments"] })
    },
    onError: (error: Error) => notify.error(error.message),
  })

  const visibleTabs = shopDetailTabs.filter((item) => {
    if (item === "orders") return canReadOrders
    if (item === "deliveries") return canReadDeliveries
    if (item === "statement" || item === "payments") return canReadStatement
    return true
  })
  const activeTab: ShopDetailTab = visibleTabs.includes(tab) ? tab : "overview"
  const canEditShop =
    canAssign ||
    (assignments.data ?? []).some(
      (item) => item.shop_id === shopId && item.salesperson_id === userId && item.is_active,
    )

  if (shop.isLoading) return <LoadingBlock label="Loading shop" />
  if (shop.error) {
    return (
      <EmptyState
        title="Shop could not be loaded"
        description={shop.error instanceof Error ? shop.error.message : "Try again."}
      />
    )
  }
  if (!row) {
    return (
      <EmptyState
        title="Shop not found"
        description="This shop is outside your scope or does not exist."
      />
    )
  }

  const shopMemberships = (memberships.data ?? []).filter((item) => item.shop_id === row.id)
  const shopAssignments = (assignments.data ?? []).filter((item) => item.shop_id === row.id)

  return (
    <section>
      <div className="print:hidden">
        <Button variant="outline" asChild>
          <Link to="/masters/shops">Back to shops</Link>
        </Button>
      </div>
      <PageHeader
        title={row.name}
        description="Shop record, visit route, and operational history. Sales statement amounts are invoice-note previews, not tax invoices."
        action={
          canEditShop ? (
            <Button className="print:hidden" onClick={() => setEditing(true)}>
              Edit shop
            </Button>
          ) : null
        }
      />
      <nav
        className="print:hidden mb-4 flex flex-wrap gap-1 border-b border-slate-200"
        aria-label="Shop sections"
      >
        {visibleTabs.map((item) => (
          <button
            key={item}
            type="button"
            className={cn(
              "px-3 py-2 text-sm font-medium",
              activeTab === item
                ? "border-b-2 border-slate-900 text-slate-900"
                : "text-muted-foreground",
            )}
            aria-current={activeTab === item ? "page" : undefined}
            onClick={() => {
              const next = new URLSearchParams(params)
              next.set("tab", item)
              setParams(next, { replace: true })
            }}
          >
            {TAB_LABEL[item]}
          </button>
        ))}
      </nav>

      {activeTab === "overview" ? (
        <OverviewPanel
          shop={row}
          routes={routes}
          memberships={shopMemberships}
          assignments={shopAssignments}
          names={names}
          people={salespeople.data ?? []}
          userId={userId}
          canAssign={canAssign}
          assignPending={assign.isPending}
          onAssign={(salespersonId) => assign.mutate(salespersonId)}
          onRevoke={(salespersonId) => revoke.mutate(salespersonId)}
        />
      ) : null}
      {activeTab === "orders" && canReadOrders ? <OrdersPanel shopId={row.id} /> : null}
      {activeTab === "deliveries" && canReadDeliveries ? <DeliveriesPanel shopId={row.id} /> : null}
      {activeTab === "statement" && canReadStatement ? <StatementPanel shopId={row.id} /> : null}
      {activeTab === "payments" && canReadStatement ? <PaymentsPanel /> : null}

      {editing ? (
        <ShopDialog
          shop={row}
          routes={routes}
          memberships={memberships.data ?? []}
          assignments={assignments.data ?? []}
          salespersonNames={names}
          canSave={canEditShop}
          canPersistRoute={canPersistRoute}
          pending={save.isPending}
          onClose={() => setEditing(false)}
          onSave={(values) => save.mutate(values)}
        />
      ) : null}
    </section>
  )
}

function OverviewPanel({
  shop,
  routes,
  memberships,
  assignments,
  names,
  people,
  userId,
  canAssign,
  assignPending,
  onAssign,
  onRevoke,
}: {
  shop: ShopListRow
  routes: SalesRouteRow[]
  memberships: ShopRouteMembership[]
  assignments: ShopAssignment[]
  names: Map<string, string>
  people: Array<{ id: string; name: string }>
  userId: string | undefined
  canAssign: boolean
  assignPending: boolean
  onAssign: (salespersonId: string) => void
  onRevoke: (salespersonId: string) => void
}) {
  return (
    <div className="grid gap-6 rounded-2xl bg-white p-4 ring-1 ring-slate-200/80">
      <dl className="grid gap-3 sm:grid-cols-2">
        <div>
          <dt className="text-xs font-medium text-muted-foreground">Status</dt>
          <dd>
            <StatusBadge tone={shop.is_active ? "success" : "neutral"}>
              {shop.is_active ? "Active" : "Inactive"}
            </StatusBadge>
          </dd>
        </div>
        <div>
          <dt className="text-xs font-medium text-muted-foreground">Phone</dt>
          <dd className="text-sm">{shop.phone || "No contact details"}</dd>
        </div>
        <div className="sm:col-span-2">
          <dt className="text-xs font-medium text-muted-foreground">Address</dt>
          <dd className="text-sm">{shop.address || "No address on file"}</dd>
        </div>
      </dl>
      <section>
        <h2 className="text-sm font-semibold">Sales route</h2>
        {memberships.length === 0 ? (
          <p className="mt-1 text-sm text-muted-foreground">No route membership yet.</p>
        ) : (
          <ul className="mt-2 grid gap-1 text-sm">
            {memberships.map((row) => {
              const route = routes.find((item) => item.id === row.route_id)
              return (
                <li key={`${row.route_id}-${row.visit_sequence}`}>
                  {route?.name ?? "Route"} · sequence {row.visit_sequence} · {weekdayLabel(route?.weekday)}
                </li>
              )
            })}
          </ul>
        )}
      </section>
      <section>
        <h2 className="text-sm font-semibold">Salesperson assignments</h2>
        {assignments.length === 0 ? (
          <p className="mt-1 text-sm text-muted-foreground">No assignments in your view.</p>
        ) : (
          <ul className="mt-2 grid gap-2">
            {assignments.map((row) => (
              <li key={row.id} className="flex items-center justify-between gap-2 text-sm">
                <span>
                  {names.get(row.salesperson_id) ??
                    (row.salesperson_id === userId ? "You" : "Salesperson")}
                  {row.is_active ? "" : " · revoked"}
                </span>
                {canAssign && row.is_active ? (
                  <Button variant="outline" onClick={() => onRevoke(row.salesperson_id)}>
                    Revoke
                  </Button>
                ) : null}
              </li>
            ))}
          </ul>
        )}
        {canAssign && shop.is_active ? (
          <div className="mt-3">
            <AssignForm people={people} pending={assignPending} onAssign={onAssign} />
          </div>
        ) : null}
      </section>
    </div>
  )
}

function OrdersPanel({ shopId }: { shopId: string }) {
  const orders = useQuery({ queryKey: ["orders", "all"], queryFn: () => listOrders("all") })
  const branches = useQuery({ queryKey: ["order-branches"], queryFn: loadOrderBranches })
  const rows = (orders.data ?? []).filter((row) => row.shop_id === shopId)
  const branchName = new Map((branches.data ?? []).map((row) => [row.id, row.name]))

  if (orders.isLoading) return <LoadingBlock label="Loading orders" />
  if (orders.error) {
    return <p role="alert" className="text-sm text-destructive">{orders.error.message}</p>
  }
  if (rows.length === 0) {
    return (
      <EmptyState
        title="No orders for this shop"
        description="Orders appear after one is captured. Sample rows are not listed."
      />
    )
  }

  return (
    <ul className="grid gap-3">
      {rows.map((row) => (
        <li key={row.id}>
          <Link to={`/orders/${row.id}`} className="block rounded-2xl bg-card p-4 ring-1 ring-border">
            <div className="flex items-start justify-between gap-3">
              <div>
                <p className="font-medium">{row.order_number}</p>
                <p className="text-sm text-muted-foreground">
                  {branchName.get(row.branch_id) ?? "Godown"} · {row.created_at.slice(0, 10)}
                </p>
              </div>
              <StatusBadge tone={orderTone[row.status]}>{row.status}</StatusBadge>
            </div>
          </Link>
        </li>
      ))}
    </ul>
  )
}

function DeliveriesPanel({ shopId }: { shopId: string }) {
  const notes = useQuery({
    queryKey: ["delivery-notes", "all", shopId],
    queryFn: () => listDeliveryNotes({ shopId }),
  })
  const rows = notes.data ?? []

  if (notes.isLoading) return <LoadingBlock label="Loading deliveries" />
  if (notes.error) {
    return <p role="alert" className="text-sm text-destructive">{notes.error.message}</p>
  }
  if (rows.length === 0) {
    return (
      <EmptyState
        title="No delivery notes for this shop"
        description="Delivery notes you are allowed to see will appear here."
      />
    )
  }

  return (
    <ul className="grid gap-3">
      {rows.map((row) => (
        <li key={row.id}>
          <Link
            to={`/deliveries/${row.id}`}
            className="block rounded-2xl bg-card p-4 ring-1 ring-border"
          >
            <div className="flex items-start justify-between gap-3">
              <div>
                <p className="font-medium">{row.delivery_note_number}</p>
                <p className="text-sm text-muted-foreground">
                  {row.order_number ?? "Order"} · {row.created_at.slice(0, 10)}
                </p>
              </div>
              <StatusBadge tone={deliveryTone[row.status]}>{row.status}</StatusBadge>
            </div>
          </Link>
        </li>
      ))}
    </ul>
  )
}

function StatementPanel({ shopId }: { shopId: string }) {
  const [from, setFrom] = useState("")
  const [to, setTo] = useState("")
  const [search, setSearch] = useState("")
  const statement = useQuery({
    queryKey: shopKeys.statement(shopId, from, to, search),
    queryFn: () => getShopSalesStatement({ shopId, from, to, search }),
  })

  if (statement.isLoading) return <LoadingBlock label="Loading sales statement" />
  if (statement.error) {
    return <p role="alert" className="text-sm text-destructive">{statement.error.message}</p>
  }
  const view = statement.data
  if (!view) return null

  return (
    <div className="grid gap-4">
      <p role="note" className="max-w-4xl text-sm leading-6 text-muted-foreground">
        {view.watermark}. {view.paymentReason}
      </p>
      <FilterToolbar>
        <SearchField label="Search bill or reference" value={search} onChange={setSearch} />
        <label className="grid gap-1.5 text-sm font-medium">
          <span>From</span>
          <input
            type="date"
            aria-label="From date"
            value={from}
            onChange={(event) => setFrom(event.target.value)}
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm"
          />
        </label>
        <label className="grid gap-1.5 text-sm font-medium">
          <span>To</span>
          <input
            type="date"
            aria-label="To date"
            value={to}
            onChange={(event) => setTo(event.target.value)}
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm"
          />
        </label>
      </FilterToolbar>
      <div className="print:hidden flex flex-wrap gap-2">
        <Button variant="outline" onClick={() => window.print()}>
          Print
        </Button>
        <Button variant="outline" onClick={() => downloadShopStatementPdf(view)}>
          Download PDF
        </Button>
      </div>
      <StatementSummary view={view} />
      {view.entries.length === 0 ? (
        <EmptyState
          title="No statement rows yet"
          description="Billing and delivery history for this shop will appear when invoice notes or delivery notes exist. Payments are not posted."
        />
      ) : (
        <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200/80">
          <table className="min-w-full text-left text-sm">
            <thead className="border-b border-slate-200 text-xs uppercase text-muted-foreground">
              <tr>
                <th className="px-3 py-2 font-medium">Date</th>
                <th className="px-3 py-2 font-medium">Particulars</th>
                <th className="px-3 py-2 font-medium">Bill / ref.</th>
                <th className="px-3 py-2 font-medium">Bill amount</th>
                <th className="px-3 py-2 font-medium">Cash received</th>
                <th className="px-3 py-2 font-medium">Balance</th>
                <th className="px-3 py-2 font-medium">Ack.</th>
                <th className="px-3 py-2 font-medium">Remarks</th>
                <th className="px-3 py-2 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {view.entries.map((row) => (
                <tr key={row.id} className="border-b border-slate-100">
                  <td className="px-3 py-2 whitespace-nowrap">{row.transactionDate}</td>
                  <td className="px-3 py-2">{row.particulars}</td>
                  <td className="px-3 py-2">
                    {row.href ? (
                      <Link className="underline" to={row.href}>
                        {row.referenceNumber}
                      </Link>
                    ) : (
                      row.referenceNumber
                    )}
                  </td>
                  <td className="px-3 py-2 whitespace-nowrap">{row.billAmount.display}</td>
                  <td className="px-3 py-2 whitespace-nowrap">{row.amountReceived.display}</td>
                  <td className="px-3 py-2 whitespace-nowrap">{row.runningBalance.display}</td>
                  <td className="px-3 py-2">{row.acknowledgement ?? "—"}</td>
                  <td className="px-3 py-2">{row.remarks ?? "—"}</td>
                  <td className="px-3 py-2">{row.statusLabel}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

function StatementSummary({ view }: { view: ShopStatementView }) {
  return (
    <dl className="grid gap-3 sm:grid-cols-3">
      <SummaryCard label="Reviewed notes" value={view.summary.reviewedNoteTotal.display} />
      <SummaryCard label="Submitted notes" value={view.summary.submittedNoteTotal.display} />
      <SummaryCard label="Draft notes" value={view.summary.draftNoteTotal.display} />
      <SummaryCard
        label="Credit adjustment previews"
        value={view.summary.creditAdjustmentPreviewTotal.display}
      />
      <SummaryCard label="Cash received" value={view.summary.amountReceived.display} />
      <SummaryCard label="Outstanding" value={view.summary.outstanding.display} />
    </dl>
  )
}

function SummaryCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl bg-slate-50 px-3 py-2">
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="text-sm font-medium">{value}</dd>
    </div>
  )
}

function PaymentsPanel() {
  return (
    <EmptyState
      title="Payments are not posted"
      description={`${PAYMENT_UNAVAILABLE_REASON} ${SHOP_STATEMENT_WATERMARK}`}
    />
  )
}
