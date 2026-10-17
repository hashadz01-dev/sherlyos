import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useNavigate, useParams } from "react-router"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { OrderForm, type OrderFormValues } from "@/features/orders/OrderForm"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { useAuth } from "@/hooks/use-auth"
import {
  createOrder,
  getOrder,
  loadOrderBranches,
  loadOrderProducts,
  loadOrderShops,
  setOrder,
} from "@/lib/orders/api"

export function NewOrderPage() {
  useDocumentTitle("New order")
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { can } = useAccess()
  const shops = useQuery({ queryKey: ["order-shops"], queryFn: loadOrderShops })
  const branches = useQuery({ queryKey: ["order-branches"], queryFn: loadOrderBranches })
  const products = useQuery({ queryKey: ["order-products"], queryFn: loadOrderProducts })
  const create = useMutation({
    mutationFn: (values: OrderFormValues) =>
      createOrder({
        shopId: values.shopId,
        branchId: values.branchId,
        source: values.source,
        sourceReference: values.sourceReference,
        notes: values.notes,
        lines: values.lines,
        idempotencyKey: `ord-${crypto.randomUUID()}`,
      }),
    onSuccess: async (created) => {
      await queryClient.invalidateQueries({ queryKey: ["orders"] })
      navigate(`/orders/${created.order.id}`)
    },
  })

  if (!can("orders.capture")) {
    return null
  }

  return (
    <section className="min-w-0">
      <PageHeader
        title="New order"
        description="Save a draft request for an authorized shop and godown. Stock is not reserved."
      />
      {shops.isLoading || branches.isLoading || products.isLoading ? (
        <LoadingBlock label="Loading catalog" />
      ) : null}
      {shops.error || branches.error || products.error ? (
        <p role="alert" className="text-sm text-destructive">
          {(shops.error ?? branches.error ?? products.error)?.message}
        </p>
      ) : null}
      {shops.data && branches.data && products.data ? (
        <OrderForm
          shops={shops.data}
          branches={branches.data}
          products={products.data}
          initial={{
            shopId: "",
            branchId: "",
            source: can("orders.verify") ? "accounts" : "salesperson",
            sourceReference: "",
            notes: "",
            lines: [{ product_id: "", requested_cases: 1 }],
          }}
          submitLabel="Create draft"
          pending={create.isPending}
          error={create.error?.message ?? null}
          onSubmit={(values) => create.mutate(values)}
        />
      ) : null}
    </section>
  )
}

export function EditOrderPage() {
  const { orderId = "" } = useParams()
  useDocumentTitle("Edit order")
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { session } = useAuth()
  const detail = useQuery({
    queryKey: ["order", orderId],
    queryFn: () => getOrder(orderId),
    enabled: orderId !== "",
  })
  const shops = useQuery({ queryKey: ["order-shops"], queryFn: loadOrderShops })
  const branches = useQuery({ queryKey: ["order-branches"], queryFn: loadOrderBranches })
  const products = useQuery({ queryKey: ["order-products"], queryFn: loadOrderProducts })
  const save = useMutation({
    mutationFn: (values: OrderFormValues) => {
      if (!detail.data) {
        throw new Error("Order is not loaded.")
      }
      return setOrder({
        orderId,
        expectedVersion: detail.data.order.version,
        shopId: values.shopId,
        branchId: values.branchId,
        source: values.source,
        sourceReference: values.sourceReference,
        notes: values.notes,
        lines: values.lines,
        idempotencyKey: `ord-edit-${crypto.randomUUID()}`,
      })
    },
    onSuccess: async (updated) => {
      await queryClient.invalidateQueries({ queryKey: ["orders"] })
      await queryClient.invalidateQueries({ queryKey: ["order", orderId] })
      navigate(`/orders/${updated.order.id}`)
    },
  })
  const order = detail.data?.order
  const editable =
    order &&
    session?.user.id === order.created_by &&
    (order.status === "draft" || order.status === "held")

  return (
    <section className="min-w-0">
      <PageHeader
        title={order ? `Edit ${order.order_number}` : "Edit order"}
        description="Replace the shop, godown, source, and lines. Status stays the same."
      />
      {detail.isLoading || shops.isLoading || branches.isLoading || products.isLoading ? (
        <LoadingBlock label="Loading order" />
      ) : null}
      {detail.error || shops.error || branches.error || products.error ? (
        <p role="alert" className="text-sm text-destructive">
          {(detail.error ?? shops.error ?? branches.error ?? products.error)?.message}
        </p>
      ) : null}
      {order && !editable ? (
        <p role="alert" className="text-sm text-destructive">
          Only the creator can edit a draft or held order.
        </p>
      ) : null}
      {editable && detail.data && shops.data && branches.data && products.data ? (
        <OrderForm
          shops={shops.data}
          branches={branches.data}
          products={products.data}
          initial={{
            shopId: order.shop_id,
            branchId: order.branch_id,
            source: order.source,
            sourceReference: order.source_reference ?? "",
            notes: order.notes ?? "",
            lines: detail.data.lines.map((line) => ({
              product_id: line.product_id,
              requested_cases: line.requested_cases,
            })),
          }}
          submitLabel="Save changes"
          pending={save.isPending}
          error={save.error?.message ?? null}
          onSubmit={(values) => save.mutate(values)}
        />
      ) : null}
    </section>
  )
}
