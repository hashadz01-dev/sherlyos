import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { ScrollText } from "lucide-react"
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
        description="Posted opening stock, same-godown transfers, verified receipts, adjustments, and dispatch consumption. This list is read only. Dispatch is the stock-consuming boundary."
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
          <div className="mb-4 max-w-sm">
            <MetricCard
              label="Loaded rows"
              icon={ScrollText}
              hint="Posted transactions for your godowns"
              value={history.data.length}
            />
          </div>
          <FilterBar label="History filters">
            <SearchField label="Search history" value={search} onChange={setSearch} />
          </FilterBar>
          {visible.length === 0 ? (
            <EmptyState
              icon={ScrollText}
              title="No transactions"
              description="Posted stock transactions for your godowns will appear here."
            />
          ) : (
            <RecordTable className="min-w-[52rem]" caption="Stock history">
              <RecordHeader>
                <tr>
                  <RecordHeadCell>Reference</RecordHeadCell>
                  <RecordHeadCell>Type</RecordHeadCell>
                  <RecordHeadCell>Product</RecordHeadCell>
                  <RecordHeadCell>Movement</RecordHeadCell>
                  <RecordHeadCell className="text-right">Cases</RecordHeadCell>
                  <RecordHeadCell>Actor</RecordHeadCell>
                  <RecordHeadCell>Posted</RecordHeadCell>
                </tr>
              </RecordHeader>
              <tbody>
                {visible.map((row) => (
                  <HistoryRow key={row.transaction_id} row={row} />
                ))}
              </tbody>
            </RecordTable>
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
    <RecordRow>
      <RecordCell className="font-medium">{row.reference_number}</RecordCell>
      <RecordCell>
        <StatusBadge tone="neutral">{stockTransactionLabel(row.transaction_type)}</StatusBadge>
      </RecordCell>
      <RecordCell>
        {row.product_name}
        <span className="ml-2 text-muted-foreground">{row.product_sku}</span>
      </RecordCell>
      <RecordCell>{movement}</RecordCell>
      <RecordCell className="text-right tabular-nums">{row.quantity}</RecordCell>
      <RecordCell>{row.actor_name ?? "Unknown"}</RecordCell>
      <RecordCell>{posted}</RecordCell>
    </RecordRow>
  )
}
