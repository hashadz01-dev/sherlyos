import type { ReactNode } from "react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { DamageExceptionalApprovalsPage } from "@/features/damage/DamageExceptionalApprovalsPage"

const listExceptionalDamageRequests = vi.fn()
const getDamageStockHoldReadyStatus = vi.fn()

vi.mock("@/lib/damage/api", () => ({
  listExceptionalDamageRequests: (...args: unknown[]) =>
    listExceptionalDamageRequests(...args),
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
    canViewExceptionalQueue: true,
    canDispose: true,
    canMonitor: true,
    canVerify: false,
  }),
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
      <MemoryRouter initialEntries={["/damage/exceptional"]}>
        <Routes>
          <Route path="/damage/exceptional" element={element} />
          <Route path="/damage/:reportId" element={<p>detail</p>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe("DamageExceptionalApprovalsPage", () => {
  beforeEach(() => {
    listExceptionalDamageRequests.mockReset()
    getDamageStockHoldReadyStatus.mockReset()
    getDamageStockHoldReadyStatus.mockResolvedValue({
      stock_hold_ready: false,
    })
  })

  it("renders server-filtered queue facts and inspect actions", async () => {
    listExceptionalDamageRequests.mockResolvedValue({
      items: [
        {
          id: "ex1",
          damage_report_id: "r1",
          report_number: "DMG-9401",
          report_status: "verified",
          report_version: 3,
          scenario: "storage",
          godown_id: "g1",
          godown_name: "Main Godown",
          godown_active: true,
          kind: "destroy",
          status: "requested",
          version: 1,
          request_reason: "destroy crushed soap",
          requested_by: "gm-1",
          requested_by_name: "GM",
          requested_at: "2026-10-26T13:00:00Z",
          has_finalized_evidence: true,
          total_cases: 2,
          remaining_hold_cases: 2,
        },
      ],
      total: 1,
      page: 1,
      page_size: 25,
    })

    wrap(<DamageExceptionalApprovalsPage />)

    await waitFor(() => {
      expect(screen.getAllByText("DMG-9401").length).toBeGreaterThan(0)
    })
    expect(screen.getAllByText("Destroy").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Requested").length).toBeGreaterThan(0)
    expect(
      screen.getAllByRole("link", { name: "Inspect" })[0],
    ).toHaveAttribute("href", "/damage/r1")
    expect(listExceptionalDamageRequests).toHaveBeenCalledWith(
      expect.objectContaining({
        page: 1,
        pageSize: 25,
      }),
    )
  })

  it("labels approved requests as pending execution", async () => {
    listExceptionalDamageRequests.mockResolvedValue({
      items: [
        {
          id: "ex2",
          damage_report_id: "r2",
          report_number: "DMG-9402",
          report_status: "verified",
          report_version: 3,
          scenario: "storage",
          godown_id: "g1",
          godown_name: "Main Godown",
          godown_active: true,
          kind: "return_supplier",
          status: "approved",
          version: 2,
          request_reason: "return crushed soap",
          requested_by: "gm-1",
          requested_by_name: "GM",
          requested_at: "2026-10-26T13:00:00Z",
          has_finalized_evidence: true,
          total_cases: 2,
          remaining_hold_cases: 2,
        },
      ],
      total: 1,
      page: 1,
      page_size: 25,
    })

    wrap(<DamageExceptionalApprovalsPage />)

    await waitFor(() => {
      expect(
        screen.getByText("Approved — pending execution"),
      ).toBeInTheDocument()
    })
    expect(screen.getAllByText("Return to supplier").length).toBeGreaterThan(0)
  })
})
