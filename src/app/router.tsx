import { createBrowserRouter, type RouteObject } from "react-router"
import { AppShell } from "@/app/layouts/AppShell"
import { DamagePage } from "@/features/damage/DamagePage"
import { SettingsPage } from "@/features/administration/SettingsPage"
import { DeliveriesPage } from "@/features/dispatch/DeliveriesPage"
import { InventoryPage } from "@/features/inventory/InventoryPage"
import { MastersPage } from "@/features/masters/MastersPage"
import { OrdersPage } from "@/features/orders/OrdersPage"
import { ReceivingPage } from "@/features/receiving/ReceivingPage"
import { RefillPage } from "@/features/refill/RefillPage"
import { ReportsPage } from "@/features/reports/ReportsPage"
import { StockVerificationPage } from "@/features/stock-verification/StockVerificationPage"
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
          { path: "reports", element: <ReportsPage /> },
          { path: "settings", element: <SettingsPage /> },
          { path: "*", element: <NotFoundPage /> },
        ],
      },
    ],
  },
]

export const router = createBrowserRouter(appRouteObjects)
