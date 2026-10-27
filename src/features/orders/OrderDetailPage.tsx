import { useState } from "react"
import { Link, useParams } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge, type StatusTone } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { useAuth } from "@/hooks/use-auth"
import {
  cancelOrder,
  checkOrderAvailability,
  getOrder,
  holdOrder,
  InsufficientStockError,
  loadOrderBranches,
  loadOrderProducts,
  loadOrderShops,
  submitOrder,
  verifyOrder,
  type AvailabilityLine,
  type OrderStatus,
} from "@/lib/orders/api"
import {
  deliveryNoteHandoverLabel,
  isAcknowledgedDeliveryNote,
} from "@/lib/orders/availability"
import {
  cutoverBlocksPicking,
  nextOrderPickingAction,
  pickingStatusLabel,
} from "@/lib/picking/rules"
import { approveShortShipment } from "@/lib/shipments/api"
import {
  shipmentStatusLabel,
  shipmentStatusTone,
  type ShipmentStatus,
} from "@/lib/shipments/rules"

const tone: Record<OrderStatus, StatusTone> = {
  draft: "neutral",
  submitted: "info",
  held: "warning",
  verified: "success",
  cancelled: "danger",
}

export function OrderDetailPage() {
  const { orderId = "" } = useParams()
  const { session } = useAuth()
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const [holdNote, setHoldNote] = useState("")
  const [cancelReason, setCancelReason] = useState("")
  const [confirmCancel, setConfirmCancel] = useState(false)
  const [shortages, setShortages] = useState<AvailabilityLine[] | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)

  const detail = useQuery({
    queryKey: ["order", orderId],
    queryFn: () => getOrder(orderId),
    enabled: orderId !== "",
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
  const availability = useQuery({
    queryKey: ["order-availability", orderId],
    queryFn: () => checkOrderAvailability(orderId),
    enabled:
      orderId !== "" &&
      can("orders.verify") &&
      detail.data?.order.status === "submitted",
  })

  const order = detail.data?.order
  useDocumentTitle(order ? order.order_number : "Order")
  const shopName = shops.data?.find((shop) => shop.id === order?.shop_id)?.name
  const branchName = branches.data?.find((branch) => branch.id === order?.branch_id)?.name
  const productName = new Map(
    (products.data ?? []).map((product) => [product.id, `${product.sku} · ${product.name}`]),
  )

  const isCreator = Boolean(order && session?.user.id === order.created_by)
  const canEdit = isCreator && (order?.status === "draft" || order?.status === "held")
  const canSubmit = isCreator && can("orders.capture") && (order?.status === "draft" || order?.status === "held")
  const canHold = can("orders.verify") && order?.status === "submitted"
  const canVerify = can("orders.verify") && order?.status === "submitted"
  const canCancelCreator =
    isCreator && can("orders.capture") && (order?.status === "draft" || order?.status === "held")
  const canCancelAccounts =
    can("orders.verify") && (order?.status === "submitted" || order?.status === "verified")
  const openNote = detail.data?.open_delivery_note ?? null
  const openPicking = detail.data?.open_picking_request ?? null
  const pickingCutover = detail.data?.picking_cutover ?? null
  const dnAcknowledged = isAcknowledgedDeliveryNote(openNote)
  const cutoverMessage = pickingCutover ? cutoverBlocksPicking(pickingCutover) : null
  const openShipment = detail.data?.open_shipment ?? null
  const linkedBackorder = detail.data?.linked_backorder ?? null
  const nextAction = order
    ? nextOrderPickingAction({
        orderStatus: order.status,
        dnStatus: openNote?.status ?? null,
        pickingStatus: openPicking?.status ?? null,
        hasShortage: openPicking?.fulfilment.has_shortage === true,
        cutoverBlocked: Boolean(cutoverMessage),
        shipmentStatus: openShipment?.status ?? openPicking?.fulfilment.shipment_status ?? null,
        fulfilmentStatus: order.fulfilment_status ?? null,
      })
    : null
  const canCreateDeliveryNote =
    can("delivery_notes.issue") && order?.status === "verified" && openNote == null
  const canAllocatePicking =
    can("picking.allocate") &&
    order?.status === "verified" &&
    dnAcknowledged &&
    openPicking == null
  const canOpenDispatch =
    can("dispatch.confirm") &&
    order?.status === "verified" &&
    openPicking?.status === "ready_for_dispatch"

  async function refresh() {
    await queryClient.invalidateQueries({ queryKey: ["orders"] })
    await queryClient.invalidateQueries({ queryKey: ["order", orderId] })
    await queryClient.invalidateQueries({ queryKey: ["order-availability", orderId] })
  }

  const submit = useMutation({
    mutationFn: () => {
      if (!order) throw new Error("Order is not loaded.")
      return submitOrder(order.id, order.version, `ord-submit-${crypto.randomUUID()}`)
    },
    onSuccess: async () => {
      setActionError(null)
      setShortages(null)
      await refresh()
    },
    onError: (error: Error) => setActionError(error.message),
  })

  const hold = useMutation({
    mutationFn: () => {
      if (!order) throw new Error("Order is not loaded.")
      return holdOrder(order.id, order.version, holdNote, `ord-hold-${crypto.randomUUID()}`)
    },
    onSuccess: async () => {
      setActionError(null)
      setShortages(null)
      setHoldNote("")
      await refresh()
    },
    onError: (error: Error) => setActionError(error.message),
  })

  const verify = useMutation({
    mutationFn: () => {
      if (!order) throw new Error("Order is not loaded.")
      return verifyOrder(order.id, order.version, `ord-verify-${crypto.randomUUID()}`)
    },
    onSuccess: async () => {
      setActionError(null)
      setShortages(null)
      await refresh()
    },
    onError: (error: Error) => {
      if (error instanceof InsufficientStockError) {
        setShortages(error.shortages)
        setActionError(error.message)
        return
      }
      setActionError(error.message)
    },
  })

  const approveShipment = useMutation({
    mutationFn: () => {
      if (!openShipment) throw new Error("Shipment is not loaded.")
      return approveShortShipment({
        target_shipment: openShipment.id,
        expected_version: openShipment.version,
        lot_quantities: null,
        idempotency_key: `sh-appr-${crypto.randomUUID()}`,
      })
    },
    onSuccess: async () => {
      setActionError(null)
      await refresh()
    },
    onError: (error: Error) => setActionError(error.message),
  })

  const cancel = useMutation({
    mutationFn: () => {
      if (!order) throw new Error("Order is not loaded.")
      return cancelOrder(
        order.id,
        order.version,
        canCancelAccounts ? cancelReason : cancelReason.trim() || null,
        `ord-cancel-${crypto.randomUUID()}`,
      )
    },
    onSuccess: async () => {
      setActionError(null)
      setShortages(null)
      setCancelReason("")
      setConfirmCancel(false)
      await refresh()
    },
    onError: (error: Error) => setActionError(error.message),
  })

  const pending =
    submit.isPending ||
    hold.isPending ||
    verify.isPending ||
    cancel.isPending ||
    approveShipment.isPending
  const shortageRows = shortages ?? []

  return (
    <section className="min-w-0">
      <PageHeader
        title={order?.order_number ?? "Order"}
        description="Capture, submit, hold, verify, or cancel a shop request. Verification checks picking-eligible stock and does not reserve it."
        action={
          canEdit ? (
            <Button asChild>
              <Link to={`/orders/${order.id}/edit`}>Edit</Link>
            </Button>
          ) : null
        }
      />
      {detail.isLoading ? <LoadingBlock label="Loading order" /> : null}
      {detail.error ? (
        <p role="alert" className="text-sm text-destructive">
          {detail.error.message}
        </p>
      ) : null}
      {order && detail.data ? (
        <div className="grid gap-6">
          <div className="flex flex-wrap items-center gap-3">
            <StatusBadge tone={tone[order.status]}>{order.status}</StatusBadge>
            {order.fulfilment_status && order.fulfilment_status !== "open" ? (
              <StatusBadge tone={order.fulfilment_status === "fulfilled" ? "success" : "warning"}>
                {order.fulfilment_status.replace("_", " ")}
              </StatusBadge>
            ) : null}
            <p className="text-sm text-muted-foreground">Version {order.version}</p>
          </div>
          <dl className="grid gap-3 sm:grid-cols-2">
            <div>
              <dt className="text-sm text-muted-foreground">Shop</dt>
              <dd>{shopName ?? order.shop_id}</dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Godown</dt>
              <dd>{branchName ?? order.branch_id}</dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Source</dt>
              <dd>{order.source}</dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Reference</dt>
              <dd>{order.source_reference ?? "—"}</dd>
            </div>
            <div className="sm:col-span-2">
              <dt className="text-sm text-muted-foreground">Notes</dt>
              <dd>{order.notes ?? "—"}</dd>
            </div>
            {order.cancellation_reason ? (
              <div className="sm:col-span-2">
                <dt className="text-sm text-muted-foreground">Cancellation reason</dt>
                <dd>{order.cancellation_reason}</dd>
              </div>
            ) : null}
            <div className="sm:col-span-2">
              <dt className="text-sm text-muted-foreground">Delivery note handover</dt>
              <dd>
                {openNote ? (
                  <span>
                    {openNote.delivery_note_number} · {deliveryNoteHandoverLabel(openNote.status)}
                    {openNote.acknowledged_at
                      ? ` · acknowledged ${openNote.acknowledged_at.slice(0, 19).replace("T", " ")}`
                      : ""}
                  </span>
                ) : (
                  deliveryNoteHandoverLabel(null)
                )}
              </dd>
            </div>
            <div className="sm:col-span-2">
              <dt className="text-sm text-muted-foreground">Next permitted action</dt>
              <dd>{nextAction}</dd>
            </div>
          </dl>

          {cutoverMessage && order.status === "verified" ? (
            <p role="status" className="rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-900">
              {cutoverMessage}
            </p>
          ) : null}

          {openPicking ? (
            <div>
              <h2 className="mb-2 text-sm font-medium">Picking fulfilment</h2>
              <p className="mb-2 text-sm text-muted-foreground">
                {pickingStatusLabel[openPicking.status]} · {openPicking.request_number}. Reserved
                quantity is a hold. Stock is not deducted until dispatch.
              </p>
              <ul className="grid gap-2 sm:grid-cols-4 lg:grid-cols-7">
                <li className="rounded-2xl bg-card px-4 py-3 text-sm ring-1 ring-border">
                  Ordered {openPicking.fulfilment.ordered_cases}
                </li>
                <li className="rounded-2xl bg-card px-4 py-3 text-sm ring-1 ring-border">
                  Reserved {openPicking.fulfilment.allocated_cases}
                </li>
                <li className="rounded-2xl bg-card px-4 py-3 text-sm ring-1 ring-border">
                  Picked {openPicking.fulfilment.picked_cases}
                </li>
                <li className="rounded-2xl bg-card px-4 py-3 text-sm ring-1 ring-border">
                  Approved {openPicking.fulfilment.approved_shipment_cases}
                </li>
                <li className="rounded-2xl bg-card px-4 py-3 text-sm ring-1 ring-border">
                  Dispatched {openPicking.fulfilment.dispatched_cases}
                </li>
                <li className="rounded-2xl bg-card px-4 py-3 text-sm ring-1 ring-border">
                  Outstanding {openPicking.fulfilment.outstanding_cases}
                </li>
                <li className="rounded-2xl bg-card px-4 py-3 text-sm ring-1 ring-border">
                  Remaining {openPicking.fulfilment.remaining_cases}
                </li>
              </ul>
            </div>
          ) : null}

          {openShipment ? (
            <div>
              <h2 className="mb-2 text-sm font-medium">Short-shipment document</h2>
              <p className="mb-2 text-sm text-muted-foreground">
                Operational record {openShipment.shipment_number}, revision {openShipment.revision}.
                Original delivery note is unchanged. This is not a tax invoice.
              </p>
              <div className="mb-3 flex flex-wrap items-center gap-3 text-sm">
                <StatusBadge tone={shipmentStatusTone[openShipment.status as ShipmentStatus]}>
                  {shipmentStatusLabel[openShipment.status as ShipmentStatus]}
                </StatusBadge>
                <span>GM {openShipment.gm_confirmed_at ? "confirmed" : "pending"}</span>
                <span>Accounts {openShipment.accounts_approved_at ? "approved" : "pending"}</span>
              </div>
              {can("shipments.approve") && openShipment.status === "gm_confirmed" ? (
                <Button
                  type="button"
                  onClick={() => approveShipment.mutate()}
                  disabled={pending}
                >
                  {approveShipment.isPending ? "Approving" : "Approve short-shipment"}
                </Button>
              ) : null}
            </div>
          ) : null}

          {linkedBackorder ? (
            <div>
              <h2 className="mb-2 text-sm font-medium">Linked backorder</h2>
              <p className="text-sm">
                <Link className="underline" to={`/orders/${linkedBackorder.id}`}>
                  {linkedBackorder.order_number}
                </Link>{" "}
                · {linkedBackorder.status} · outstanding remainder, not reserved
              </p>
            </div>
          ) : null}

          <div>
            <h2 className="mb-2 text-sm font-medium">Lines</h2>
            <ul className="grid gap-2">
              {detail.data.lines.map((line) => (
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

          {canVerify ? (
            <div>
              <h2 className="mb-2 text-sm font-medium">Picking-eligible availability</h2>
              <p className="mb-2 text-sm text-muted-foreground">
                Eligible cases exclude reservations, quarantine, and ineligible lots. On-hand is
                informational. This check does not reserve stock.
              </p>
              {availability.isLoading ? <LoadingBlock label="Checking stock" /> : null}
              {availability.error ? (
                <p role="alert" className="text-sm text-destructive">
                  {availability.error.message}
                </p>
              ) : null}
              {availability.data && !availability.data.picking_operational ? (
                <p role="status" className="mb-2 rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-900">
                  Lot-aware picking is not operational. Verification stays fail-closed until dual-write
                  cutover. {(availability.data.cutover_blockers ?? []).join(" ")}
                </p>
              ) : null}
              {(availability.data?.lines ?? []).length > 0 ? (
                <ul className="grid gap-2">
                  {(availability.data?.lines ?? []).map((row) => (
                    <li
                      key={row.product_id}
                      className="grid gap-1 rounded-2xl bg-card px-4 py-3 text-sm ring-1 ring-border sm:grid-cols-5"
                    >
                      <span>{productName.get(row.product_id) ?? row.product_id}</span>
                      <span>Requested {row.requested_cases}</span>
                      <span>On hand {row.on_hand_cases}</span>
                      <span>Eligible {row.eligible_cases}</span>
                      <span>Shortfall {row.shortfall_cases}</span>
                      {row.blockers.length > 0 ? (
                        <span className="sm:col-span-5 text-muted-foreground">{row.blockers.join(" ")}</span>
                      ) : null}
                    </li>
                  ))}
                </ul>
              ) : null}
            </div>
          ) : null}

          {shortageRows.length > 0 ? (
            <div role="alert" className="grid gap-2 rounded-2xl bg-destructive/10 p-4 text-sm text-destructive">
              <p className="font-medium">
                Verification cannot be completed because the following products have insufficient
                picking-eligible stock.
              </p>
              <ul className="grid gap-2">
                {shortageRows.map((row) => (
                  <li key={row.product_id} className="grid gap-1 sm:grid-cols-5">
                    <span>{productName.get(row.product_id) ?? row.product_id}</span>
                    <span>Requested {row.requested_cases}</span>
                    <span>On hand {row.on_hand_cases}</span>
                    <span>Eligible {row.eligible_cases}</span>
                    <span>Shortfall {row.shortfall_cases}</span>
                  </li>
                ))}
              </ul>
              <p className="text-foreground">
                The order remains submitted. Stock was not reserved. Hold it separately if correction is
                needed.
              </p>
            </div>
          ) : null}

          {actionError && shortageRows.length === 0 ? (
            <p role="alert" className="text-sm text-destructive">
              {actionError}
            </p>
          ) : null}

          <div className="grid gap-4">
            {canAllocatePicking ? (
              <Button asChild variant="outline" className="w-full sm:w-auto">
                <Link to={`/picking/allocate/${order.id}`}>Allocate for picking</Link>
              </Button>
            ) : null}

            {openPicking ? (
              <Button asChild variant="outline" className="w-full sm:w-auto">
                <Link to={`/picking/${openPicking.id}`}>Open picking</Link>
              </Button>
            ) : null}

            {order.status === "verified" && can("picking.allocate") && !dnAcknowledged ? (
              <p role="status" className="text-sm text-muted-foreground">
                Godown Manager must acknowledge the delivery note before picking allocation.
              </p>
            ) : null}

            {openNote ? (
              <Button asChild variant="outline" className="w-full sm:w-auto">
                <Link to={`/deliveries/${openNote.id}`}>Open delivery note</Link>
              </Button>
            ) : null}

            {canOpenDispatch ? (
              <Button asChild variant="outline" className="w-full sm:w-auto">
                <Link to={`/dispatch/prepare/${order.id}`}>Open dispatch</Link>
              </Button>
            ) : null}

            {canCreateDeliveryNote ? (
              <Button asChild className="w-full sm:w-auto">
                <Link to={`/deliveries/new?orderId=${order.id}`}>Create delivery note</Link>
              </Button>
            ) : null}

            {canSubmit ? (
              <Button onClick={() => submit.mutate()} disabled={pending}>
                Submit order
              </Button>
            ) : null}

            {canVerify ? (
              <Button onClick={() => verify.mutate()} disabled={pending}>
                Verify order
              </Button>
            ) : null}

            {canHold ? (
              <div className="grid gap-2">
                <label className="grid gap-1 text-sm">
                  Hold reason
                  <textarea
                    className="min-h-20 rounded-xl border bg-card px-3 py-2"
                    value={holdNote}
                    onChange={(event) => setHoldNote(event.target.value)}
                    maxLength={500}
                    required
                  />
                </label>
                <Button
                  variant="outline"
                  onClick={() => hold.mutate()}
                  disabled={pending || holdNote.trim().length < 1}
                >
                  Hold for correction
                </Button>
              </div>
            ) : null}

            {canCancelCreator || canCancelAccounts ? (
              <div className="grid gap-2">
                {canCancelAccounts ? (
                  <label className="grid gap-1 text-sm">
                    Cancellation reason
                    <textarea
                      className="min-h-20 rounded-xl border bg-card px-3 py-2"
                      value={cancelReason}
                      onChange={(event) => setCancelReason(event.target.value)}
                      maxLength={500}
                      required
                    />
                  </label>
                ) : (
                  <label className="grid gap-1 text-sm">
                    Cancellation note (optional)
                    <textarea
                      className="min-h-20 rounded-xl border bg-card px-3 py-2"
                      value={cancelReason}
                      onChange={(event) => setCancelReason(event.target.value)}
                      maxLength={500}
                    />
                  </label>
                )}
                <label className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={confirmCancel}
                    onChange={(event) => setConfirmCancel(event.target.checked)}
                  />
                  Confirm cancellation
                </label>
                <Button
                  variant="destructive"
                  onClick={() => cancel.mutate()}
                  disabled={
                    pending ||
                    !confirmCancel ||
                    (canCancelAccounts && cancelReason.trim().length < 1)
                  }
                >
                  Cancel order
                </Button>
              </div>
            ) : null}
          </div>

          <div>
            <h2 className="mb-2 text-sm font-medium">History</h2>
            <ul className="grid gap-2">
              {detail.data.events.map((event) => (
                <li
                  key={event.id}
                  className="rounded-2xl bg-card px-4 py-3 text-sm ring-1 ring-border"
                >
                  <p className="font-medium">
                    {event.event_type} → {event.to_status}
                  </p>
                  <p className="text-muted-foreground">
                    v{event.version} · {event.created_at.slice(0, 19).replace("T", " ")}
                  </p>
                  {event.note ? <p className="mt-1">{event.note}</p> : null}
                </li>
              ))}
            </ul>
          </div>
        </div>
      ) : null}
    </section>
  )
}
