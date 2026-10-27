import { NavLink } from "react-router"
import { cn } from "cn"
import { useAccess } from "@/lib/access/use-access"
import {
  canAny,
  dispatchReportPermissions,
  inventoryReportPermissions,
  operationsReportPermissions,
  orderReportPermissions,
  refillReportPermissions,
} from "@/lib/reports/access"

const links = [
  {
    to: "/reports",
    label: "All reports",
    permissions: [...operationsReportPermissions, ...refillReportPermissions],
    end: true,
  },
  {
    to: "/reports/inventory",
    label: "Inventory",
    permissions: inventoryReportPermissions,
  },
  {
    to: "/reports/lots",
    label: "Lots",
    permissions: inventoryReportPermissions,
  },
  {
    to: "/reports/movements",
    label: "Movements",
    permissions: inventoryReportPermissions,
  },
  {
    to: "/reports/orders-picking",
    label: "Orders & picking",
    permissions: orderReportPermissions,
  },
  {
    to: "/reports/dispatch",
    label: "Dispatch & delivery",
    permissions: dispatchReportPermissions,
  },
  {
    to: "/reports/exceptions",
    label: "Exceptions",
    permissions: operationsReportPermissions,
  },
  {
    to: "/reports/refill",
    label: "Refill",
    permissions: refillReportPermissions,
  },
]

export function ReportLinks() {
  const access = useAccess()
  const visible = links.filter((link) => !access.loading && canAny(access, link.permissions))

  return (
    <nav aria-label="Reports" className="mb-6 flex flex-wrap gap-2">
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
