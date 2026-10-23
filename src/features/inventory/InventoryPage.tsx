import { useMemo, useState } from "react"
import { Package } from "lucide-react"
import { EmptyState } from "@/components/shared/EmptyState"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PageHeader } from "@/components/shared/PageHeader"
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
        description="On-hand carton cases by crate. These balances are not available-to-pick while operational lot cutover is inactive. Lot identities, when they exist, are on the lot stock report. You see godowns you are already allowed to work at."
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
          <div className="mb-4 grid gap-3 sm:grid-cols-[minmax(0,1fr)_16rem]">
            <SearchField label="Search inventory" value={search} onChange={setSearch} />
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
              icon={Package}
              title="No stock"
              description="Opening stock and transfers posted for your godowns will appear here."
            />
          ) : (
            <div className="overflow-x-auto rounded-2xl bg-white ring-1 ring-slate-200">
              <table className="w-full min-w-[44rem] text-left text-sm">
                <thead className="text-xs tracking-wide text-muted-foreground uppercase">
                  <tr>
                    <th className="px-4 py-3 font-medium">Godown</th>
                    <th className="px-4 py-3 font-medium">Zone</th>
                    <th className="px-4 py-3 font-medium">Crate</th>
                    <th className="px-4 py-3 font-medium">Product</th>
                    <th className="px-4 py-3 font-medium">SKU</th>
                    <th className="px-4 py-3 text-right font-medium">On-hand cases</th>
                  </tr>
                </thead>
                <tbody>
                  {visible.map((row) => (
                    <BalanceRow key={`${row.crate_id}-${row.product_id}`} row={row} />
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

function BalanceRow({ row }: { row: StockBalance }) {
  return (
    <tr className="border-t border-slate-100">
      <td className="px-4 py-3">{row.godown_name}</td>
      <td className="px-4 py-3">
        {row.zone_code}
        <span className="ml-2 text-muted-foreground">{row.zone_name}</span>
      </td>
      <td className="px-4 py-3">{row.crate_code}</td>
      <td className="px-4 py-3">{row.product_name}</td>
      <td className="px-4 py-3">{row.product_sku}</td>
      <td className="px-4 py-3 text-right font-medium">{row.quantity}</td>
    </tr>
  )
}
