import { useMemo, useState } from "react"
import { Layers } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
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
          <div className="mb-4 grid gap-3 sm:grid-cols-[minmax(0,1fr)_16rem]">
            <SearchField label="Search lot stock" value={search} onChange={setSearch} />
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
          </div>
          {visible.length === 0 ? (
            <EmptyState
              icon={Layers}
              title="No lot balances"
              description="Lot rows appear when lot-attributed stock exists for your godowns."
            />
          ) : (
            <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200">
              <table className="w-full min-w-[52rem] text-left text-sm">
                <thead className="text-xs tracking-wide text-muted-foreground uppercase">
                  <tr>
                    <th className="px-4 py-3 font-medium">Lot</th>
                    <th className="px-4 py-3 font-medium">Status</th>
                    <th className="px-4 py-3 font-medium">Expiry</th>
                    <th className="px-4 py-3 font-medium">Product</th>
                    <th className="px-4 py-3 font-medium">Godown</th>
                    <th className="px-4 py-3 font-medium">Crate</th>
                    <th className="px-4 py-3 text-right font-medium">On-hand cases</th>
                  </tr>
                </thead>
                <tbody>
                  {visible.map((row) => (
                    <LotBalanceRow key={`${row.lot_id}-${row.crate_id}`} row={row} />
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

function LotBalanceRow({ row }: { row: StockLotBalance }) {
  return (
    <tr className="border-t border-slate-100">
      <td className="px-4 py-3">{row.manufacturer_lot_code ?? row.lot_id}</td>
      <td className="px-4 py-3">{row.lot_status}</td>
      <td className="px-4 py-3">{row.expiry_date ?? "Unknown"}</td>
      <td className="px-4 py-3">
        {row.product_name}
        <span className="ml-2 text-muted-foreground">{row.product_sku}</span>
      </td>
      <td className="px-4 py-3">{row.godown_code}</td>
      <td className="px-4 py-3">{row.crate_code}</td>
      <td className="px-4 py-3 text-right font-medium">{row.quantity}</td>
    </tr>
  )
}
