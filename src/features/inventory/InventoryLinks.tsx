import { SegmentedTabs } from "@/components/shared/SegmentedTabs"
import { useAccess } from "@/lib/access/use-access"

/** Stock workspace tabs. Lot stock stays under /inventory so it does not open Reports. */
export const inventoryWorkspaceLinks = [
  { to: "/inventory", label: "Balances", permission: "stock.read", end: true },
  { to: "/inventory/history", label: "History", permission: "stock.read", end: false },
  { to: "/inventory/lots", label: "Lot stock", permission: "stock.read", end: false },
  { to: "/inventory/opening", label: "Opening stock", permission: "stock.opening.post", end: false },
  { to: "/inventory/transfers", label: "Transfers", permission: "stock.transfer.post", end: false },
]

export function InventoryLinks() {
  const { can, loading } = useAccess()
  const visible = inventoryWorkspaceLinks.filter((link) => !loading && can(link.permission))

  if (visible.length === 0) return null

  return (
    <SegmentedTabs
      label="Inventory"
      items={visible.map((link) => ({
        to: link.to,
        label: link.label,
        end: link.end,
      }))}
    />
  )
}
