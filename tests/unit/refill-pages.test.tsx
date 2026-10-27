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
  recordStockRefillSupplierCommunication: vi.fn(),
  recordStockRefillSupplierAcknowledgement: vi.fn(),
  recordStockRefillSupplierDispatch: vi.fn(),
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
          communication_status: "not_sent",
          acknowledgement_status: "none",
          dispatch_status: "not_recorded",
          expected_arrival_on: null,
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
    expect(screen.getAllByText("Brand").length).toBeGreaterThan(0)
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
      communication_status: "not_sent",
      acknowledgement_status: "none",
      dispatch_status: "not_recorded",
      expected_arrival_on: null,
      communication: null,
      dispatch: null,
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

  it("shows manual send controls and no-inventory copy on an approved request", async () => {
    getStockRefillRequest.mockResolvedValue({
      id: "r2",
      request_number: "RF-20261027-000003",
      supplier_id: "s1",
      supplier_name: "Brand",
      destination_godown_id: "g1",
      godown_code: "G1",
      godown_name: "Main",
      godown_active: true,
      status: "approved",
      communication_status: "not_sent",
      acknowledgement_status: "none",
      dispatch_status: "not_recorded",
      expected_arrival_on: null,
      communication: null,
      dispatch: null,
      notes: null,
      version: 3,
      created_by: "acct",
      creator_name: "Accounts",
      created_at: "2026-10-27T00:00:00Z",
      updated_by: "admin",
      updated_at: "2026-10-27T02:00:00Z",
      submitted_by: "acct",
      submitted_at: "2026-10-27T01:00:00Z",
      held_by: null,
      held_at: null,
      hold_reason: null,
      decided_by: "admin",
      decided_at: "2026-10-27T02:00:00Z",
      decision_reason: null,
      total_requested_cases: 3,
      receiving: {
        summary: {
          requested_cases: 3,
          reserved_cases: 1,
          draft_reserved_cases: 0,
          accepted_cases: 1,
          outstanding_cases: 2,
          excess_cases: 0,
          damaged_cases: 1,
          pending_receipt_cases: 0,
          completion_label: "partially_received",
        },
        lines: [
          {
            product_id: "p1",
            product_sku: "SKU-1",
            product_name: "Soap",
            requested_cases: 3,
            reserved_cases: 1,
            draft_reserved_cases: 0,
            accepted_cases: 1,
            outstanding_cases: 2,
            excess_cases: 0,
            damaged_cases: 1,
            pending_receipt_cases: 0,
          },
        ],
        receipts: [
          {
            id: "rc1",
            receipt_number: "RC-20261027-000001",
            status: "posted",
            document_reference: "INV-P1",
            received_date: "2026-10-27",
            verified_at: "2026-10-27T03:00:00Z",
            posted_at: "2026-10-27T03:00:00Z",
            accepted_cases: 1,
            damaged_cases: 1,
            counted_cases: 2,
          },
        ],
      },
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
          action: "approved",
          previous_status: "submitted",
          next_status: "approved",
          reason: null,
          version: 3,
          actor_id: "admin",
          actor_name: "Admin",
          created_at: "2026-10-27T02:00:00Z",
        },
      ],
    })
    renderAt("/refill/r2", <RefillDetailPage />)
    expect(await screen.findByText("RF-20261027-000003")).toBeInTheDocument()
    expect(
      screen.getByRole("heading", { name: "Supplier communication & dispatch" }),
    ).toBeInTheDocument()
    expect(
      screen.getByRole("button", { name: "Mark as sent — manually recorded" }),
    ).toBeInTheDocument()
    expect(
      screen.getByText(/Supplier dispatch does not add inventory/i),
    ).toBeInTheDocument()
    expect(
      screen.getByRole("heading", { name: "Receiving & reconciliation" }),
    ).toBeInTheDocument()
    expect(screen.getByText("Partially received")).toBeInTheDocument()
    expect(screen.getByText("RC-20261027-000001")).toBeInTheDocument()
    expect(
      screen.getByText(/Accounts cannot post receiving/i),
    ).toBeInTheDocument()
  })

  it("shows draft reservation separately and does not link receipts for Accounts", async () => {
    getStockRefillRequest.mockResolvedValue({
      id: "r3",
      request_number: "RF-20261027-000004",
      supplier_id: "s1",
      supplier_name: "Brand",
      destination_godown_id: "g1",
      godown_code: "G1",
      godown_name: "Main",
      godown_active: true,
      status: "approved",
      communication_status: "sent",
      acknowledgement_status: "acknowledged",
      dispatch_status: "recorded",
      expected_arrival_on: "2026-10-30",
      communication: null,
      dispatch: null,
      notes: null,
      version: 5,
      created_by: "acct",
      creator_name: "Accounts",
      created_at: "2026-10-27T00:00:00Z",
      updated_by: "acct",
      updated_at: "2026-10-27T04:00:00Z",
      submitted_by: "acct",
      submitted_at: "2026-10-27T01:00:00Z",
      held_by: null,
      held_at: null,
      hold_reason: null,
      decided_by: "admin",
      decided_at: "2026-10-27T02:00:00Z",
      decision_reason: null,
      total_requested_cases: 10,
      receiving: {
        summary: {
          requested_cases: 10,
          reserved_cases: 4,
          draft_reserved_cases: 4,
          accepted_cases: 0,
          outstanding_cases: 10,
          excess_cases: 0,
          damaged_cases: 0,
          pending_receipt_cases: 0,
          completion_label: "not_started",
        },
        lines: [
          {
            product_id: "p1",
            product_sku: "SKU-1",
            product_name: "Soap",
            requested_cases: 10,
            reserved_cases: 4,
            draft_reserved_cases: 4,
            accepted_cases: 0,
            outstanding_cases: 10,
            excess_cases: 0,
            damaged_cases: 0,
            pending_receipt_cases: 0,
          },
        ],
        receipts: [
          {
            id: "rc-draft",
            receipt_number: "RC-20261027-000099",
            status: "draft",
            document_reference: "VAN-1",
            received_date: "2026-10-27",
            verified_at: null,
            posted_at: null,
            accepted_cases: 4,
            damaged_cases: 0,
            counted_cases: 4,
          },
        ],
      },
      lines: [
        {
          id: "l1",
          product_id: "p1",
          product_sku: "SKU-1",
          product_name: "Soap",
          requested_cases: 10,
        },
      ],
      events: [],
    })
    renderAt("/refill/r3", <RefillDetailPage />)
    expect(await screen.findByText("Reserved on drafts")).toBeInTheDocument()
    expect(
      screen.getByText(/Draft receipts still reserve requested quantity/i),
    ).toBeInTheDocument()
    expect(screen.getByText("RC-20261027-000099")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "RC-20261027-000099" })).not.toBeInTheDocument()
    expect(
      screen.getByText(/Accounts cannot cancel receiving documents/i),
    ).toBeInTheDocument()
  })

  it("exposes server-backed queue filters including receiving progress", async () => {
    listStockRefillRequests.mockResolvedValue({
      total: 0,
      page: 1,
      page_size: 25,
      items: [],
    })
    renderAt("/refill", <RefillPage />)
    expect(await screen.findByLabelText("Approval status")).toBeInTheDocument()
    expect(screen.getByLabelText("Supplier")).toBeInTheDocument()
    expect(screen.getByLabelText("Destination godown")).toBeInTheDocument()
    expect(screen.getByLabelText("Supplier communication")).toBeInTheDocument()
    expect(screen.getByLabelText("Acknowledgement")).toBeInTheDocument()
    expect(screen.getByLabelText("Dispatch status")).toBeInTheDocument()
    expect(screen.getByLabelText("Receiving progress")).toBeInTheDocument()
    expect(screen.getByLabelText("Created from")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Refill report" })).toHaveAttribute(
      "href",
      "/reports/refill",
    )
  })
})
