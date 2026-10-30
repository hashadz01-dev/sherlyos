import { useState } from "react"
import { Link, useParams } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { AppModal } from "@/components/shared/AppModal"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge, type StatusTone } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import {
  acknowledgeDeliveryNote,
  generateDeliveryNote,
  getCompanyPrintIdentity,
  getDeliveryNote,
  sendDeliveryNote,
  voidDeliveryNote,
  type DeliveryNoteStatus,
} from "@/lib/delivery-notes/api"

const tone: Record<DeliveryNoteStatus, StatusTone> = {
  draft: "neutral",
  generated: "info",
  sent: "warning",
  acknowledged: "success",
  voided: "danger",
}

function formatStamp(value: string | null | undefined) {
  if (!value) return "—"
  return value.slice(0, 19).replace("T", " ")
}

export function DeliveryNoteDetailPage() {
  const { noteId = "" } = useParams()
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const [voidReason, setVoidReason] = useState("")
  const [confirmVoid, setConfirmVoid] = useState(false)
  const [sendOpen, setSendOpen] = useState(false)
  const [ackOpen, setAckOpen] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)
  const [actionSuccess, setActionSuccess] = useState<string | null>(null)

  const detail = useQuery({
    queryKey: ["delivery-note", noteId],
    queryFn: () => getDeliveryNote(noteId),
    enabled: noteId !== "",
  })
  const identity = useQuery({
    queryKey: ["company-print-identity"],
    queryFn: getCompanyPrintIdentity,
    enabled:
      can("delivery_notes.issue") ||
      can("delivery_notes.acknowledge") ||
      can("operations.monitor"),
  })

  const note = detail.data?.delivery_note
  useDocumentTitle(note ? note.delivery_note_number : "Delivery note")

  const canIssue = can("delivery_notes.issue")
  const canAcknowledge = can("delivery_notes.acknowledge")
  const canGenerate = canIssue && note?.status === "draft"
  const canSend = canIssue && note?.status === "generated"
  const canAck = canAcknowledge && note?.status === "sent"
  const canVoid =
    canIssue && note != null && ["draft", "generated", "sent"].includes(note.status)
  const canOpenPrint = note != null && ["generated", "sent", "acknowledged"].includes(note.status)
  const totalCases = (detail.data?.lines ?? []).reduce(
    (sum, line) => sum + line.requested_cases,
    0,
  )

  async function refresh() {
    await queryClient.invalidateQueries({ queryKey: ["delivery-notes"] })
    await queryClient.invalidateQueries({ queryKey: ["delivery-note", noteId] })
    await queryClient.invalidateQueries({ queryKey: ["verified-orders-without-dn"] })
  }

  const generate = useMutation({
    mutationFn: () => {
      if (!note) throw new Error("Delivery note is not loaded.")
      return generateDeliveryNote(note.id, note.version, `dn-generate-${crypto.randomUUID()}`)
    },
    onSuccess: async () => {
      setActionError(null)
      setActionSuccess("Delivery note generated.")
      await refresh()
    },
    onError: (error: Error) => {
      setActionSuccess(null)
      setActionError(error.message)
    },
  })

  const send = useMutation({
    mutationFn: () => {
      if (!note) throw new Error("Delivery note is not loaded.")
      return sendDeliveryNote(note.id, note.version, `dn-send-${crypto.randomUUID()}`)
    },
    onSuccess: async () => {
      setActionError(null)
      setActionSuccess("Delivery note sent to godown.")
      setSendOpen(false)
      await refresh()
    },
    onError: (error: Error) => {
      setActionSuccess(null)
      setActionError(error.message)
    },
  })

  const acknowledge = useMutation({
    mutationFn: () => {
      if (!note) throw new Error("Delivery note is not loaded.")
      return acknowledgeDeliveryNote(
        note.id,
        note.version,
        `dn-ack-${crypto.randomUUID()}`,
      )
    },
    onSuccess: async () => {
      setActionError(null)
      setActionSuccess("Delivery note acknowledged.")
      setAckOpen(false)
      await refresh()
    },
    onError: (error: Error) => {
      setActionSuccess(null)
      setActionError(error.message)
    },
  })

  const voidNote = useMutation({
    mutationFn: () => {
      if (!note) throw new Error("Delivery note is not loaded.")
      return voidDeliveryNote(
        note.id,
        note.version,
        voidReason,
        `dn-void-${crypto.randomUUID()}`,
      )
    },
    onSuccess: async () => {
      setActionError(null)
      setActionSuccess("Delivery note voided.")
      setVoidReason("")
      setConfirmVoid(false)
      await refresh()
    },
    onError: (error: Error) => {
      setActionSuccess(null)
      setActionError(error.message)
    },
  })

  const pending =
    generate.isPending || send.isPending || acknowledge.isPending || voidNote.isPending

  return (
    <section className="min-w-0">
      <PageHeader
        title={note?.delivery_note_number ?? "Delivery note"}
        description="Draft, generate, send, acknowledge, void, or open the printable view. Acknowledgement is paperwork only and does not change stock. Packing cannot start until this note is acknowledged."
        action={
          <Button asChild variant="outline">
            <Link to="/deliveries">Back</Link>
          </Button>
        }
      />

      {detail.isLoading ? <LoadingBlock label="Loading delivery note" /> : null}
      {detail.error ? (
        <p role="alert" className="text-sm text-destructive">
          {detail.error.message}
        </p>
      ) : null}

      {note && detail.data ? (
        <div className="grid gap-6">
          <div className="flex flex-wrap items-center gap-3">
            <StatusBadge tone={tone[note.status]}>{note.status}</StatusBadge>
            <p className="text-sm text-muted-foreground">Version {note.version}</p>
          </div>

          <dl className="grid gap-3 sm:grid-cols-2">
            <div>
              <dt className="text-sm text-muted-foreground">Order</dt>
              <dd>
                <Link className="underline" to={`/orders/${detail.data.order.id}`}>
                  {detail.data.order.order_number}
                </Link>
              </dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Shop</dt>
              <dd>{detail.data.shop.name}</dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Phone</dt>
              <dd>{detail.data.shop.phone ?? "—"}</dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Address</dt>
              <dd>{detail.data.shop.address ?? "—"}</dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Godown</dt>
              <dd>
                {detail.data.godown.name} ({detail.data.godown.code})
              </dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Total cases</dt>
              <dd>{totalCases}</dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Sent</dt>
              <dd>{formatStamp(note.sent_at)}</dd>
            </div>
            <div>
              <dt className="text-sm text-muted-foreground">Acknowledged</dt>
              <dd>{formatStamp(note.acknowledged_at)}</dd>
            </div>
            {note.void_reason ? (
              <div className="sm:col-span-2">
                <dt className="text-sm text-muted-foreground">Void reason</dt>
                <dd>{note.void_reason}</dd>
              </div>
            ) : null}
          </dl>

          <div>
            <h2 className="mb-2 text-sm font-medium">Lines</h2>
            <ul className="grid gap-2">
              {detail.data.lines.map((line) => (
                <li
                  key={line.id}
                  className="flex items-center justify-between gap-3 rounded-2xl bg-card px-4 py-3 text-sm ring-1 ring-border"
                >
                  <span>
                    {line.sku} · {line.product_name}
                  </span>
                  <span>{line.requested_cases} cases</span>
                </li>
              ))}
            </ul>
          </div>

          {actionSuccess ? (
            <p role="status" className="text-sm text-emerald-700">
              {actionSuccess}
            </p>
          ) : null}
          {actionError ? (
            <p role="alert" className="text-sm text-destructive">
              {actionError}
            </p>
          ) : null}

          <div className="grid gap-4">
            {canGenerate ? (
              <Button onClick={() => generate.mutate()} disabled={pending} className="w-full sm:w-auto">
                Generate delivery note
              </Button>
            ) : null}

            {canSend ? (
              <Button
                onClick={() => setSendOpen(true)}
                disabled={pending}
                className="w-full sm:w-auto"
              >
                Send to godown
              </Button>
            ) : null}

            {canAck ? (
              <Button
                onClick={() => setAckOpen(true)}
                disabled={pending}
                className="w-full sm:w-auto"
              >
                Acknowledge receipt
              </Button>
            ) : null}

            {canOpenPrint ? (
              <div className="grid gap-2">
                {identity.data && !identity.data.ready ? (
                  <p role="status" className="rounded-2xl bg-muted px-4 py-3 text-sm">
                    Official printing requires configured company identity (legal name and
                    registered address). Configure `company.legal_name` and
                    `company.registered_address` before printing.
                  </p>
                ) : null}
                <Button asChild variant="outline" className="w-full sm:w-auto">
                  <Link to={`/deliveries/${note.id}/print`}>Open print view</Link>
                </Button>
              </div>
            ) : null}

            {canVoid ? (
              <div className="grid gap-2">
                <label className="grid gap-1 text-sm">
                  Void reason
                  <textarea
                    className="min-h-20 rounded-xl border bg-card px-3 py-2"
                    value={voidReason}
                    onChange={(event) => setVoidReason(event.target.value)}
                    maxLength={500}
                    required
                  />
                </label>
                <label className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={confirmVoid}
                    onChange={(event) => setConfirmVoid(event.target.checked)}
                  />
                  Confirm void
                </label>
                <Button
                  variant="destructive"
                  onClick={() => voidNote.mutate()}
                  disabled={pending || !confirmVoid || voidReason.trim().length < 1}
                  className="w-full sm:w-auto"
                >
                  Void delivery note
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

      <AppModal
        open={sendOpen}
        onOpenChange={setSendOpen}
        title="Send delivery note"
        description="Send this generated delivery note to the fulfilling godown manager."
        footer={
          <>
            <Button variant="outline" onClick={() => setSendOpen(false)} disabled={send.isPending}>
              Cancel
            </Button>
            <Button onClick={() => send.mutate()} disabled={send.isPending}>
              Confirm send
            </Button>
          </>
        }
      />

      <AppModal
        open={ackOpen}
        onOpenChange={setAckOpen}
        title="Acknowledge receipt"
        description="Confirm that this godown has received the delivery note. This does not change stock."
        footer={
          <>
            <Button
              variant="outline"
              onClick={() => setAckOpen(false)}
              disabled={acknowledge.isPending}
            >
              Cancel
            </Button>
            <Button onClick={() => acknowledge.mutate()} disabled={acknowledge.isPending}>
              Confirm acknowledgement
            </Button>
          </>
        }
      />
    </section>
  )
}
