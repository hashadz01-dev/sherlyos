import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { PackageOpen } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge, type StatusTone } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { SearchField } from "@/features/masters/MasterControls"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { matchesSearch } from "@/lib/masters/filters"
import { listStockReceipts, type ReceiptSummary } from "@/lib/receiving/api"
import type { ReceiptStatus } from "@/lib/receiving/rules"

const statusTone: Record<ReceiptStatus, StatusTone> = {
  draft: "neutral",
  submitted: "info",
  held: "warning",
  posted: "success",
  cancelled: "danger",
}

export function ReceivingPage() {
  useDocumentTitle("Stock receiving")
  const { can } = useAccess()
  const [search, setSearch] = useState("")
  const [status, setStatus] = useState("all")
  const [godownId, setGodownId] = useState("all")
  const receipts = useQuery({
    queryKey: ["stock-receipts"],
    queryFn: listStockReceipts,
  })
  const rows = receipts.data ?? []
  const godowns = [...new Map(rows.map((row) => [row.godown_id, row.godown_name])).entries()]
  const visible = rows.filter((row) => {
    if (status !== "all" && row.status !== status) return false
    if (godownId !== "all" && row.godown_id !== godownId) return false
    return matchesSearch(search, [
      row.receipt_number,
      row.supplier_name,
      row.godown_name,
      row.document_reference,
      row.creator_name,
      row.status,
    ])
  })

  return (
    <section>
      <PageHeader
        title="Stock receiving"
        description="Record supplier deliveries, separate damaged cases, and verify accepted cartons before they enter inventory."
        action={
          can("receiving.execute") ? (
            <Button asChild>
              <Link to="/receiving/new">New receipt</Link>
            </Button>
          ) : null
        }
      />
      {receipts.isLoading ? <LoadingBlock label="Loading receipts" /> : null}
      {receipts.error ? (
        <p role="alert" className="text-sm text-destructive">
          {receipts.error.message}
        </p>
      ) : null}
      {receipts.data ? (
        <>
          <div className="mb-4 grid gap-3 md:grid-cols-3">
            <SearchField label="Search receipts" value={search} onChange={setSearch} />
            <label className="grid gap-2 text-sm font-medium">
              Status
              <select
                className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm font-normal"
                value={status}
                onChange={(event) => setStatus(event.target.value)}
              >
                <option value="all">All statuses</option>
                <option value="draft">Draft</option>
                <option value="submitted">Submitted</option>
                <option value="held">Held</option>
                <option value="posted">Posted</option>
                <option value="cancelled">Cancelled</option>
              </select>
            </label>
            <label className="grid gap-2 text-sm font-medium">
              Godown
              <select
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
          </div>
          {visible.length === 0 ? (
            <EmptyState
              icon={PackageOpen}
              title="No receipts"
              description="Receipts you are allowed to see will appear here."
            />
          ) : (
            <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200">
              <table className="w-full min-w-[60rem] text-left text-sm">
                <thead className="text-xs tracking-wide text-muted-foreground uppercase">
                  <tr>
                    <th className="px-4 py-3 font-medium">Receipt</th>
                    <th className="px-4 py-3 font-medium">Supplier</th>
                    <th className="px-4 py-3 font-medium">Godown</th>
                    <th className="px-4 py-3 font-medium">Document</th>
                    <th className="px-4 py-3 font-medium">Date</th>
                    <th className="px-4 py-3 font-medium">Status</th>
                    <th className="px-4 py-3 font-medium">Creator</th>
                    <th className="px-4 py-3 font-medium">Verification</th>
                  </tr>
                </thead>
                <tbody>
                  {visible.map((row) => (
                    <ReceiptRow key={row.id} row={row} />
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

function ReceiptRow({ row }: { row: ReceiptSummary }) {
  return (
    <tr className="border-t border-slate-100">
      <td className="px-4 py-3 font-medium">
        <Link className="underline-offset-4 hover:underline" to={`/receiving/${row.id}`}>
          {row.receipt_number}
        </Link>
      </td>
      <td className="px-4 py-3">{row.supplier_name}</td>
      <td className="px-4 py-3">{row.godown_name}</td>
      <td className="px-4 py-3">{row.document_reference}</td>
      <td className="px-4 py-3">{row.received_date}</td>
      <td className="px-4 py-3">
        <StatusBadge tone={statusTone[row.status]}>{row.status}</StatusBadge>
      </td>
      <td className="px-4 py-3">{row.creator_name ?? "Unknown"}</td>
      <td className="px-4 py-3">{row.verified_at ? "Verified" : "Not verified"}</td>
    </tr>
  )
}
