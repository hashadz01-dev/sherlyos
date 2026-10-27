/**
 * Accounts-only REF-05/REF-06 recording. Mutations never retry and never
 * mark send/dispatch complete until the RPC returns.
 */
import { useMemo, useState } from "react"
import { useMutation } from "@tanstack/react-query"
import { AppModal } from "@/components/shared/AppModal"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import {
  formatDateOnly,
  formatRefillAcknowledgement,
  formatRefillChannel,
  formatRefillCommunication,
  formatRefillDispatch,
  formatTimestamp,
  refillAcknowledgementTone,
  refillChannelLabels,
  refillCommunicationTone,
  refillDispatchTone,
} from "@/features/refill/utils/labels"
import type { RefillRequestDetail } from "@/lib/refill/api"
import {
  recordStockRefillSupplierAcknowledgement,
  recordStockRefillSupplierCommunication,
  recordStockRefillSupplierDispatch,
} from "@/lib/refill/api"
import {
  canRecordRefillAcknowledgement,
  canRecordRefillDispatch,
  canRecordRefillSend,
  clearRefillSessionIdempotencyKey,
  isValidDecisionReason,
  isValidRefillShortText,
  refillCommunicationChannels,
  refillSessionIdempotencyKey,
  type RefillCommunicationChannel,
} from "@/lib/refill/rules"

function emptyToNull(value: string) {
  const cleaned = value.trim()
  return cleaned.length > 0 ? cleaned : null
}

function toIsoFromDatetimeLocal(value: string) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return null
  return date.toISOString()
}

function defaultDatetimeLocal() {
  const now = new Date()
  now.setSeconds(0, 0)
  const pad = (n: number) => String(n).padStart(2, "0")
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}T${pad(now.getHours())}:${pad(now.getMinutes())}`
}

function todayIsoDate() {
  const now = new Date()
  const pad = (n: number) => String(n).padStart(2, "0")
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

export function RefillSupplierPanel({
  request,
  canRequest,
  onChanged,
}: {
  request: RefillRequestDetail
  canRequest: boolean
  onChanged: () => Promise<unknown>
}) {
  const [dialog, setDialog] = useState<"send" | "ack" | "dispatch" | null>(null)
  const [channel, setChannel] = useState<RefillCommunicationChannel>("whatsapp")
  const [communicatedAt, setCommunicatedAt] = useState(defaultDatetimeLocal)
  const [externalReference, setExternalReference] = useState("")
  const [sendNotes, setSendNotes] = useState("")
  const [ackStatus, setAckStatus] = useState<"acknowledged" | "declined">(
    "acknowledged",
  )
  const [responseAt, setResponseAt] = useState(defaultDatetimeLocal)
  const [ackReference, setAckReference] = useState("")
  const [ackNotes, setAckNotes] = useState("")
  const [declineReason, setDeclineReason] = useState("")
  const [dispatchedOn, setDispatchedOn] = useState(todayIsoDate)
  const [expectedArrivalOn, setExpectedArrivalOn] = useState("")
  const [dispatchReference, setDispatchReference] = useState("")
  const [transportProvider, setTransportProvider] = useState("")
  const [vehicleReference, setVehicleReference] = useState("")
  const [trackingReference, setTrackingReference] = useState("")
  const [dispatchNotes, setDispatchNotes] = useState("")
  const [networkHint, setNetworkHint] = useState<string | null>(null)

  const sendKey = useMemo(
    () => `sherlyos.refill.send.${request.id}`,
    [request.id],
  )
  const ackKey = useMemo(
    () => `sherlyos.refill.ack.${request.id}`,
    [request.id],
  )
  const dispatchKey = useMemo(
    () => `sherlyos.refill.dispatch.${request.id}`,
    [request.id],
  )

  const sendable = canRecordRefillSend({
    status: request.status,
    communicationStatus: request.communication_status,
    godownActive: request.godown_active,
    canRequest,
  })
  const acknowledgeable = canRecordRefillAcknowledgement({
    status: request.status,
    communicationStatus: request.communication_status,
    godownActive: request.godown_active,
    canRequest,
  })
  const dispatchable = canRecordRefillDispatch({
    status: request.status,
    communicationStatus: request.communication_status,
    acknowledgementStatus: request.acknowledgement_status,
    godownActive: request.godown_active,
    canRequest,
  })
  const awaitingReceiving =
    request.dispatch_status === "recorded" &&
    request.acknowledgement_status !== "declined"

  const resetDialog = () => {
    setDialog(null)
    setNetworkHint(null)
  }

  const send = useMutation({
    retry: false,
    mutationFn: async () => {
      const communicatedIso = toIsoFromDatetimeLocal(communicatedAt)
      if (!communicatedIso) throw new Error("Enter a valid communication date and time.")
      return recordStockRefillSupplierCommunication({
        requestId: request.id,
        expectedVersion: request.version,
        channel,
        communicatedAt: communicatedIso,
        idempotencyKey: refillSessionIdempotencyKey(sendKey),
        externalReference: emptyToNull(externalReference),
        notes: emptyToNull(sendNotes),
      })
    },
    onSuccess: async () => {
      clearRefillSessionIdempotencyKey(sendKey)
      resetDialog()
      await onChanged()
    },
    onError: () => {
      setNetworkHint(
        "If the network dropped, refresh this request before recording again. Do not open a second tab.",
      )
    },
  })

  const acknowledge = useMutation({
    retry: false,
    mutationFn: async () => {
      const responseIso = toIsoFromDatetimeLocal(responseAt)
      if (!responseIso) throw new Error("Enter a valid supplier response date and time.")
      return recordStockRefillSupplierAcknowledgement({
        requestId: request.id,
        expectedVersion: request.version,
        status: ackStatus,
        responseAt: responseIso,
        idempotencyKey: refillSessionIdempotencyKey(ackKey),
        acknowledgementReference: emptyToNull(ackReference),
        notes: emptyToNull(ackNotes),
        declineReason: ackStatus === "declined" ? declineReason.trim() : null,
      })
    },
    onSuccess: async () => {
      clearRefillSessionIdempotencyKey(ackKey)
      resetDialog()
      await onChanged()
    },
    onError: () => {
      setNetworkHint(
        "If the network dropped, refresh this request before recording again. Do not assume the supplier response was saved.",
      )
    },
  })

  const dispatch = useMutation({
    retry: false,
    mutationFn: async () => {
      if (!dispatchedOn) throw new Error("Enter the supplier-reported dispatch date.")
      return recordStockRefillSupplierDispatch({
        requestId: request.id,
        expectedVersion: request.version,
        dispatchedOn,
        idempotencyKey: refillSessionIdempotencyKey(dispatchKey),
        supplierDispatchReference: emptyToNull(dispatchReference),
        expectedArrivalOn: emptyToNull(expectedArrivalOn),
        transportProvider: emptyToNull(transportProvider),
        vehicleReference: emptyToNull(vehicleReference),
        trackingReference: emptyToNull(trackingReference),
        notes: emptyToNull(dispatchNotes),
      })
    },
    onSuccess: async () => {
      clearRefillSessionIdempotencyKey(dispatchKey)
      resetDialog()
      await onChanged()
    },
    onError: () => {
      setNetworkHint(
        "If the network dropped, refresh this request before recording again. Supplier dispatch is not a stock receipt.",
      )
    },
  })

  const mutationError =
    send.error?.message ?? acknowledge.error?.message ?? dispatch.error?.message ?? null
  const sendValid = isValidRefillShortText(externalReference)
  const ackValid =
    isValidRefillShortText(ackReference) &&
    (ackStatus !== "declined" || isValidDecisionReason(declineReason))
  const dispatchValid =
    dispatchedOn.length > 0 &&
    (!expectedArrivalOn || expectedArrivalOn >= dispatchedOn) &&
    isValidRefillShortText(dispatchReference) &&
    isValidRefillShortText(transportProvider) &&
    isValidRefillShortText(vehicleReference) &&
    isValidRefillShortText(trackingReference)

  return (
    <section className="grid gap-4" aria-labelledby="refill-supplier-heading">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 id="refill-supplier-heading" className="text-base font-semibold">
            Supplier communication & dispatch
          </h2>
          <p className="text-sm text-muted-foreground">
            Manual recording only. SherlysOS does not send messages or add inventory
            here.
          </p>
        </div>
        {canRequest ? (
          <div className="flex flex-wrap gap-2">
            {sendable ? (
              <Button type="button" onClick={() => setDialog("send")}>
                Mark as sent — manually recorded
              </Button>
            ) : null}
            {acknowledgeable ? (
              <Button type="button" variant="outline" onClick={() => setDialog("ack")}>
                Record supplier response
              </Button>
            ) : null}
            {dispatchable ? (
              <Button
                type="button"
                variant="outline"
                onClick={() => setDialog("dispatch")}
              >
                Record supplier dispatch
              </Button>
            ) : null}
          </div>
        ) : null}
      </div>

      <aside
        role="note"
        className="rounded-2xl bg-sky-50 px-4 py-3 text-sm text-sky-950 ring-1 ring-sky-200"
      >
        Admin approval does not add inventory. Supplier dispatch does not add
        inventory. Accepted stock is posted only by Branch 03 receiving verification.
      </aside>

      {awaitingReceiving ? (
        <p className="text-sm font-medium">Awaiting physical receiving</p>
      ) : null}

      <dl className="grid gap-3 rounded-2xl bg-card p-4 text-sm ring-1 ring-border sm:grid-cols-2 lg:grid-cols-3">
        <div>
          <dt className="text-muted-foreground">Communication</dt>
          <dd>
            <StatusBadge tone={refillCommunicationTone[request.communication_status]}>
              {formatRefillCommunication(request.communication_status)}
            </StatusBadge>
          </dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Supplier acknowledgement</dt>
          <dd>
            <StatusBadge tone={refillAcknowledgementTone[request.acknowledgement_status]}>
              {formatRefillAcknowledgement(request.acknowledgement_status)}
            </StatusBadge>
          </dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Supplier dispatch</dt>
          <dd>
            <StatusBadge tone={refillDispatchTone[request.dispatch_status]}>
              {formatRefillDispatch(request.dispatch_status)}
            </StatusBadge>
          </dd>
        </div>
        {request.communication ? (
          <>
            <div>
              <dt className="text-muted-foreground">Channel</dt>
              <dd>{formatRefillChannel(request.communication.channel)}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Communicated</dt>
              <dd>{formatTimestamp(request.communication.communicated_at)}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">External reference</dt>
              <dd>{request.communication.external_reference ?? "—"}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Recorded by</dt>
              <dd>
                {request.communication.recorder_name ?? "—"} ·{" "}
                {formatTimestamp(request.communication.recorded_at)}
              </dd>
            </div>
            {request.communication.acknowledgement_at ? (
              <div>
                <dt className="text-muted-foreground">Supplier response time</dt>
                <dd>{formatTimestamp(request.communication.acknowledgement_at)}</dd>
              </div>
            ) : null}
            {request.communication.acknowledgement_reason ? (
              <div className="sm:col-span-2">
                <dt className="text-muted-foreground">Decline reason</dt>
                <dd>{request.communication.acknowledgement_reason}</dd>
              </div>
            ) : null}
          </>
        ) : null}
        {request.dispatch ? (
          <>
            <div>
              <dt className="text-muted-foreground">Supplier dispatch date</dt>
              <dd>{formatDateOnly(request.dispatch.dispatched_on)}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Expected arrival</dt>
              <dd>{formatDateOnly(request.dispatch.expected_arrival_on)}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Dispatch reference</dt>
              <dd>{request.dispatch.supplier_dispatch_reference ?? "—"}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Transport</dt>
              <dd>{request.dispatch.transport_provider ?? "—"}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Vehicle</dt>
              <dd>{request.dispatch.vehicle_reference ?? "—"}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Tracking</dt>
              <dd>{request.dispatch.tracking_reference ?? "—"}</dd>
            </div>
          </>
        ) : null}
      </dl>

      {mutationError ? (
        <p role="alert" className="text-sm text-destructive">
          {mutationError}
        </p>
      ) : null}
      {networkHint ? (
        <p role="status" className="text-sm text-muted-foreground">
          {networkHint}
        </p>
      ) : null}

      <AppModal
        open={dialog === "send"}
        onOpenChange={(open) => {
          if (!open) resetDialog()
        }}
        title="Mark as sent — manually recorded"
        description="Record that Accounts already communicated this approved request outside SherlysOS. This does not send a message and does not add inventory."
        footer={
          <>
            <Button type="button" variant="outline" onClick={resetDialog} disabled={send.isPending}>
              Cancel
            </Button>
            <Button
              type="button"
              disabled={send.isPending || !sendValid}
              onClick={() => send.mutate()}
              aria-label="Confirm mark as sent"
            >
              {send.isPending ? "Saving…" : "Confirm recorded send"}
            </Button>
          </>
        }
      >
        <div className="grid gap-3">
          <label className="grid gap-2 text-sm font-medium">
            Channel
            <select
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={channel}
              onChange={(event) =>
                setChannel(event.target.value as RefillCommunicationChannel)
              }
              aria-label="Communication channel"
            >
              {refillCommunicationChannels.map((value) => (
                <option key={value} value={value}>
                  {refillChannelLabels[value]}
                </option>
              ))}
            </select>
          </label>
          <label className="grid gap-2 text-sm font-medium">
            Communication date and time
            <input
              type="datetime-local"
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={communicatedAt}
              onChange={(event) => setCommunicatedAt(event.target.value)}
              aria-label="Communication date and time"
            />
          </label>
          <label className="grid gap-2 text-sm font-medium">
            Optional external reference
            <input
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={externalReference}
              onChange={(event) => setExternalReference(event.target.value)}
              maxLength={120}
              aria-label="Optional external reference"
            />
          </label>
          <label className="grid gap-2 text-sm font-medium">
            Optional notes
            <textarea
              className="min-h-20 rounded-lg border border-input bg-transparent px-2.5 py-2 text-sm font-normal"
              value={sendNotes}
              onChange={(event) => setSendNotes(event.target.value)}
              maxLength={500}
              aria-label="Optional send notes"
            />
          </label>
        </div>
      </AppModal>

      <AppModal
        open={dialog === "ack"}
        onOpenChange={(open) => {
          if (!open) resetDialog()
        }}
        title="Supplier response — manually recorded"
        description="Record information received from the supplier. This is not independently verified and does not change the Admin approval."
        footer={
          <>
            <Button
              type="button"
              variant="outline"
              onClick={resetDialog}
              disabled={acknowledge.isPending}
            >
              Cancel
            </Button>
            <Button
              type="button"
              disabled={acknowledge.isPending || !ackValid}
              onClick={() => acknowledge.mutate()}
              aria-label="Confirm supplier response"
            >
              {acknowledge.isPending ? "Saving…" : "Save supplier response"}
            </Button>
          </>
        }
      >
        <div className="grid gap-3">
          <label className="grid gap-2 text-sm font-medium">
            Acknowledgement outcome
            <select
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={ackStatus}
              onChange={(event) =>
                setAckStatus(event.target.value as "acknowledged" | "declined")
              }
              aria-label="Acknowledgement outcome"
            >
              <option value="acknowledged">Acknowledged</option>
              <option value="declined">Declined</option>
            </select>
          </label>
          <label className="grid gap-2 text-sm font-medium">
            Response date and time
            <input
              type="datetime-local"
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={responseAt}
              onChange={(event) => setResponseAt(event.target.value)}
              aria-label="Supplier response date and time"
            />
          </label>
          <label className="grid gap-2 text-sm font-medium">
            Optional supplier reference
            <input
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={ackReference}
              onChange={(event) => setAckReference(event.target.value)}
              maxLength={120}
              aria-label="Optional supplier acknowledgement reference"
            />
          </label>
          {ackStatus === "declined" ? (
            <label className="grid gap-2 text-sm font-medium">
              Decline reason
              <textarea
                className="min-h-20 rounded-lg border border-input bg-transparent px-2.5 py-2 text-sm font-normal"
                value={declineReason}
                onChange={(event) => setDeclineReason(event.target.value)}
                maxLength={500}
                aria-label="Decline reason"
              />
            </label>
          ) : (
            <label className="grid gap-2 text-sm font-medium">
              Optional notes
              <textarea
                className="min-h-20 rounded-lg border border-input bg-transparent px-2.5 py-2 text-sm font-normal"
                value={ackNotes}
                onChange={(event) => setAckNotes(event.target.value)}
                maxLength={500}
                aria-label="Optional acknowledgement notes"
              />
            </label>
          )}
        </div>
      </AppModal>

      <AppModal
        open={dialog === "dispatch"}
        onOpenChange={(open) => {
          if (!open) resetDialog()
        }}
        title="Supplier dispatch recorded"
        description="Record dispatch details provided by the FMCG supplier. This is not goods received and does not post inventory."
        footer={
          <>
            <Button
              type="button"
              variant="outline"
              onClick={resetDialog}
              disabled={dispatch.isPending}
            >
              Cancel
            </Button>
            <Button
              type="button"
              disabled={dispatch.isPending || !dispatchValid}
              onClick={() => dispatch.mutate()}
              aria-label="Confirm supplier dispatch"
            >
              {dispatch.isPending ? "Saving…" : "Save supplier dispatch"}
            </Button>
          </>
        }
      >
        <div className="grid gap-3">
          <label className="grid gap-2 text-sm font-medium">
            Supplier-reported dispatch date
            <input
              type="date"
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={dispatchedOn}
              onChange={(event) => setDispatchedOn(event.target.value)}
              aria-label="Supplier-reported dispatch date"
            />
          </label>
          <label className="grid gap-2 text-sm font-medium">
            Expected arrival date
            <input
              type="date"
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={expectedArrivalOn}
              onChange={(event) => setExpectedArrivalOn(event.target.value)}
              aria-label="Expected arrival date"
            />
          </label>
          <label className="grid gap-2 text-sm font-medium">
            Optional supplier dispatch reference
            <input
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={dispatchReference}
              onChange={(event) => setDispatchReference(event.target.value)}
              maxLength={120}
              aria-label="Optional supplier dispatch reference"
            />
          </label>
          <label className="grid gap-2 text-sm font-medium">
            Optional transport provider
            <input
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={transportProvider}
              onChange={(event) => setTransportProvider(event.target.value)}
              maxLength={120}
              aria-label="Optional transport provider"
            />
          </label>
          <label className="grid gap-2 text-sm font-medium">
            Optional vehicle reference
            <input
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={vehicleReference}
              onChange={(event) => setVehicleReference(event.target.value)}
              maxLength={120}
              aria-label="Optional vehicle reference"
            />
          </label>
          <label className="grid gap-2 text-sm font-medium">
            Optional tracking reference
            <input
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
              value={trackingReference}
              onChange={(event) => setTrackingReference(event.target.value)}
              maxLength={120}
              aria-label="Optional tracking reference"
            />
          </label>
          <label className="grid gap-2 text-sm font-medium">
            Optional notes
            <textarea
              className="min-h-20 rounded-lg border border-input bg-transparent px-2.5 py-2 text-sm font-normal"
              value={dispatchNotes}
              onChange={(event) => setDispatchNotes(event.target.value)}
              maxLength={500}
              aria-label="Optional dispatch notes"
            />
          </label>
        </div>
      </AppModal>
    </section>
  )
}
