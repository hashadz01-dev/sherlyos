import type { ReactNode } from "react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { DamagePage } from "@/features/damage/DamagePage"
import { DamageReportDetailPage } from "@/features/damage/DamageReportDetailPage"
import { DamageReportsPage } from "@/features/damage/DamageReportsPage"

const listDamageReports = vi.fn()
const getDamageDashboard = vi.fn()
const getDamageReport = vi.fn()

vi.mock("@/lib/damage/api", () => ({
  listDamageReports: (...args: unknown[]) => listDamageReports(...args),
  getDamageDashboard: (...args: unknown[]) => getDamageDashboard(...args),
  getDamageReport: (...args: unknown[]) => getDamageReport(...args),
  confirmShopReturnCustody: vi.fn(),
  transferVerifiedDamageToQuarantine: vi.fn(),
  listDamageQuarantineInventory: vi.fn(),
  getDamageStockHoldReadyStatus: vi.fn(),
  verifyDamageReport: vi.fn(),
  returnDamageReport: vi.fn(),
  rejectDamageReport: vi.fn(),
  postOrdinaryDamageWriteoff: vi.fn(),
  requestExceptionalDamageDisposition: vi.fn(),
  approveExceptionalDamageDisposition: vi.fn(),
  rejectExceptionalDamageDisposition: vi.fn(),
  postExceptionalDamageDisposition: vi.fn(),
  listExceptionalDamageRequests: vi.fn(),
  damagePhotoPreview: vi.fn(),
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
    loading: false,
    roles: ["godown_manager"],
    can: () => true,
    canOpenDamage: true,
    canCreate: true,
    availableScenarios: [
      "refill_supply",
      "unloading",
      "storage",
      "loading",
      "transit",
      "shop_return",
    ],
    canRead: true,
    canRecord: true,
    canVerify: true,
    canDispose: false,
    canMonitor: false,
    canTransitOnly: false,
    isAdminMonitor: false,
    showVerificationQueues: true,
    showDispositionQueues: true,
    showExceptionalQueues: true,
    canRequestExceptional: true,
    canApproveExceptional: false,
    canExecuteExceptional: true,
    canViewExceptionalQueue: true,
    canViewQuarantine: true,
    canConfirmCustody: true,
    canTransferQuarantine: true,
    canViewVerification: true,
  }),
}))

vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({ session: { user: { id: "u1" } } }),
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
          <Route
            path={path.split("?")[0].replace(/[0-9a-f-]{8,}/i, ":reportId")}
            element={element}
          />
          <Route path="/damage" element={element} />
          <Route path="/damage/reports" element={element} />
          <Route path="/damage/:reportId" element={element} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe("damage pages", () => {
  beforeEach(() => {
    listDamageReports.mockReset()
    getDamageDashboard.mockReset()
    getDamageReport.mockReset()
  })

  it("renders dashboard metrics and readiness from the authorized RPC", async () => {
    getDamageDashboard.mockResolvedValue({
      stock_hold_ready: false,
      totals: {
        reports: 2,
        pending_verification: 1,
        verified: 1,
        active_hold_cases: 4,
        quarantined_cases: 0,
        pending_exceptional: 0,
        ordinary_writeoff_cases: 3,
        exceptional_writeoff_cases: 7,
        returned_supplier_cases: 4,
      },
      queues: {
        recent_submitted: [],
        awaiting_verification: [],
        awaiting_disposition: [],
        exceptional_pending: [
          {
            id: "r-ex",
            report_number: "DMG-9401",
            scenario: "storage",
            status: "verified",
            godown_name: "Main Godown",
            created_at: "2026-10-26T10:00:00Z",
            exceptional_status: "approved",
          },
        ],
        recently_resolved: [],
      },
    })

    renderAt("/damage", <DamagePage />)

    await waitFor(() => {
      expect(
        screen.getByText("Damage stock isolation not ready"),
      ).toBeInTheDocument()
    })
    expect(screen.getByText("2")).toBeInTheDocument()
    expect(screen.getByText("All reports")).toBeInTheDocument()
    expect(screen.getByText("Ordinary write-off cases")).toBeInTheDocument()
    expect(screen.getByText("Exceptional write-off cases")).toBeInTheDocument()
    expect(screen.getByText("Returned to supplier")).toBeInTheDocument()
    expect(
      screen.getByText("Approved — pending execution"),
    ).toBeInTheDocument()
  })

  it("shows an empty report list state", async () => {
    listDamageReports.mockResolvedValue({
      items: [],
      total: 0,
      page: 1,
      page_size: 25,
    })
    renderAt("/damage/reports", <DamageReportsPage />)
    await waitFor(() => {
      expect(screen.getByText("No damage reports")).toBeInTheDocument()
    })
  })

  it("shows API errors on the report list", async () => {
    listDamageReports.mockRejectedValue(new Error("not authorized"))
    renderAt("/damage/reports", <DamageReportsPage />)
    await waitFor(() => {
      expect(screen.getByRole("alert")).toHaveTextContent("not authorized")
    })
  })

  it("renders report detail sections from get_damage_report", async () => {
    getDamageReport.mockResolvedValue({
      id: "r1",
      report_number: "DMG-1001",
      scenario: "storage",
      godown_id: "g1",
      godown_name: "Main Godown",
      status: "submitted",
      version: 1,
      reporter_name: "Keeper",
      created_at: "2026-10-26T10:00:00Z",
      updated_at: "2026-10-26T11:00:00Z",
      receipt_id: null,
      picking_request_id: null,
      dispatch_id: null,
      order_id: null,
      shop_id: null,
      notes: "Crushed corner",
      physical_custody_confirmed: false,
      lines: [
        {
          id: "l1",
          product_id: "p1",
          product_sku: "SKU-1",
          product_name: "Carton A",
          crate_id: "c1",
          crate_code: "CR-1",
          lot_id: null,
          quantity_cases: 2,
          damage_reason: "crushed",
          notes: null,
          receipt_line_id: null,
        },
      ],
      holds: [],
      exceptional_requests: [],
      events: [
        {
          action: "submit",
          actor_name: "Keeper",
          previous_status: "draft",
          next_status: "submitted",
          created_at: "2026-10-26T10:05:00Z",
          metadata: {},
        },
      ],
      evidence: [],
    })

    const client = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/damage/r1"]}>
          <Routes>
            <Route
              path="/damage/:reportId"
              element={<DamageReportDetailPage />}
            />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>,
    )

    await waitFor(() => {
      expect(screen.getByText("DMG-1001")).toBeInTheDocument()
    })
    expect(screen.getByText("SKU-1 · Carton A")).toBeInTheDocument()
    expect(screen.getByText("Stock isolation")).toBeInTheDocument()
    expect(
      screen.getByText("No finalized evidence is available for this report."),
    ).toBeInTheDocument()
  })
})
