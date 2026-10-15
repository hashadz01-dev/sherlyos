import { NavLink } from "react-router"
import { cn } from "cn"
import { useAccess } from "@/lib/access/use-access"

const links = [
  { to: "/inventory", label: "Balances", permission: "stock.read", end: true },
  { to: "/inventory/history", label: "History", permission: "stock.read", end: false },
  { to: "/inventory/opening", label: "Opening stock", permission: "stock.opening.post", end: false },
  { to: "/inventory/transfers", label: "Transfers", permission: "stock.transfer.post", end: false },
]

export function InventoryLinks() {
  const { can, loading } = useAccess()
  const visible = links.filter((link) => !loading && can(link.permission))

  return (
    <nav aria-label="Inventory" className="mb-6 flex flex-wrap gap-2">
      {visible.map((link) => (
        <NavLink
          key={link.to}
          to={link.to}
          end={link.end}
          className={({ isActive }) =>
            cn(
              "rounded-full px-3 py-1.5 text-sm font-medium ring-1 ring-slate-200",
              isActive ? "bg-slate-900 text-white" : "bg-white text-slate-700",
            )
          }
        >
          {link.label}
        </NavLink>
      ))}
    </nav>
  )
}
