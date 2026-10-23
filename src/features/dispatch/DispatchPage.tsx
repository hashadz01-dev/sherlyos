import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { Truck } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { SearchField } from "@/features/masters/MasterControls"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { dispatchKeys, listDispatchQueue, type DispatchQueueRow } from "@/lib/dispatch/api"
import {
  dispatchRequestStatuses,
  dispatchStatusLabel,
  dispatchStatusTone,
} from "@/lib/dispatch/rules"
import { matchesSearch } from "@/lib/masters/filters"

const queueStatuses = dispatchRequestStatuses

export function DispatchPage() {
  useDocumentTitle("Dispatch")
  const { can } = useAccess()
  const [search, setSearch] = useState("")
  const [status, setStatus] = useState("ready_for_dispatch")
  const canConfirm = can("dispatch.confirm")
  const queue = useQuery({
    queryKey: dispatchKeys.queue(status),
    queryFn: () => listDispatchQueue(status),
  })
  const rows = (queue.data ?? []).filter((row) =>
    matchesSearch(search, [row.order_number, row.request_number, row.status]),
  )

  return (
    <section className="min-w-0">
      <PageHeader
        title="Dispatch"
        description="Confirm ready-for-dispatch picks, consume reserved carton cases once, then assign delivery."
      />
      {queue.isLoading ? <LoadingBlock label="Loading dispatch queue" /> : null}
      {queue.error ? (
        <p role="alert" className="text-sm text-destructive">
          {queue.error.message}
        </p>
      ) : null}
      {queue.data ? (
        <>
          <div className="mb-4 grid gap-3 md:grid-cols-2">
            <SearchField label="Search dispatch" value={search} onChange={setSearch} />
            <label className="grid gap-2 text-sm font-medium">
              Status
              <select
                aria-label="Dispatch status"
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={status}
                onChange={(event) => setStatus(event.target.value)}
              >
                {queueStatuses.map((value) => (
                  <option key={value} value={value}>
                    {dispatchStatusLabel[value]}
                  </option>
                ))}
              </select>
            </label>
          </div>
          {can("deliveries.execute") || can("deliveries.assign") ? (
            <p className="mb-4 text-sm">
              <Link className="underline" to="/delivery-runs">
                Open delivery runs
              </Link>
            </p>
          ) : null}
          {rows.length === 0 ? (
            <EmptyState
              icon={Truck}
              title="No dispatch work in this status"
              description="Picked orders appear here after warehouse handoff. Stock is deducted only when dispatch is confirmed."
            />
          ) : (
            <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200/80">
              <table className="w-min min-w-full text-left text-sm">
                <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-3 font-medium">Reference</th>
                    <th className="px-4 py-3 font-medium">Order</th>
                    <th className="px-4 py-3 font-medium">Status</th>
                    <th className="px-4 py-3 font-medium">Assignee</th>
                    <th className="px-4 py-3 font-medium">Action</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row) => (
                    <QueueRow key={`${row.kind}-${row.id}`} row={row} canConfirm={canConfirm} />
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      ) : null}
    </section>
  )
}

function QueueRow({
  row,
  canConfirm,
}: {
  row: DispatchQueueRow
  canConfirm: boolean
}) {
  const href =
    row.kind === "handoff" ? `/dispatch/prepare/${row.order_id}` : `/dispatch/${row.id}`
  const label = row.kind === "handoff" ? (canConfirm ? "Dispatch" : "View") : "Open"

  return (
    <tr className="border-b border-slate-100 last:border-0">
      <td className="px-4 py-3 font-medium">{row.request_number}</td>
      <td className="px-4 py-3">{row.order_number}</td>
      <td className="px-4 py-3">
        <StatusBadge tone={dispatchStatusTone[row.status]}>{dispatchStatusLabel[row.status]}</StatusBadge>
      </td>
      <td className="px-4 py-3">{row.assigned_to_name ?? "—"}</td>
      <td className="px-4 py-3">
        <Button asChild size="sm" variant={row.kind === "handoff" ? "default" : "outline"}>
          <Link to={href}>{label}</Link>
        </Button>
      </td>
    </tr>
  )
}
