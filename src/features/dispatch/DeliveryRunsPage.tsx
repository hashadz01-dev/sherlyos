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
import { dispatchKeys, listAssignedDeliveries } from "@/lib/dispatch/api"
import { dispatchStatusLabel, dispatchStatusTone } from "@/lib/dispatch/rules"
import { matchesSearch } from "@/lib/masters/filters"

export function DeliveryRunsPage() {
  useDocumentTitle("Delivery runs")
  const [search, setSearch] = useState("")
  const queue = useQuery({
    queryKey: dispatchKeys.assigned,
    queryFn: listAssignedDeliveries,
  })
  const rows = (queue.data ?? []).filter((row) =>
    matchesSearch(search, [row.order_number, row.request_number, row.status, row.assigned_to_name ?? ""]),
  )

  return (
    <section className="min-w-0">
      <PageHeader
        title="Delivery runs"
        description="Assigned physical deliveries. Proof of delivery does not change inventory. Failed delivery does not restock the godown."
      />
      {queue.isLoading ? <LoadingBlock label="Loading delivery runs" /> : null}
      {queue.error ? (
        <p role="alert" className="text-sm text-destructive">
          {queue.error.message}
        </p>
      ) : null}
      {queue.data ? (
        <>
          <div className="mb-4">
            <SearchField label="Search deliveries" value={search} onChange={setSearch} />
          </div>
          {rows.length === 0 ? (
            <EmptyState
              icon={Truck}
              title="No assigned deliveries"
              description="Godown managers assign delivery personnel after dispatch confirmation."
            />
          ) : (
            <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200/80">
              <table className="w-min min-w-full text-left text-sm">
                <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-3 font-medium">Dispatch</th>
                    <th className="px-4 py-3 font-medium">Order</th>
                    <th className="px-4 py-3 font-medium">Status</th>
                    <th className="px-4 py-3 font-medium">Assignee</th>
                    <th className="px-4 py-3 font-medium">Action</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row) => (
                    <tr key={row.id} className="border-b border-slate-100 last:border-0">
                      <td className="px-4 py-3 font-medium">{row.request_number}</td>
                      <td className="px-4 py-3">{row.order_number}</td>
                      <td className="px-4 py-3">
                        <StatusBadge tone={dispatchStatusTone[row.status]}>
                          {dispatchStatusLabel[row.status]}
                        </StatusBadge>
                      </td>
                      <td className="px-4 py-3">{row.assigned_to_name ?? "—"}</td>
                      <td className="px-4 py-3">
                        <Button asChild size="sm" variant="outline">
                          <Link to={`/dispatch/${row.id}`}>Open</Link>
                        </Button>
                      </td>
                    </tr>
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
