import type { AppNavItem } from "@/types/navigation"

/** Paths that stay Admin/staff-admin unless employees.read or audit.read is granted. */
export const ADMIN_ONLY_NAV_PATHS = [
  "/employees",
  "/godowns",
  "/users-roles",
  "/audit",
] as const

/**
 * Cloud-observed Accounts role grants. Navigation tests use this list so a
 * hidden item is not confused with an unauthorized RPC.
 */
export const ACCOUNTS_ROLE_PERMISSIONS = [
  "accounts.godowns.all",
  "delivery_notes.issue",
  "invoices.issue",
  "invoices.review",
  "orders.capture",
  "orders.verify",
  "products.price.manage",
  "products.price.read",
  "products.read",
  "refill.request",
  "shipments.approve",
  "shipments.view",
  "shops.read",
  "shops.read_all",
  "shops.statement.read",
  "statutory.config.prepare",
  "statutory.config.read",
  "stock.read",
  "suppliers.manage",
  "suppliers.read",
] as const

export function canSeeNavigationItem(
  item: AppNavItem,
  can: (permission: string) => boolean,
) {
  if (item.anyPermissions && item.anyPermissions.length > 0) {
    return item.anyPermissions.some((permission) => can(permission))
  }
  if (!item.permission) return true
  return can(item.permission)
}

export function visibleNavigationItems(
  items: readonly AppNavItem[],
  can: (permission: string) => boolean,
) {
  return items.filter((item) => canSeeNavigationItem(item, can))
}

/**
 * Sidebar active state. `/orders/verification` is a sibling of the Orders
 * list, not a child that should keep Orders highlighted.
 */
export function isNavigationPathActive(itemTo: string, pathname: string, end?: boolean) {
  if (itemTo === "/") return pathname === "/"
  if (itemTo === "/orders") {
    if (pathname === "/orders") return true
    if (pathname.startsWith("/orders/verification")) return false
    return pathname.startsWith("/orders/")
  }
  if (itemTo === "/receiving") {
    if (pathname === "/receiving") return true
    if (pathname.startsWith("/receiving/verification")) return false
    return pathname.startsWith("/receiving/")
  }
  if (end) return pathname === itemTo
  return pathname === itemTo || pathname.startsWith(`${itemTo}/`)
}
