import {
  ChartColumn,
  ClipboardCheck,
  LayoutDashboard,
  Library,
  Package,
  PackageOpen,
  RefreshCw,
  Settings,
  ShoppingCart,
  TriangleAlert,
  Truck,
} from "lucide-react"
import type { AppNavItem, NavGroup } from "@/types/navigation"

export const navigationItems: AppNavItem[] = [
  {
    to: "/",
    label: "Overview",
    title: "Operations Overview",
    description:
      "A summary of orders, deliveries, stock alerts, and approvals.",
    group: "Operations",
    icon: LayoutDashboard,
    end: true,
  },
  {
    to: "/orders",
    label: "Orders",
    title: "Orders",
    description:
      "Shop orders will be listed and progressed here in a later phase.",
    group: "Operations",
    icon: ShoppingCart,
  },
  {
    to: "/deliveries",
    label: "Deliveries",
    title: "Deliveries",
    description:
      "Delivery notes and handover status will be tracked here in a later phase.",
    group: "Operations",
    icon: Truck,
  },
  {
    to: "/damage",
    label: "Damage",
    title: "Damage Management",
    description:
      "Damage reports and quarantine will be handled here in a later phase.",
    group: "Operations",
    icon: TriangleAlert,
  },
  {
    to: "/receiving",
    label: "Receiving",
    title: "Stock Receiving",
    description:
      "Inbound stock receiving will be recorded here in a later phase.",
    group: "Operations",
    icon: PackageOpen,
  },
  {
    to: "/stock-verification",
    label: "Verification",
    title: "Daily Stock Verification",
    description: "Daily stock checks will be completed here in a later phase.",
    group: "Operations",
    icon: ClipboardCheck,
  },
  {
    to: "/refill",
    label: "Refill",
    title: "Stock Refill",
    description:
      "Refill requests will be raised and fulfilled here in a later phase.",
    group: "Operations",
    icon: RefreshCw,
  },
  {
    to: "/inventory",
    label: "Inventory",
    title: "Inventory",
    description:
      "The inventory ledger will be viewed here in a later phase. This screen cannot change stock.",
    group: "Stock",
    icon: Package,
  },
  {
    to: "/masters",
    label: "Masters",
    title: "Masters",
    description:
      "Shops, products, and other master data will be maintained here in a later phase.",
    group: "Stock",
    icon: Library,
  },
  {
    to: "/reports",
    label: "Reports",
    title: "Reports",
    description: "Operational reports will be generated here in a later phase.",
    group: "Workspace",
    icon: ChartColumn,
  },
  {
    to: "/settings",
    label: "Settings",
    title: "Settings",
    description: "Workspace configuration and account details.",
    group: "Workspace",
    icon: Settings,
  },
]

export const navigationGroups: NavGroup[] = ["Operations", "Stock", "Workspace"]

export function findNavigationItem(pathname: string) {
  return navigationItems.find((item) => {
    if (item.to === "/") {
      return pathname === "/"
    }
    return pathname === item.to || pathname.startsWith(`${item.to}/`)
  })
}
