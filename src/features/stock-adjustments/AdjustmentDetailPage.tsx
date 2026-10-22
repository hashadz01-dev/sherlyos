import { useMemo, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Link, useParams } from "react-router"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge, type StatusTone } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAuth } from "@/hooks/use-auth"
import { useAccess } from "@/lib/access/use-access"
import {
  approveStockAdjustment,
  getStockAdjustment,
  postStockAdjustment,
  rejectStockAdjustment,
  returnStockAdjustment,
  setStockAdjustmentLineLotAllocations,
  submitStockAdjustment,
  type AdjustmentDetail,
} from "@/lib/adjustment/api"
import { adjustmentActions, type AdjustmentStatus } from "@/lib/adjustment/rules"
import { getStockLotCutoverState, listStockLotBalances } from "@/lib/inventory/api"
import { notify } from "@/lib/utilities/notify"

const tone: Record<AdjustmentStatus, StatusTone> = {
  draft: "neutral",
  submitted: "info",
  returned: "warning",
  approved: "success",
  rejected: "danger",
  posted: "success",
}

export function AdjustmentDetailPage() {
  useDocumentTitle("Adjustment request")
  const { requestId = "" } = useParams()
  const { session } = useAuth()
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const [note, setNote] = useState("")
  const [confirmPost, setConfirmPost] = useState(false)
  const cutover = useQuery({
    queryKey: ["stock-lot-cutover"],
    queryFn: getStockLotCutoverState,
  })
  const dualWriteEnabled = cutover.data?.dual_write_enabled ?? false
  const detail = useQuery({
    queryKey: ["stock-adjustment", requestId],
    queryFn: () => getStockAdjustment(requestId),
    enabled: requestId.length > 0,
  })
  const refresh = async () => {
    await queryClient.invalidateQueries({ queryKey: ["stock-adjustment", requestId] })
    await queryClient.invalidateQueries({ queryKey: ["stock-adjustments"] })
    await queryClient.invalidateQueries({ queryKey: ["stock-lot-balances"] })
  }
  const request = detail.data
  const actions = request
    ? adjustmentActions({
        status: request.status,
        exceptional: request.exceptional,
        isRequester: request.requested_by === session?.user.id,
        canRequest: can("stock.adjustment.request"),
        canPost: can("stock.adjustment.post"),
        canApproveExceptional: can("stock.adjustment.approve_exceptional"),
        otherManagerExists: request.other_manager_exists,
      })
    : null
  const allocationsReady = useMemo(() => {
    if (!dualWriteEnabled || !request) return true
    return request.lines.every((line) => {
      const total = (line.lot_allocations ?? []).reduce((sum, row) => sum + row.quantity, 0)
      return total === line.requested_cases
    })
  }, [dualWriteEnabled, request])
  const act = useMutation({
    mutationFn: async (kind: "submit" | "approve" | "return" | "reject" | "post") => {
      if (!request) return
      if (kind === "submit") return submitStockAdjustment(request.id, request.version)
      if (kind === "approve") return approveStockAdjustment(request.id, request.version, note)
      if (kind === "return") return returnStockAdjustment(request.id, request.version, note)
      if (kind === "reject") return rejectStockAdjustment(request.id, request.version, note)
      return postStockAdjustment(request.id, request.version, `post-${crypto.randomUUID()}`)
    },
    onSuccess: async () => {
      notify.success("Adjustment updated")
      await refresh()
    },
    onError: (error: Error) => notify.error(error.message),
  })

  return (
    <section className="min-w-0">
      <PageHeader
        title={request?.request_number ?? "Adjustment request"}
        description="Approval does not change inventory. Posting is a separate action."
      />
      <Link className="mb-4 inline-block text-sm underline-offset-4 hover:underline" to="/stock-adjustments">Back to adjustments</Link>
      {detail.isLoading ? <LoadingBlock label="Loading adjustment" /> : null}
      {detail.error ? <p role="alert" className="text-sm text-destructive">{detail.error.message}</p> : null}
      {request && actions ? (
        <div className="grid gap-4">
          <div className="flex flex-wrap items-center gap-2">
            <StatusBadge tone={tone[request.status]}>{request.status}</StatusBadge>
            <StatusBadge tone={request.exceptional ? "warning" : "neutral"}>
              {request.exceptional ? "Exceptional, above 10 cases" : "Ordinary, 10 cases or fewer"}
            </StatusBadge>
          </div>
          <div className="grid gap-3 rounded-2xl bg-card p-4 ring-1 ring-border md:grid-cols-2">
            <p className="text-sm">Godown: {request.godown_name}</p>
            <p className="text-sm">Verification: <Link className="underline-offset-4 hover:underline" to={`/stock-verification/${request.verification_id}`}>{request.verification_number}</Link></p>
            <p className="text-sm">Reason: {request.reason_code}</p>
            <p className="text-sm">Photo: {request.evidence_id}</p>
            <p className="text-sm md:col-span-2">Note: {request.note}</p>
          </div>
          <div className="grid gap-3">
            {request.lines.map((line) => (
              <article key={line.id} className="rounded-2xl bg-card p-4 ring-1 ring-border">
                <h2 className="font-medium">{line.sku} · {line.product_name}</h2>
                <p className="text-sm text-muted-foreground">Crate {line.crate_code}</p>
                <p className="mt-2 text-sm">Approved correction: {line.requested_cases} cases</p>
                <p className="text-sm">Current book quantity: {line.current_cases ?? 0} cases</p>
                <p className="text-sm">Posting impact: book quantity becomes {(line.current_cases ?? 0) + line.requested_cases} if no later movement has made this request stale.</p>
                {dualWriteEnabled ? (
                  <AdjustmentLotAllocator
                    request={request}
                    line={line}
                    canEdit={
                      (request.status === "draft" || request.status === "returned") &&
                      can("stock.adjustment.request")
                    }
                    onSaved={refresh}
                  />
                ) : null}
              </article>
            ))}
          </div>
          {request.status === "approved" ? (
            <p className="rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-950 ring-1 ring-amber-200">
              This request is approved and inventory has not changed. Posting checks movements after the verification and refuses the request if the discrepancy is no longer provable.
            </p>
          ) : null}
          {actions.submit ? (
            <Button
              onClick={() => act.mutate("submit")}
              disabled={dualWriteEnabled && !allocationsReady}
            >
              Submit
            </Button>
          ) : null}
          {actions.approve || actions.return || actions.reject ? (
            <label className="grid gap-1 text-sm">
              Decision note
              <textarea className="min-h-20 rounded-xl border bg-card px-3 py-2" value={note} onChange={(event) => setNote(event.target.value)} />
            </label>
          ) : null}
          <div className="flex flex-col gap-2 sm:flex-row">
            {actions.approve ? <Button onClick={() => act.mutate("approve")} disabled={note.trim() === ""}>Approve</Button> : null}
            {actions.return ? <Button variant="outline" onClick={() => act.mutate("return")} disabled={note.trim() === ""}>Return</Button> : null}
            {actions.reject ? <Button variant="outline" onClick={() => act.mutate("reject")} disabled={note.trim() === ""}>Reject</Button> : null}
          </div>
          {actions.post ? (
            <div className="grid gap-2">
              <label className="flex items-start gap-2 text-sm">
                <input type="checkbox" checked={confirmPost} onChange={(event) => setConfirmPost(event.target.checked)} />
                I understand posting will change inventory by the approved quantities and cannot be undone by editing the ledger.
              </label>
              <Button
                onClick={() => act.mutate("post")}
                disabled={!confirmPost || (dualWriteEnabled && !allocationsReady)}
              >
                Post adjustment
              </Button>
              {dualWriteEnabled && !allocationsReady ? (
                <p role="alert" className="text-sm text-destructive">
                  Lot allocations must equal each line quantity before post.
                </p>
              ) : null}
            </div>
          ) : null}
          {act.error ? <p role="alert" className="text-sm text-destructive">{act.error.message}</p> : null}
          <section>
            <h2 className="mb-2 font-medium">History</h2>
            {request.events.length === 0 ? <EmptyState title="No events" description="Actions on this request will appear here." /> : null}
            <ol className="grid gap-2">
              {request.events.map((event) => (
                <li key={`${event.created_at}-${event.event_type}`} className="rounded-2xl bg-card p-3 text-sm ring-1 ring-border">
                  <p className="font-medium">{event.event_type} · version {event.request_version}</p>
                  <p className="text-muted-foreground">{event.actor_name} · {event.created_at}</p>
                  {event.note ? <p>{event.note}</p> : null}
                </li>
              ))}
            </ol>
          </section>
        </div>
      ) : null}
    </section>
  )
}

function AdjustmentLotAllocator({
  request,
  line,
  canEdit,
  onSaved,
}: {
  request: AdjustmentDetail
  line: AdjustmentDetail["lines"][number]
  canEdit: boolean
  onSaved: () => Promise<void>
}) {
  const lots = useQuery({
    queryKey: ["stock-lot-balances", request.godown_id, line.crate_id, line.product_id],
    queryFn: () =>
      listStockLotBalances({
        filter_branch: request.godown_id,
        filter_crate: line.crate_id,
        filter_product: line.product_id,
      }),
  })
  const [quantities, setQuantities] = useState<Record<string, string>>(() => {
    const initial: Record<string, string> = {}
    for (const alloc of line.lot_allocations ?? []) {
      initial[alloc.lot_id] = String(Math.abs(alloc.quantity))
    }
    return initial
  })
  const sign = line.requested_cases >= 0 ? 1 : -1
  const save = useMutation({
    mutationFn: () => {
      const allocations = Object.entries(quantities)
        .filter(([, value]) => Number(value) > 0)
        .map(([lotId, value]) => ({
          lot_id: lotId,
          quantity: sign * Number(value),
        }))
      return setStockAdjustmentLineLotAllocations(line.id, allocations)
    },
    onSuccess: async () => {
      notify.success(`Lot allocations saved for ${line.sku}`)
      await onSaved()
    },
    onError: (error: Error) => notify.error(error.message),
  })
  const total = Object.values(quantities).reduce((sum, value) => sum + (Number(value) || 0), 0)

  return (
    <div className="mt-3 grid gap-2 border-t border-border pt-3">
      <p className="text-sm font-medium">Lot allocations (explicit)</p>
      <p className="text-xs text-muted-foreground">
        Enter absolute quantities; sign follows the line ({line.requested_cases}). Attributed magnitude:{" "}
        {total} / {Math.abs(line.requested_cases)}
      </p>
      {lots.isLoading ? <p className="text-sm text-muted-foreground">Loading lots…</p> : null}
      {(lots.data ?? []).map((lot) => (
        <label key={lot.lot_id} className="grid gap-1 text-sm">
          <span>
            {lot.manufacturer_lot_code ?? "No manufacturer code"} · on-hand {lot.quantity}
            {lot.expiry_date ? ` · exp ${lot.expiry_date}` : ""}
          </span>
          <input
            className="h-10 rounded-xl border bg-card px-3"
            inputMode="numeric"
            disabled={!canEdit}
            value={quantities[lot.lot_id] ?? ""}
            onChange={(event) =>
              setQuantities({ ...quantities, [lot.lot_id]: event.target.value })
            }
          />
        </label>
      ))}
      {(lots.data ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No lots available for this crate/product.</p>
      ) : null}
      {canEdit ? (
        <Button type="button" className="w-fit" disabled={save.isPending} onClick={() => save.mutate()}>
          Save lot allocations
        </Button>
      ) : (
        <ul className="text-sm text-muted-foreground">
          {(line.lot_allocations ?? []).map((alloc) => (
            <li key={alloc.lot_id}>
              {alloc.lot_id.slice(0, 8)}… · {alloc.quantity}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
