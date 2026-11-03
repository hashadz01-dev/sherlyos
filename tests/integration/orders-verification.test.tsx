import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { createMemoryRouter, RouterProvider } from "react-router"
import { describe, expect, it, vi } from "vitest"
import { OrderVerificationPage } from "@/features/orders/OrdersPage"

const access = vi.hoisted(() => ({
  permissions: ["orders.verify"] as string[],
}))

const ordersApi = vi.hoisted(() => ({
  listOrders: vi.fn(),
  loadOrderShops: vi.fn(),
  loadOrderBranches: vi.fn(),
  loadOrderCaseTotals: vi.fn(),
}))

vi.mock("@/lib/access/use-access", () => ({
  useAccess: () => ({
    loading: false,
    roles: ["accounts"],
    permissions: access.permissions,
    can: (permission: string) => access.permissions.includes(permission),
  }),
}))

vi.mock("@/lib/orders/api", () => ({
  listOrders: (...args: unknown[]) => ordersApi.listOrders(...args),
  loadOrderShops: () => ordersApi.loadOrderShops(),
  loadOrderBranches: () => ordersApi.loadOrderBranches(),
  loadOrderCaseTotals: (...args: unknown[]) => ordersApi.loadOrderCaseTotals(...args),
}))

function renderQueue() {
  const router = createMemoryRouter(
    [{ path: "/orders/verification", element: <OrderVerificationPage /> }],
    { initialEntries: ["/orders/verification"] },
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

describe("order verification queue", () => {
  it("shows a submitted order when the user has a godown assignment", async () => {
    access.permissions = ["orders.verify"]
    ordersApi.listOrders.mockResolvedValue([
      {
        id: "ord-1",
        order_number: "SO-20261030-000025",
        shop_id: "shop-1",
        branch_id: "g1",
        source: "salesperson",
        status: "submitted",
        submitted_at: "2026-10-30T13:19:03+00:00",
        created_at: "2026-10-30T13:11:49+00:00",
      },
      {
        id: "ord-2",
        order_number: "SO-HIDDEN",
        shop_id: "shop-2",
        branch_id: "g2",
        source: "salesperson",
        status: "submitted",
        submitted_at: "2026-10-30T14:00:00+00:00",
        created_at: "2026-10-30T14:00:00+00:00",
      },
    ])
    ordersApi.loadOrderShops.mockResolvedValue([
      { id: "shop-1", name: "Haritha Thevara", is_active: true },
      { id: "shop-2", name: "Other Shop", is_active: true },
    ])
    ordersApi.loadOrderBranches.mockResolvedValue([
      { id: "g1", code: "G1", name: "Godown-1", is_active: true },
    ])
    ordersApi.loadOrderCaseTotals.mockResolvedValue(new Map([["ord-1", 2], ["ord-2", 4]]))
    renderQueue()

    expect(await screen.findByRole("heading", { name: "Order verification" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "New order" })).not.toBeInTheDocument()
    expect(await screen.findByText("SO-20261030-000025")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /SO-20261030-000025/ })).toHaveAttribute(
      "href",
      "/orders/verification/ord-1",
    )
    expect(screen.getAllByText(/Haritha Thevara/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/Requested cases/).length).toBeGreaterThan(0)
    expect(await screen.findByText("2")).toBeInTheDocument()
    expect(screen.getAllByText(/Submitted \/ Awaiting Verification/).length).toBeGreaterThan(0)

    const user = userEvent.setup()
    await user.type(screen.getByLabelText("Search order number or shop"), "Haritha")
    expect(screen.getByText("SO-20261030-000025")).toBeInTheDocument()
    expect(screen.queryByText("SO-HIDDEN")).not.toBeInTheDocument()
  })

  it("does not show a godown-assignment banner when the queue is empty", async () => {
    access.permissions = ["orders.verify"]
    ordersApi.listOrders.mockResolvedValue([])
    ordersApi.loadOrderShops.mockResolvedValue([])
    ordersApi.loadOrderBranches.mockResolvedValue([])
    ordersApi.loadOrderCaseTotals.mockResolvedValue(new Map())
    renderQueue()

    expect(await screen.findByText("No orders in verification")).toBeInTheDocument()
    expect(screen.queryByText(/You are not assigned to Godown-1/i)).not.toBeInTheDocument()
  })

  it("lists a previously verified order on the default verification queue", async () => {
    access.permissions = ["orders.verify"]
    ordersApi.listOrders.mockResolvedValue([
      {
        id: "ord-25",
        order_number: "SO-20261030-000025",
        shop_id: "shop-1",
        branch_id: "g1",
        source: "salesperson",
        status: "verified",
        submitted_at: "2026-10-30T13:19:03+00:00",
        created_at: "2026-10-30T13:11:49+00:00",
      },
    ])
    ordersApi.loadOrderShops.mockResolvedValue([
      { id: "shop-1", name: "Haritha Thevara", is_active: true },
    ])
    ordersApi.loadOrderBranches.mockResolvedValue([
      { id: "g1", code: "G1", name: "Godown-1", is_active: true },
    ])
    ordersApi.loadOrderCaseTotals.mockResolvedValue(new Map([["ord-25", 2]]))
    renderQueue()

    expect(await screen.findByText("SO-20261030-000025")).toBeInTheDocument()
    expect(screen.getAllByText("Verified").length).toBeGreaterThan(0)
    expect(ordersApi.listOrders).toHaveBeenCalledWith("all")
    expect(screen.queryByText("No submitted orders")).not.toBeInTheDocument()
  })
})
