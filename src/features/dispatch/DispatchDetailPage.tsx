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
import {
  acknowledgeDispatchDelivery,
  assignDispatchDelivery,
  cancelDispatch,
  confirmDispatch,
  dispatchKeys,
  getDispatchRequest,
  listDispatchAssignees,
  reportDispatchDeliveryException,
  startDispatchDelivery,
  type DispatchDetail,
} from "@/lib/dispatch/api"
import {
  dispatchEventLabel,
  dispatchStatusLabel,
  dispatchStatusTone,
  isStaleDispatchVersion,
} from "@/lib/dispatch/rules"

function nextKey(prefix: string) {
  return `${prefix}-${crypto.randomUUID()}`
}

export function DispatchDetailPage() {
  const { dispatchId = "" } = useParams()
  const queryClient = useQueryClient()
  const { can } = useAccess()
  const [confirmOpen, setConfirmOpen] = useState(false)
  const [cancelOpen, setCancelOpen] = useState(false)
  const [ackOpen, setAckOpen] = useState(false)
  const [failOpen, setFailOpen] = useState(false)
  const [cancelReason, setCancelReason] = useState("")
  const [recipientName, setRecipientName] = useState("")
  const [ackNotes, setAckNotes] = useState("")
  const [failReason, setFailReason] = useState("")
  const [assignee, setAssignee] = useState("")
  const [actionError, setActionError] = useState<string | null>(null)

  const detail = useQuery({
    queryKey: dispatchKeys.detail(dispatchId),
    queryFn: () => getDispatchRequest(dispatchId),
    enabled: dispatchId !== "",
  })
  const request = detail.data
  useDocumentTitle(request ? request.request_number : "Dispatch")

  const assignees = useQuery({
    queryKey: dispatchKeys.assignees(request?.branch_id ?? ""),
    queryFn: () => listDispatchAssignees(request?.branch_id ?? ""),
    enabled: Boolean(request?.branch_id) && can("deliveries.assign"),
  })

  async function refresh() {
    await queryClient.invalidateQueries({ queryKey: dispatchKeys.detail(dispatchId) })
    await queryClient.invalidateQueries({ queryKey: ["dispatch-queue"] })
    await queryClient.invalidateQueries({ queryKey: dispatchKeys.assigned })
  }

  function onError(error: Error) {
    setActionError(
      isStaleDispatchVersion(error)
        ? "This dispatch changed. Refresh and try again."
        : error.message,
    )
  }

  const [confirmKey] = useState(() => nextKey("ds-cfm"))
  const confirm = useMutation({
    mutationFn: () =>
      confirmDispatch({
        target_dispatch: dispatchId,
        expected_version: request?.version ?? 1,
        idempotency_key: confirmKey,
      }),
    onSuccess: refresh,
    onError,
    onSettled: () => setConfirmOpen(false),
  })
  const cancel = useMutation({
    mutationFn: () =>
      cancelDispatch({
        target_dispatch: dispatchId,
        expected_version: request?.version ?? 1,
        cancel_reason: cancelReason,
        idempotency_key: nextKey("ds-can"),
      }),
    onSuccess: refresh,
    onError,
    onSettled: () => setCancelOpen(false),
  })
  const assign = useMutation({
    mutationFn: () =>
      assignDispatchDelivery({
        target_dispatch: dispatchId,
        assignee,
        expected_version: request?.version ?? 1,
        idempotency_key: nextKey("ds-asg"),
      }),
    onSuccess: refresh,
    onError,
  })
  const start = useMutation({
    mutationFn: () =>
      startDispatchDelivery({
        target_dispatch: dispatchId,
        expected_version: request?.version ?? 1,
        idempotency_key: nextKey("ds-go"),
      }),
    onSuccess: refresh,
    onError,
  })
  const acknowledge = useMutation({
    mutationFn: () =>
      acknowledgeDispatchDelivery({
        target_dispatch: dispatchId,
        recipient_name: recipientName,
        acknowledgement_notes: ackNotes.trim() === "" ? null : ackNotes.trim(),
        expected_version: request?.version ?? 1,
        idempotency_key: nextKey("ds-pod"),
      }),
    onSuccess: refresh,
    onError,
    onSettled: () => setAckOpen(false),
  })
  const fail = useMutation({
    mutationFn: () =>
      reportDispatchDeliveryException({
        target_dispatch: dispatchId,
        exception_reason: failReason,
        expected_version: request?.version ?? 1,
        idempotency_key: nextKey("ds-fail"),
      }),
    onSuccess: refresh,
    onError,
    onSettled: () => setFailOpen(false),
  })

  const pending =
    confirm.isPending ||
    cancel.isPending ||
    assign.isPending ||
    start.isPending ||
    acknowledge.isPending ||
    fail.isPending

  return (
    <section className="min-w-0">
      <PageHeader
        title={request ? request.request_number : "Dispatch"}
        description="One physical dispatch consumes reserved carton cases exactly once. Delivery acknowledgement does not change inventory."
      />
      {detail.isLoading ? <LoadingBlock label="Loading dispatch" /> : null}
      {detail.error ? (
        <p role="alert" className="text-sm text-destructive">
          {detail.error.message}
        </p>
      ) : null}
      {request ? (
        <DispatchBody
          request={request}
          canConfirm={can("dispatch.confirm")}
          canAssign={can("deliveries.assign")}
          canExecute={can("deliveries.execute")}
          canException={can("dispatch.exception") || can("deliveries.execute")}
          assignees={assignees.data ?? []}
          assignee={assignee}
          setAssignee={setAssignee}
          actionError={actionError}
          pending={pending}
          onConfirm={() => setConfirmOpen(true)}
          onCancel={() => setCancelOpen(true)}
          onAssign={() => assign.mutate()}
          onStart={() => start.mutate()}
          onAck={() => setAckOpen(true)}
          onFail={() => setFailOpen(true)}
        />
      ) : null}

      <AppModal
        open={confirmOpen}
        onOpenChange={setConfirmOpen}
        title="Confirm dispatch"
        description="This deducts the reserved carton cases from inventory exactly once."
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => setConfirmOpen(false)}>
              Back
            </Button>
            <Button type="button" onClick={() => confirm.mutate()} disabled={confirm.isPending}>
              {confirm.isPending ? "Confirming" : `Dispatch ${request?.total_cases ?? 0} cases`}
            </Button>
          </>
        }
      />
      <AppModal
        open={cancelOpen}
        onOpenChange={setCancelOpen}
        title="Cancel dispatch"
        description="Allowed only before stock is consumed. Picking stays ready for a new dispatch."
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => setCancelOpen(false)}>
              Back
            </Button>
            <Button
              type="button"
              variant="destructive"
              onClick={() => cancel.mutate()}
              disabled={cancel.isPending || cancelReason.trim() === ""}
            >
              {cancel.isPending ? "Cancelling" : "Cancel dispatch"}
            </Button>
          </>
        }
      >
        <label className="grid gap-1 text-sm font-medium">
          Reason
          <textarea
            className="min-h-20 rounded-lg border border-input px-3 py-2 text-sm font-normal"
            value={cancelReason}
            onChange={(event) => setCancelReason(event.target.value)}
            maxLength={500}
            aria-label="Cancellation reason"
          />
        </label>
      </AppModal>
      <AppModal
        open={ackOpen}
        onOpenChange={setAckOpen}
        title="Record proof of delivery"
        description="This confirms the shop received the cartons. It does not change inventory."
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => setAckOpen(false)}>
              Back
            </Button>
            <Button
              type="button"
              onClick={() => acknowledge.mutate()}
              disabled={acknowledge.isPending || recipientName.trim() === ""}
            >
              {acknowledge.isPending ? "Saving" : "Acknowledge delivery"}
            </Button>
          </>
        }
      >
        <div className="grid gap-3">
          <label className="grid gap-1 text-sm font-medium">
            Recipient name
            <input
              className="h-10 rounded-lg border border-input px-2.5 text-sm font-normal"
              value={recipientName}
              onChange={(event) => setRecipientName(event.target.value)}
              maxLength={120}
              aria-label="Recipient name"
            />
          </label>
          <label className="grid gap-1 text-sm font-medium">
            Notes (optional)
            <textarea
              className="min-h-20 rounded-lg border border-input px-3 py-2 text-sm font-normal"
              value={ackNotes}
              onChange={(event) => setAckNotes(event.target.value)}
              maxLength={500}
              aria-label="Acknowledgement notes"
            />
          </label>
        </div>
      </AppModal>
      <AppModal
        open={failOpen}
        onOpenChange={setFailOpen}
        title="Report failed delivery"
        description="Inventory stays deducted. Physical return needs a later receiving workflow."
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => setFailOpen(false)}>
              Back
            </Button>
            <Button
              type="button"
              variant="destructive"
              onClick={() => fail.mutate()}
              disabled={fail.isPending || failReason.trim() === ""}
            >
              {fail.isPending ? "Saving" : "Record exception"}
            </Button>
          </>
        }
      >
        <label className="grid gap-1 text-sm font-medium">
          Reason
          <textarea
            className="min-h-20 rounded-lg border border-input px-3 py-2 text-sm font-normal"
            value={failReason}
            onChange={(event) => setFailReason(event.target.value)}
            maxLength={500}
            aria-label="Failed delivery reason"
          />
        </label>
      </AppModal>
    </section>
  )
}

function DispatchBody({
  request,
  canConfirm,
  canAssign,
  canExecute,
  canException,
  assignees,
  assignee,
  setAssignee,
  actionError,
  pending,
  onConfirm,
  onCancel,
  onAssign,
  onStart,
  onAck,
  onFail,
}: {
  request: DispatchDetail
  canConfirm: boolean
  canAssign: boolean
  canExecute: boolean
  canException: boolean
  assignees: { id: string; full_name: string }[]
  assignee: string
  setAssignee: (value: string) => void
  actionError: string | null
  pending: boolean
  onConfirm: () => void
  onCancel: () => void
  onAssign: () => void
  onStart: () => void
  onAck: () => void
  onFail: () => void
}) {
  const deliveryReady = request.stock_consumed && ["dispatched", "in_transit"].includes(request.status)

  return (
    <div className="grid gap-6">
      <div className="flex flex-wrap items-center gap-3">
        <StatusBadge tone={dispatchStatusTone[request.status]}>
          {dispatchStatusLabel[request.status]}
        </StatusBadge>
        <span className="text-sm text-slate-600">
          Stock {request.stock_consumed ? "consumed" : "not consumed"}
        </span>
      </div>
      <dl className="grid gap-2 text-sm sm:grid-cols-2">
        <div>
          <dt className="text-slate-500">Order</dt>
          <dd>
            <Link className="underline" to={`/orders/${request.order_id}`}>
              {request.order_number}
            </Link>
          </dd>
        </div>
        <div>
          <dt className="text-slate-500">Picking</dt>
          <dd>
            <Link className="underline" to={`/picking/${request.picking_request_id}`}>
              {request.picking_request_number}
            </Link>
          </dd>
        </div>
        <div>
          <dt className="text-slate-500">Delivery note</dt>
          <dd>
            {request.delivery_note_id ? (
              <Link className="underline" to={`/deliveries/${request.delivery_note_id}`}>
                {request.delivery_note_number} ({request.delivery_note_status})
              </Link>
            ) : (
              "None"
            )}
          </dd>
        </div>
        <div>
          <dt className="text-slate-500">Carton cases</dt>
          <dd>{request.total_cases}</dd>
        </div>
        <div>
          <dt className="text-slate-500">Assigned to</dt>
          <dd>{request.assigned_to_name ?? "Unassigned"}</dd>
        </div>
        <div>
          <dt className="text-slate-500">Recipient</dt>
          <dd>{request.recipient_name ?? "—"}</dd>
        </div>
        {request.physical_return_status ? (
          <div>
            <dt className="text-slate-500">Physical return</dt>
            <dd>Pending verification (stock not restored)</dd>
          </div>
        ) : null}
        {request.exception_reason ? (
          <div className="sm:col-span-2">
            <dt className="text-slate-500">Exception</dt>
            <dd>{request.exception_reason}</dd>
          </div>
        ) : null}
      </dl>

      {actionError ? (
        <p role="alert" className="text-sm text-destructive">
          {actionError}
        </p>
      ) : null}

      <div className="flex flex-wrap gap-2">
        {canConfirm && request.status === "preparing" ? (
          <Button type="button" onClick={onConfirm} disabled={pending}>
            Confirm dispatch
          </Button>
        ) : null}
        {canConfirm && request.status === "preparing" ? (
          <Button type="button" variant="outline" onClick={onCancel} disabled={pending}>
            Cancel before consumption
          </Button>
        ) : null}
        {canExecute && request.status === "dispatched" && request.assigned_to ? (
          <Button type="button" onClick={onStart} disabled={pending}>
            {pending ? "Updating" : "Start delivery"}
          </Button>
        ) : null}
        {canExecute && deliveryReady ? (
          <Button type="button" onClick={onAck} disabled={pending}>
            Record proof of delivery
          </Button>
        ) : null}
        {canException && deliveryReady ? (
          <Button type="button" variant="outline" onClick={onFail} disabled={pending}>
            Report failed delivery
          </Button>
        ) : null}
      </div>

      {canAssign && deliveryReady ? (
        <form
          className="flex flex-wrap items-end gap-2"
          onSubmit={(event) => {
            event.preventDefault()
            onAssign()
          }}
        >
          <label className="grid gap-1 text-sm font-medium">
            Assign delivery personnel
            <select
              className="h-10 min-w-64 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={assignee}
              onChange={(event) => setAssignee(event.target.value)}
              aria-label="Delivery assignee"
            >
              <option value="">Select employee</option>
              {assignees.map((person) => (
                <option key={person.id} value={person.id}>
                  {person.full_name}
                </option>
              ))}
            </select>
          </label>
          <Button type="submit" variant="outline" disabled={pending || assignee === ""}>
            Assign
          </Button>
        </form>
      ) : null}

      <section>
        <h2 className="mb-2 text-base font-semibold">Reserved carton cases</h2>
        <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200/80">
          <table className="w-min min-w-full text-left text-sm">
            <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-4 py-3 font-medium">Product</th>
                <th className="px-4 py-3 font-medium">Location</th>
                <th className="px-4 py-3 font-medium">Lot</th>
                <th className="px-4 py-3 font-medium">Cases</th>
                <th className="px-4 py-3 font-medium">Hold</th>
              </tr>
            </thead>
            <tbody>
              {request.reservations.map((row) => (
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
                  <td className="px-4 py-3">{row.status}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section>
        <h2 className="mb-2 text-base font-semibold">Assignment history</h2>
        {request.assignments.length === 0 ? (
          <p className="text-sm text-slate-600">No delivery assignment yet.</p>
        ) : (
          <ul className="space-y-2 text-sm">
            {request.assignments.map((item) => (
              <li key={item.id} className="rounded-lg bg-slate-50 px-3 py-2">
                {item.assignee_name ?? "Employee"} · {new Date(item.assigned_at).toLocaleString()}
                {item.unassigned_at ? ` · unassigned ${new Date(item.unassigned_at).toLocaleString()}` : ""}
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
              <strong>{dispatchEventLabel[event.event_type] ?? event.event_type}</strong>
              <span className="text-slate-500">
                {" "}
                · {new Date(event.created_at).toLocaleString()}
              </span>
            </li>
          ))}
        </ol>
      </section>
    </div>
  )
}
