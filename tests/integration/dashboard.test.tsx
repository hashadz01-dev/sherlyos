import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { createMemoryRouter, RouterProvider } from "react-router"
import { describe, expect, it, vi } from "vitest"
import { AppShell } from "@/app/layouts/AppShell"
import { DashboardPage } from "@/pages/dashboard/DashboardPage"

const access = vi.hoisted(() => ({
  permissions: [] as string[],
}))

const reports = vi.hoisted(() => ({
  getOperationsDashboard: vi.fn(),
}))

vi.mock("@/lib/access/use-access", () => ({
  useAccess: () => ({
    loading: false,
    roles: [],
    permissions: access.permissions,
    can: (permission: string) => access.permissions.includes(permission),
  }),
}))

vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({
    configured: true,
    loading: false,
    session: { user: { id: "user-ada", email: "ada@example.com" } },
    signIn: vi.fn(),
    signOut: vi.fn(),
  }),
}))

vi.mock("@/lib/reports/api", async () => {
  const actual = await vi.importActual<typeof import("@/lib/reports/api")>(
    "@/lib/reports/api",
  )
  return { ...actual, getOperationsDashboard: reports.getOperationsDashboard }
})

vi.mock("@/features/inventory/location-options", () => ({
  useStockLocations: () => ({
    branches: {
      data: [
        { id: "b1", code: "G1", name: "Main", is_active: true },
        { id: "b0", code: "G0", name: "Closed godown", is_active: false },
      ],
    },
    zones: { data: [] },
    crates: { data: [] },
    products: { data: [] },
  }),
}))

function renderDashboard() {
  const router = createMemoryRouter(
    [
      {
        path: "/",
        element: <AppShell />,
        children: [{ index: true, element: <DashboardPage /> }],
      },
    ],
    { initialEntries: ["/"] },
  )
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  render(
    <QueryClientProvider client={client}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  )
}

describe("dashboard", () => {
  it("shows the overview without sample operational figures when reporting is unauthorized", () => {
    access.permissions = []
    renderDashboard()

    expect(
      screen.getByRole("heading", { name: "Operations Overview" }),
    ).toBeInTheDocument()
    expect(
      screen.getByText(/no operational reporting permission/i),
    ).toBeInTheDocument()
    expect(screen.queryByText("ORD-001")).not.toBeInTheDocument()
    expect(screen.queryByText("48")).not.toBeInTheDocument()
    expect(
      screen.getByRole("navigation", { name: "Primary" }),
    ).toBeInTheDocument()
  })

  it("renders authoritative KPI cards without inventing available-to-pick", async () => {
    access.permissions = ["stock.read", "operations.monitor"]
    reports.getOperationsDashboard.mockResolvedValue({
      timezone: "UTC",
      filter_branch: null,
      authorized_branches: [{ id: "b1", code: "G1", name: "Main" }],
      cutover: { dual_write_enabled: false, aggregate_only_blocked: false },
      inventory: {
        visible: true,
        total_cartons_on_hand: 10,
        products_with_positive_stock: 1,
        stock_by_godown: [
          { branch_id: "b1", branch_code: "G1", branch_name: "Main", cartons: 8 },
          { branch_id: "b0", branch_code: "G0", branch_name: "Closed godown", cartons: 2 },
        ],
        lot_attributed_cartons: 0,
        legacy_unattributed_cartons: 0,
        active_reserved_cartons: 0,
        available_to_pick: {
          state: "not_applicable",
          reason: "lot_aware_allocation_inactive",
          value: null,
        },
      },
      orders: { visible: false },
      picking: { visible: false },
      dispatch: { visible: false },
      deliveries: { visible: false },
      operations: { visible: true, pending_receiving: 0, pending_adjustments: 0, pending_verification: 0, unclassified_products: 0, pending_physical_returns: 0 },
    })
    renderDashboard()

    expect(await screen.findByText("Cartons on hand")).toBeInTheDocument()
    expect(screen.getAllByText("10").length).toBeGreaterThan(0)
    expect(screen.getByText("Available to pick")).toBeInTheDocument()
    expect(
      screen.getByText(/Lot-aware allocation is inactive/i),
    ).toBeInTheDocument()
    expect(screen.getByText(/Inactive \/ Historical/i)).toBeInTheDocument()
    expect(screen.getByText(/include inactive godown stock/i)).toBeInTheDocument()
    expect(screen.getByRole("option", { name: "Closed godown (G0) (inactive)" })).toBeInTheDocument()
    expect(screen.getByText("Closed godown")).toBeInTheDocument()
    expect(screen.getByText("Inactive (historical)")).toBeInTheDocument()
    expect(screen.queryByText("Orders Today")).not.toBeInTheDocument()
  })
})
