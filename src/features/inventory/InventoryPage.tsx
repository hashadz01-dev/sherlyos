import { useMemo, useState } from "react"
import { Package } from "lucide-react"
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
import { SearchField } from "@/features/masters/MasterControls"
import { InventoryLinks } from "@/features/inventory/InventoryLinks"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { listStockBalances, type StockBalance } from "@/lib/inventory/api"
import { matchesSearch } from "@/lib/masters/filters"
import { useQuery } from "@tanstack/react-query"

export function InventoryPage() {
  useDocumentTitle("Inventory")
  const [search, setSearch] = useState("")
  const [godownId, setGodownId] = useState("all")
  const balances = useQuery({
    queryKey: ["stock-balances"],
    queryFn: listStockBalances,
  })

  const godowns = useMemo(() => {
    const rows = new Map<string, string>()
    for (const row of balances.data ?? []) {
      rows.set(row.godown_id, `${row.godown_name} (${row.godown_code})`)
    }
    return [...rows.entries()]
  }, [balances.data])

  const visible = (balances.data ?? []).filter((row) => {
    if (godownId !== "all" && row.godown_id !== godownId) return false
    return matchesSearch(search, [
      row.godown_name,
      row.zone_code,
      row.zone_name,
      row.crate_code,
      row.product_name,
      row.product_sku,
    ])
  })

  return (
    <section>
      <PageHeader
        title="Inventory"
        description="On-hand carton cases by crate. These balances are not available-to-pick while operational lot cutover is inactive. Lot identities, when they exist, are on Lot stock. You see godowns you are already allowed to work at."
      />
      <InventoryLinks />
      {balances.isLoading ? <LoadingBlock label="Loading inventory" /> : null}
      {balances.error ? (
        <p role="alert" className="text-sm text-destructive">
          {balances.error.message}
        </p>
      ) : null}
      {balances.data ? (
        <>
          <div className="mb-4 max-w-sm">
            <MetricCard
              label="Loaded rows"
              icon={Package}
              hint="Balances returned for your godowns"
              value={balances.data.length}
            />
          </div>
          <FilterBar label="Inventory filters">
            <SearchField label="Search inventory" value={search} onChange={setSearch} />
            <label className="grid w-full min-w-[12rem] gap-1.5 text-sm font-medium sm:w-56">
              <span>Godown</span>
            <select
              aria-label="Godown"
              value={godownId}
              onChange={(event) => setGodownId(event.target.value)}
              className="h-10 rounded-lg border border-input bg-transparent px-2.5 text-sm"
            >
              <option value="all">All authorized godowns</option>
              {godowns.map(([id, label]) => (
                <option key={id} value={id}>
                  {label}
                </option>
              ))}
            </select>
            </label>
          </FilterBar>
          {visible.length === 0 ? (
            <EmptyState
              icon={Package}
              title="No stock"
              description="Opening stock and transfers posted for your godowns will appear here."
            />
          ) : (
            <RecordTable className="min-w-[44rem]" caption="Stock balances">
              <RecordHeader>
                <tr>
                  <RecordHeadCell>Godown</RecordHeadCell>
                  <RecordHeadCell>Zone</RecordHeadCell>
                  <RecordHeadCell>Crate</RecordHeadCell>
                  <RecordHeadCell>Product</RecordHeadCell>
                  <RecordHeadCell>SKU</RecordHeadCell>
                  <RecordHeadCell className="text-right">On-hand cases</RecordHeadCell>
                </tr>
              </RecordHeader>
              <tbody>
                {visible.map((row) => (
                  <BalanceRow key={`${row.crate_id}-${row.product_id}`} row={row} />
                ))}
              </tbody>
            </RecordTable>
          )}
        </>
      ) : null}
    </section>
  )
}

function BalanceRow({ row }: { row: StockBalance }) {
  return (
    <RecordRow>
      <RecordCell>{row.godown_name}</RecordCell>
      <RecordCell>
        {row.zone_code}
        <span className="ml-2 text-muted-foreground">{row.zone_name}</span>
      </RecordCell>
      <RecordCell>{row.crate_code}</RecordCell>
      <RecordCell>{row.product_name}</RecordCell>
      <RecordCell>{row.product_sku}</RecordCell>
      <RecordCell className="text-right font-medium tabular-nums">{row.quantity}</RecordCell>
    </RecordRow>
  )
}
