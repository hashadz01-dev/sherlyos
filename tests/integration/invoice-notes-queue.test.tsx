import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { createMemoryRouter, RouterProvider } from "react-router"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { InvoicesPage } from "@/features/invoices/InvoicesPage"
import { INVOICE_AWAITING_QUEUE_TITLE } from "@/lib/invoices/rules"

const access = vi.hoisted(() => ({
  roles: ["accounts"] as string[],
  permissions: ["invoices.review"] as string[],
}))

const invoiceApi = vi.hoisted(() => ({
  listInvoiceNotes: vi.fn(),
  listInvoiceEligibleDispatches: vi.fn(),
  prepareInvoiceNote: vi.fn(),
}))

vi.mock("@/lib/access/use-access", () => ({
  useAccess: () => ({
    loading: false,
    roles: access.roles,
    permissions: access.permissions,
    can: (permission: string) => access.permissions.includes(permission),
  }),
}))

vi.mock("@/lib/invoices/api", () => ({
  invoiceKeys: {
    list: (status: string, branchId: string, shopId: string) =>
      ["invoice-notes", status, branchId, shopId] as const,
    eligible: ["invoice-eligible-dispatches"] as const,
  },
  listInvoiceNotes: (...args: unknown[]) => invoiceApi.listInvoiceNotes(...args),
  listInvoiceEligibleDispatches: () => invoiceApi.listInvoiceEligibleDispatches(),
  prepareInvoiceNote: (...args: unknown[]) => invoiceApi.prepareInvoiceNote(...args),
}))

const deliveredOrder = {
  dispatch_id: "5c1dcd85-c2d2-4ebc-99f2-7b6788d8afc9",
  dispatch_number: "DS-20261102-000001",
  order_id: "2558cf41-e600-4b92-9e2a-e12035123475",
  order_number: "SO-20261030-000025",
  shop_id: "shop-1",
  shop_name: "Haritha Thevara",
  branch_id: "g1",
  status: "delivered",
  dispatched_at: "2026-11-02T09:14:25.594Z",
}

function renderInvoices() {
  const router = createMemoryRouter(
    [
      { path: "/invoices", element: <InvoicesPage /> },
      { path: "/orders/:orderId", element: <p>Order detail</p> },
    ],
    { initialEntries: ["/invoices"] },
  )
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  access.roles = ["accounts"]
  access.permissions = ["invoices.review"]
  invoiceApi.listInvoiceNotes.mockResolvedValue([])
  invoiceApi.listInvoiceEligibleDispatches.mockResolvedValue([])
  invoiceApi.prepareInvoiceNote.mockReset()
})

describe("Invoice notes awaiting queue", () => {
  it("shows the delivered order to Accounts before a draft exists", async () => {
    invoiceApi.listInvoiceEligibleDispatches.mockResolvedValue([deliveredOrder])
    renderInvoices()

    expect(
      await screen.findByRole("heading", { name: INVOICE_AWAITING_QUEUE_TITLE }),
    ).toBeInTheDocument()
    expect(await screen.findByText("SO-20261030-000025")).toBeInTheDocument()
    expect(screen.getByText(/DS-20261102-000001/)).toBeInTheDocument()
    expect(screen.getByText("Haritha Thevara", { exact: false })).toBeInTheDocument()
    expect(screen.getByText("Delivered")).toBeInTheDocument()
    expect(screen.getByText("Awaiting draft")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Prepare draft" })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: /SO-20261030-000025/ })).toHaveAttribute(
      "href",
      "/orders/2558cf41-e600-4b92-9e2a-e12035123475",
    )
  })

  it("does not keep the awaiting order under Reviewed or Cancelled", async () => {
    invoiceApi.listInvoiceEligibleDispatches.mockResolvedValue([deliveredOrder])
    renderInvoices()
    expect(await screen.findByText("SO-20261030-000025")).toBeInTheDocument()

    await userEvent.selectOptions(screen.getByLabelText("Status"), "reviewed")
    expect(screen.queryByText("SO-20261030-000025")).not.toBeInTheDocument()
    expect(screen.queryByRole("heading", { name: INVOICE_AWAITING_QUEUE_TITLE })).not.toBeInTheDocument()
    expect(screen.getByText("No reviewed invoice notes.")).toBeInTheDocument()

    await userEvent.selectOptions(screen.getByLabelText("Status"), "cancelled")
    expect(screen.queryByText("SO-20261030-000025")).not.toBeInTheDocument()
    expect(screen.getByText("No cancelled invoice notes.")).toBeInTheDocument()
  })

  it("keeps Prepare draft on the same order for Godown Manager", async () => {
    access.roles = ["godown_manager"]
    access.permissions = ["invoice_notes.prepare"]
    invoiceApi.listInvoiceEligibleDispatches.mockResolvedValue([deliveredOrder])
    renderInvoices()

    expect(
      await screen.findByRole("heading", { name: "Prepare from confirmed dispatch" }),
    ).toBeInTheDocument()
    expect(await screen.findByText("SO-20261030-000025")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Prepare draft" })).toBeInTheDocument()
  })
})
