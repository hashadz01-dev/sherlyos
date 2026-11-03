/**
 * Capture list and Godown Manager verification inbox share list_stock_receipts.
 * Submitted receipts never belonged on daily crate counts.
 */
import { useState } from "react"
import { Link } from "react-router"
import { useQuery } from "@tanstack/react-query"
import { PackageOpen } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { StatusBadge, type StatusTone } from "@/components/shared/StatusBadge"
import { Button } from "@/components/ui/button"
import { FilterSelect, FilterToolbar, SearchField } from "@/features/masters/MasterControls"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { useAccess } from "@/lib/access/use-access"
import { matchesSearch } from "@/lib/masters/filters"
import { listStockReceipts, type ReceiptSummary } from "@/lib/receiving/api"
import type { ReceiptStatus } from "@/lib/receiving/rules"
import {
  awaitingReceiptVerification,
  RECEIPT_VERIFICATION_DEFAULT_STATUS,
  receiptRecordPath,
  receiptVerificationEmptyCopy,
  receiptVerificationRows,
  type ReceiptWorkflowMode,
} from "@/lib/receiving/verification"

const statusTone: Record<ReceiptStatus, StatusTone> = {
  draft: "neutral",
  submitted: "info",
  held: "warning",
  posted: "success",
  cancelled: "danger",
}

function ReceiptsQueue({ mode }: { mode: ReceiptWorkflowMode }) {
  const isVerification = mode === "verification"
  useDocumentTitle(isVerification ? "Receipt verification" : "Stock receiving")
  const { can } = useAccess()
  const [search, setSearch] = useState("")
  // Explicit union: FilterSelect emits string; ReceiptStatus|"all" is the filter domain.
  const [status, setStatus] = useState<ReceiptStatus | "all">(
    isVerification ? RECEIPT_VERIFICATION_DEFAULT_STATUS : "all",
  )
  const [godownId, setGodownId] = useState("all")
  const receipts = useQuery({
    queryKey: ["stock-receipts"],
    queryFn: listStockReceipts,
  })
  const rows = receipts.data ?? []
  const awaiting = awaitingReceiptVerification(rows)
  // Verification never lists Store Keeper drafts, even when Status is All.
  const scoped = isVerification ? receiptVerificationRows(rows, status) : rows
  const godowns = [...new Map(scoped.map((row) => [row.godown_id, row.godown_name])).entries()]
  const visible = scoped.filter((row) => {
    if (!isVerification && status !== "all" && row.status !== status) return false
    if (godownId !== "all" && row.godown_id !== godownId) return false
    return matchesSearch(search, [
      row.receipt_number,
      row.supplier_name,
      row.godown_name,
      row.document_reference,
      row.creator_name,
      row.status,
      row.refill_request_number,
    ])
  })
  const empty = isVerification
    ? receiptVerificationEmptyCopy(status)
    : {
        title: "No receipts",
        description: "Receipts you are allowed to see will appear here.",
      }

  return (
    <section>
      <PageHeader
        title={isVerification ? "Receipt verification" : "Stock receiving"}
        description={
          isVerification
            ? "Review Store Keeper submissions, post accepted cartons, and reopen past verifications. This is not the daily crate count."
            : "Record supplier deliveries, separate damaged cases, and verify accepted cartons before they enter inventory."
        }
        action={
          <div className="flex flex-wrap gap-2">
            {isVerification ? (
              <Button asChild variant="outline">
                <Link to="/receiving">All receipts</Link>
              </Button>
            ) : can("receiving.verify") ? (
              <Button asChild variant="outline">
                <Link to="/receiving/verification">Receipt verification</Link>
              </Button>
            ) : null}
            {!isVerification && can("receiving.execute") ? (
              <Button asChild>
                <Link to="/receiving/new">New receipt</Link>
              </Button>
            ) : null}
          </div>
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
          {isVerification && awaiting.length > 0 ? (
            <p
              role="status"
              className="mb-4 max-w-3xl rounded-2xl bg-amber-50 px-4 py-3 text-sm leading-6 text-amber-900 ring-1 ring-amber-200"
            >
              {awaiting.length} receipt{awaiting.length === 1 ? "" : "s"} awaiting review.
              Posted receipts stay in this list after verification.
            </p>
          ) : null}
          {!isVerification && can("receiving.verify") && awaiting.length > 0 ? (
            <p
              role="status"
              className="mb-4 max-w-3xl rounded-2xl bg-amber-50 px-4 py-3 text-sm leading-6 text-amber-900 ring-1 ring-amber-200"
            >
              {awaiting.length} receipt{awaiting.length === 1 ? "" : "s"} awaiting
              Godown Manager verification.{" "}
              <Link className="font-medium underline-offset-2 hover:underline" to="/receiving/verification">
                Open the verification queue
              </Link>
            </p>
          ) : null}
          <FilterToolbar>
            <SearchField label="Search receipts" value={search} onChange={setSearch} />
            <FilterSelect
              label="Status"
              value={status}
              onChange={(value) => setStatus(value as ReceiptStatus | "all")}
            >
              <option value="all">All statuses</option>
              {!isVerification ? <option value="draft">Draft</option> : null}
              <option value="submitted">Submitted</option>
              <option value="held">Held</option>
              <option value="posted">Posted</option>
              <option value="cancelled">Cancelled</option>
            </FilterSelect>
            <FilterSelect label="Godown" value={godownId} onChange={setGodownId}>
              <option value="all">All godowns</option>
              {godowns.map(([id, name]) => (
                <option key={id} value={id}>
                  {name}
                </option>
              ))}
            </FilterSelect>
          </FilterToolbar>
          {visible.length === 0 ? (
            <EmptyState icon={PackageOpen} title={empty.title} description={empty.description} />
          ) : (
            <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200">
              <table className="w-full min-w-[60rem] text-left text-sm">
                <thead className="text-xs tracking-wide text-muted-foreground uppercase">
                  <tr>
                    <th className="px-4 py-3 font-medium">Receipt</th>
                    <th className="px-4 py-3 font-medium">Supplier</th>
                    <th className="px-4 py-3 font-medium">Godown</th>
                    <th className="px-4 py-3 font-medium">Document</th>
                    <th className="px-4 py-3 font-medium">Refill</th>
                    <th className="px-4 py-3 font-medium">Date</th>
                    <th className="px-4 py-3 font-medium">Status</th>
                    <th className="px-4 py-3 font-medium">Creator</th>
                    <th className="px-4 py-3 font-medium">Verification</th>
                  </tr>
                </thead>
                <tbody>
                  {visible.map((row) => (
                    <ReceiptRow key={row.id} row={row} mode={mode} />
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

function ReceiptRow({
  row,
  mode,
}: {
  row: ReceiptSummary
  mode: ReceiptWorkflowMode
}) {
  return (
    <tr className="border-t border-slate-100">
      <td className="px-4 py-3 font-medium">
        <Link
          className="underline-offset-4 hover:underline"
          to={receiptRecordPath(mode, row.id)}
        >
          {row.receipt_number}
        </Link>
      </td>
      <td className="px-4 py-3">{row.supplier_name}</td>
      <td className="px-4 py-3">{row.godown_name}</td>
      <td className="px-4 py-3">{row.document_reference}</td>
      <td className="px-4 py-3">{row.refill_request_number ?? "—"}</td>
      <td className="px-4 py-3">{row.received_date}</td>
      <td className="px-4 py-3">
        <StatusBadge tone={statusTone[row.status]}>{row.status}</StatusBadge>
      </td>
      <td className="px-4 py-3">{row.creator_name ?? "Unknown"}</td>
      <td className="px-4 py-3">{row.verified_at ? "Verified" : "Not verified"}</td>
    </tr>
  )
}

export function ReceivingPage() {
  return <ReceiptsQueue mode="capture" />
}

/** Godown Manager inbox for submitted work and posted verification history. */
export function ReceiptVerificationPage() {
  return <ReceiptsQueue mode="verification" />
}
