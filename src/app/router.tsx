import { createBrowserRouter, type RouteObject } from "react-router"
import { AppShell } from "@/app/layouts/AppShell"
import { AuditPage } from "@/features/administration/audit/AuditPage"
import { BranchesPage } from "@/features/administration/branches/BranchesPage"
import { EmployeesPage } from "@/features/administration/employees/EmployeesPage"
import { UsersRolesPage } from "@/features/administration/users/UsersRolesPage"
import { DamagePage } from "@/features/damage/DamagePage"
import { SettingsPage } from "@/features/administration/SettingsPage"
import { DeliveriesPage } from "@/features/dispatch/DeliveriesPage"
import { InventoryPage } from "@/features/inventory/InventoryPage"
import { CategoriesPage } from "@/features/masters/categories/CategoriesPage"
import { LocationsPage } from "@/features/masters/locations/LocationsPage"
import { MastersPage } from "@/features/masters/MastersPage"
import { ProductsPage } from "@/features/masters/products/ProductsPage"
import { ShopsPage } from "@/features/masters/shops/ShopsPage"
import { SuppliersPage } from "@/features/masters/suppliers/SuppliersPage"
import { OrdersPage } from "@/features/orders/OrdersPage"
import { ReceivingPage } from "@/features/receiving/ReceivingPage"
import { RefillPage } from "@/features/refill/RefillPage"
import { ReportsPage } from "@/features/reports/ReportsPage"
import { StockVerificationPage } from "@/features/stock-verification/StockVerificationPage"
import { RequirePermission } from "@/lib/access/RequirePermission"
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
          { path: "orders", element: <OrdersPage /> },
          { path: "deliveries", element: <DeliveriesPage /> },
          { path: "damage", element: <DamagePage /> },
          { path: "receiving", element: <ReceivingPage /> },
          { path: "stock-verification", element: <StockVerificationPage /> },
          { path: "refill", element: <RefillPage /> },
          { path: "inventory", element: <InventoryPage /> },
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
          { path: "reports", element: <ReportsPage /> },
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
