import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge, type StatusTone } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { listStockAdjustments, type AdjustmentSummary } from "@/lib/adjustment/api"
import type { AdjustmentStatus } from "@/lib/adjustment/rules"

const tone: Record<AdjustmentStatus, StatusTone> = {
  draft: "neutral",
  submitted: "info",
  returned: "warning",
  approved: "success",
  rejected: "danger",
  posted: "success",
}

function AdjustmentCard({ row }: { row: AdjustmentSummary }) {
  return (
    <Link
      to={`/stock-adjustments/${row.id}`}
      className="block rounded-2xl bg-card p-4 ring-1 ring-border"
    >
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-medium">{row.request_number}</p>
          <p className="text-sm text-muted-foreground">{row.godown_name}</p>
        </div>
        <StatusBadge tone={tone[row.status]}>{row.status}</StatusBadge>
      </div>
      <dl className="mt-3 grid grid-cols-2 gap-2 text-sm">
        <div>
          <dt className="text-muted-foreground">Verification</dt>
          <dd>{row.verification_number}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Class</dt>
          <dd>{row.exceptional ? "Exceptional" : "Ordinary"}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Requested by</dt>
          <dd>{row.requested_by_name}</dd>
        </div>
        <div>
          <dt className="text-muted-foreground">Date</dt>
          <dd>{row.created_at.slice(0, 10)}</dd>
        </div>
      </dl>
    </Link>
  )
}

export function AdjustmentsPage() {
  useDocumentTitle("Stock adjustments")
  const { can } = useAccess()
  const [status, setStatus] = useState("all")
  const [classification, setClassification] = useState("all")
  const adjustments = useQuery({
    queryKey: ["stock-adjustments"],
    queryFn: listStockAdjustments,
  })
  const rows = (adjustments.data ?? []).filter((row) => {
    if (status !== "all" && row.status !== status) return false
    if (classification === "exceptional" && !row.exceptional) return false
    if (classification === "ordinary" && row.exceptional !== false) return false
    return true
  })

  return (
    <section className="min-w-0">
      <PageHeader
        title="Stock adjustments"
        description="Approval records a decision. Inventory changes only when an assigned Godown Manager posts the request."
        action={
          can("stock.adjustment.request") ? (
            <Button asChild>
              <Link to="/stock-adjustments/new">New adjustment</Link>
            </Button>
          ) : null
        }
      />
      <div className="mb-4 flex flex-col gap-2 sm:flex-row">
        <select className="rounded-xl border bg-card px-3 py-2 text-sm" value={status} onChange={(event) => setStatus(event.target.value)} aria-label="Status">
          <option value="all">All statuses</option>
          <option value="submitted">Submitted</option>
          <option value="approved">Approved</option>
          <option value="posted">Posted</option>
          <option value="returned">Returned</option>
          <option value="rejected">Rejected</option>
        </select>
        <select className="rounded-xl border bg-card px-3 py-2 text-sm" value={classification} onChange={(event) => setClassification(event.target.value)} aria-label="Classification">
          <option value="all">Ordinary and exceptional</option>
          <option value="ordinary">Ordinary</option>
          <option value="exceptional">Exceptional</option>
        </select>
      </div>
      {adjustments.isLoading ? <LoadingBlock label="Loading adjustments" /> : null}
      {adjustments.error ? <p role="alert" className="text-sm text-destructive">{adjustments.error.message}</p> : null}
      {adjustments.data && rows.length === 0 ? (
        <EmptyState title="No adjustment requests" description="Closed verifications with a remaining discrepancy can be requested by the assigned Godown Manager." />
      ) : null}
      <div className="grid gap-3 md:hidden">
        {rows.map((row) => <AdjustmentCard key={row.id} row={row} />)}
      </div>
      <div className="hidden overflow-x-auto md:block">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b text-left text-muted-foreground">
              <th className="py-2 pr-3">Request</th>
              <th className="py-2 pr-3">Godown</th>
              <th className="py-2 pr-3">Verification</th>
              <th className="py-2 pr-3">Requested by</th>
              <th className="py-2 pr-3">Class</th>
              <th className="py-2 pr-3">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.id} className="border-b">
                <td className="py-3 pr-3"><Link className="font-medium underline-offset-4 hover:underline" to={`/stock-adjustments/${row.id}`}>{row.request_number}</Link></td>
                <td className="py-3 pr-3">{row.godown_name}</td>
                <td className="py-3 pr-3">{row.verification_number}</td>
                <td className="py-3 pr-3">{row.requested_by_name}</td>
                <td className="py-3 pr-3">{row.exceptional ? "Exceptional" : "Ordinary"}</td>
                <td className="py-3 pr-3"><StatusBadge tone={tone[row.status]}>{row.status}</StatusBadge></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
