import { useMemo, useState } from "react"
import { Layers } from "lucide-react"
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
import { StatusBadge, type StatusTone } from "@/components/shared/StatusBadge"
import { SearchField } from "@/features/masters/MasterControls"
import { InventoryLinks } from "@/features/inventory/InventoryLinks"
import { useDocumentTitle } from "@/hooks/use-document-title"
import { listStockLotBalances, type StockLotBalance } from "@/lib/inventory/api"
import { matchesSearch } from "@/lib/masters/filters"
import { useQuery } from "@tanstack/react-query"

/**
 * Operational lot balances under Stock. Kept on /inventory/lots so the
 * History toolbar does not jump into the Reports workspace at /reports/lots.
 */
export function LotStockPage() {
  useDocumentTitle("Lot stock")
  const [search, setSearch] = useState("")
  const [godownId, setGodownId] = useState("all")
  const lots = useQuery({
    queryKey: ["stock-lot-balances"],
    queryFn: () => listStockLotBalances(),
  })

  const godowns = useMemo(() => {
    const rows = new Map<string, string>()
    for (const row of lots.data ?? []) {
      rows.set(row.godown_id, row.godown_code)
    }
    return [...rows.entries()]
  }, [lots.data])

  const visible = (lots.data ?? []).filter((row) => {
    if (godownId !== "all" && row.godown_id !== godownId) return false
    return matchesSearch(search, [
      row.godown_code,
      row.crate_code,
      row.product_name,
      row.product_sku,
      row.manufacturer_lot_code,
      row.lot_status,
      row.lot_origin,
    ])
  })

  return (
    <section>
      <PageHeader
        title="Lot stock"
        description="Lot-attributed carton cases for godowns you can already work at. This is the stock workspace, not the lot stock report. Operational cutover is inactive until owner flags are enabled."
      />
      <InventoryLinks />
      {lots.isLoading ? <LoadingBlock label="Loading lot stock" /> : null}
      {lots.error ? (
        <p role="alert" className="text-sm text-destructive">
          {lots.error.message}
        </p>
      ) : null}
      {lots.data ? (
        <>
          <div className="mb-4 max-w-sm">
            <MetricCard
              label="Loaded rows"
              icon={Layers}
              hint="Lot balances returned for your godowns"
              value={lots.data.length}
            />
          </div>
          <FilterBar label="Lot stock filters">
            <SearchField label="Search lot stock" value={search} onChange={setSearch} />
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
              icon={Layers}
              title="No lot balances"
              description="Lot rows appear when lot-attributed stock exists for your godowns."
            />
          ) : (
            <RecordTable className="min-w-[52rem]" caption="Lot stock">
              <RecordHeader>
                <tr>
                  <RecordHeadCell>Lot</RecordHeadCell>
                  <RecordHeadCell>Status</RecordHeadCell>
                  <RecordHeadCell>Expiry</RecordHeadCell>
                  <RecordHeadCell>Product</RecordHeadCell>
                  <RecordHeadCell>Godown</RecordHeadCell>
                  <RecordHeadCell>Crate</RecordHeadCell>
                  <RecordHeadCell className="text-right">On-hand cases</RecordHeadCell>
                </tr>
              </RecordHeader>
              <tbody>
                {visible.map((row) => (
                  <LotBalanceRow key={`${row.lot_id}-${row.crate_id}`} row={row} />
                ))}
              </tbody>
            </RecordTable>
          )}
        </>
      ) : null}
    </section>
  )
}

/** Color only. The status word on the row is unchanged. */
function lotStatusTone(status: string): StatusTone {
  const value = status.toLowerCase()
  if (value.includes("quarantine")) return "quarantine"
  if (value.includes("block") || value.includes("cancel")) return "danger"
  if (value.includes("hold") || value.includes("expir")) return "warning"
  if (value.includes("active") || value.includes("available")) return "success"
  return "neutral"
}

function LotBalanceRow({ row }: { row: StockLotBalance }) {
  return (
    <RecordRow>
      <RecordCell>{row.manufacturer_lot_code ?? row.lot_id}</RecordCell>
      <RecordCell>
        <StatusBadge tone={lotStatusTone(row.lot_status)}>{row.lot_status}</StatusBadge>
      </RecordCell>
      <RecordCell>{row.expiry_date ?? "Unknown"}</RecordCell>
      <RecordCell>
        {row.product_name}
        <span className="ml-2 text-muted-foreground">{row.product_sku}</span>
      </RecordCell>
      <RecordCell>{row.godown_code}</RecordCell>
      <RecordCell>{row.crate_code}</RecordCell>
      <RecordCell className="text-right font-medium tabular-nums">{row.quantity}</RecordCell>
    </RecordRow>
  )
}
