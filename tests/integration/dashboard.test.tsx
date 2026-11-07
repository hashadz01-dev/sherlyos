import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { createMemoryRouter, RouterProvider } from "react-router"
import { describe, expect, it, vi } from "vitest"
import { AppShell } from "@/app/layouts/AppShell"
import { DashboardPage } from "@/pages/dashboard/DashboardPage"

const access = vi.hoisted(() => ({
  permissions: [] as string[],
  roles: [] as string[],
}))

const reports = vi.hoisted(() => ({
  getOperationsDashboard: vi.fn(),
}))

const damageApi = vi.hoisted(() => ({
  getDamageDashboard: vi.fn(),
}))

vi.mock("@/lib/access/use-access", () => ({
  useAccess: () => ({
    loading: false,
    roles: access.roles,
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

vi.mock("@/lib/damage/api", async () => {
  const actual = await vi.importActual<typeof import("@/lib/damage/api")>(
    "@/lib/damage/api",
  )
  return { ...actual, getDamageDashboard: damageApi.getDamageDashboard }
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
    access.roles = []
    renderDashboard()

    expect(
      screen.getByRole("heading", { name: "Operations Dashboard" }),
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
    access.roles = ["godown_manager"]
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
          {
            branch_id: "b0",
            branch_code: "G0",
            branch_name: "Closed godown",
            cartons: 2,
          },
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
      operations: {
        visible: true,
        pending_receiving: 0,
        pending_adjustments: 0,
        pending_verification: 0,
        unclassified_products: 0,
        pending_physical_returns: 0,
      },
    })
    renderDashboard()

    expect(
      (await screen.findAllByText("Cartons on hand")).length,
    ).toBeGreaterThan(0)
    expect(screen.getAllByText("10").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Available to pick").length).toBeGreaterThan(0)
    expect(
      screen.getAllByText(/Lot-aware allocation is inactive/i).length,
    ).toBeGreaterThan(0)
    expect(screen.getByText(/Inactive \/ Historical/i)).toBeInTheDocument()
    expect(
      screen.getByText(/include inactive godown stock/i),
    ).toBeInTheDocument()
    expect(
      screen.getByRole("option", { name: "Closed godown (G0) (inactive)" }),
    ).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Stock Distribution" })).toBeInTheDocument()
    expect(screen.queryByText("Orders Today")).not.toBeInTheDocument()
    expect(screen.getAllByText(/Current Snapshot/i).length).toBeGreaterThan(0)
    expect(
      screen.getByText(/Period metrics \(.+\) stay unavailable/i),
    ).toBeInTheDocument()
    expect(screen.getByText(/Packing handoffs/i)).toBeInTheDocument()
    expect(screen.getByText(/Dispatches confirmed/i)).toBeInTheDocument()
    expect(
      screen.getByRole("combobox", { name: /Reporting period/i }),
    ).toBeDisabled()
    expect(
      screen.queryByRole("link", { name: /Open Verified orders/i }),
    ).not.toBeInTheDocument()
    expect(
      screen.getByRole("heading", { name: "Needs Your Attention" }),
    ).toBeInTheDocument()
    expect(screen.getByText(/Godown Manager/i)).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Inventory Availability" })).toBeInTheDocument()
  })

  it("scopes submitted counts and keeps verification navigation authorized", async () => {
    access.permissions = ["orders.verify", "stock.read"]
    access.roles = ["accounts"]
    reports.getOperationsDashboard.mockResolvedValue({
      timezone: "UTC",
      filter_branch: null,
      authorized_branches: [],
      cutover: { dual_write_enabled: false, aggregate_only_blocked: false },
      inventory: {
        visible: true,
        total_cartons_on_hand: 0,
        products_with_positive_stock: 0,
        stock_by_godown: [],
        lot_attributed_cartons: 0,
        legacy_unattributed_cartons: 0,
        active_reserved_cartons: 0,
        available_to_pick: {
          state: "not_applicable",
          reason: "lot_aware_allocation_inactive",
          value: null,
        },
      },
      orders: {
        visible: true,
        draft: 0,
        submitted: 0,
        held: 0,
        verified: 0,
        cancelled: 0,
        awaiting_picking: 0,
      },
      picking: { visible: false },
      dispatch: { visible: false },
      deliveries: { visible: false },
      operations: { visible: false },
    })
    renderDashboard()

    expect((await screen.findAllByText("Submitted")).length).toBeGreaterThan(0)
    expect(
      screen.queryByText(/You are not assigned to Godown-1/i),
    ).not.toBeInTheDocument()
    expect(
      screen.getByRole("link", { name: "Open Verified orders" }),
    ).toHaveAttribute("href", "/orders/verification")
    expect(
      screen.getByRole("link", { name: "Order verification" }),
    ).toBeInTheDocument()
    expect(
      screen.queryByRole("link", { name: "Employees" }),
    ).not.toBeInTheDocument()
  })

  it("joins damage attention queues when damage.read is granted", async () => {
    access.permissions = ["stock.read", "damage.read"]
    access.roles = ["store_keeper"]
    reports.getOperationsDashboard.mockResolvedValue({
      timezone: "UTC",
      filter_branch: null,
      authorized_branches: [{ id: "b1", code: "G1", name: "Main" }],
      cutover: { dual_write_enabled: false, aggregate_only_blocked: false },
      inventory: {
        visible: true,
        total_cartons_on_hand: 4,
        products_with_positive_stock: 1,
        stock_by_godown: [
          { branch_id: "b1", branch_code: "G1", branch_name: "Main", cartons: 4 },
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
      operations: { visible: false },
    })
    damageApi.getDamageDashboard.mockResolvedValue({
      stock_hold_ready: true,
      totals: {
        reports: 3,
        pending_verification: 2,
        verified: 1,
        active_hold_cases: 5,
        quarantined_cases: 1,
        pending_exceptional: 0,
        ordinary_writeoff_cases: 0,
        exceptional_writeoff_cases: 0,
        returned_supplier_cases: 0,
      },
      queues: {
        recent_submitted: [],
        awaiting_verification: [],
        awaiting_disposition: [],
        exceptional_pending: [],
        recently_resolved: [],
      },
    })
    renderDashboard()

    expect(
      await screen.findByText("Damage awaiting verification"),
    ).toBeInTheDocument()
    expect(screen.getByText("Active damage holds")).toBeInTheDocument()
    expect(
      screen.getByRole("link", { name: /Damage awaiting verification/i }),
    ).toHaveAttribute("href", "/damage/verification")
  })
})
