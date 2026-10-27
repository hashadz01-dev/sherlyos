import { useState } from "react"
import { Link, useParams } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { AppModal } from "@/components/shared/AppModal"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { useAuth } from "@/hooks/use-auth"
import {
  assignPickingRequest,
  cancelPickingRequest,
  completePicking,
  confirmPickingHandoff,
  confirmPickingQuantity,
  getPickingRequest,
  pickingKeys,
  reportPickingShortage,
  startPicking,
  type PickingReservation,
} from "@/lib/picking/api"
import {
  cutoverBlocksPicking,
  isStalePickingVersion,
  nextOrderPickingAction,
  pickingEventLabel,
  pickingHasShortage,
  pickingStatusLabel,
  pickingStatusTone,
  remainingCases,
} from "@/lib/picking/rules"
import {
  confirmShortShipmentQuantities,
  createShortShipment,
} from "@/lib/shipments/api"
import {
  shipmentStatusLabel,
  shipmentStatusTone,
  type ShipmentStatus,
} from "@/lib/shipments/rules"

export function PickingDetailPage() {
  const { requestId = "" } = useParams()
  const queryClient = useQueryClient()
  const { can } = useAccess()
  const { session } = useAuth()
  const [assignee, setAssignee] = useState(session?.user.id ?? "")
  const [cancelReason, setCancelReason] = useState("")
  const [confirmCancel, setConfirmCancel] = useState(false)
  const detail = useQuery({
    queryKey: pickingKeys.detail(requestId),
    queryFn: () => getPickingRequest(requestId),
    enabled: requestId !== "",
  })
  const request = detail.data
  useDocumentTitle(request ? request.request_number : "Picking")

  async function refresh() {
    await queryClient.invalidateQueries({ queryKey: pickingKeys.detail(requestId) })
    await queryClient.invalidateQueries({ queryKey: ["picking-queue"] })
  }

  const start = useMutation({
    mutationFn: () => {
      if (!request) throw new Error("Picking is not loaded.")
      return startPicking({
        target_request: request.id,
        expected_version: request.version,
        idempotency_key: `pk-start-${crypto.randomUUID()}`,
      })
    },
    onSuccess: refresh,
  })
  const assign = useMutation({
    mutationFn: () => {
      if (!request) throw new Error("Picking is not loaded.")
      return assignPickingRequest({
        target_request: request.id,
        assignee,
        expected_version: request.version,
        idempotency_key: `pk-assign-${crypto.randomUUID()}`,
      })
    },
    onSuccess: refresh,
  })
  const complete = useMutation({
    mutationFn: () => {
      if (!request) throw new Error("Picking is not loaded.")
      return completePicking({
        target_request: request.id,
        expected_version: request.version,
        idempotency_key: `pk-complete-${crypto.randomUUID()}`,
      })
    },
    onSuccess: refresh,
  })
  const handoff = useMutation({
    mutationFn: () => {
      if (!request) throw new Error("Picking is not loaded.")
      return confirmPickingHandoff({
        target_request: request.id,
        expected_version: request.version,
        idempotency_key: `pk-handoff-${crypto.randomUUID()}`,
      })
    },
    onSuccess: refresh,
  })
  const cancel = useMutation({
    mutationFn: () => {
      if (!request) throw new Error("Picking is not loaded.")
      return cancelPickingRequest({
        target_request: request.id,
        expected_version: request.version,
        cancel_reason: cancelReason,
        idempotency_key: `pk-cancel-${crypto.randomUUID()}`,
      })
    },
    onSuccess: async () => {
      setConfirmCancel(false)
      await refresh()
    },
  })

  const createShipment = useMutation({
    mutationFn: () => {
      if (!request) throw new Error("Picking is not loaded.")
      return createShortShipment({
        target_request: request.id,
        expected_picking_version: request.version,
        idempotency_key: `sh-create-${crypto.randomUUID()}`,
      })
    },
    onSuccess: refresh,
  })
  const confirmShipment = useMutation({
    mutationFn: () => {
      if (!request?.open_shipment) throw new Error("Shipment is not loaded.")
      return confirmShortShipmentQuantities({
        target_shipment: request.open_shipment.id,
        expected_version: request.open_shipment.version,
        idempotency_key: `sh-gm-${crypto.randomUUID()}`,
      })
    },
    onSuccess: refresh,
  })
  const actionError =
    start.error ??
    assign.error ??
    complete.error ??
    handoff.error ??
    cancel.error ??
    createShipment.error ??
    confirmShipment.error
  const actionMessage =
    actionError && isStalePickingVersion(actionError)
      ? "This picking task changed. Reload before continuing."
      : actionError?.message
  const fulfilment = request?.fulfilment
  const hasShortage =
    fulfilment?.has_shortage === true || pickingHasShortage(request?.exceptions ?? [])
  const shipment = request?.open_shipment ?? null
  const cutoverMessage = request ? cutoverBlocksPicking(request.cutover) : null
  const nextAction = request
    ? nextOrderPickingAction({
        orderStatus: request.order_status,
        dnStatus: request.delivery_note_status,
        pickingStatus: request.status,
        hasShortage,
        cutoverBlocked: Boolean(cutoverMessage),
        shipmentStatus: shipment?.status ?? fulfilment?.shipment_status ?? null,
      })
    : null
  const shipmentApproved = shipment?.status === "approved"
  const pickedCases = fulfilment?.picked_cases ?? 0
  const canHandoff =
    can("picking.manage") &&
    request?.status === "picked" &&
    (!hasShortage || shipmentApproved)
  // A short-shipment document snapshots picked lots. Zero-pick shortages stay
  // on cancel-and-reallocate; the RPC also refuses them.
  const canCreateShipment =
    can("shipments.manage") &&
    (request?.status === "picked" || request?.status === "ready_for_dispatch") &&
    !shipment &&
    pickedCases >= 1
  const canConfirmShipment =
    can("shipments.manage") && shipment?.status === "draft"

  return (
    <section className="min-w-0">
      <PageHeader
        title={request?.request_number ?? "Picking"}
        description={request ? `Order ${request.order_number}` : "Warehouse picking task"}
        action={
          <Button asChild variant="outline">
            <Link to="/picking">Back to queue</Link>
          </Button>
        }
      />
      {detail.isLoading ? <LoadingBlock label="Loading picking task" /> : null}
      {detail.error ? (
        <p role="alert" className="text-sm text-destructive">
          {detail.error.message}
        </p>
      ) : null}
      {request ? (
        <div className="space-y-6">
          <div className="flex flex-wrap items-center gap-3">
            <StatusBadge tone={pickingStatusTone[request.status]}>
              {pickingStatusLabel[request.status]}
            </StatusBadge>
            <Link className="text-sm underline" to={`/orders/${request.order_id}`}>
              Open order
            </Link>
            {request.delivery_note_status ? (
              <span className="text-sm text-slate-600">
                Delivery note: {request.delivery_note_status}
              </span>
            ) : null}
          </div>
          {nextAction ? (
            <p role="status" className="text-sm text-slate-700">
              {nextAction}
            </p>
          ) : null}
          {fulfilment ? (
            <ul className="grid gap-2 sm:grid-cols-4 lg:grid-cols-8">
              <li className="rounded-2xl bg-white px-4 py-3 text-sm ring-1 ring-slate-200/80">
                Ordered {fulfilment.ordered_cases}
              </li>
              <li className="rounded-2xl bg-white px-4 py-3 text-sm ring-1 ring-slate-200/80">
                Reserved {fulfilment.allocated_cases}
              </li>
              <li className="rounded-2xl bg-white px-4 py-3 text-sm ring-1 ring-slate-200/80">
                Picked {fulfilment.picked_cases}
              </li>
              <li className="rounded-2xl bg-white px-4 py-3 text-sm ring-1 ring-slate-200/80">
                Proposed {fulfilment.proposed_shipment_cases}
              </li>
              <li className="rounded-2xl bg-white px-4 py-3 text-sm ring-1 ring-slate-200/80">
                Approved {fulfilment.approved_shipment_cases}
              </li>
              <li className="rounded-2xl bg-white px-4 py-3 text-sm ring-1 ring-slate-200/80">
                Dispatched {fulfilment.dispatched_cases}
              </li>
              <li className="rounded-2xl bg-white px-4 py-3 text-sm ring-1 ring-slate-200/80">
                Outstanding {fulfilment.outstanding_cases}
              </li>
              <li className="rounded-2xl bg-white px-4 py-3 text-sm ring-1 ring-slate-200/80">
                Remaining {fulfilment.remaining_cases}
              </li>
            </ul>
          ) : null}
          {cutoverMessage ? (
            <p role="alert" className="rounded-xl bg-amber-50 px-4 py-3 text-sm text-amber-900">
              {cutoverMessage}
            </p>
          ) : null}
          {shipment ? (
            <div className="flex flex-wrap items-center gap-3 rounded-xl bg-slate-50 px-4 py-3 text-sm">
              <StatusBadge tone={shipmentStatusTone[shipment.status as ShipmentStatus]}>
                {shipmentStatusLabel[shipment.status as ShipmentStatus]} {shipment.shipment_number}
              </StatusBadge>
              <span>Revision {shipment.revision}</span>
              <span>GM {shipment.gm_confirmed_at ? "confirmed" : "pending"}</span>
              <span>Accounts {shipment.accounts_approved_at ? "approved" : "pending"}</span>
            </div>
          ) : null}
          {actionMessage ? (
            <p role="alert" className="text-sm text-destructive">
              {actionMessage}
            </p>
          ) : null}
          <div className="flex flex-wrap gap-2">
            {can("picking.execute") && request.status === "allocated" ? (
              <Button type="button" onClick={() => start.mutate()} disabled={start.isPending}>
                {start.isPending ? "Starting" : "Start picking"}
              </Button>
            ) : null}
            {can("picking.execute") && request.status === "picking" ? (
              <Button type="button" onClick={() => complete.mutate()} disabled={complete.isPending}>
                {complete.isPending ? "Completing" : "Complete picking"}
              </Button>
            ) : null}
            {canCreateShipment ? (
              <Button
                type="button"
                variant="outline"
                onClick={() => createShipment.mutate()}
                disabled={createShipment.isPending}
              >
                {createShipment.isPending ? "Creating shipment" : "Create short-shipment"}
              </Button>
            ) : null}
            {canConfirmShipment ? (
              <Button
                type="button"
                variant="outline"
                onClick={() => confirmShipment.mutate()}
                disabled={confirmShipment.isPending}
              >
                {confirmShipment.isPending ? "Confirming" : "Confirm picked quantities"}
              </Button>
            ) : null}
            {canHandoff ? (
              <Button type="button" onClick={() => handoff.mutate()} disabled={handoff.isPending}>
                {handoff.isPending ? "Handing off" : "Ready for dispatch"}
              </Button>
            ) : null}
            {can("picking.manage") &&
            request.status === "picked" &&
            hasShortage &&
            !shipmentApproved ? (
              <p className="w-full text-sm text-muted-foreground">
                {pickedCases < 1
                  ? "Zero picked cartons cannot become a short-shipment. Cancel and reallocate the full order."
                  : "Ready for dispatch is blocked until Accounts approves the short-shipment document."}
              </p>
            ) : null}
            {can("dispatch.confirm") && request.status === "ready_for_dispatch" ? (
              <Button asChild>
                <Link to={`/dispatch/prepare/${request.order_id}`}>Open dispatch</Link>
              </Button>
            ) : null}
            {can("picking.manage") &&
            ["allocated", "picking", "picked", "blocked"].includes(request.status) ? (
              <Button type="button" variant="outline" onClick={() => setConfirmCancel(true)}>
                Cancel picking
              </Button>
            ) : null}
          </div>
          {can("picking.manage") && (request.status === "allocated" || request.status === "picking") ? (
            <form
              className="flex flex-wrap items-end gap-2"
              onSubmit={(event) => {
                event.preventDefault()
                assign.mutate()
              }}
            >
              <label className="grid gap-1 text-sm font-medium">
                Assign picker (user id)
                <input
                  className="h-10 w-80 rounded-lg border border-input px-2.5 text-sm font-normal"
                  value={assignee}
                  onChange={(event) => setAssignee(event.target.value)}
                  aria-label="Assignee user id"
                />
              </label>
              <Button type="submit" variant="outline" disabled={assign.isPending || assignee === ""}>
                Assign
              </Button>
            </form>
          ) : null}
          <ReservationTable
            requestId={request.id}
            version={request.version}
            status={request.status}
            rows={request.reservations}
          />
          <section>
            <h2 className="mb-2 text-base font-semibold">Exceptions</h2>
            {request.exceptions.length === 0 ? (
              <p className="text-sm text-slate-600">No exceptions recorded.</p>
            ) : (
              <ul className="space-y-2 text-sm">
                {request.exceptions.map((item) => (
                  <li key={item.id} className="rounded-lg bg-amber-50 px-3 py-2">
                    {item.exception_type}: {item.message}
                    {item.quantity != null ? ` (${item.quantity})` : ""}
                  </li>
                ))}
              </ul>
            )}
          </section>
          <section>
            <h2 className="mb-2 text-base font-semibold">Audit timeline</h2>
            <ol className="space-y-2 text-sm">
              {request.events.map((event) => (
                <li key={event.id} className="rounded-lg bg-slate-50 px-3 py-2">
                  <strong>{pickingEventLabel[event.event_type] ?? event.event_type}</strong>
                  <span className="text-slate-500">
                    {" "}
                    · {new Date(event.created_at).toLocaleString()}
                  </span>
                </li>
              ))}
            </ol>
          </section>
        </div>
      ) : null}
      <AppModal
        open={confirmCancel}
        onOpenChange={setConfirmCancel}
        title="Cancel picking?"
        description="Active reservations will be released. Picked quantities are not written to the ledger."
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => setConfirmCancel(false)}>
              Keep picking
            </Button>
            <Button type="button" disabled={cancel.isPending || cancelReason.trim() === ""} onClick={() => cancel.mutate()}>
              {cancel.isPending ? "Cancelling" : "Cancel picking"}
            </Button>
          </>
        }
      >
        <label className="grid gap-2 text-sm font-medium">
          Reason
          <textarea
            className="min-h-20 rounded-lg border border-input px-2.5 py-2 text-sm font-normal"
            value={cancelReason}
            onChange={(event) => setCancelReason(event.target.value)}
          />
        </label>
      </AppModal>
    </section>
  )
}

function ReservationTable({
  requestId,
  version,
  status,
  rows,
}: {
  requestId: string
  version: number
  status: string
  rows: PickingReservation[]
}) {
  const queryClient = useQueryClient()
  const { can } = useAccess()
  const [quantities, setQuantities] = useState<Record<string, string>>({})
  const confirm = useMutation({
    mutationFn: async (row: PickingReservation) => {
      const parsed = Number.parseInt(quantities[row.id] ?? String(row.reserved_cases), 10)
      return confirmPickingQuantity({
        target_request: requestId,
        target_reservation: row.id,
        picked_quantity: parsed,
        expected_version: version,
        idempotency_key: `pk-qty-${crypto.randomUUID()}`,
      })
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: pickingKeys.detail(requestId) }),
  })
  const shortage = useMutation({
    mutationFn: async (row: PickingReservation) => {
      const remaining = remainingCases(row.reserved_cases, row.picked_cases)
      return reportPickingShortage({
        target_request: requestId,
        target_reservation: row.id,
        short_quantity: remaining,
        shortage_note: "Shortage reported from picking task",
        expected_version: version,
        idempotency_key: `pk-short-${crypto.randomUUID()}`,
      })
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: pickingKeys.detail(requestId) }),
  })

  return (
    <section className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200/80">
      <table className="w-min min-w-full text-left text-sm">
        <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
          <tr>
            <th className="px-4 py-3 font-medium">Product</th>
            <th className="px-4 py-3 font-medium">Location</th>
            <th className="px-4 py-3 font-medium">Lot</th>
            <th className="px-4 py-3 font-medium">Reserved</th>
            <th className="px-4 py-3 font-medium">Picked</th>
            <th className="px-4 py-3 font-medium">Remaining</th>
            <th className="px-4 py-3 font-medium">Actions</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.id} className="border-b border-slate-100 last:border-0">
              <td className="px-4 py-3">
                {row.sku} · {row.product_name}
              </td>
              <td className="px-4 py-3">
                {row.zone_code} / {row.crate_code}
              </td>
              <td className="px-4 py-3">
                {row.manufacturer_lot_code ?? "—"}
                {row.expiry_date ? ` · ${row.expiry_date}` : ""}
              </td>
              <td className="px-4 py-3">{row.reserved_cases}</td>
              <td className="px-4 py-3">{row.picked_cases}</td>
              <td className="px-4 py-3">{row.remaining_cases}</td>
              <td className="px-4 py-3">
                {can("picking.execute") && status === "picking" && row.status === "active" ? (
                  <div className="flex flex-wrap items-center gap-2">
                    <input
                      aria-label={`Picked cases for ${row.sku}`}
                      className="h-9 w-20 rounded-lg border border-input px-2 text-sm"
                      inputMode="numeric"
                      value={quantities[row.id] ?? String(row.reserved_cases)}
                      onChange={(event) =>
                        setQuantities((current) => ({ ...current, [row.id]: event.target.value }))
                      }
                    />
                    <Button
                      type="button"
                      size="sm"
                      onClick={() => confirm.mutate(row)}
                      disabled={confirm.isPending}
                    >
                      Confirm pick
                    </Button>
                    <Button
                      type="button"
                      size="sm"
                      variant="outline"
                      onClick={() => shortage.mutate(row)}
                      disabled={shortage.isPending || row.remaining_cases < 1}
                    >
                      Report shortage
                    </Button>
                  </div>
                ) : null}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {status === "picking" ? (
        <p className="px-4 py-3 text-sm text-slate-600">
          Reporting a shortage releases unused reserved cartons. Confirm at least one picked carton
          first if a short-shipment document is required. Zero-pick shortages stay on
          cancel-and-reallocate. Stock deduction still waits for lot cutover.
        </p>
      ) : null}
      {confirm.error || shortage.error ? (
        <p role="alert" className="px-4 py-3 text-sm text-destructive">
          {(confirm.error ?? shortage.error)?.message}
        </p>
      ) : null}
    </section>
  )
}
