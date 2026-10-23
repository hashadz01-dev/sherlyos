import { createBrowserRouter, type RouteObject } from "react-router"
import { AppShell } from "@/app/layouts/AppShell"
import { AuditPage } from "@/features/administration/audit/AuditPage"
import { BranchesPage } from "@/features/administration/branches/BranchesPage"
import { EmployeesPage } from "@/features/administration/employees/EmployeesPage"
import { UsersRolesPage } from "@/features/administration/users/UsersRolesPage"
import { DamagePage } from "@/features/damage/DamagePage"
import { SettingsPage } from "@/features/administration/SettingsPage"
import { DeliveriesPage } from "@/features/delivery-notes/DeliveriesPage"
import { DeliveryNoteDetailPage } from "@/features/delivery-notes/DeliveryNoteDetailPage"
import { DeliveryNotePrintPage } from "@/features/delivery-notes/DeliveryNotePrintPage"
import { NewDeliveryNotePage } from "@/features/delivery-notes/NewDeliveryNotePage"
import { HistoryPage } from "@/features/inventory/HistoryPage"
import { InventoryPage } from "@/features/inventory/InventoryPage"
import { OpeningStockPage } from "@/features/inventory/OpeningStockPage"
import { TransfersPage } from "@/features/inventory/TransfersPage"
import { CategoriesPage } from "@/features/masters/categories/CategoriesPage"
import { LocationsPage } from "@/features/masters/locations/LocationsPage"
import { MastersPage } from "@/features/masters/MastersPage"
import { ProductsPage } from "@/features/masters/products/ProductsPage"
import { ShopsPage } from "@/features/masters/shops/ShopsPage"
import { SuppliersPage } from "@/features/masters/suppliers/SuppliersPage"
import { EditOrderPage, NewOrderPage } from "@/features/orders/OrderEditorPage"
import { OrderDetailPage } from "@/features/orders/OrderDetailPage"
import { OrdersPage } from "@/features/orders/OrdersPage"
import { DeliveryRunsPage } from "@/features/dispatch/DeliveryRunsPage"
import { DispatchDetailPage } from "@/features/dispatch/DispatchDetailPage"
import { DispatchPage } from "@/features/dispatch/DispatchPage"
import { DispatchPreparePage } from "@/features/dispatch/DispatchPreparePage"
import { PickingAllocatePage } from "@/features/picking/PickingAllocatePage"
import { PickingDetailPage } from "@/features/picking/PickingDetailPage"
import { PickingExceptionsPage } from "@/features/picking/PickingExceptionsPage"
import { PickingPage } from "@/features/picking/PickingPage"
import { ReceiptDetailPage } from "@/features/receiving/ReceiptDetailPage"
import { ReceiptEditorPage } from "@/features/receiving/ReceiptEditorPage"
import { ReceivingPage } from "@/features/receiving/ReceivingPage"
import { RefillPage } from "@/features/refill/RefillPage"
import { DispatchReportPage } from "@/features/reports/DispatchReportPage"
import { ExceptionsReportPage } from "@/features/reports/ExceptionsReportPage"
import { InventoryReportPage } from "@/features/reports/InventoryReportPage"
import { LotStockReportPage } from "@/features/reports/LotStockReportPage"
import { MovementReportPage } from "@/features/reports/MovementReportPage"
import { OrderPickingReportPage } from "@/features/reports/OrderPickingReportPage"
import { ReportsPage } from "@/features/reports/ReportsPage"
import { AdjustmentDetailPage } from "@/features/stock-adjustments/AdjustmentDetailPage"
import { AdjustmentsPage } from "@/features/stock-adjustments/AdjustmentsPage"
import { NewAdjustmentPage } from "@/features/stock-adjustments/NewAdjustmentPage"
import { LotReconciliationDetailPage } from "@/features/stock-lot-reconciliation/LotReconciliationDetailPage"
import { LotReconciliationPage } from "@/features/stock-lot-reconciliation/LotReconciliationPage"
import { NewLotReconciliationPage } from "@/features/stock-lot-reconciliation/NewLotReconciliationPage"
import { StartVerificationPage } from "@/features/stock-verification/StartVerificationPage"
import { StockVerificationPage } from "@/features/stock-verification/StockVerificationPage"
import { VerificationDetailPage } from "@/features/stock-verification/VerificationDetailPage"
import { RequireAnyPermission } from "@/lib/access/RequireAnyPermission"
import { RequirePermission } from "@/lib/access/RequirePermission"
import {
  dispatchReportPermissions,
  inventoryReportPermissions,
  operationsReportPermissions,
  orderReportPermissions,
} from "@/lib/reports/access"
import { RequireAuth } from "@/lib/auth/RequireAuth"
import { LoginPage } from "@/pages/auth/LoginPage"
import { DashboardPage } from "@/pages/dashboard/DashboardPage"
import { NotFoundPage } from "@/pages/errors/NotFoundPage"

export const appRouteObjects: RouteObject[] = [
  {
    path: "/login",
    element: <LoginPage />,
  },
  {
    element: <RequireAuth />,
    children: [
      {
        element: <AppShell />,
        children: [
          { index: true, element: <DashboardPage /> },
          {
            path: "orders",
            element: (
              <RequireAnyPermission
                permissions={["orders.capture", "orders.verify", "operations.monitor"]}
              >
                <OrdersPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "orders/new",
            element: (
              <RequirePermission permission="orders.capture">
                <NewOrderPage />
              </RequirePermission>
            ),
          },
          {
            path: "orders/:orderId/edit",
            element: (
              <RequirePermission permission="orders.capture">
                <EditOrderPage />
              </RequirePermission>
            ),
          },
          {
            path: "orders/:orderId",
            element: (
              <RequireAnyPermission
                permissions={["orders.capture", "orders.verify", "operations.monitor"]}
              >
                <OrderDetailPage />
              </RequireAnyPermission>
            ),
          },

          {
            path: "picking",
            element: (
              <RequireAnyPermission
                permissions={[
                  "picking.allocate",
                  "picking.manage",
                  "picking.execute",
                  "operations.monitor",
                ]}
              >
                <PickingPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "picking/exceptions",
            element: (
              <RequireAnyPermission permissions={["picking.manage", "picking.allocate", "operations.monitor"]}>
                <PickingExceptionsPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "picking/allocate/:orderId",
            element: (
              <RequirePermission permission="picking.allocate">
                <PickingAllocatePage />
              </RequirePermission>
            ),
          },
          {
            path: "picking/:requestId",
            element: (
              <RequireAnyPermission
                permissions={[
                  "picking.allocate",
                  "picking.manage",
                  "picking.execute",
                  "operations.monitor",
                ]}
              >
                <PickingDetailPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "dispatch",
            element: (
              <RequireAnyPermission
                permissions={["dispatch.view", "dispatch.confirm", "operations.monitor"]}
              >
                <DispatchPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "dispatch/prepare/:orderId",
            element: (
              <RequireAnyPermission permissions={["dispatch.view", "dispatch.confirm", "operations.monitor"]}>
                <DispatchPreparePage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "dispatch/:dispatchId",
            element: (
              <RequireAnyPermission
                permissions={[
                  "dispatch.view",
                  "dispatch.confirm",
                  "deliveries.execute",
                  "deliveries.assign",
                  "operations.monitor",
                ]}
              >
                <DispatchDetailPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "delivery-runs",
            element: (
              <RequireAnyPermission
                permissions={[
                  "deliveries.execute",
                  "deliveries.assign",
                  "dispatch.view",
                  "operations.monitor",
                ]}
              >
                <DeliveryRunsPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "deliveries",
            element: (
              <RequireAnyPermission
                permissions={[
                  "delivery_notes.issue",
                  "delivery_notes.acknowledge",
                  "operations.monitor",
                ]}
              >
                <DeliveriesPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "deliveries/new",
            element: (
              <RequirePermission permission="delivery_notes.issue">
                <NewDeliveryNotePage />
              </RequirePermission>
            ),
          },
          {
            path: "deliveries/:noteId/print",
            element: (
              <RequireAnyPermission
                permissions={[
                  "delivery_notes.issue",
                  "delivery_notes.acknowledge",
                  "operations.monitor",
                ]}
              >
                <DeliveryNotePrintPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "deliveries/:noteId",
            element: (
              <RequireAnyPermission
                permissions={[
                  "delivery_notes.issue",
                  "delivery_notes.acknowledge",
                  "operations.monitor",
                ]}
              >
                <DeliveryNoteDetailPage />
              </RequireAnyPermission>
            ),
          },
          { path: "damage", element: <DamagePage /> },
          {
            path: "receiving",
            element: (
              <RequireAnyPermission
                permissions={["receiving.execute", "receiving.verify", "operations.monitor"]}
              >
                <ReceivingPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "receiving/new",
            element: (
              <RequirePermission permission="receiving.execute">
                <ReceiptEditorPage />
              </RequirePermission>
            ),
          },
          {
            path: "receiving/:receiptId",
            element: (
              <RequireAnyPermission
                permissions={["receiving.execute", "receiving.verify", "operations.monitor"]}
              >
                <ReceiptDetailPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "stock-verification",
            element: (
              <RequireAnyPermission
                permissions={["stock.verify", "stock.count_assist", "operations.monitor"]}
              >
                <StockVerificationPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "stock-verification/new",
            element: (
              <RequirePermission permission="stock.verify">
                <StartVerificationPage />
              </RequirePermission>
            ),
          },
          {
            path: "stock-verification/:verificationId",
            element: (
              <RequireAnyPermission
                permissions={["stock.verify", "stock.count_assist", "operations.monitor"]}
              >
                <VerificationDetailPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "stock-lot-reconciliation",
            element: (
              <RequireAnyPermission
                permissions={[
                  "stock.lots.physical_reconcile",
                  "stock.lots.legacy.reconcile",
                  "operations.monitor",
                ]}
              >
                <LotReconciliationPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "stock-lot-reconciliation/new",
            element: (
              <RequirePermission permission="stock.lots.legacy.reconcile">
                <NewLotReconciliationPage />
              </RequirePermission>
            ),
          },
          {
            path: "stock-lot-reconciliation/:sessionId",
            element: (
              <RequireAnyPermission
                permissions={[
                  "stock.lots.physical_reconcile",
                  "stock.lots.legacy.reconcile",
                  "operations.monitor",
                ]}
              >
                <LotReconciliationDetailPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "stock-adjustments",
            element: (
              <RequireAnyPermission
                permissions={[
                  "stock.adjustment.request",
                  "stock.adjustment.post",
                  "stock.adjustment.approve_exceptional",
                  "operations.monitor",
                  "stock.read",
                ]}
              >
                <AdjustmentsPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "stock-adjustments/new",
            element: (
              <RequirePermission permission="stock.adjustment.request">
                <NewAdjustmentPage />
              </RequirePermission>
            ),
          },
          {
            path: "stock-adjustments/:requestId",
            element: (
              <RequireAnyPermission
                permissions={[
                  "stock.adjustment.request",
                  "stock.adjustment.post",
                  "stock.adjustment.approve_exceptional",
                  "operations.monitor",
                  "stock.read",
                ]}
              >
                <AdjustmentDetailPage />
              </RequireAnyPermission>
            ),
          },
          { path: "refill", element: <RefillPage /> },
          {
            path: "inventory",
            element: (
              <RequirePermission permission="stock.read">
                <InventoryPage />
              </RequirePermission>
            ),
          },
          {
            path: "inventory/opening",
            element: (
              <RequirePermission permission="stock.opening.post">
                <OpeningStockPage />
              </RequirePermission>
            ),
          },
          {
            path: "inventory/transfers",
            element: (
              <RequirePermission permission="stock.transfer.post">
                <TransfersPage />
              </RequirePermission>
            ),
          },
          {
            path: "inventory/history",
            element: (
              <RequirePermission permission="stock.read">
                <HistoryPage />
              </RequirePermission>
            ),
          },
          { path: "masters", element: <MastersPage /> },
          {
            path: "masters/products",
            element: (
              <RequirePermission permission="products.read">
                <ProductsPage />
              </RequirePermission>
            ),
          },
          {
            path: "masters/categories",
            element: (
              <RequirePermission permission="products.read">
                <CategoriesPage />
              </RequirePermission>
            ),
          },
          {
            path: "masters/suppliers",
            element: (
              <RequirePermission permission="suppliers.read">
                <SuppliersPage />
              </RequirePermission>
            ),
          },
          {
            path: "masters/shops",
            element: (
              <RequirePermission permission="shops.read">
                <ShopsPage />
              </RequirePermission>
            ),
          },
          {
            path: "masters/locations",
            element: (
              <RequirePermission permission="locations.read">
                <LocationsPage />
              </RequirePermission>
            ),
          },
          {
            path: "reports",
            element: (
              <RequireAnyPermission permissions={operationsReportPermissions}>
                <ReportsPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "reports/inventory",
            element: (
              <RequireAnyPermission permissions={inventoryReportPermissions}>
                <InventoryReportPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "reports/lots",
            element: (
              <RequireAnyPermission permissions={inventoryReportPermissions}>
                <LotStockReportPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "reports/movements",
            element: (
              <RequireAnyPermission permissions={inventoryReportPermissions}>
                <MovementReportPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "reports/orders-picking",
            element: (
              <RequireAnyPermission permissions={orderReportPermissions}>
                <OrderPickingReportPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "reports/dispatch",
            element: (
              <RequireAnyPermission permissions={dispatchReportPermissions}>
                <DispatchReportPage />
              </RequireAnyPermission>
            ),
          },
          {
            path: "reports/exceptions",
            element: (
              <RequireAnyPermission permissions={operationsReportPermissions}>
                <ExceptionsReportPage />
              </RequireAnyPermission>
            ),
          },
          { path: "settings", element: <SettingsPage /> },
          {
            path: "employees",
            element: (
              <RequirePermission permission="employees.read">
                <EmployeesPage />
              </RequirePermission>
            ),
          },
          {
            path: "branches",
            element: (
              <RequirePermission permission="employees.read">
                <BranchesPage />
              </RequirePermission>
            ),
          },
          {
            path: "users-roles",
            element: (
              <RequirePermission permission="employees.read">
                <UsersRolesPage />
              </RequirePermission>
            ),
          },
          {
            path: "audit",
            element: (
              <RequirePermission permission="audit.read">
                <AuditPage />
              </RequirePermission>
            ),
          },
          { path: "*", element: <NotFoundPage /> },
        ],
      },
    ],
  },
]

export const router = createBrowserRouter(appRouteObjects)
