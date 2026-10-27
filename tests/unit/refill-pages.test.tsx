import type { ReactNode } from "react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { RefillDetailPage } from "@/features/refill/RefillDetailPage"
import { RefillPage } from "@/features/refill/RefillPage"

const listStockRefillRequests = vi.fn()
const getStockRefillRequest = vi.fn()
const listStockRefillOptions = vi.fn()

vi.mock("@/lib/refill/api", () => ({
  listStockRefillRequests: (...args: unknown[]) => listStockRefillRequests(...args),
  getStockRefillRequest: (...args: unknown[]) => getStockRefillRequest(...args),
  listStockRefillOptions: (...args: unknown[]) => listStockRefillOptions(...args),
  submitStockRefillRequest: vi.fn(),
  approveStockRefillRequest: vi.fn(),
  holdStockRefillRequest: vi.fn(),
  rejectStockRefillRequest: vi.fn(),
}))

vi.mock("@/lib/access/use-access", () => ({
  useAccess: () => ({
    loading: false,
    can: (permission: string) =>
      permission === "refill.request" || permission === "refill.approve",
  }),
}))

vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({ session: { user: { id: "acct" } } }),
}))

vi.mock("@/hooks/use-document-title", () => ({
  useDocumentTitle: () => undefined,
}))

function renderAt(path: string, element: ReactNode) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path="/refill" element={<RefillPage />} />
          <Route path="/refill/:requestId" element={element} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe("refill pages", () => {
  beforeEach(() => {
    listStockRefillRequests.mockReset()
    getStockRefillRequest.mockReset()
    listStockRefillOptions.mockReset()
    listStockRefillOptions.mockResolvedValue({
      godowns: [{ id: "g1", code: "G1", name: "Main", is_active: true }],
      suppliers: [{ id: "s1", name: "Brand", is_active: true }],
      products: [
        {
          id: "p1",
          sku: "SKU-1",
          name: "Soap",
          supplier_id: "s1",
          is_active: true,
        },
      ],
    })
  })

  it("lists refill requests with status and case counts", async () => {
    listStockRefillRequests.mockResolvedValue({
      total: 1,
      page: 1,
      page_size: 25,
      items: [
        {
          id: "r1",
          request_number: "RF-20261027-000001",
          supplier_id: "s1",
          supplier_name: "Brand",
          destination_godown_id: "g1",
          godown_code: "G1",
          godown_name: "Main",
          godown_active: true,
          status: "submitted",
          version: 2,
          total_requested_cases: 4,
          created_at: "2026-10-27T00:00:00Z",
          submitted_at: "2026-10-27T01:00:00Z",
          created_by: "acct",
        },
      ],
    })
    renderAt("/refill", <RefillPage />)
    expect(
      await screen.findByRole("link", { name: "RF-20261027-000001" }),
    ).toBeInTheDocument()
    expect(screen.getByText("4 cases")).toBeInTheDocument()
    expect(screen.getByText("Brand")).toBeInTheDocument()
  })

  it("shows the no-stock-receipt warning and Admin actions on a submitted request", async () => {
    getStockRefillRequest.mockResolvedValue({
      id: "r1",
      request_number: "RF-20261027-000002",
      supplier_id: "s1",
      supplier_name: "Brand",
      destination_godown_id: "g1",
      godown_code: "G1",
      godown_name: "Main",
      godown_active: true,
      status: "submitted",
      notes: null,
      version: 2,
      created_by: "acct",
      creator_name: "Accounts",
      created_at: "2026-10-27T00:00:00Z",
      updated_by: "acct",
      updated_at: "2026-10-27T01:00:00Z",
      submitted_by: "acct",
      submitted_at: "2026-10-27T01:00:00Z",
      held_by: null,
      held_at: null,
      hold_reason: null,
      decided_by: null,
      decided_at: null,
      decision_reason: null,
      total_requested_cases: 3,
      lines: [
        {
          id: "l1",
          product_id: "p1",
          product_sku: "SKU-1",
          product_name: "Soap",
          requested_cases: 3,
        },
      ],
      events: [
        {
          id: "e1",
          action: "submitted",
          previous_status: "draft",
          next_status: "submitted",
          reason: null,
          version: 2,
          actor_id: "acct",
          actor_name: "Accounts",
          created_at: "2026-10-27T01:00:00Z",
        },
      ],
    })
    renderAt("/refill/r1", <RefillDetailPage />)
    expect(await screen.findByText("RF-20261027-000002")).toBeInTheDocument()
    expect(
      screen.getByText(/Admin approval is not a stock receipt/i),
    ).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Approve" })).toBeInTheDocument()
    expect(screen.getByText("Submitted for Admin review")).toBeInTheDocument()
  })
})
