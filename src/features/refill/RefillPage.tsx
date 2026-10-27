import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { RefillQueueFilters } from "@/features/refill/components/RefillQueueFilters"
import {
  emptyRefillQueueFilters,
  type RefillQueueFilterState,
} from "@/features/refill/utils/queue-filters"
import {
  formatCases,
  formatDateOnly,
  formatRefillAcknowledgement,
  formatRefillCommunication,
  formatRefillDispatch,
  formatRefillReceivingLabel,
  formatRefillStatus,
  formatTimestamp,
  refillAcknowledgementTone,
  refillCommunicationTone,
  refillDispatchTone,
  refillStatusTone,
} from "@/features/refill/utils/labels"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import {
  listStockRefillOptions,
  listStockRefillRequests,
} from "@/lib/refill/api"
import { utcDayEndExclusive, utcDayStart } from "@/lib/reports/format"

export function RefillPage() {
  useDocumentTitle("Stock Refill")
  const { can } = useAccess()
  const [filters, setFilters] = useState<RefillQueueFilterState>(emptyRefillQueueFilters)
  const [page, setPage] = useState(1)
  const options = useQuery({
    queryKey: ["refill-options"],
    queryFn: listStockRefillOptions,
  })
  const list = useQuery({
    queryKey: ["refill-requests", page, filters],
    queryFn: () =>
      listStockRefillRequests({
        page,
        status: filters.status,
        godownId: filters.godownId,
        supplierId: filters.supplierId,
        search: filters.search,
        communication: filters.communication,
        acknowledgement: filters.acknowledgement,
        dispatch: filters.dispatch,
        receiving: filters.receiving,
        createdFrom: utcDayStart(filters.createdFrom),
        createdTo: utcDayEndExclusive(filters.createdTo),
      }),
  })
  const items = list.data?.items ?? []
  const total = list.data?.total ?? 0
  const pageSize = list.data?.page_size ?? 25
  const pageCount = Math.max(1, Math.ceil(total / pageSize))

  return (
    <section className="min-w-0">
      <PageHeader
        title="Stock Refill"
        description="Accounts prepares supplier replenishment requests. Admin approval is not a stock receipt."
        action={
          <div className="flex flex-wrap gap-2">
            {can("refill.request") || can("refill.approve") ? (
              <Button asChild variant="outline">
                <Link to="/reports/refill">Refill report</Link>
              </Button>
            ) : null}
            {can("refill.request") ? (
              <Button asChild>
                <Link to="/refill/new">New request</Link>
              </Button>
            ) : null}
          </div>
        }
      />
      {list.isLoading ? <LoadingBlock label="Loading refill requests" /> : null}
      {list.error ? (
        <p role="alert" className="text-sm text-destructive">
          {list.error.message}
        </p>
      ) : null}
      {list.data ? (
        <>
          <RefillQueueFilters
            value={filters}
            options={options.data}
            onChange={(next) => {
              setFilters(next)
              setPage(1)
            }}
          />
          {items.length === 0 ? (
            <EmptyState
              title="No refill requests"
              description="Authorized Accounts requests for your godowns will appear here."
            />
          ) : (
            <div className="overflow-x-auto rounded-2xl bg-card ring-1 ring-border">
              <table className="w-full min-w-[80rem] text-left text-sm">
                <thead>
                  <tr className="border-b border-border text-muted-foreground">
                    <th className="px-4 py-3 font-medium">Request</th>
                    <th className="px-4 py-3 font-medium">Supplier</th>
                    <th className="px-4 py-3 font-medium">Godown</th>
                    <th className="px-4 py-3 font-medium">Approval</th>
                    <th className="px-4 py-3 font-medium">Communication</th>
                    <th className="px-4 py-3 font-medium">Acknowledgement</th>
                    <th className="px-4 py-3 font-medium">Dispatch</th>
                    <th className="px-4 py-3 font-medium">Receiving</th>
                    <th className="px-4 py-3 font-medium">Requested</th>
                    <th className="px-4 py-3 font-medium">Reserved</th>
                    <th className="px-4 py-3 font-medium">Verified</th>
                    <th className="px-4 py-3 font-medium">Outstanding</th>
                    <th className="px-4 py-3 font-medium">Expected arrival</th>
                    <th className="px-4 py-3 font-medium">Created</th>
                  </tr>
                </thead>
                <tbody>
                  {items.map((row) => (
                    <tr key={row.id} className="border-b border-border last:border-0">
                      <td className="px-4 py-3">
                        <Link className="font-medium underline-offset-2 hover:underline" to={`/refill/${row.id}`}>
                          {row.request_number}
                        </Link>
                      </td>
                      <td className="px-4 py-3">{row.supplier_name}</td>
                      <td className="px-4 py-3">
                        {row.godown_name}
                        {row.godown_active ? "" : " (inactive)"}
                      </td>
                      <td className="px-4 py-3">
                        <StatusBadge tone={refillStatusTone[row.status]}>
                          {formatRefillStatus(row.status)}
                        </StatusBadge>
                      </td>
                      <td className="px-4 py-3">
                        <StatusBadge
                          tone={refillCommunicationTone[row.communication_status ?? "not_sent"]}
                        >
                          {formatRefillCommunication(row.communication_status ?? "not_sent")}
                        </StatusBadge>
                      </td>
                      <td className="px-4 py-3">
                        <StatusBadge
                          tone={
                            refillAcknowledgementTone[row.acknowledgement_status ?? "none"]
                          }
                        >
                          {formatRefillAcknowledgement(
                            row.acknowledgement_status ?? "none",
                          )}
                        </StatusBadge>
                      </td>
                      <td className="px-4 py-3">
                        <StatusBadge
                          tone={refillDispatchTone[row.dispatch_status ?? "not_recorded"]}
                        >
                          {formatRefillDispatch(row.dispatch_status ?? "not_recorded")}
                        </StatusBadge>
                      </td>
                      <td className="px-4 py-3">
                        {formatRefillReceivingLabel(row.completion_label ?? "not_started")}
                      </td>
                      <td className="px-4 py-3">{formatCases(row.total_requested_cases)}</td>
                      <td className="px-4 py-3">{formatCases(row.reserved_cases ?? 0)}</td>
                      <td className="px-4 py-3">{formatCases(row.accepted_cases ?? 0)}</td>
                      <td className="px-4 py-3">{formatCases(row.outstanding_cases ?? 0)}</td>
                      <td className="px-4 py-3">
                        {formatDateOnly(row.expected_arrival_on)}
                      </td>
                      <td className="px-4 py-3">{formatTimestamp(row.created_at)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <div className="mt-4 flex flex-wrap items-center gap-3">
            <Button
              type="button"
              variant="outline"
              disabled={page <= 1}
              onClick={() => setPage((current) => Math.max(1, current - 1))}
            >
              Previous
            </Button>
            <p className="text-sm text-muted-foreground">
              Page {page} of {pageCount} · {total} requests
            </p>
            <Button
              type="button"
              variant="outline"
              disabled={page >= pageCount}
              onClick={() => setPage((current) => Math.min(pageCount, current + 1))}
            >
              Next
            </Button>
          </div>
        </>
      ) : null}
    </section>
  )
}
