import { useState } from "react"
import { Link, useParams } from "react-router"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { AppModal } from "@/components/shared/AppModal"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import {
  formatCases,
  formatRefillEvent,
  formatRefillStatus,
  formatTimestamp,
  refillStatusTone,
} from "@/features/refill/utils/labels"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAuth } from "@/hooks/use-auth"
import { useAccess } from "@/lib/access/use-access"
import {
  approveStockRefillRequest,
  getStockRefillRequest,
  holdStockRefillRequest,
  rejectStockRefillRequest,
  submitStockRefillRequest,
} from "@/lib/refill/api"
import {
  canDecideRefillRequest,
  canEditRefillRequest,
  canSubmitRefillRequest,
  isValidDecisionReason,
  refillMutationIdempotencyKey,
} from "@/lib/refill/rules"

export function RefillDetailPage() {
  const { requestId = "" } = useParams()
  useDocumentTitle("Refill request")
  const { session } = useAuth()
  const { can } = useAccess()
  const queryClient = useQueryClient()
  const [decisionOpen, setDecisionOpen] = useState<"hold" | "reject" | "approve" | null>(
    null,
  )
  const [reason, setReason] = useState("")
  const detail = useQuery({
    queryKey: ["refill-request", requestId],
    queryFn: () => getStockRefillRequest(requestId),
    enabled: requestId.length > 0,
  })
  const request = detail.data
  const viewerId = session?.user.id ?? null
  const canRequest = can("refill.request")
  const canApprove = can("refill.approve")
  const editable = request
    ? canEditRefillRequest({
        status: request.status,
        createdBy: request.created_by,
        viewerId,
        canRequest,
      })
    : false
  const submittable = request
    ? canSubmitRefillRequest({
        status: request.status,
        createdBy: request.created_by,
        viewerId,
        canRequest,
      })
    : false
  const decidable = request
    ? canDecideRefillRequest({
        status: request.status,
        canApprove,
      })
    : false

  const refresh = async () => {
    await queryClient.invalidateQueries({ queryKey: ["refill-request", requestId] })
    await queryClient.invalidateQueries({ queryKey: ["refill-requests"] })
  }

  const submit = useMutation({
    retry: false,
    mutationFn: async () => {
      if (!request) return
      return submitStockRefillRequest(
        request.id,
        request.version,
        refillMutationIdempotencyKey("sub", request.id),
      )
    },
    onSuccess: refresh,
  })
  const decide = useMutation({
    retry: false,
    mutationFn: async () => {
      if (!request || !decisionOpen) return
      if (decisionOpen === "approve") {
        return approveStockRefillRequest(
          request.id,
          request.version,
          refillMutationIdempotencyKey("apr", request.id),
          reason.trim() || null,
        )
      }
      if (decisionOpen === "hold") {
        return holdStockRefillRequest(
          request.id,
          request.version,
          reason.trim(),
          refillMutationIdempotencyKey("hld", request.id),
        )
      }
      return rejectStockRefillRequest(
        request.id,
        request.version,
        reason.trim(),
        refillMutationIdempotencyKey("rej", request.id),
      )
    },
    onSuccess: async () => {
      setDecisionOpen(null)
      setReason("")
      await refresh()
    },
  })

  const mutationError = submit.error?.message ?? decide.error?.message ?? null
  const reasonRequired = decisionOpen === "hold" || decisionOpen === "reject"
  const reasonValid = !reasonRequired || isValidDecisionReason(reason)

  return (
    <section className="min-w-0">
      <PageHeader
        title={request ? request.request_number : "Refill request"}
        description="Approval authorizes a later supplier order. It does not receive stock."
        action={
          <div className="flex flex-wrap gap-2">
            <Button asChild variant="outline">
              <Link to="/refill">All requests</Link>
            </Button>
            {editable ? (
              <Button asChild variant="outline">
                <Link to={`/refill/${requestId}/edit`}>Edit</Link>
              </Button>
            ) : null}
            {submittable ? (
              <Button
                type="button"
                onClick={() => submit.mutate()}
                disabled={submit.isPending}
              >
                {request?.status === "held" ? "Resubmit" : "Submit to Admin"}
              </Button>
            ) : null}
            {decidable ? (
              <>
                <Button type="button" onClick={() => setDecisionOpen("approve")}>
                  Approve
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  onClick={() => setDecisionOpen("hold")}
                >
                  Hold
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  onClick={() => setDecisionOpen("reject")}
                >
                  Reject
                </Button>
              </>
            ) : null}
          </div>
        }
      />
      {detail.isLoading ? <LoadingBlock label="Loading request" /> : null}
      {detail.error ? (
        <p role="alert" className="text-sm text-destructive">
          {detail.error.message}
        </p>
      ) : null}
      {mutationError ? (
        <p role="alert" className="mb-4 text-sm text-destructive">
          {mutationError}
        </p>
      ) : null}
      {request ? (
        <div className="grid gap-6">
          <aside
            role="status"
            className="rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-950 ring-1 ring-amber-200"
          >
            Admin approval is not a stock receipt. Accepted inventory is posted only
            after Branch 03 receiving verification.
          </aside>
          <dl className="grid gap-3 rounded-2xl bg-card p-4 text-sm ring-1 ring-border sm:grid-cols-2 lg:grid-cols-3">
            <div>
              <dt className="text-muted-foreground">Status</dt>
              <dd>
                <StatusBadge tone={refillStatusTone[request.status]}>
                  {formatRefillStatus(request.status)}
                </StatusBadge>
              </dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Supplier</dt>
              <dd>{request.supplier_name}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Destination godown</dt>
              <dd>
                {request.godown_code} · {request.godown_name}
                {request.godown_active ? "" : " (inactive)"}
              </dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Requested</dt>
              <dd>{formatCases(request.total_requested_cases)}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Created by</dt>
              <dd>{request.creator_name ?? "—"}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Submitted</dt>
              <dd>{formatTimestamp(request.submitted_at)}</dd>
            </div>
            {request.hold_reason ? (
              <div className="sm:col-span-2">
                <dt className="text-muted-foreground">Hold reason</dt>
                <dd>{request.hold_reason}</dd>
              </div>
            ) : null}
            {request.decision_reason ? (
              <div className="sm:col-span-2">
                <dt className="text-muted-foreground">Decision reason</dt>
                <dd>{request.decision_reason}</dd>
              </div>
            ) : null}
            {request.notes ? (
              <div className="sm:col-span-2">
                <dt className="text-muted-foreground">Notes</dt>
                <dd>{request.notes}</dd>
              </div>
            ) : null}
          </dl>
          <div className="overflow-x-auto rounded-2xl bg-card ring-1 ring-border">
            <table className="w-full min-w-[28rem] text-left text-sm">
              <thead>
                <tr className="border-b border-border text-muted-foreground">
                  <th className="px-4 py-3 font-medium">SKU</th>
                  <th className="px-4 py-3 font-medium">Product</th>
                  <th className="px-4 py-3 font-medium">Requested cases</th>
                </tr>
              </thead>
              <tbody>
                {request.lines.map((line) => (
                  <tr key={line.id} className="border-b border-border last:border-0">
                    <td className="px-4 py-3">{line.product_sku}</td>
                    <td className="px-4 py-3">{line.product_name}</td>
                    <td className="px-4 py-3">{formatCases(line.requested_cases)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <section>
            <h2 className="mb-3 text-base font-semibold">Audit history</h2>
            {request.events.length === 0 ? (
              <EmptyState title="No events" description="Lifecycle events will appear here." />
            ) : (
              <ol className="grid gap-2">
                {request.events.map((event) => (
                  <li
                    key={event.id}
                    className="rounded-xl bg-card px-4 py-3 text-sm ring-1 ring-border"
                  >
                    <p className="font-medium">{formatRefillEvent(event.action)}</p>
                    <p className="text-muted-foreground">
                      {event.actor_name ?? "—"} · {formatTimestamp(event.created_at)}
                    </p>
                    {event.reason ? <p className="mt-1">{event.reason}</p> : null}
                  </li>
                ))}
              </ol>
            )}
          </section>
        </div>
      ) : null}

      <AppModal
        open={decisionOpen !== null}
        onOpenChange={(open) => {
          if (!open) {
            setDecisionOpen(null)
            setReason("")
          }
        }}
        title={
          decisionOpen === "approve"
            ? "Approve refill request"
            : decisionOpen === "hold"
              ? "Hold refill request"
              : "Reject refill request"
        }
        description={
          decisionOpen === "approve"
            ? "This authorizes Accounts to send a supplier request later. It does not receive stock and does not post inventory."
            : decisionOpen === "hold"
              ? "Return this request to Accounts for correction. No supplier order is created."
              : "Reject this request. The decision is terminal and does not change stock."
        }
        footer={
          <>
            <Button
              type="button"
              variant="outline"
              disabled={decide.isPending}
              onClick={() => {
                setDecisionOpen(null)
                setReason("")
              }}
            >
              Cancel
            </Button>
            <Button
              type="button"
              disabled={decide.isPending || !reasonValid}
              onClick={() => decide.mutate()}
              aria-label={
                decisionOpen === "approve"
                  ? "Confirm refill approval"
                  : decisionOpen === "hold"
                    ? "Confirm refill hold"
                    : "Confirm refill rejection"
              }
            >
              {decide.isPending ? "Saving…" : "Confirm"}
            </Button>
          </>
        }
      >
        <label className="grid gap-2 text-sm font-medium">
          {reasonRequired ? "Reason" : "Optional note"}
          <textarea
            className="min-h-24 rounded-lg border border-input bg-transparent px-2.5 py-2 text-sm font-normal"
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            maxLength={500}
            aria-label={reasonRequired ? "Decision reason" : "Optional approval note"}
          />
        </label>
        {reasonRequired && !reasonValid ? (
          <p className="mt-2 text-sm text-destructive">
            Enter a reason between 1 and 500 characters.
          </p>
        ) : null}
      </AppModal>
    </section>
  )
}
