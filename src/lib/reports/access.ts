import type { AccessState } from "@/lib/access/use-access"

export const inventoryReportPermissions = ["stock.read", "operations.monitor"]

export const orderReportPermissions = [
  "orders.capture",
  "orders.verify",
  "picking.allocate",
  "picking.manage",
  "picking.execute",
  "operations.monitor",
]

export const dispatchReportPermissions = [
  "dispatch.view",
  "dispatch.confirm",
  "deliveries.execute",
  "deliveries.assign",
  "operations.monitor",
]

export const operationsReportPermissions = [
  ...inventoryReportPermissions,
  ...orderReportPermissions,
  ...dispatchReportPermissions,
  "receiving.execute",
  "receiving.verify",
  "stock.verify",
  "stock.adjustment.request",
  "stock.adjustment.post",
  "stock.lots.physical_reconcile",
  "stock.lots.legacy.reconcile",
]

export function canAny(access: AccessState, permissions: string[]) {
  return permissions.some((permission) => access.can(permission))
}
