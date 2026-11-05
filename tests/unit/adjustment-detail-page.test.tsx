import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router"
import { describe, expect, it, vi } from "vitest"
import { AdjustmentDetailPage } from "@/features/stock-adjustments/AdjustmentDetailPage"
import type { AdjustmentDetail } from "@/lib/adjustment/api"
import type { AdjustmentStatus } from "@/lib/adjustment/rules"

vi.mock("@/hooks/use-document-title", () => ({
  useDocumentTitle: () => undefined,
}))

vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({
    session: { user: { id: "gm-1" } },
  }),
}))

vi.mock("@/lib/access/use-access", () => ({
  useAccess: () => ({
    loading: false,
    roles: ["godown_manager"],
    permissions: ["stock.adjustment.request", "stock.adjustment.post"],
    can: (permission: string) =>
      permission === "stock.adjustment.request" || permission === "stock.adjustment.post",
  }),
}))

const detailHolder: { current: AdjustmentDetail } = {
  current: null as unknown as AdjustmentDetail,
}

vi.mock("@/lib/adjustment/api", () => ({
  getStockAdjustment: () => Promise.resolve(detailHolder.current),
  approveStockAdjustment: vi.fn(),
  postStockAdjustment: vi.fn(),
  rejectStockAdjustment: vi.fn(),
  returnStockAdjustment: vi.fn(),
  setStockAdjustmentLineLotAllocations: vi.fn(),
  submitStockAdjustment: vi.fn(),
}))

vi.mock("@/lib/inventory/api", () => ({
  getStockLotCutoverState: () =>
    Promise.resolve({ dual_write_enabled: false, aggregate_only_blocked: true }),
  listStockLotBalances: vi.fn(),
}))

function request(status: AdjustmentStatus, requestedCases: number, currentCases: number): AdjustmentDetail {
  return {
    id: "req-1",
    request_number: "AJ-TEST",
    godown_id: "godown-1",
    godown_name: "Godown-1",
    verification_id: "ver-1",
    verification_number: "DV-TEST",
    evidence_id: "photo-1",
    compensates_request_id: null,
    status,
    exceptional: false,
    version: 6,
    reason_code: requestedCases < 0 ? "shortage" : "surplus",
    note: "count",
    requested_by: "gm-1",
    requested_by_name: "Test Godownmanager",
    approved_by_name: null,
    posted_by_name: status === "posted" ? "Test Godownmanager" : null,
    other_manager_exists: false,
    lines: [
      {
        id: "line-1",
        crate_id: "crate-1",
        product_id: "product-1",
        crate_code: "uat_c1",
        sku: "TEST-DMG03M-ONLY",
        product_name: "Test product",
        requested_cases: requestedCases,
        current_cases: currentCases,
        lot_allocations: [],
      },
    ],
    events: [],
  }
}

function renderDetail(status: AdjustmentStatus, requestedCases: number, currentCases: number) {
  detailHolder.current = request(status, requestedCases, currentCases)
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/stock-adjustments/req-1"]}>
        <Routes>
          <Route path="/stock-adjustments/:requestId" element={<AdjustmentDetailPage />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe("adjustment detail quantities", () => {
  it("shows a posted shortage as already included in the book balance", async () => {
    renderDetail("posted", -2, 8)
    expect(await screen.findByText("Posted correction: -2 cases")).toBeTruthy()
    expect(screen.getByText("Current book quantity: 8 cases")).toBeTruthy()
    expect(screen.queryByText(/Posting impact/)).toBeNull()
    expect(screen.queryByText(/becomes 6/)).toBeNull()
    expect(screen.queryByRole("button", { name: "Post adjustment" })).toBeNull()
  })

  it("does not project a second increase for a posted surplus", async () => {
    renderDetail("posted", 2, 5)
    expect(await screen.findByText("Posted correction: 2 cases")).toBeTruthy()
    expect(screen.getByText("Current book quantity: 5 cases")).toBeTruthy()
    expect(screen.queryByText(/becomes 7/)).toBeNull()
    expect(screen.queryByRole("button", { name: "Post adjustment" })).toBeNull()
  })

  it("keeps the prospective impact while an approved shortage is unposted", async () => {
    renderDetail("approved", -2, 10)
    expect(await screen.findByText("Approved correction: -2 cases")).toBeTruthy()
    expect(screen.getByText("Current book quantity: 10 cases")).toBeTruthy()
    expect(
      screen.getByText(
        "Posting impact: book quantity becomes 8 if no later movement has made this request stale.",
      ),
    ).toBeTruthy()
    expect(screen.getByRole("button", { name: "Post adjustment" })).toBeTruthy()
  })

  it("keeps the prospective impact for draft and submitted requests", async () => {
    const { unmount } = renderDetail("draft", -2, 10)
    expect(await screen.findByText(/Posting impact: book quantity becomes 8/)).toBeTruthy()
    expect(screen.getByRole("button", { name: "Submit" })).toBeTruthy()
    expect(screen.queryByRole("button", { name: "Post adjustment" })).toBeNull()
    unmount()

    renderDetail("submitted", -2, 10)
    expect(await screen.findByText("Approved correction: -2 cases")).toBeTruthy()
    expect(screen.getByText(/Posting impact: book quantity becomes 8/)).toBeTruthy()
    expect(screen.queryByRole("button", { name: "Post adjustment" })).toBeNull()
  })

  it("keeps the prospective wording for a rejected request", async () => {
    renderDetail("rejected", -2, 10)
    expect(await screen.findByText("Approved correction: -2 cases")).toBeTruthy()
    expect(screen.getByText("Current book quantity: 10 cases")).toBeTruthy()
    expect(screen.getByText(/Posting impact: book quantity becomes 8/)).toBeTruthy()
    expect(screen.queryByText("Posted correction: -2 cases")).toBeNull()
    expect(screen.queryByRole("button", { name: "Post adjustment" })).toBeNull()
    expect(screen.queryByRole("button", { name: "Reject" })).toBeNull()
  })
})
