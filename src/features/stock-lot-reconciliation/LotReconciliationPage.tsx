import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { ClipboardCheck } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { FilterSelect, FilterToolbar, SearchField } from "@/features/masters/MasterControls"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAuth } from "@/hooks/use-auth"
import { useAccess } from "@/lib/access/use-access"
import { listLotReconciliations, lotReconciliationKeys, type LotReconciliationListRow } from "@/lib/lot-reconciliation/api"
import {
  actorLabel,
  formatTimestamp,
  lotReconciliationStatuses,
  sessionListAction,
  statusTone,
} from "@/lib/lot-reconciliation/rules"
import { matchesSearch } from "@/lib/masters/filters"

export function LotReconciliationPage() {
  useDocumentTitle("Lot reconciliation")
  const { can } = useAccess()
  const { session } = useAuth()
  const [search, setSearch] = useState("")
  const [status, setStatus] = useState("all")
  const [godownId, setGodownId] = useState("all")
  const canAdmin = can("stock.lots.legacy.reconcile")
  const canPhysical = can("stock.lots.physical_reconcile")
  const sessions = useQuery({
    queryKey: lotReconciliationKeys.list,
    queryFn: listLotReconciliations,
  })
  const rows = sessions.data ?? []
  const godowns = [...new Map(rows.map((row) => [row.godown_id, row.godown_name])).entries()]
  const visible = rows.filter((row) => {
    if (status !== "all" && row.status !== status) return false
    if (godownId !== "all" && row.godown_id !== godownId) return false
    return matchesSearch(search, [
      row.session_number,
      row.godown_name,
      row.status,
      row.created_by,
    ])
  })

  return (
    <section className="min-w-0">
      <PageHeader
        title="Lot reconciliation"
        description="Count selected crates and record physical lot evidence. Approval does not change inventory."
        action={
          canAdmin ? (
            <Button asChild>
              <Link to="/stock-lot-reconciliation/new">New session</Link>
            </Button>
          ) : null
        }
      />
      {sessions.isLoading ? <LoadingBlock label="Loading lot reconciliations" /> : null}
      {sessions.error ? (
        <p role="alert" className="text-sm text-destructive">
          {sessions.error.message}
        </p>
      ) : null}
      {sessions.data ? (
        <>
          <FilterToolbar>
            <SearchField label="Search sessions" value={search} onChange={setSearch} />
            <FilterSelect label="Godown" value={godownId} onChange={setGodownId}>
              <option value="all">All authorized godowns</option>
              {godowns.map(([id, name]) => (
                <option key={id} value={id}>
                  {name}
                </option>
              ))}
            </FilterSelect>
            <FilterSelect label="Status" value={status} onChange={setStatus}>
              <option value="all">All statuses</option>
              {lotReconciliationStatuses.map((value) => (
                <option key={value} value={value}>
                  {value}
                </option>
              ))}
            </FilterSelect>
          </FilterToolbar>
          {visible.length === 0 ? (
            <EmptyState
              icon={ClipboardCheck}
              title="No lot reconciliations"
              description="Sessions you are allowed to see will appear here."
            />
          ) : (
            <>
              <div className="grid gap-3 md:hidden">
                {visible.map((row) => (
                  <SessionCard
                    key={row.id}
                    row={row}
                    currentUserId={session?.user.id}
                    canAdmin={canAdmin}
                    canPhysical={canPhysical}
                  />
                ))}
              </div>
              <div className="hidden overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200 md:block">
                <table className="w-full min-w-[64rem] text-left text-sm">
                  <thead className="text-xs tracking-wide text-muted-foreground uppercase">
                    <tr>
                      <th className="px-4 py-3 font-medium">Session</th>
                      <th className="px-4 py-3 font-medium">Godown</th>
                      <th className="px-4 py-3 font-medium">Crates</th>
                      <th className="px-4 py-3 font-medium">Status</th>
                      <th className="px-4 py-3 font-medium">Created by</th>
                      <th className="px-4 py-3 font-medium">Created</th>
                      <th className="px-4 py-3 font-medium">Updated</th>
                      <th className="px-4 py-3 font-medium">Action</th>
                    </tr>
                  </thead>
                  <tbody>
                    {visible.map((row) => (
                      <SessionRow
                        key={row.id}
                        row={row}
                        currentUserId={session?.user.id}
                        canAdmin={canAdmin}
                        canPhysical={canPhysical}
                      />
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </>
      ) : null}
    </section>
  )
}

function SessionCard({
  row,
  currentUserId,
  canAdmin,
  canPhysical,
}: {
  row: LotReconciliationListRow
  currentUserId?: string
  canAdmin: boolean
  canPhysical: boolean
}) {
  const action = sessionListAction({ status: row.status, canAdmin, canPhysical })
  return (
    <article className="grid gap-2 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200">
      <div className="flex items-start justify-between gap-3">
        <Link className="font-medium underline-offset-4 hover:underline" to={`/stock-lot-reconciliation/${row.id}`}>
          {row.session_number}
        </Link>
        <StatusBadge tone={statusTone[row.status]}>{row.status}</StatusBadge>
      </div>
      <p>{row.godown_name}</p>
      <p>{row.crate_count} crates · {row.unmatched_lines} unmatched</p>
      <p>Created by {actorLabel(row.created_by, currentUserId)}</p>
      <p>Created {formatTimestamp(row.created_at)}</p>
      <p>Updated {formatTimestamp(row.updated_at ?? row.submitted_at ?? row.created_at)}</p>
      <Link className="font-medium underline-offset-4 hover:underline" to={`/stock-lot-reconciliation/${row.id}`}>
        {action}
      </Link>
    </article>
  )
}

function SessionRow({
  row,
  currentUserId,
  canAdmin,
  canPhysical,
}: {
  row: LotReconciliationListRow
  currentUserId?: string
  canAdmin: boolean
  canPhysical: boolean
}) {
  const action = sessionListAction({ status: row.status, canAdmin, canPhysical })
  return (
    <tr className="border-t border-slate-100">
      <td className="px-4 py-3 font-medium">
        <Link className="underline-offset-4 hover:underline" to={`/stock-lot-reconciliation/${row.id}`}>
          {row.session_number}
        </Link>
      </td>
      <td className="px-4 py-3">{row.godown_name}</td>
      <td className="px-4 py-3">{row.crate_count}</td>
      <td className="px-4 py-3">
        <StatusBadge tone={statusTone[row.status]}>{row.status}</StatusBadge>
      </td>
      <td className="px-4 py-3">{actorLabel(row.created_by, currentUserId)}</td>
      <td className="px-4 py-3">{formatTimestamp(row.created_at)}</td>
      <td className="px-4 py-3">{formatTimestamp(row.updated_at ?? row.submitted_at ?? row.created_at)}</td>
      <td className="px-4 py-3">
        <Link className="underline-offset-4 hover:underline" to={`/stock-lot-reconciliation/${row.id}`}>
          {action}
        </Link>
      </td>
    </tr>
  )
}
