import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { createMemoryRouter, RouterProvider } from "react-router"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { DeliveriesPage } from "@/features/delivery-notes/DeliveriesPage"
import { NewDeliveryNotePage } from "@/features/delivery-notes/NewDeliveryNotePage"

const access = vi.hoisted(() => ({
  roles: ["accounts"] as string[],
  permissions: ["delivery_notes.issue", "accounts.godowns.all"] as string[],
}))

const dnApi = vi.hoisted(() => ({
  listDeliveryNotes: vi.fn(),
  listVerifiedOrdersWithoutDn: vi.fn(),
  createDeliveryNote: vi.fn(),
}))

const ordersApi = vi.hoisted(() => ({
  getOrder: vi.fn(),
  loadOrderShops: vi.fn(),
  loadOrderBranches: vi.fn(),
  loadOrderProducts: vi.fn(),
  loadOrderLineRows: vi.fn(),
}))

const godownScope = vi.hoisted(() => ({
  loadOwnAssignedBranchIds: vi.fn(),
}))

vi.mock("@/lib/access/use-access", () => ({
  useAccess: () => ({
    loading: false,
    roles: access.roles,
    permissions: access.permissions,
    can: (permission: string) => access.permissions.includes(permission),
  }),
}))

vi.mock("@/lib/delivery-notes/api", () => ({
  listDeliveryNotes: (...args: unknown[]) => dnApi.listDeliveryNotes(...args),
  listVerifiedOrdersWithoutDn: () => dnApi.listVerifiedOrdersWithoutDn(),
  createDeliveryNote: (...args: unknown[]) => dnApi.createDeliveryNote(...args),
}))

vi.mock("@/lib/orders/api", () => ({
  getOrder: (...args: unknown[]) => ordersApi.getOrder(...args),
  loadOrderShops: () => ordersApi.loadOrderShops(),
  loadOrderBranches: () => ordersApi.loadOrderBranches(),
  loadOrderProducts: () => ordersApi.loadOrderProducts(),
  loadOrderLineRows: (...args: unknown[]) => ordersApi.loadOrderLineRows(...args),
}))

vi.mock("@/lib/access/godown-scope", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/access/godown-scope")>()
  return {
    ...actual,
    loadOwnAssignedBranchIds: () => godownScope.loadOwnAssignedBranchIds(),
  }
})

const verifiedOrder = {
  id: "ord-1",
  order_number: "SO-20261030-000025",
  shop_id: "shop-1",
  branch_id: "g1",
  source: "salesperson",
  status: "verified",
  version: 3,
  verified_at: "2026-11-02T06:48:26+00:00",
  created_at: "2026-10-30T13:11:49+00:00",
  created_by: "user-1",
}

const altOrder = {
  ...verifiedOrder,
  id: "ord-2",
  order_number: "SO-ALT-000002",
  verified_at: "2026-11-02T07:00:00+00:00",
}

function orderDetail(order: typeof verifiedOrder, openNote: null | { id: string; delivery_note_number: string; status: string } = null) {
  return {
    order,
    lines: [
      {
        id: "line-1",
        order_id: order.id,
        product_id: "prod-1",
        requested_cases: 2,
        created_at: order.created_at,
      },
    ],
    events: [],
    open_delivery_note: openNote
      ? {
          id: openNote.id,
          delivery_note_number: openNote.delivery_note_number,
          status: openNote.status,
          version: 1,
          acknowledged_at: null,
          acknowledged_by: null,
        }
      : null,
    open_picking_request: null,
    open_shipment: null,
    linked_backorder: null,
    picking_cutover: null,
  }
}

function catalogs() {
  ordersApi.loadOrderShops.mockResolvedValue([{ id: "shop-1", name: "Haritha Thevara", is_active: true }])
  ordersApi.loadOrderBranches.mockResolvedValue([
    { id: "g1", code: "G1", name: "Godown-1", is_active: true },
  ])
  ordersApi.loadOrderProducts.mockResolvedValue([
    { id: "prod-1", sku: "GOODLIFE-MILK-500ML", name: "Goodlife Milk 500ml", is_active: true },
  ])
  ordersApi.loadOrderLineRows.mockResolvedValue([{ order_id: "ord-1", requested_cases: 2 }])
}

function renderPath(path: string) {
  const router = createMemoryRouter(
    [
      { path: "/deliveries", element: <DeliveriesPage /> },
      { path: "/deliveries/new", element: <NewDeliveryNotePage /> },
      { path: "/deliveries/:noteId", element: <p>Delivery note detail</p> },
    ],
    { initialEntries: [path] },
  )
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  )
  return router
}

beforeEach(() => {
  access.roles = ["accounts"]
  access.permissions = ["delivery_notes.issue", "accounts.godowns.all"]
  catalogs()
  dnApi.listDeliveryNotes.mockResolvedValue([])
  dnApi.listVerifiedOrdersWithoutDn.mockResolvedValue([])
  dnApi.createDeliveryNote.mockReset()
  ordersApi.getOrder.mockReset()
  godownScope.loadOwnAssignedBranchIds.mockResolvedValue(["g1"])
})

describe("DN waiting queue states", () => {
  it("shows a verified order with shop, godown, cases, and create action", async () => {
    dnApi.listVerifiedOrdersWithoutDn.mockResolvedValue([verifiedOrder])
    renderPath("/deliveries")

    expect(await screen.findByRole("heading", { name: "Verified Orders Awaiting Delivery Note" })).toBeInTheDocument()
    expect(await screen.findByText("SO-20261030-000025")).toBeInTheDocument()
    expect(screen.getAllByText(/Haritha Thevara/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/Godown-1/).length).toBeGreaterThan(0)
    expect(await screen.findByText("2")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Create Delivery Note" })).toHaveAttribute(
      "href",
      "/deliveries/new?orderId=ord-1",
    )
  })

  it("treats an empty queue as empty when Accounts has company-wide godown access", async () => {
    godownScope.loadOwnAssignedBranchIds.mockResolvedValue([])
    renderPath("/deliveries")

    expect(await screen.findByText("No verified orders waiting")).toBeInTheDocument()
    expect(screen.queryByText("No godown assignment")).not.toBeInTheDocument()
  })

  it("still explains a missing assignment when company-wide godown access is absent", async () => {
    access.roles = ["salesperson"]
    access.permissions = ["delivery_notes.issue"]
    godownScope.loadOwnAssignedBranchIds.mockResolvedValue([])
    renderPath("/deliveries")

    expect(await screen.findByText("No godown assignment")).toBeInTheDocument()
    expect(screen.queryByText("No verified orders waiting")).not.toBeInTheDocument()
  })

  it("shows a genuine empty waitlist only after a godown assignment is loaded", async () => {
    renderPath("/deliveries")
    expect(await screen.findByText("No verified orders waiting")).toBeInTheDocument()
  })

  it("shows a queue error instead of an empty waitlist", async () => {
    dnApi.listVerifiedOrdersWithoutDn.mockRejectedValue(new Error("not authorized"))
    renderPath("/deliveries")
    expect(await screen.findByRole("alert")).toHaveTextContent("not authorized")
    expect(screen.queryByText("No verified orders waiting")).not.toBeInTheDocument()
  })
})

describe("New delivery note selection", () => {
  it("preselects a deep-linked verified order even when the queue is empty", async () => {
    ordersApi.getOrder.mockResolvedValue(orderDetail(verifiedOrder))
    renderPath("/deliveries/new?orderId=ord-1")

    expect(await screen.findByText("2 cases")).toBeInTheDocument()
    expect(screen.getByLabelText("Verified order")).toHaveValue("ord-1")
    expect(screen.getAllByText("SO-20261030-000025").length).toBeGreaterThan(0)
    expect(screen.getByText(/GOODLIFE-MILK-500ML/)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Create draft delivery note" })).toBeEnabled()
  })

  it("keeps the dropdown, details, and submit payload on the same order after a switch", async () => {
    dnApi.listVerifiedOrdersWithoutDn.mockResolvedValue([verifiedOrder, altOrder])
    ordersApi.getOrder.mockImplementation((id: string) =>
      Promise.resolve(orderDetail(id === "ord-2" ? altOrder : verifiedOrder)),
    )
    dnApi.createDeliveryNote.mockResolvedValue({
      delivery_note: { id: "dn-new" },
    })
    renderPath("/deliveries/new?orderId=ord-1")

    expect(await screen.findByText("2 cases")).toBeInTheDocument()
    expect(screen.getByLabelText("Verified order")).toHaveValue("ord-1")
    const user = userEvent.setup()
    await user.selectOptions(screen.getByLabelText("Verified order"), "ord-2")
    expect(await screen.findByText("SO-ALT-000002")).toBeInTheDocument()
    expect(screen.getByLabelText("Verified order")).toHaveValue("ord-2")
    await user.click(screen.getByRole("button", { name: "Create draft delivery note" }))
    expect(dnApi.createDeliveryNote).toHaveBeenCalledWith("ord-2", expect.any(String))
  })

  it("fails safely for an invalid order id and does not enable create", async () => {
    ordersApi.getOrder.mockRejectedValue(new Error("This order is not available."))
    renderPath("/deliveries/new?orderId=missing-id")
    expect(await screen.findByRole("alert")).toHaveTextContent("This order is not available.")
    expect(screen.getByRole("button", { name: "Create draft delivery note" })).toBeDisabled()
  })

  it("shows the existing note and blocks a second create", async () => {
    ordersApi.getOrder.mockResolvedValue(
      orderDetail(verifiedOrder, { id: "dn-1", delivery_note_number: "DN-1", status: "draft" }),
    )
    renderPath("/deliveries/new?orderId=ord-1")
    expect(await screen.findByRole("link", { name: "Open delivery note" })).toHaveAttribute("href", "/deliveries/dn-1")
    expect(screen.getByText(/already has an active delivery note \(DN-1\)/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Create draft delivery note" })).toBeDisabled()
  })

  it("shows acknowledged delivery notes in the godown inbox", async () => {
    access.roles = ["godown_manager"]
    access.permissions = ["delivery_notes.acknowledge", "godown_manager.godowns.all"]
    dnApi.listDeliveryNotes.mockResolvedValue([
      {
        id: "dn-16",
        delivery_note_number: "DN-20261105-000016",
        order_id: "ord-1",
        shop_id: "shop-1",
        branch_id: "g1",
        status: "acknowledged",
        version: 4,
        idempotency_key: "key-1",
        created_by: "user-1",
        generated_at: "2026-11-05T10:30:00+00:00",
        generated_by: "user-1",
        sent_at: "2026-11-05T10:35:33+00:00",
        sent_by: "user-1",
        acknowledged_at: "2026-11-05T10:37:49+00:00",
        acknowledged_by: "gm-1",
        voided_at: null,
        voided_by: null,
        void_reason: null,
        created_at: "2026-11-05T10:20:00+00:00",
        updated_at: "2026-11-05T10:37:49+00:00",
        order_number: "SO-20261105-000028",
        total_cases: 1,
      },
    ])
    renderPath("/deliveries")

    expect(await screen.findByText("DN-20261105-000016")).toBeInTheDocument()
    expect(screen.getByText("acknowledged")).toBeInTheDocument()
    expect(screen.getByText(/Acknowledged 2026-11-05 10:37:49/)).toBeInTheDocument()
    expect(screen.queryByText("No sent delivery notes")).not.toBeInTheDocument()
    expect(dnApi.listDeliveryNotes).toHaveBeenCalledWith(
      expect.objectContaining({ status: "all" }),
    )
  })

  it("offers create when Accounts has company-wide godown access without an assignment", async () => {
    godownScope.loadOwnAssignedBranchIds.mockResolvedValue([])
    ordersApi.getOrder.mockResolvedValue(orderDetail(verifiedOrder))
    renderPath("/deliveries/new?orderId=ord-1")
    expect(await screen.findByText("2 cases")).toBeInTheDocument()
    expect(screen.getByLabelText("Verified order")).toHaveValue("ord-1")
    expect(screen.getByRole("button", { name: "Create draft delivery note" })).toBeEnabled()
  })
})
