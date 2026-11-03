import { useMemo } from "react"
import { Link, useNavigate, useSearchParams } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { hasCompanyWideGodownAccess, loadOwnAssignedBranchIds } from "@/lib/access/godown-scope"
import {
  createDeliveryNote,
  listVerifiedOrdersWithoutDn,
} from "@/lib/delivery-notes/api"
import {
  canIssueDeliveryNoteForOrder,
  describeDeliveryNoteFormBlock,
  isActiveDeliveryNote,
  mergeHandoverOrderOptions,
} from "@/lib/delivery-notes/handover"
import { getOrder, loadOrderBranches, loadOrderProducts, loadOrderShops } from "@/lib/orders/api"
import { readableSiteLabel } from "@/lib/orders/verification"

export function NewDeliveryNotePage() {
  useDocumentTitle("New delivery note")
  const { can, roles } = useAccess()
  const canIssue = can("delivery_notes.issue")
  const companyWideGodownAccess = hasCompanyWideGodownAccess(can, roles)
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [params, setParams] = useSearchParams()
  // URL is the only selected-order ID so details, dropdown, and submit cannot drift.
  const orderId = params.get("orderId")?.trim() ?? ""

  function setSelectedOrder(next: string) {
    if (next) setParams({ orderId: next }, { replace: true })
    else setParams({}, { replace: true })
  }

  const queue = useQuery({
    queryKey: ["verified-orders-without-dn"],
    queryFn: listVerifiedOrdersWithoutDn,
    enabled: canIssue,
  })
  const assignments = useQuery({
    queryKey: ["own-branch-assignments"],
    queryFn: loadOwnAssignedBranchIds,
    enabled: canIssue && !companyWideGodownAccess,
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
    enabled: orderId !== "" && canIssue,
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
      await queryClient.invalidateQueries({ queryKey: ["delivery-notes"] })
      await queryClient.invalidateQueries({ queryKey: ["verified-orders-without-dn"] })
      await queryClient.invalidateQueries({ queryKey: ["order", orderId] })
      navigate(`/deliveries/${detail.delivery_note.id}`)
    },
  })

  if (!canIssue) {
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
  const openNote = orderDetail.data?.open_delivery_note ?? null
  const hasActiveDeliveryNote = isActiveDeliveryNote(openNote)
  const listedInHandoverQueue = (queue.data ?? []).some((row) => row.id === orderId)
  const assignedBranchIds = assignments.data ?? []
  const canCreate = canIssueDeliveryNoteForOrder({
    canIssue,
    orderStatus: order?.status,
    hasActiveDeliveryNote,
    orderBranchId: order?.branch_id,
    assignedBranchIds,
    listedInHandoverQueue,
    companyWideGodownAccess,
  })
  const block = describeDeliveryNoteFormBlock({
    canIssue,
    orderId,
    orderFound: Boolean(order),
    loadError: orderDetail.error?.message ?? create.error?.message ?? null,
    loading: Boolean(orderId) && (orderDetail.isLoading || assignments.isLoading),
    orderStatus: order?.status,
    hasActiveDeliveryNote,
    activeNoteNumber: openNote?.delivery_note_number ?? null,
    assignedBranchCount: assignedBranchIds.length,
    listedInHandoverQueue,
    companyWideGodownAccess,
    canCreate,
  })
  const options = mergeHandoverOrderOptions(queue.data ?? [], order ?? null)
  const detailsReady = Boolean(order && orderDetail.data && !orderDetail.isFetching)
  const createEnabled =
    canCreate &&
    detailsReady &&
    !create.isPending &&
    !orderDetail.isLoading &&
    (listedInHandoverQueue || companyWideGodownAccess || !assignments.isLoading)

  return (
    <section className="min-w-0">
      <PageHeader
        title="New delivery note"
        description="Creates a draft delivery note that copies every verified order line. Quantities cannot be edited. Stock does not change."
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
            onChange={(event) => setSelectedOrder(event.target.value)}
          >
            <option value="">Select order</option>
            {options.map((row) => (
              <option key={row.id} value={row.id}>
                {row.order_number} · {readableSiteLabel(shopName.get(row.shop_id), "Shop")}
              </option>
            ))}
          </select>
        </label>

        {orderId && orderDetail.isLoading ? <LoadingBlock label="Loading order" /> : null}

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
                <dd>{readableSiteLabel(shopName.get(order.shop_id), "Shop")}</dd>
              </div>
              <div>
                <dt className="text-sm text-muted-foreground">Godown</dt>
                <dd>{readableSiteLabel(branchName.get(order.branch_id), "Godown")}</dd>
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

        {hasActiveDeliveryNote && openNote ? (
          <p role="status" className="rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-950">
            {block}{" "}
            <Link className="underline" to={`/deliveries/${openNote.id}`}>
              Open delivery note
            </Link>
          </p>
        ) : null}

        {block && !hasActiveDeliveryNote && (orderId || create.error) ? (
          <p role="alert" className="text-sm text-destructive">
            {block}
          </p>
        ) : null}

        <Button
          onClick={() => create.mutate()}
          disabled={!createEnabled}
          className="w-full sm:w-auto"
        >
          Create draft delivery note
        </Button>
      </div>
    </section>
  )
}
