import { useMemo, useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge, type StatusTone } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { SearchField } from "@/features/masters/MasterControls"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { matchesSearch } from "@/lib/masters/filters"
import {
  listOrders,
  loadOrderBranches,
  loadOrderShops,
  type OrderStatus,
} from "@/lib/orders/api"

const tone: Record<OrderStatus, StatusTone> = {
  draft: "neutral",
  submitted: "info",
  held: "warning",
  verified: "success",
  cancelled: "danger",
}

export function OrdersPage() {
  useDocumentTitle("Orders")
  const { can } = useAccess()
  const [search, setSearch] = useState("")
  const [status, setStatus] = useState("all")
  const [shopId, setShopId] = useState("all")
  const [branchId, setBranchId] = useState("all")
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
  const shopName = useMemo(() => {
    return new Map((shops.data ?? []).map((shop) => [shop.id, shop.name]))
  }, [shops.data])
  const branchName = useMemo(() => {
    return new Map((branches.data ?? []).map((branch) => [branch.id, branch.name]))
  }, [branches.data])
  const rows = (orders.data ?? []).filter((row) => {
    if (shopId !== "all" && row.shop_id !== shopId) return false
    if (branchId !== "all" && row.branch_id !== branchId) return false
    return matchesSearch(search, [
      row.order_number,
      shopName.get(row.shop_id) ?? "",
      branchName.get(row.branch_id) ?? "",
      row.status,
      row.source,
    ])
  })

  return (
    <section className="min-w-0">
      <PageHeader
        title="Orders"
        description="Capture shop requests. Accounts verifies availability later. Inventory does not change here."
        action={
          can("orders.capture") ? (
            <Button asChild>
              <Link to="/orders/new">New order</Link>
            </Button>
          ) : null
        }
      />
      {orders.isLoading || shops.isLoading || branches.isLoading ? (
        <LoadingBlock label="Loading orders" />
      ) : null}
      {orders.error || shops.error || branches.error ? (
        <p role="alert" className="text-sm text-destructive">
          {(orders.error ?? shops.error ?? branches.error)?.message}
        </p>
      ) : null}
      {orders.data ? (
        <>
          <div className="mb-4 grid gap-3 md:grid-cols-4">
            <SearchField label="Search orders" value={search} onChange={setSearch} />
            <label className="grid gap-2 text-sm font-medium">
              Status
              <select
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={status}
                onChange={(event) => setStatus(event.target.value)}
              >
                <option value="all">All statuses</option>
                <option value="draft">Draft</option>
                <option value="submitted">Submitted</option>
                <option value="held">Held</option>
                <option value="verified">Verified</option>
                <option value="cancelled">Cancelled</option>
              </select>
            </label>
            <label className="grid gap-2 text-sm font-medium">
              Shop
              <select
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={shopId}
                onChange={(event) => setShopId(event.target.value)}
              >
                <option value="all">All shops</option>
                {(shops.data ?? []).map((shop) => (
                  <option key={shop.id} value={shop.id}>
                    {shop.name}
                  </option>
                ))}
              </select>
            </label>
            <label className="grid gap-2 text-sm font-medium">
              Godown
              <select
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={branchId}
                onChange={(event) => setBranchId(event.target.value)}
              >
                <option value="all">All godowns</option>
                {(branches.data ?? []).map((branch) => (
                  <option key={branch.id} value={branch.id}>
                    {branch.name}
                  </option>
                ))}
              </select>
            </label>
          </div>
          {rows.length === 0 ? (
            <EmptyState
              title="No orders yet"
              description="Orders appear after one is captured. Sample rows are not listed."
            />
          ) : (
            <ul className="grid gap-3">
              {rows.map((row) => (
                <li key={row.id}>
                  <Link
                    to={`/orders/${row.id}`}
                    className="block rounded-2xl bg-card p-4 ring-1 ring-border"
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <p className="font-medium">{row.order_number}</p>
                        <p className="text-sm text-muted-foreground">
                          {shopName.get(row.shop_id) ?? "Shop"} ·{" "}
                          {branchName.get(row.branch_id) ?? "Godown"}
                        </p>
                      </div>
                      <StatusBadge tone={tone[row.status]}>{row.status}</StatusBadge>
                    </div>
                    <p className="mt-3 text-sm text-muted-foreground">
                      {row.source} · {row.created_at.slice(0, 10)}
                    </p>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </>
      ) : null}
    </section>
  )
}
