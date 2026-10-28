import {
  ArrowLeftRight,
  Building2,
  Car,
  ChartColumn,
  ClipboardCheck,
  History,
  LayoutDashboard,
  Library,
  MapPinned,
  Package,
  PackageCheck,
  PackageOpen,
  PackagePlus,
  Send,
  RefreshCw,
  ScrollText,
  Settings,
  ShoppingCart,
  Store,
  Tags,
  TriangleAlert,
  Truck,
  UserRound,
  Users,
} from "lucide-react"
import { damageNavPermissions } from "@/lib/damage/rules"
import { operationsReportPermissions } from "@/lib/reports/access"
import type { AppNavItem, NavGroup } from "@/types/navigation"

export const navigationItems: AppNavItem[] = [
  {
    to: "/",
    label: "Overview",
    title: "Operations Overview",
    description:
      "Authoritative operational counts for inventory, orders, picking, dispatch, and exceptions.",
    group: "Operations",
    icon: LayoutDashboard,
    end: true,
  },
  {
    to: "/orders",
    label: "Orders",
    title: "Orders",
    description:
      "Capture shop requests and review their status. Verification does not change inventory.",
    group: "Operations",
    icon: ShoppingCart,
    anyPermissions: ["orders.capture", "orders.verify", "operations.monitor"],
  },

  {
    to: "/picking",
    label: "Picking",
    title: "Picking",
    description:
      "Allocate verified orders with FEFO or FIFO, reserve crate and lot stock, and confirm warehouse picks.",
    group: "Operations",
    icon: PackageCheck,
    anyPermissions: [
      "picking.allocate",
      "picking.manage",
      "picking.execute",
      "operations.monitor",
    ],
  },
  {
    to: "/dispatch",
    label: "Dispatch",
    title: "Dispatch",
    description:
      "Confirm ready-for-dispatch picks and consume reserved carton cases exactly once.",
    group: "Operations",
    icon: Send,
    anyPermissions: [
      "dispatch.view",
      "dispatch.confirm",
      "operations.monitor",
    ],
  },
  {
    to: "/delivery-runs",
    label: "Delivery runs",
    title: "Delivery runs",
    description:
      "Assigned physical deliveries, proof of delivery, and failed-delivery exceptions.",
    group: "Operations",
    icon: Truck,
    anyPermissions: [
      "deliveries.execute",
      "deliveries.assign",
      "deliveries.return_view",
      "dispatch.view",
      "operations.monitor",
    ],
  },
  {
    to: "/deliveries",
    label: "Delivery notes",
    title: "Delivery notes",
    description:
      "Create draft delivery notes from verified orders, generate printable documents, and void when required.",
    group: "Operations",
    icon: ScrollText,
    anyPermissions: [
      "delivery_notes.issue",
      "delivery_notes.acknowledge",
      "operations.monitor",
    ],
  },
  {
    to: "/damage",
    label: "Damage",
    title: "Damage Management",
    description:
      "Authorized damage reports, verification queues, and stock isolation status.",
    group: "Operations",
    icon: TriangleAlert,
    anyPermissions: [...damageNavPermissions],
  },
  {
    to: "/receiving",
    label: "Receiving",
    title: "Stock Receiving",
    description:
      "Record supplier deliveries and verify accepted carton cases before they enter inventory.",
    group: "Operations",
    icon: PackageOpen,
    anyPermissions: [
      "receiving.execute",
      "receiving.verify",
      "operations.monitor",
    ],
  },
  {
    to: "/stock-verification",
    label: "Verification",
    title: "Daily Stock Verification",
    description:
      "Count selected crates against a frozen stock snapshot and record any difference.",
    group: "Operations",
    icon: ClipboardCheck,
    anyPermissions: [
      "stock.verify",
      "stock.count_assist",
      "operations.monitor",
    ],
  },
  {
    to: "/stock-lot-reconciliation",
    label: "Lot reconciliation",
    title: "Physical lot reconciliation",
    description:
      "Count selected crates and record physical lot evidence. Approval does not change inventory.",
    group: "Operations",
    icon: ClipboardCheck,
    anyPermissions: [
      "stock.lots.physical_reconcile",
      "stock.lots.legacy.reconcile",
      "operations.monitor",
    ],
  },
  {
    to: "/stock-adjustments",
    label: "Adjustments",
    title: "Stock adjustments",
    description:
      "Request, approve, and post a reviewed stock discrepancy without editing the ledger.",
    group: "Operations",
    icon: ClipboardCheck,
    anyPermissions: [
      "stock.adjustment.request",
      "stock.adjustment.post",
      "stock.adjustment.approve_exceptional",
      "operations.monitor",
      "stock.read",
    ],
  },
  {
    to: "/refill",
    label: "Refill",
    title: "Stock Refill",
    description:
      "Accounts prepares supplier replenishment requests. Admin approval is not a stock receipt.",
    group: "Operations",
    icon: RefreshCw,
    anyPermissions: ["refill.request", "refill.approve"],
  },
  {
    to: "/inventory",
    label: "Inventory",
    title: "Inventory",
    description:
      "Whole carton cases by crate. Balances change only through posted transactions.",
    group: "Stock",
    icon: Package,
    permission: "stock.read",
    end: true,
  },
  {
    to: "/inventory/opening",
    label: "Opening stock",
    title: "Opening stock",
    description: "Post a one-time opening quantity into an active crate.",
    group: "Stock",
    icon: PackagePlus,
    permission: "stock.opening.post",
  },
  {
    to: "/inventory/transfers",
    label: "Transfers",
    title: "Stock transfers",
    description: "Move carton cases between crates in the same godown.",
    group: "Stock",
    icon: ArrowLeftRight,
    permission: "stock.transfer.post",
  },
  {
    to: "/inventory/history",
    label: "History",
    title: "Stock history",
    description: "Read posted opening stock and crate transfers.",
    group: "Stock",
    icon: History,
    permission: "stock.read",
  },
  {
    to: "/masters/products",
    label: "Products",
    title: "Products",
    description: "Product names and SKUs. Quantities are not stored here.",
    group: "Master data",
    icon: Package,
    permission: "products.read",
  },
  {
    to: "/masters/categories",
    label: "Categories",
    title: "Categories",
    description: "Optional product groups. Categories are not hierarchical.",
    group: "Master data",
    icon: Tags,
    permission: "products.read",
  },
  {
    to: "/masters/suppliers",
    label: "Suppliers",
    title: "Suppliers",
    description: "Supplier companies. A product has at most one supplier.",
    group: "Master data",
    icon: Store,
    permission: "suppliers.read",
  },
  {
    to: "/masters/shops",
    label: "Shops",
    title: "Shops",
    description: "Customer shops you are allowed to see.",
    group: "Master data",
    icon: ShoppingCart,
    permission: "shops.read",
  },
  {
    to: "/masters/locations",
    label: "Locations",
    title: "Godown locations",
    description: "Zones and crates inside a godown you can work at.",
    group: "Master data",
    icon: MapPinned,
    permission: "locations.read",
  },
  {
    to: "/masters/vehicles",
    label: "Vehicles",
    title: "Vehicles",
    description: "Delivery vehicles for assignment. Inactive vehicles stay in history.",
    group: "Master data",
    icon: Car,
    permission: "vehicles.view",
  },
  {
    to: "/masters",
    label: "Masters",
    title: "Master data",
    description: "Products, suppliers, shops, godown locations, and vehicles.",
    group: "Master data",
    icon: Library,
    end: true,
    anyPermissions: [
      "products.read",
      "suppliers.read",
      "shops.read",
      "locations.read",
      "vehicles.view",
    ],
  },
  {
    to: "/reports",
    label: "Reports",
    title: "Reports",
    description:
      "Read-only operational dashboards, inventory, movements, orders, dispatch, refill, and exceptions.",
    group: "Workspace",
    icon: ChartColumn,
    anyPermissions: [...operationsReportPermissions, "refill.request", "refill.approve"],
  },
  {
    to: "/settings",
    label: "Settings",
    title: "Settings",
    description: "Workspace configuration and account details.",
    group: "Workspace",
    icon: Settings,
  },
  {
    to: "/employees",
    label: "Employees",
    title: "Employees",
    description: "Profiles, roles, and operating-site assignments.",
    group: "Administration",
    icon: Users,
    permission: "employees.read",
  },
  {
    to: "/branches",
    label: "Branches",
    title: "Operating sites",
    description:
      "Godowns and other sites. Workflow branches from the blueprint are not listed here.",
    group: "Administration",
    icon: Building2,
    permission: "employees.read",
  },
  {
    to: "/audit",
    label: "Audit",
    title: "Audit history",
    description: "Security events recorded by privileged changes.",
    group: "Administration",
    icon: ScrollText,
    permission: "audit.read",
  },
  {
    to: "/users-roles",
    label: "Users & role",
    title: "Users & role",
    description:
      "People who can sign in, and the roles currently assigned to them.",
    group: "Administration",
    icon: UserRound,
    permission: "employees.read",
  },
]

export const navigationGroups: NavGroup[] = [
  "Operations",
  "Stock",
  "Master data",
  "Workspace",
  "Administration",
]

export function findNavigationItem(pathname: string) {
  const matches = navigationItems.filter((item) => {
    if (item.to === "/") {
      return pathname === "/"
    }
    return pathname === item.to || pathname.startsWith(`${item.to}/`)
  })
  return matches.sort((left, right) => right.to.length - left.to.length)[0]
}
