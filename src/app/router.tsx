import { createBrowserRouter, type RouteObject } from "react-router"
import { AppShell } from "@/app/layouts/AppShell"
import {
  AdjustmentDetailPage,
  AdjustmentsPage,
  AuditPage,
  BranchesPage,
  CategoriesPage,
  DamagePage,
  DeliveriesPage,
  DeliveryNoteDetailPage,
  DeliveryNotePrintPage,
  DeliveryRunsPage,
  DispatchDetailPage,
  DispatchPage,
  DispatchPreparePage,
  DispatchReportPage,
  DashboardPage,
  EditOrderPage,
  EmployeesPage,
  ExceptionsReportPage,
  HistoryPage,
  InventoryPage,
  InventoryReportPage,
  LocationsPage,
  LotReconciliationDetailPage,
  LotReconciliationPage,
  LotStockReportPage,
  MastersPage,
  MovementReportPage,
  NewAdjustmentPage,
  NewDeliveryNotePage,
  NewLotReconciliationPage,
  NewOrderPage,
  NotFoundPage,
  OpeningStockPage,
  OrderDetailPage,
  OrderPickingReportPage,
  OrdersPage,
  PickingAllocatePage,
  PickingDetailPage,
  PickingExceptionsPage,
  PickingPage,
  ProductsPage,
  ReceiptDetailPage,
  ReceiptEditorPage,
  ReceivingPage,
  RefillPage,
  ReportsPage,
  SettingsPage,
  ShopsPage,
  StartVerificationPage,
  StockVerificationPage,
  SuppliersPage,
  TransfersPage,
  UsersRolesPage,
  VerificationDetailPage,
} from "@/app/lazy-pages"
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
          {
            path: "masters",
            element: (
              <RequireAnyPermission
                permissions={["products.read", "suppliers.read", "shops.read", "locations.read"]}
              >
                <MastersPage />
              </RequireAnyPermission>
            ),
          },
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
