import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { Truck } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { FilterBar } from "@/components/shared/FilterBar"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { MetricCard } from "@/components/shared/MetricCard"
import { PageHeader } from "@/components/shared/PageHeader"
import {
  RecordCell,
  RecordHeadCell,
  RecordHeader,
  RecordRow,
  RecordTable,
} from "@/components/shared/RecordTable"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { FilterSelect, SearchField } from "@/features/masters/MasterControls"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { dispatchKeys, listDispatchQueue, type DispatchQueueRow } from "@/lib/dispatch/api"
import {
  dispatchRequestStatuses,
  dispatchStatusLabel,
  dispatchStatusTone,
  type DispatchRequestStatus,
} from "@/lib/dispatch/rules"
import { matchesSearch } from "@/lib/masters/filters"

const queueStatuses = dispatchRequestStatuses

export function DispatchPage() {
  useDocumentTitle("Dispatch")
  const { can } = useAccess()
  const [search, setSearch] = useState("")
  const [status, setStatus] = useState<DispatchRequestStatus>("ready_for_dispatch")
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
          <div className="mb-4 max-w-sm">
            <MetricCard
              label="In this status"
              icon={Truck}
              hint={dispatchStatusLabel[status]}
              value={queue.data.length}
            />
          </div>
          <FilterBar label="Dispatch filters">
            <SearchField label="Search dispatch" value={search} onChange={setSearch} />
            <FilterSelect
              label="Status"
              value={status}
              onChange={(value) => setStatus(value as DispatchRequestStatus)}
            >
              {queueStatuses.map((value) => (
                <option key={value} value={value}>
                  {dispatchStatusLabel[value]}
                </option>
              ))}
            </FilterSelect>
          </FilterBar>
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
            <RecordTable className="w-min min-w-full" caption="Dispatch queue">
              <RecordHeader>
                <tr>
                  <RecordHeadCell>Reference</RecordHeadCell>
                  <RecordHeadCell>Order</RecordHeadCell>
                  <RecordHeadCell>Status</RecordHeadCell>
                  <RecordHeadCell>Assignee</RecordHeadCell>
                  <RecordHeadCell>Action</RecordHeadCell>
                </tr>
              </RecordHeader>
              <tbody>
                {rows.map((row) => (
                  <QueueRow key={`${row.kind}-${row.id}`} row={row} canConfirm={canConfirm} />
                ))}
              </tbody>
            </RecordTable>
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
    <RecordRow>
      <RecordCell className="font-medium">{row.request_number}</RecordCell>
      <RecordCell>{row.order_number}</RecordCell>
      <RecordCell>
        <StatusBadge tone={dispatchStatusTone[row.status]}>{dispatchStatusLabel[row.status]}</StatusBadge>
      </RecordCell>
      <RecordCell>{row.assigned_to_name ?? "—"}</RecordCell>
      <RecordCell>
        <Button asChild size="sm" variant={row.kind === "handoff" ? "default" : "outline"}>
          <Link to={href}>{label}</Link>
        </Button>
      </RecordCell>
    </RecordRow>
  )
}
