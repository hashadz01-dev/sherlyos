import { useState } from "react"
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
  submitStockAdjustment,
} from "@/lib/adjustment/api"
import { adjustmentActions, type AdjustmentStatus } from "@/lib/adjustment/rules"

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
  const detail = useQuery({
    queryKey: ["stock-adjustment", requestId],
    queryFn: () => getStockAdjustment(requestId),
    enabled: requestId.length > 0,
  })
  const refresh = async () => {
    await queryClient.invalidateQueries({ queryKey: ["stock-adjustment", requestId] })
    await queryClient.invalidateQueries({ queryKey: ["stock-adjustments"] })
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
  const act = useMutation({
    mutationFn: async (kind: "submit" | "approve" | "return" | "reject" | "post") => {
      if (!request) return
      if (kind === "submit") return submitStockAdjustment(request.id, request.version)
      if (kind === "approve") return approveStockAdjustment(request.id, request.version, note)
      if (kind === "return") return returnStockAdjustment(request.id, request.version, note)
      if (kind === "reject") return rejectStockAdjustment(request.id, request.version, note)
      return postStockAdjustment(request.id, request.version, `post-${crypto.randomUUID()}`)
    },
    onSuccess: refresh,
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
              </article>
            ))}
          </div>
          {request.status === "approved" ? (
            <p className="rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-950 ring-1 ring-amber-200">
              This request is approved and inventory has not changed. Posting checks movements after the verification and refuses the request if the discrepancy is no longer provable.
            </p>
          ) : null}
          {actions.submit ? <Button onClick={() => act.mutate("submit")}>Submit</Button> : null}
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
              <Button onClick={() => act.mutate("post")} disabled={!confirmPost}>Post adjustment</Button>
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
