import { useMemo, useState } from "react"
import { Link, useNavigate, useSearchParams } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import {
  createDeliveryNote,
  listVerifiedOrdersWithoutDn,
} from "@/lib/delivery-notes/api"
import { getOrder, loadOrderBranches, loadOrderProducts, loadOrderShops } from "@/lib/orders/api"

export function NewDeliveryNotePage() {
  useDocumentTitle("New delivery note")
  const { can } = useAccess()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [params] = useSearchParams()
  const initialOrderId = params.get("orderId") ?? ""
  const [orderId, setOrderId] = useState(initialOrderId)
  const [actionError, setActionError] = useState<string | null>(null)

  const queue = useQuery({
    queryKey: ["verified-orders-without-dn"],
    queryFn: listVerifiedOrdersWithoutDn,
    enabled: can("delivery_notes.issue"),
  })
  const shops = useQuery({ queryKey: ["order-shops"], queryFn: loadOrderShops })
  const branches = useQuery({
    queryKey: ["order-branches"],
    queryFn: loadOrderBranches,
  })
  const products = useQuery({
    queryKey: ["order-products"],
    queryFn: loadOrderProducts,
  })
  const orderDetail = useQuery({
    queryKey: ["order", orderId],
    queryFn: () => getOrder(orderId),
    enabled: orderId !== "" && can("delivery_notes.issue"),
  })

  const shopName = useMemo(
    () => new Map((shops.data ?? []).map((shop) => [shop.id, shop.name])),
    [shops.data],
  )
  const branchName = useMemo(
    () => new Map((branches.data ?? []).map((branch) => [branch.id, branch.name])),
    [branches.data],
  )
  const productName = useMemo(
    () =>
      new Map(
        (products.data ?? []).map((product) => [product.id, `${product.sku} · ${product.name}`]),
      ),
    [products.data],
  )

  const create = useMutation({
    mutationFn: () => {
      if (!orderId) throw new Error("Select a verified order.")
      return createDeliveryNote(orderId, `dn-create-${crypto.randomUUID()}`)
    },
    onSuccess: async (detail) => {
      setActionError(null)
      await queryClient.invalidateQueries({ queryKey: ["delivery-notes"] })
      await queryClient.invalidateQueries({ queryKey: ["verified-orders-without-dn"] })
      navigate(`/deliveries/${detail.delivery_note.id}`)
    },
    onError: (error: Error) => setActionError(error.message),
  })

  if (!can("delivery_notes.issue")) {
    return (
      <section className="min-w-0">
        <PageHeader title="New delivery note" description="Accounts only." />
        <EmptyState
          title="Not authorized"
          description="Only Accounts can create delivery notes."
        />
      </section>
    )
  }

  const order = orderDetail.data?.order

  return (
    <section className="min-w-0">
      <PageHeader
        title="New delivery note"
        description="Creates a draft delivery note that copies every verified order line. Quantities cannot be edited."
        action={
          <Button asChild variant="outline">
            <Link to="/deliveries">Back</Link>
          </Button>
        }
      />

      <div className="grid gap-6">
        <label className="grid gap-2 text-sm font-medium">
          Verified order
          <select
            className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
            value={orderId}
            onChange={(event) => setOrderId(event.target.value)}
          >
            <option value="">Select order</option>
            {(queue.data ?? []).map((row) => (
              <option key={row.id} value={row.id}>
                {row.order_number} · {shopName.get(row.shop_id) ?? row.shop_id}
              </option>
            ))}
          </select>
        </label>

        {orderId && orderDetail.isLoading ? <LoadingBlock label="Loading order" /> : null}
        {orderDetail.error ? (
          <p role="alert" className="text-sm text-destructive">
            {orderDetail.error.message}
          </p>
        ) : null}

        {order && orderDetail.data ? (
          <div className="grid gap-4">
            <dl className="grid gap-3 sm:grid-cols-2">
              <div>
                <dt className="text-sm text-muted-foreground">Order</dt>
                <dd>{order.order_number}</dd>
              </div>
              <div>
                <dt className="text-sm text-muted-foreground">Status</dt>
                <dd>{order.status}</dd>
              </div>
              <div>
                <dt className="text-sm text-muted-foreground">Shop</dt>
                <dd>{shopName.get(order.shop_id) ?? order.shop_id}</dd>
              </div>
              <div>
                <dt className="text-sm text-muted-foreground">Godown</dt>
                <dd>{branchName.get(order.branch_id) ?? order.branch_id}</dd>
              </div>
            </dl>
            <div>
              <h2 className="mb-2 text-sm font-medium">Lines to copy</h2>
              <ul className="grid gap-2">
                {orderDetail.data.lines.map((line) => (
                  <li
                    key={line.id}
                    className="flex items-center justify-between gap-3 rounded-2xl bg-card px-4 py-3 text-sm ring-1 ring-border"
                  >
                    <span>{productName.get(line.product_id) ?? line.product_id}</span>
                    <span>{line.requested_cases} cases</span>
                  </li>
                ))}
              </ul>
            </div>
          </div>
        ) : null}

        {actionError ? (
          <p role="alert" className="text-sm text-destructive">
            {actionError}
          </p>
        ) : null}

        <Button
          onClick={() => create.mutate()}
          disabled={!orderId || create.isPending || order?.status !== "verified"}
          className="w-full sm:w-auto"
        >
          Create draft delivery note
        </Button>
      </div>
    </section>
  )
}
