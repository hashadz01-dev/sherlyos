import { useMemo, useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { FilterSelect, FilterToolbar, SearchField } from "@/features/masters/MasterControls"
import { ReportPager } from "@/features/reports/ReportControls"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import {
  listOrders,
  loadOrderBranches,
  loadOrderCaseTotals,
  loadOrderShops,
} from "@/lib/orders/api"
import {
  filterOrderQueueRows,
  formatOrderTimestamp,
  orderRecordPath,
  paginateRows,
  readableSiteLabel,
  shouldShowNewOrderAction,
  VERIFICATION_DEFAULT_STATUS_FILTER,
  VERIFICATION_PAGE_SIZE,
  VERIFICATION_STATUS_FILTERS,
  verificationActionLabel,
  verificationQueueEmptyCopy,
  verificationStatusLabel,
  verificationStatusTone,
  type OrderWorkflowMode,
} from "@/lib/orders/verification"

function OrdersQueue({ mode }: { mode: OrderWorkflowMode }) {
  const isVerification = mode === "verification"
  useDocumentTitle(isVerification ? "Order verification" : "Orders")
  const { can } = useAccess()
  const [search, setSearch] = useState("")
  const [status, setStatus] = useState(
    isVerification ? VERIFICATION_DEFAULT_STATUS_FILTER : "all",
  )
  const [shopId, setShopId] = useState("all")
  const [branchId, setBranchId] = useState("all")
  const filterKey = `${search}|${status}|${shopId}|${branchId}`
  const [pageState, setPageState] = useState({ key: filterKey, page: 1 })
  const page = pageState.key === filterKey ? pageState.page : 1
  const orders = useQuery({
    queryKey: ["orders", status],
    queryFn: () => listOrders(status),
  })
  const shops = useQuery({
    queryKey: ["order-shops"],
    queryFn: loadOrderShops,
  })
  const branches = useQuery({
    queryKey: ["order-branches"],
    queryFn: loadOrderBranches,
  })
  const orderIds = (orders.data ?? []).map((row) => row.id)
  const caseTotals = useQuery({
    queryKey: ["order-case-totals", orderIds.join(",")],
    queryFn: () => loadOrderCaseTotals(orderIds),
    enabled: orderIds.length > 0,
  })
  const shopName = useMemo(() => {
    return new Map((shops.data ?? []).map((shop) => [shop.id, shop.name]))
  }, [shops.data])
  const branchName = useMemo(() => {
    return new Map((branches.data ?? []).map((branch) => [branch.id, branch.name]))
  }, [branches.data])
  const filtered = filterOrderQueueRows(orders.data ?? [], {
    search,
    shopId,
    branchId,
    shopName,
    branchName,
  })
  const paged = paginateRows(filtered, page, VERIFICATION_PAGE_SIZE)

  return (
    <section className="min-w-0">
      <PageHeader
        title={isVerification ? "Order verification" : "Orders"}
        description={
          isVerification
            ? "Submitted orders awaiting Accounts review, plus previously verified and held records. Verify and hold call the authorized RPCs. Inventory does not change here."
            : "Capture shop requests. Accounts verifies availability later. Inventory does not change here."
        }
        action={
          shouldShowNewOrderAction({
            mode,
            canCapture: can("orders.capture"),
          }) ? (
            <Button asChild>
              <Link to="/orders/new">New order</Link>
            </Button>
          ) : null
        }
      />
      {orders.isLoading || shops.isLoading || branches.isLoading ? (
        <LoadingBlock label={isVerification ? "Loading verification queue" : "Loading orders"} />
      ) : null}
      {orders.error || shops.error || branches.error ? (
        <p role="alert" className="text-sm text-destructive">
          {(orders.error ?? shops.error ?? branches.error)?.message}
        </p>
      ) : null}
      {orders.data ? (
        <>
          <FilterToolbar>
            <SearchField label="Search order number or shop" value={search} onChange={setSearch} />
            <FilterSelect label="Status" value={status} onChange={setStatus}>
              {isVerification ? (
                VERIFICATION_STATUS_FILTERS.map((value) => (
                  <option key={value} value={value}>
                    {value === "all" ? "All verification statuses" : verificationStatusLabel(value)}
                  </option>
                ))
              ) : (
                <>
                  <option value="all">All statuses</option>
                  <option value="draft">Draft</option>
                  <option value="submitted">Submitted</option>
                  <option value="held">Held</option>
                  <option value="verified">Verified</option>
                  <option value="cancelled">Cancelled</option>
                </>
              )}
            </FilterSelect>
            <FilterSelect label="Shop" value={shopId} onChange={setShopId}>
              <option value="all">All shops</option>
              {(shops.data ?? []).map((shop) => (
                <option key={shop.id} value={shop.id}>
                  {shop.name}
                </option>
              ))}
            </FilterSelect>
            <FilterSelect label="Godown" value={branchId} onChange={setBranchId}>
              <option value="all">All godowns</option>
              {(branches.data ?? []).map((branch) => (
                <option key={branch.id} value={branch.id}>
                  {branch.name}
                </option>
              ))}
            </FilterSelect>
          </FilterToolbar>
          {filtered.length === 0 ? (
            <EmptyState
              title={
                isVerification
                  ? verificationQueueEmptyCopy(status).title
                  : "No orders yet"
              }
              description={
                isVerification
                  ? verificationQueueEmptyCopy(status).description
                  : "Orders appear after one is captured. Sample rows are not listed."
              }
            />
          ) : (
            <>
              <ul className="grid gap-3">
                {paged.rows.map((row) => {
                  const cases = caseTotals.data?.get(row.id)
                  return (
                    <li key={row.id}>
                      <Link
                        to={orderRecordPath(mode, row.id)}
                        className="block rounded-2xl bg-card p-4 ring-1 ring-border"
                      >
                        <div className="flex items-start justify-between gap-3">
                          <div>
                            <p className="font-medium">{row.order_number}</p>
                            <p className="text-sm text-muted-foreground">
                              {readableSiteLabel(shopName.get(row.shop_id), "Shop")} ·{" "}
                              {readableSiteLabel(branchName.get(row.branch_id), "Godown")}
                            </p>
                          </div>
                          <StatusBadge tone={verificationStatusTone(row.status)}>
                            {verificationStatusLabel(row.status)}
                          </StatusBadge>
                        </div>
                        {isVerification ? (
                          <dl className="mt-3 grid gap-1 text-sm text-muted-foreground sm:grid-cols-2">
                            <div>
                              <dt className="inline">Requested cases: </dt>
                              <dd className="inline">{cases ?? "—"}</dd>
                            </div>
                            <div>
                              <dt className="inline">Submitted: </dt>
                              <dd className="inline">{formatOrderTimestamp(row.submitted_at)}</dd>
                            </div>
                            <div className="sm:col-span-2">
                              <dt className="inline">Next: </dt>
                              <dd className="inline">{verificationActionLabel(row.status)}</dd>
                            </div>
                          </dl>
                        ) : (
                          <p className="mt-3 text-sm text-muted-foreground">
                            {row.source} · {row.created_at.slice(0, 10)}
                            {cases != null ? ` · ${cases} cases` : null}
                          </p>
                        )}
                      </Link>
                    </li>
                  )
                })}
              </ul>
              {paged.total > VERIFICATION_PAGE_SIZE ? (
                <ReportPager
                  page={paged.page}
                  pageSize={VERIFICATION_PAGE_SIZE}
                  total={paged.total}
                  onPage={(next) => setPageState({ key: filterKey, page: next })}
                />
              ) : null}
            </>
          )}
        </>
      ) : null}
    </section>
  )
}

export function OrdersPage() {
  return <OrdersQueue mode="capture" />
}

export function OrderVerificationPage() {
  return <OrdersQueue mode="verification" />
}
