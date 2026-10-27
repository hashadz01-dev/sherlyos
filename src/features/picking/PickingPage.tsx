import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { PackageSearch } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { SearchField } from "@/features/masters/MasterControls"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { listPickingRequests, pickingKeys, type PickingQueueRow } from "@/lib/picking/api"
import {
  pickingRequestStatuses,
  pickingStatusLabel,
  pickingStatusTone,
} from "@/lib/picking/rules"
import { matchesSearch } from "@/lib/masters/filters"

const dashboardStatuses = pickingRequestStatuses

export function PickingPage() {
  useDocumentTitle("Picking")
  const { can } = useAccess()
  const [search, setSearch] = useState("")
  const [status, setStatus] = useState("pending_allocation")
  const canAllocate = can("picking.allocate")
  const queue = useQuery({
    queryKey: pickingKeys.queue(status),
    queryFn: () => listPickingRequests(status),
  })
  const rows = (queue.data ?? []).filter((row) =>
    matchesSearch(search, [row.order_number, row.request_number ?? "", row.status]),
  )

  return (
    <section className="min-w-0">
      <PageHeader
        title="Picking"
        description="Allocate verified orders with FEFO or FIFO, then pick reserved carton cases. Stock is not deducted until dispatch."
      />
      {queue.isLoading ? <LoadingBlock label="Loading picking queue" /> : null}
      {queue.error ? (
        <p role="alert" className="text-sm text-destructive">
          {queue.error.message}
        </p>
      ) : null}
      {queue.data ? (
        <>
          <div className="mb-4 grid gap-3 md:grid-cols-2">
            <SearchField label="Search picking" value={search} onChange={setSearch} />
            <label className="grid gap-2 text-sm font-medium">
              Status
              <select
                aria-label="Picking status"
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={status}
                onChange={(event) => setStatus(event.target.value)}
              >
                {dashboardStatuses.map((value) => (
                  <option key={value} value={value}>
                    {pickingStatusLabel[value]}
                  </option>
                ))}
              </select>
            </label>
          </div>
          {can("picking.manage") ? (
            <p className="mb-4 text-sm">
              <Link className="underline" to="/picking/exceptions">
                Review picking exceptions
              </Link>
            </p>
          ) : null}
          {rows.length === 0 ? (
            <EmptyState
              icon={PackageSearch}
              title="No picking work in this status"
              description="Verified orders appear here after the Godown Manager acknowledges the delivery note. Allocation stays disabled until lot-aware dual-write is on."
            />
          ) : (
            <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200/80">
              <table className="w-min min-w-full text-left text-sm">
                <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-3 font-medium">Reference</th>
                    <th className="px-4 py-3 font-medium">Order</th>
                    <th className="px-4 py-3 font-medium">Delivery note</th>
                    <th className="px-4 py-3 font-medium">Ordered</th>
                    <th className="px-4 py-3 font-medium">Allocated</th>
                    <th className="px-4 py-3 font-medium">Picked</th>
                    <th className="px-4 py-3 font-medium">Status</th>
                    <th className="px-4 py-3 font-medium">Action</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row) => (
                    <QueueRow key={row.id ?? row.order_id} row={row} canAllocate={canAllocate} />
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

function QueueRow({ row, canAllocate }: { row: PickingQueueRow; canAllocate: boolean }) {
  const href =
    row.kind === "pending_order"
      ? `/picking/allocate/${row.order_id}`
      : `/picking/${row.id}`
  const label =
    row.kind === "pending_order"
      ? canAllocate
        ? "Allocate"
        : "View"
      : "Open"

  return (
    <tr className="border-b border-slate-100 last:border-0">
      <td className="px-4 py-3 font-medium">{row.request_number ?? "—"}</td>
      <td className="px-4 py-3">{row.order_number}</td>
      <td className="px-4 py-3">{row.delivery_note_status ?? "—"}</td>
      <td className="px-4 py-3">{row.ordered_cases ?? "—"}</td>
      <td className="px-4 py-3">{row.allocated_cases ?? "—"}</td>
      <td className="px-4 py-3">{row.picked_cases ?? "—"}</td>
      <td className="px-4 py-3">
        <StatusBadge tone={pickingStatusTone[row.status]}>{pickingStatusLabel[row.status]}</StatusBadge>
      </td>
      <td className="px-4 py-3">
        <Button asChild size="sm" variant={row.kind === "pending_order" ? "default" : "outline"}>
          <Link to={href}>{label}</Link>
        </Button>
      </td>
    </tr>
  )
}
