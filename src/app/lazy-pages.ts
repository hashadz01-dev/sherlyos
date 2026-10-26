import { lazy } from "react"

/** Route-level splits so the login shell does not download every operations module. */
export const DashboardPage = lazy(() =>
  import("@/pages/dashboard/DashboardPage").then((m) => ({
    default: m.DashboardPage,
  })),
)
export const NotFoundPage = lazy(() =>
  import("@/pages/errors/NotFoundPage").then((m) => ({
    default: m.NotFoundPage,
  })),
)
export const OrdersPage = lazy(() =>
  import("@/features/orders/OrdersPage").then((m) => ({
    default: m.OrdersPage,
  })),
)
export const NewOrderPage = lazy(() =>
  import("@/features/orders/OrderEditorPage").then((m) => ({
    default: m.NewOrderPage,
  })),
)
export const EditOrderPage = lazy(() =>
  import("@/features/orders/OrderEditorPage").then((m) => ({
    default: m.EditOrderPage,
  })),
)
export const OrderDetailPage = lazy(() =>
  import("@/features/orders/OrderDetailPage").then((m) => ({
    default: m.OrderDetailPage,
  })),
)
export const PickingPage = lazy(() =>
  import("@/features/picking/PickingPage").then((m) => ({
    default: m.PickingPage,
  })),
)
export const PickingExceptionsPage = lazy(() =>
  import("@/features/picking/PickingExceptionsPage").then((m) => ({
    default: m.PickingExceptionsPage,
  })),
)
export const PickingAllocatePage = lazy(() =>
  import("@/features/picking/PickingAllocatePage").then((m) => ({
    default: m.PickingAllocatePage,
  })),
)
export const PickingDetailPage = lazy(() =>
  import("@/features/picking/PickingDetailPage").then((m) => ({
    default: m.PickingDetailPage,
  })),
)
export const DispatchPage = lazy(() =>
  import("@/features/dispatch/DispatchPage").then((m) => ({
    default: m.DispatchPage,
  })),
)
export const DispatchPreparePage = lazy(() =>
  import("@/features/dispatch/DispatchPreparePage").then((m) => ({
    default: m.DispatchPreparePage,
  })),
)
export const DispatchDetailPage = lazy(() =>
  import("@/features/dispatch/DispatchDetailPage").then((m) => ({
    default: m.DispatchDetailPage,
  })),
)
export const DeliveryRunsPage = lazy(() =>
  import("@/features/dispatch/DeliveryRunsPage").then((m) => ({
    default: m.DeliveryRunsPage,
  })),
)
export const DeliveriesPage = lazy(() =>
  import("@/features/delivery-notes/DeliveriesPage").then((m) => ({
    default: m.DeliveriesPage,
  })),
)
export const NewDeliveryNotePage = lazy(() =>
  import("@/features/delivery-notes/NewDeliveryNotePage").then((m) => ({
    default: m.NewDeliveryNotePage,
  })),
)
export const DeliveryNotePrintPage = lazy(() =>
  import("@/features/delivery-notes/DeliveryNotePrintPage").then((m) => ({
    default: m.DeliveryNotePrintPage,
  })),
)
export const DeliveryNoteDetailPage = lazy(() =>
  import("@/features/delivery-notes/DeliveryNoteDetailPage").then((m) => ({
    default: m.DeliveryNoteDetailPage,
  })),
)
export const DamagePage = lazy(() =>
  import("@/features/damage/DamagePage").then((m) => ({
    default: m.DamagePage,
  })),
)
export const DamageReportsPage = lazy(() =>
  import("@/features/damage/DamageReportsPage").then((m) => ({
    default: m.DamageReportsPage,
  })),
)
export const DamageReportDetailPage = lazy(() =>
  import("@/features/damage/DamageReportDetailPage").then((m) => ({
    default: m.DamageReportDetailPage,
  })),
)
export const ReceivingPage = lazy(() =>
  import("@/features/receiving/ReceivingPage").then((m) => ({
    default: m.ReceivingPage,
  })),
)
export const ReceiptEditorPage = lazy(() =>
  import("@/features/receiving/ReceiptEditorPage").then((m) => ({
    default: m.ReceiptEditorPage,
  })),
)
export const ReceiptDetailPage = lazy(() =>
  import("@/features/receiving/ReceiptDetailPage").then((m) => ({
    default: m.ReceiptDetailPage,
  })),
)
export const StockVerificationPage = lazy(() =>
  import("@/features/stock-verification/StockVerificationPage").then((m) => ({
    default: m.StockVerificationPage,
  })),
)
export const StartVerificationPage = lazy(() =>
  import("@/features/stock-verification/StartVerificationPage").then((m) => ({
    default: m.StartVerificationPage,
  })),
)
export const VerificationDetailPage = lazy(() =>
  import("@/features/stock-verification/VerificationDetailPage").then((m) => ({
    default: m.VerificationDetailPage,
  })),
)
export const LotReconciliationPage = lazy(() =>
  import("@/features/stock-lot-reconciliation/LotReconciliationPage").then(
    (m) => ({
      default: m.LotReconciliationPage,
    }),
  ),
)
export const NewLotReconciliationPage = lazy(() =>
  import("@/features/stock-lot-reconciliation/NewLotReconciliationPage").then(
    (m) => ({
      default: m.NewLotReconciliationPage,
    }),
  ),
)
export const LotReconciliationDetailPage = lazy(() =>
  import("@/features/stock-lot-reconciliation/LotReconciliationDetailPage").then(
    (m) => ({
      default: m.LotReconciliationDetailPage,
    }),
  ),
)
export const AdjustmentsPage = lazy(() =>
  import("@/features/stock-adjustments/AdjustmentsPage").then((m) => ({
    default: m.AdjustmentsPage,
  })),
)
export const NewAdjustmentPage = lazy(() =>
  import("@/features/stock-adjustments/NewAdjustmentPage").then((m) => ({
    default: m.NewAdjustmentPage,
  })),
)
export const AdjustmentDetailPage = lazy(() =>
  import("@/features/stock-adjustments/AdjustmentDetailPage").then((m) => ({
    default: m.AdjustmentDetailPage,
  })),
)
export const RefillPage = lazy(() =>
  import("@/features/refill/RefillPage").then((m) => ({
    default: m.RefillPage,
  })),
)
export const InventoryPage = lazy(() =>
  import("@/features/inventory/InventoryPage").then((m) => ({
    default: m.InventoryPage,
  })),
)
export const OpeningStockPage = lazy(() =>
  import("@/features/inventory/OpeningStockPage").then((m) => ({
    default: m.OpeningStockPage,
  })),
)
export const TransfersPage = lazy(() =>
  import("@/features/inventory/TransfersPage").then((m) => ({
    default: m.TransfersPage,
  })),
)
export const HistoryPage = lazy(() =>
  import("@/features/inventory/HistoryPage").then((m) => ({
    default: m.HistoryPage,
  })),
)
export const MastersPage = lazy(() =>
  import("@/features/masters/MastersPage").then((m) => ({
    default: m.MastersPage,
  })),
)
export const ProductsPage = lazy(() =>
  import("@/features/masters/products/ProductsPage").then((m) => ({
    default: m.ProductsPage,
  })),
)
export const CategoriesPage = lazy(() =>
  import("@/features/masters/categories/CategoriesPage").then((m) => ({
    default: m.CategoriesPage,
  })),
)
export const SuppliersPage = lazy(() =>
  import("@/features/masters/suppliers/SuppliersPage").then((m) => ({
    default: m.SuppliersPage,
  })),
)
export const ShopsPage = lazy(() =>
  import("@/features/masters/shops/ShopsPage").then((m) => ({
    default: m.ShopsPage,
  })),
)
export const LocationsPage = lazy(() =>
  import("@/features/masters/locations/LocationsPage").then((m) => ({
    default: m.LocationsPage,
  })),
)
export const ReportsPage = lazy(() =>
  import("@/features/reports/ReportsPage").then((m) => ({
    default: m.ReportsPage,
  })),
)
export const InventoryReportPage = lazy(() =>
  import("@/features/reports/InventoryReportPage").then((m) => ({
    default: m.InventoryReportPage,
  })),
)
export const LotStockReportPage = lazy(() =>
  import("@/features/reports/LotStockReportPage").then((m) => ({
    default: m.LotStockReportPage,
  })),
)
export const MovementReportPage = lazy(() =>
  import("@/features/reports/MovementReportPage").then((m) => ({
    default: m.MovementReportPage,
  })),
)
export const OrderPickingReportPage = lazy(() =>
  import("@/features/reports/OrderPickingReportPage").then((m) => ({
    default: m.OrderPickingReportPage,
  })),
)
export const DispatchReportPage = lazy(() =>
  import("@/features/reports/DispatchReportPage").then((m) => ({
    default: m.DispatchReportPage,
  })),
)
export const ExceptionsReportPage = lazy(() =>
  import("@/features/reports/ExceptionsReportPage").then((m) => ({
    default: m.ExceptionsReportPage,
  })),
)
export const SettingsPage = lazy(() =>
  import("@/features/administration/SettingsPage").then((m) => ({
    default: m.SettingsPage,
  })),
)
export const EmployeesPage = lazy(() =>
  import("@/features/administration/employees/EmployeesPage").then((m) => ({
    default: m.EmployeesPage,
  })),
)
export const BranchesPage = lazy(() =>
  import("@/features/administration/branches/BranchesPage").then((m) => ({
    default: m.BranchesPage,
  })),
)
export const UsersRolesPage = lazy(() =>
  import("@/features/administration/users/UsersRolesPage").then((m) => ({
    default: m.UsersRolesPage,
  })),
)
export const AuditPage = lazy(() =>
  import("@/features/administration/audit/AuditPage").then((m) => ({
    default: m.AuditPage,
  })),
)
