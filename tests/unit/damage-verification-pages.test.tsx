import type { ReactNode } from "react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { DamageVerificationPage } from "@/features/damage/DamageVerificationPage"

const listDamageReports = vi.fn()
const getDamageStockHoldReadyStatus = vi.fn()

vi.mock("@/lib/damage/api", () => ({
  listDamageReports: (...args: unknown[]) => listDamageReports(...args),
  getDamageStockHoldReadyStatus: (...args: unknown[]) =>
    getDamageStockHoldReadyStatus(...args),
}))

vi.mock("@/features/inventory/location-options", () => ({
  useStockLocations: () => ({
    branches: {
      data: [{ id: "g1", code: "G1", name: "Main Godown", is_active: true }],
    },
  }),
}))

vi.mock("@/features/damage/hooks/use-damage-access", () => ({
  useDamageAccess: () => ({
    canViewVerification: true,
    canVerify: true,
    canMonitor: false,
  }),
}))

vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({ session: { user: { id: "gm-1" } } }),
}))

vi.mock("@/hooks/use-document-title", () => ({
  useDocumentTitle: () => undefined,
}))

function wrap(element: ReactNode) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/damage/verification"]}>
        <Routes>
          <Route path="/damage/verification" element={element} />
          <Route path="/damage/:reportId" element={<p>detail</p>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe("DamageVerificationPage", () => {
  beforeEach(() => {
    listDamageReports.mockReset()
    getDamageStockHoldReadyStatus.mockReset()
    getDamageStockHoldReadyStatus.mockResolvedValue({
      stock_hold_ready: false,
    })
  })

  it("renders server-filtered queue facts and inspect actions", async () => {
    listDamageReports.mockResolvedValue({
      items: [
        {
          id: "r1",
          report_number: "DMG-9001",
          scenario: "refill_supply",
          godown_id: "g1",
          godown_name: "Main Godown",
          status: "submitted",
          version: 2,
          reporter_name: "Keeper",
          reporter_user_id: "keeper-1",
          created_at: "2026-10-26T10:00:00Z",
          has_finalized_evidence: true,
          finalized_evidence_count: 1,
          total_cases: 2,
          active_hold_cases: 0,
        },
      ],
      total: 1,
      page: 1,
      page_size: 25,
    })

    wrap(<DamageVerificationPage />)

    await waitFor(() => {
      expect(screen.getAllByText("DMG-9001").length).toBeGreaterThan(0)
    })
    expect(screen.getByText("Eligible for verification")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Inspect" })).toHaveAttribute(
      "href",
      "/damage/r1",
    )
    expect(listDamageReports).toHaveBeenCalledWith(
      expect.objectContaining({
        page: 1,
        pageSize: 25,
      }),
    )
  })

  it("labels missing evidence from persisted list facts", async () => {
    listDamageReports.mockResolvedValue({
      items: [
        {
          id: "r2",
          report_number: "DMG-9002",
          scenario: "refill_supply",
          godown_id: "g1",
          godown_name: "Main Godown",
          status: "submitted",
          version: 2,
          reporter_name: "Keeper",
          reporter_user_id: "keeper-1",
          created_at: "2026-10-26T10:00:00Z",
          has_finalized_evidence: false,
          finalized_evidence_count: 0,
          total_cases: 1,
          active_hold_cases: 0,
        },
      ],
      total: 1,
      page: 1,
      page_size: 25,
    })

    wrap(<DamageVerificationPage />)

    await waitFor(() => {
      expect(screen.getByText("Blocked — missing evidence")).toBeInTheDocument()
    })
  })
})
