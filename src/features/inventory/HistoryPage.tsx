import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { ScrollText } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
import { SearchField } from "@/features/masters/MasterControls"
import { InventoryLinks } from "@/features/inventory/InventoryLinks"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { listStockTransactions, type StockTransaction } from "@/lib/inventory/api"
import { stockMovementLabel, stockTransactionLabel } from "@/lib/inventory/labels"
import { matchesSearch } from "@/lib/masters/filters"

export function HistoryPage() {
  useDocumentTitle("Stock history")
  const [search, setSearch] = useState("")
  const history = useQuery({
    queryKey: ["stock-transactions"],
    queryFn: listStockTransactions,
  })
  const visible = (history.data ?? []).filter((row) =>
    matchesSearch(search, [
      row.reference_number,
      row.transaction_type,
      row.product_name,
      row.product_sku,
      row.source_crate_code,
      row.destination_crate_code,
      row.actor_name,
    ]),
  )

  return (
    <section>
      <PageHeader
        title="Stock history"
        description="Posted opening stock, same-godown transfers, and verified receipts. This list is read only."
      />
      <InventoryLinks />
      {history.isLoading ? <LoadingBlock label="Loading history" /> : null}
      {history.error ? (
        <p role="alert" className="text-sm text-destructive">
          {history.error.message}
        </p>
      ) : null}
      {history.data ? (
        <>
          <div className="mb-4">
            <SearchField label="Search history" value={search} onChange={setSearch} />
          </div>
          {visible.length === 0 ? (
            <EmptyState
              icon={ScrollText}
              title="No transactions"
              description="Posted stock transactions for your godowns will appear here."
            />
          ) : (
            <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200">
              <table className="w-full min-w-[52rem] text-left text-sm">
                <thead className="text-xs tracking-wide text-muted-foreground uppercase">
                  <tr>
                    <th className="px-4 py-3 font-medium">Reference</th>
                    <th className="px-4 py-3 font-medium">Type</th>
                    <th className="px-4 py-3 font-medium">Product</th>
                    <th className="px-4 py-3 font-medium">Movement</th>
                    <th className="px-4 py-3 text-right font-medium">Cases</th>
                    <th className="px-4 py-3 font-medium">Actor</th>
                    <th className="px-4 py-3 font-medium">Posted</th>
                  </tr>
                </thead>
                <tbody>
                  {visible.map((row) => (
                    <HistoryRow key={row.transaction_id} row={row} />
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

function HistoryRow({ row }: { row: StockTransaction }) {
  const movement = stockMovementLabel({
    transactionType: row.transaction_type,
    sourceCrateCode: row.source_crate_code,
    destinationCrateCode: row.destination_crate_code,
  })
  const posted = new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(row.posted_at))

  return (
    <tr className="border-t border-slate-100">
      <td className="px-4 py-3 font-medium">{row.reference_number}</td>
      <td className="px-4 py-3">
        {stockTransactionLabel(row.transaction_type)}
      </td>
      <td className="px-4 py-3">
        {row.product_name}
        <span className="ml-2 text-muted-foreground">{row.product_sku}</span>
      </td>
      <td className="px-4 py-3">{movement}</td>
      <td className="px-4 py-3 text-right">{row.quantity}</td>
      <td className="px-4 py-3">{row.actor_name ?? "Unknown"}</td>
      <td className="px-4 py-3">{posted}</td>
    </tr>
  )
}
