import { useState } from "react"
import { Link, useParams } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import {
  hasCompanyWideGodownAccess,
  loadOwnAssignedBranchIds,
} from "@/lib/access/godown-scope"
import {
  canIssueDeliveryNoteForOrder,
  describeDeliveryNoteFormBlock,
  isActiveDeliveryNote,
} from "@/lib/delivery-notes/handover"
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
} from "@/lib/orders/api"
import {
  deliveryNoteHandoverLabel,
  describeAtpLine,
  isAcknowledgedDeliveryNote,
} from "@/lib/orders/availability"
import {
  describeOrderLoadFailure,
  describeVerificationBlock,
  orderRecordPath,
  readableSiteLabel,
  verificationStatusLabel,
  verificationStatusTone,
  type OrderWorkflowMode,
} from "@/lib/orders/verification"
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

function OrderRecordPage({ mode }: { mode: OrderWorkflowMode }) {
  const isVerification = mode === "verification"
  const { orderId = "" } = useParams()
  const { session } = useAuth()
  const { can, roles } = useAccess()
  const companyWideGodownAccess = hasCompanyWideGodownAccess(can, roles)
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
      isVerification &&
      orderId !== "" &&
      can("orders.verify") &&
      detail.data?.order.status === "submitted",
  })
  // Assignment, not catalog visibility: get_order can succeed for unassigned Accounts.
  const assignments = useQuery({
    queryKey: ["own-branch-assignments"],
    queryFn: loadOwnAssignedBranchIds,
    enabled: isVerification && can("delivery_notes.issue") && !companyWideGodownAccess,
  })

  const order = detail.data?.order
  useDocumentTitle(order ? order.order_number : "Order")
  const shopName = readableSiteLabel(
    shops.data?.find((shop) => shop.id === order?.shop_id)?.name,
    "Shop",
  )
  const branchName = readableSiteLabel(
    branches.data?.find((branch) => branch.id === order?.branch_id)?.name,
    "Godown",
  )
  const productName = new Map(
    (products.data ?? []).map((product) => [product.id, `${product.sku} · ${product.name}`]),
  )

  const isCreator = Boolean(order && session?.user.id === order.created_by)
  const canEdit =
    !isVerification && isCreator && (order?.status === "draft" || order?.status === "held")
  const canSubmit =
    !isVerification &&
    isCreator &&
    can("orders.capture") &&
    (order?.status === "draft" || order?.status === "held")
  const canHold = isVerification && can("orders.verify") && order?.status === "submitted"
  const canVerify = isVerification && can("orders.verify") && order?.status === "submitted"
  const canCancelCreator =
    !isVerification &&
    isCreator &&
    can("orders.capture") &&
    (order?.status === "draft" || order?.status === "held")
  const canCancelAccounts =
    isVerification &&
    can("orders.verify") &&
    (order?.status === "submitted" || order?.status === "verified")
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
  const assignedBranchIds = assignments.data ?? []
  const hasActiveDeliveryNote = isActiveDeliveryNote(openNote)
  const canCreateDeliveryNote =
    isVerification &&
    (!assignments.isLoading || companyWideGodownAccess) &&
    canIssueDeliveryNoteForOrder({
      canIssue: can("delivery_notes.issue"),
      orderStatus: order?.status,
      hasActiveDeliveryNote,
      orderBranchId: order?.branch_id,
      assignedBranchIds,
      listedInHandoverQueue: false,
      companyWideGodownAccess,
    })
  const deliveryNoteBlock =
    isVerification && order?.status === "verified"
      ? describeDeliveryNoteFormBlock({
          canIssue: can("delivery_notes.issue"),
          orderId: order.id,
          orderFound: true,
          loading: assignments.isLoading && !companyWideGodownAccess,
          orderStatus: order.status,
          hasActiveDeliveryNote,
          activeNoteNumber: openNote?.delivery_note_number ?? null,
          assignedBranchCount: assignedBranchIds.length,
          listedInHandoverQueue: false,
          companyWideGodownAccess,
          canCreate: canCreateDeliveryNote,
        })
      : null
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
    await queryClient.invalidateQueries({ queryKey: ["verified-orders-without-dn"] })
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
  const verificationGate =
    isVerification && order && can("orders.verify")
      ? describeVerificationBlock({
          orderFound: true,
          canVerify: true,
          assignedBranchCount: branches.data?.length ?? 0,
          orderBranchId: order.branch_id,
          assignedBranchIds: (branches.data ?? []).map((branch) => branch.id),
          godownName: branchName,
          availability: availability.data,
          rpcError: actionError && shortageRows.length === 0 ? actionError : null,
        })
      : null

  return (
    <section className="min-w-0">
      <PageHeader
        title={order?.order_number ?? (isVerification ? "Order verification" : "Order")}
        description={
          isVerification
            ? "Accounts reviews packing-eligible ATP, then verifies or holds. Inventory does not change here."
            : "Create, submit, and track this shop request. Approval happens in Order verification."
        }
        action={
          <div className="flex flex-wrap items-center gap-2">
            <Button asChild variant="outline">
              <Link to={isVerification ? "/orders/verification" : "/orders"}>
                {isVerification ? "Back to verification" : "Back to orders"}
              </Link>
            </Button>
            {canEdit && order ? (
              <Button asChild>
                <Link to={`/orders/${order.id}/edit`}>Edit</Link>
              </Button>
            ) : null}
          </div>
        }
      />
      {detail.isLoading ? <LoadingBlock label="Loading order" /> : null}
      {detail.error ? (
        <p role="alert" className="text-sm text-destructive">
          {
            describeOrderLoadFailure({
              errorMessage: detail.error.message,
              canVerify: can("orders.verify"),
              assignedBranchCount: branches.data?.length ?? 0,
            }).message
          }
        </p>
      ) : null}
      {order && detail.data ? (
        <div className="grid gap-6">
          <div className="flex flex-wrap items-center gap-3">
            <StatusBadge tone={verificationStatusTone(order.status)}>
              {verificationStatusLabel(order.status)}
            </StatusBadge>
            {isVerification && order.status === "submitted" ? (
              <StatusBadge tone="info">Awaiting Verification</StatusBadge>
            ) : null}
            {verificationGate?.label === "Blocked by Stock" ? (
              <StatusBadge tone="warning">Blocked by Stock</StatusBadge>
            ) : null}
            {verificationGate?.label === "Blocked by Access" ? (
              <StatusBadge tone="danger">Blocked by Access</StatusBadge>
            ) : null}
            {!isVerification && can("orders.verify") && (order.status === "submitted" || order.status === "verified") ? (
              <Button asChild variant="outline">
                <Link to={orderRecordPath("verification", order.id)}>
                  Open in Order verification
                </Link>
              </Button>
            ) : null}
            {order.fulfilment_status && order.fulfilment_status !== "open" ? (
              <StatusBadge tone={order.fulfilment_status === "fulfilled" ? "success" : "warning"}>
                {order.fulfilment_status.replace("_", " ")}
              </StatusBadge>
            ) : null}
            <p className="text-sm text-muted-foreground">Version {order.version}</p>
          </div>
          {verificationGate &&
          (verificationGate.kind === "missing_godown_assignment" ||
            verificationGate.kind === "wrong_godown" ||
            verificationGate.kind === "not_authorized") ? (
            <p
              role="status"
              className="rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-950"
            >
              <span className="font-medium">{verificationGate.label}. </span>
              {verificationGate.message}
            </p>
          ) : null}
          <dl className="grid gap-3 sm:grid-cols-2">
            <div>
              <dt className="text-sm text-muted-foreground">Shop</dt>
              <dd>{shopName}</dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Godown</dt>
              <dd>{branchName}</dd>
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
              <h2 className="mb-2 text-sm font-medium">Packing fulfilment</h2>
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
                <Link className="underline" to={orderRecordPath(mode, linkedBackorder.id)}>
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
              <h2 className="mb-2 text-sm font-medium">Packing-eligible availability</h2>
              <p className="mb-2 text-sm text-muted-foreground">
                Eligible cases are the packing-coverable quantity for this request, not remaining
                warehouse stock. On-hand is informational crate stock. This check does not reserve.
              </p>
              {availability.isLoading ? <LoadingBlock label="Checking stock" /> : null}
              {availability.error ? (
                <p role="alert" className="text-sm text-destructive">
                  {availability.error.message}
                </p>
              ) : null}
              {availability.data && !availability.data.picking_operational ? (
                <p role="status" className="mb-2 rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-900">
                  Lot-aware packing is not operational. Verification stays fail-closed until dual-write
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
                      <span className="sm:col-span-5 text-muted-foreground">
                        {describeAtpLine(row).summary}
                        {row.blockers.length > 0 ? ` ${row.blockers.join(" ")}` : ""}
                      </span>
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
                packing-eligible stock.
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
            {!isVerification && canAllocatePicking ? (
              <Button asChild variant="outline" className="w-full sm:w-auto">
                <Link to={`/picking/allocate/${order.id}`}>Allocate for packing</Link>
              </Button>
            ) : null}

            {openPicking ? (
              <Button asChild variant="outline" className="w-full sm:w-auto">
                <Link to={`/picking/${openPicking.id}`}>Open packing</Link>
              </Button>
            ) : null}

            {order.status === "verified" && can("picking.allocate") && !dnAcknowledged ? (
              <p role="status" className="text-sm text-muted-foreground">
                Godown Manager must acknowledge the delivery note before packing allocation.
              </p>
            ) : null}

            {openNote ? (
              <Button asChild variant="outline" className="w-full sm:w-auto">
                <Link to={`/deliveries/${openNote.id}`}>Open delivery note</Link>
              </Button>
            ) : null}

            {!isVerification && canOpenDispatch ? (
              <Button asChild variant="outline" className="w-full sm:w-auto">
                <Link to={`/dispatch/prepare/${order.id}`}>Open dispatch</Link>
              </Button>
            ) : null}

            {isVerification && order.status === "verified" && hasActiveDeliveryNote && openNote ? (
              <p role="status" className="text-sm text-muted-foreground">
                An active delivery note already exists
                {openNote.delivery_note_number ? ` (${openNote.delivery_note_number})` : ""}. A
                second note cannot be created for this order.
              </p>
            ) : null}

            {isVerification &&
            order.status === "verified" &&
            !hasActiveDeliveryNote &&
            deliveryNoteBlock ? (
              <p role="status" className="text-sm text-muted-foreground">
                {deliveryNoteBlock}
              </p>
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

export function OrderDetailPage() {
  return <OrderRecordPage mode="capture" />
}

export function OrderVerificationDetailPage() {
  return <OrderRecordPage mode="verification" />
}
