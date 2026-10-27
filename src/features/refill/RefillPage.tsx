import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { SearchField } from "@/features/masters/MasterControls"
import {
  formatCases,
  formatDateOnly,
  formatRefillAcknowledgement,
  formatRefillCommunication,
  formatRefillDispatch,
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
import { refillStatuses } from "@/lib/refill/rules"

export function RefillPage() {
  useDocumentTitle("Stock Refill")
  const { can } = useAccess()
  const [search, setSearch] = useState("")
  const [status, setStatus] = useState("all")
  const [godownId, setGodownId] = useState("all")
  const [page, setPage] = useState(1)
  const options = useQuery({
    queryKey: ["refill-options"],
    queryFn: listStockRefillOptions,
  })
  const list = useQuery({
    queryKey: ["refill-requests", page, status, godownId, search],
    queryFn: () =>
      listStockRefillRequests({
        page,
        status: status === "all" ? null : status,
        godownId: godownId === "all" ? null : godownId,
        search,
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
          can("refill.request") ? (
            <Button asChild>
              <Link to="/refill/new">New request</Link>
            </Button>
          ) : null
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
          <div className="mb-4 grid gap-3 md:grid-cols-3">
            <SearchField
              label="Search requests"
              value={search}
              onChange={(value) => {
                setSearch(value)
                setPage(1)
              }}
            />
            <label className="grid gap-2 text-sm font-medium">
              Status
              <select
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={status}
                onChange={(event) => {
                  setStatus(event.target.value)
                  setPage(1)
                }}
                aria-label="Status"
              >
                <option value="all">All statuses</option>
                {refillStatuses.map((value) => (
                  <option key={value} value={value}>
                    {formatRefillStatus(value)}
                  </option>
                ))}
              </select>
            </label>
            <label className="grid gap-2 text-sm font-medium">
              Godown
              <select
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={godownId}
                onChange={(event) => {
                  setGodownId(event.target.value)
                  setPage(1)
                }}
                aria-label="Godown"
              >
                <option value="all">All authorized godowns</option>
                {(options.data?.godowns ?? []).map((godown) => (
                  <option key={godown.id} value={godown.id}>
                    {godown.code} · {godown.name}
                    {godown.is_active ? "" : " (inactive)"}
                  </option>
                ))}
              </select>
            </label>
          </div>
          {items.length === 0 ? (
            <EmptyState
              title="No refill requests"
              description="Authorized Accounts requests for your godowns will appear here."
            />
          ) : (
            <div className="overflow-x-auto rounded-2xl bg-card ring-1 ring-border">
              <table className="w-full min-w-[64rem] text-left text-sm">
                <thead>
                  <tr className="border-b border-border text-muted-foreground">
                    <th className="px-4 py-3 font-medium">Request</th>
                    <th className="px-4 py-3 font-medium">Supplier</th>
                    <th className="px-4 py-3 font-medium">Godown</th>
                    <th className="px-4 py-3 font-medium">Approval</th>
                    <th className="px-4 py-3 font-medium">Communication</th>
                    <th className="px-4 py-3 font-medium">Acknowledgement</th>
                    <th className="px-4 py-3 font-medium">Dispatch</th>
                    <th className="px-4 py-3 font-medium">Expected arrival</th>
                    <th className="px-4 py-3 font-medium">Cases</th>
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
                        {formatDateOnly(row.expected_arrival_on)}
                      </td>
                      <td className="px-4 py-3">{formatCases(row.total_requested_cases)}</td>
                      <td className="px-4 py-3">{formatTimestamp(row.created_at)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          {pageCount > 1 ? (
            <div className="mt-4 flex items-center gap-3">
              <Button
                type="button"
                variant="outline"
                disabled={page <= 1}
                onClick={() => setPage((current) => Math.max(1, current - 1))}
              >
                Previous
              </Button>
              <p className="text-sm text-muted-foreground">
                Page {page} of {pageCount}
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
          ) : null}
        </>
      ) : null}
    </section>
  )
}
