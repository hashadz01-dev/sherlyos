import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { ClipboardCheck } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge, type StatusTone } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { SearchField } from "@/features/masters/MasterControls"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { matchesSearch } from "@/lib/masters/filters"
import { listStockVerifications, type VerificationSummary } from "@/lib/verification/api"
import type { VerificationStatus } from "@/lib/verification/rules"

const statusTone: Record<VerificationStatus, StatusTone> = {
  draft: "neutral",
  counting: "info",
  submitted: "info",
  recount: "warning",
  review: "warning",
  closed: "success",
}

export function StockVerificationPage() {
  useDocumentTitle("Daily stock verification")
  const { can } = useAccess()
  const [search, setSearch] = useState("")
  const [status, setStatus] = useState("all")
  const [godownId, setGodownId] = useState("all")
  const [businessDate, setBusinessDate] = useState("")
  const verifications = useQuery({
    queryKey: ["stock-verifications"],
    queryFn: listStockVerifications,
  })
  const rows = verifications.data?.verifications ?? []
  const indicators = verifications.data?.indicators ?? []
  const godowns = [...new Map(rows.map((row) => [row.godown_id, row.godown_name])).entries()]
  const visible = rows.filter((row) => {
    if (status !== "all" && row.status !== status) return false
    if (godownId !== "all" && row.godown_id !== godownId) return false
    if (businessDate && row.business_date !== businessDate) return false
    return matchesSearch(search, [
      row.verification_number,
      row.godown_name,
      row.started_by_name,
      row.scope_codes,
      row.status,
    ])
  })

  return (
    <section className="min-w-0">
      <PageHeader
        title="Daily stock verification"
        description="Compare a frozen stock snapshot with a physical count. Closing a verification records the result and does not change inventory."
        action={
          can("stock.verify") ? (
            <Button asChild>
              <Link to="/stock-verification/new">Start verification</Link>
            </Button>
          ) : null
        }
      />
      {verifications.isLoading ? <LoadingBlock label="Loading verifications" /> : null}
      {verifications.error ? (
        <p role="alert" className="text-sm text-destructive">
          {verifications.error.message}
        </p>
      ) : null}
      {verifications.data ? (
        <>
          {indicators.some((item) => item.missing_today) ? (
            <div className="mb-4 rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-900 ring-1 ring-amber-200">
              {indicators
                .filter((item) => item.missing_today)
                .map((item) => (
                  <p key={item.godown_id}>
                    {item.godown_name} has no verification for today.
                    {item.last_verification_date
                      ? ` Last closed verification: ${item.last_verification_date}.`
                      : " No closed verification is on record."}
                    {" "}
                    Receiving and transfers remain available.
                  </p>
                ))}
            </div>
          ) : null}
          <div className="mb-4 grid gap-3 md:grid-cols-4">
            <SearchField label="Search verifications" value={search} onChange={setSearch} />
            <label className="grid gap-2 text-sm font-medium">
              Date
              <input
                type="date"
                aria-label="Business date"
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={businessDate}
                onChange={(event) => setBusinessDate(event.target.value)}
              />
            </label>
            <label className="grid gap-2 text-sm font-medium">
              Godown
              <select
                aria-label="Godown"
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={godownId}
                onChange={(event) => setGodownId(event.target.value)}
              >
                <option value="all">All godowns</option>
                {godowns.map(([id, name]) => (
                  <option key={id} value={id}>
                    {name}
                  </option>
                ))}
              </select>
            </label>
            <label className="grid gap-2 text-sm font-medium">
              Status
              <select
                aria-label="Status"
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={status}
                onChange={(event) => setStatus(event.target.value)}
              >
                <option value="all">All statuses</option>
                <option value="counting">Counting</option>
                <option value="submitted">Submitted</option>
                <option value="recount">Recount</option>
                <option value="review">Review</option>
                <option value="closed">Closed</option>
              </select>
            </label>
          </div>
          {visible.length === 0 ? (
            <EmptyState
              icon={ClipboardCheck}
              title="No verifications"
              description="Verifications you are allowed to see will appear here."
            />
          ) : (
            <>
            <div className="grid gap-3 md:hidden">
              {visible.map((row) => (
                <article key={row.id} className="grid gap-2 rounded-2xl bg-white p-4 text-sm ring-1 ring-slate-200">
                  <div className="flex items-start justify-between gap-3">
                    <Link className="font-medium underline-offset-4 hover:underline" to={`/stock-verification/${row.id}`}>
                      {row.verification_number}
                    </Link>
                    <StatusBadge tone={statusTone[row.status]}>{row.status}</StatusBadge>
                  </div>
                  <p>{row.business_date} · {row.godown_name}</p>
                  <p>{row.scope_codes || `${row.crate_count} crates`}</p>
                  <p>
                    {row.counted_count}/{row.line_count} counted · {row.discrepancy_count} discrepancies
                  </p>
                  <p>Started by {row.started_by_name ?? "Unknown"}</p>
                </article>
              ))}
            </div>
            <div className="hidden overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200 md:block">
              <table className="w-full min-w-[64rem] text-left text-sm">
                <thead className="text-xs tracking-wide text-muted-foreground uppercase">
                  <tr>
                    <th className="px-4 py-3 font-medium">Verification</th>
                    <th className="px-4 py-3 font-medium">Date</th>
                    <th className="px-4 py-3 font-medium">Godown</th>
                    <th className="px-4 py-3 font-medium">Status</th>
                    <th className="px-4 py-3 font-medium">Scope</th>
                    <th className="px-4 py-3 font-medium">Started by</th>
                    <th className="px-4 py-3 font-medium">Progress</th>
                    <th className="px-4 py-3 font-medium">Discrepancies</th>
                  </tr>
                </thead>
                <tbody>
                  {visible.map((row) => (
                    <VerificationRow key={row.id} row={row} />
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

function VerificationRow({ row }: { row: VerificationSummary }) {
  return (
    <tr className="border-t border-slate-100">
      <td className="px-4 py-3 font-medium">
        <Link className="underline-offset-4 hover:underline" to={`/stock-verification/${row.id}`}>
          {row.verification_number}
        </Link>
      </td>
      <td className="px-4 py-3">{row.business_date}</td>
      <td className="px-4 py-3">{row.godown_name}</td>
      <td className="px-4 py-3">
        <StatusBadge tone={statusTone[row.status]}>{row.status}</StatusBadge>
      </td>
      <td className="px-4 py-3">{row.scope_codes || `${row.crate_count} crates`}</td>
      <td className="px-4 py-3">{row.started_by_name ?? "Unknown"}</td>
      <td className="px-4 py-3">
        {row.counted_count}/{row.line_count} counted
      </td>
      <td className="px-4 py-3">{row.discrepancy_count}</td>
    </tr>
  )
}
