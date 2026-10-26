import type { ReactNode } from "react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { MemoryRouter, Route, Routes } from "react-router"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { DamageCustodyPanel } from "@/features/damage/components/DamageCustodyPanel"
import { DamageHoldDetails } from "@/features/damage/components/DamageHoldDetails"
import { DamageLifecycleTimeline } from "@/features/damage/components/DamageLifecycleTimeline"
import { DamageQuarantineTable } from "@/features/damage/components/DamageQuarantineTable"
import { DamageQuarantineTransferDialog } from "@/features/damage/components/DamageQuarantineTransferDialog"
import { DamageReportDetailPage } from "@/features/damage/DamageReportDetailPage"
import { DamageQuarantinePage } from "@/features/damage/DamageQuarantinePage"
import type { DamageQuarantineRow, DamageReportDetail } from "@/lib/damage/api"

const confirmShopReturnCustody = vi.fn()
const transferVerifiedDamageToQuarantine = vi.fn()
const getDamageReport = vi.fn()
const listDamageQuarantineInventory = vi.fn()
const getDamageStockHoldReadyStatus = vi.fn()

const accessState = {
  loading: false,
  roles: ["godown_manager"],
  can: () => true,
  canOpenDamage: true,
  canCreate: true,
  availableScenarios: ["shop_return"],
  canRead: true,
  canRecord: true,
  canVerify: true,
  canMonitor: false,
  canTransitOnly: false,
  isAdminMonitor: false,
  showVerificationQueues: true,
  showDispositionQueues: true,
  showExceptionalQueues: true,
  canViewQuarantine: true,
  canConfirmCustody: true,
  canTransferQuarantine: true,
  canViewVerification: true,
}

vi.mock("@/lib/damage/api", () => ({
  confirmShopReturnCustody: (...args: unknown[]) =>
    confirmShopReturnCustody(...args),
  transferVerifiedDamageToQuarantine: (...args: unknown[]) =>
    transferVerifiedDamageToQuarantine(...args),
  getDamageReport: (...args: unknown[]) => getDamageReport(...args),
  listDamageQuarantineInventory: (...args: unknown[]) =>
    listDamageQuarantineInventory(...args),
  getDamageStockHoldReadyStatus: (...args: unknown[]) =>
    getDamageStockHoldReadyStatus(...args),
  damagePhotoPreview: vi.fn(),
}))

vi.mock("@/features/damage/hooks/use-damage-access", () => ({
  useDamageAccess: () => accessState,
}))

vi.mock("@/features/inventory/location-options", () => ({
  useStockLocations: () => ({
    branches: {
      data: [{ id: "g1", code: "G1", name: "Main Godown", is_active: true }],
    },
  }),
}))

vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({ session: { user: { id: "u1" } } }),
}))

vi.mock("@/hooks/use-document-title", () => ({
  useDocumentTitle: () => undefined,
}))

vi.mock("@/lib/utilities/notify", () => ({
  notify: { success: vi.fn(), error: vi.fn(), info: vi.fn() },
}))

const shopReturn: DamageReportDetail = {
  id: "r1",
  report_number: "DMG-SR-1",
  scenario: "shop_return",
  godown_id: "g1",
  godown_name: "Main Godown",
  status: "draft",
  version: 2,
  reporter_name: "GM",
  reporter_user_id: "u1",
  created_at: "2026-10-26T10:00:00Z",
  receipt_id: null,
  picking_request_id: null,
  dispatch_id: null,
  order_id: null,
  shop_id: "s1",
  shop_name: "Corner Shop",
  notes: null,
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
      quantity_cases: 3,
      damage_reason: "expired",
      notes: null,
      receipt_line_id: null,
    },
  ],
  holds: [],
  exceptional_requests: [],
  events: [],
  evidence: [],
}

const quarantineRow: DamageQuarantineRow = {
  hold_id: "h1",
  damage_report_id: "r1",
  report_number: "DMG-SR-1",
  report_status: "rejected",
  scenario: "shop_return",
  godown_id: "g1",
  godown_name: "Main Godown",
  godown_active: true,
  product_id: "p1",
  product_sku: "SKU-1",
  product_name: "Carton A",
  quantity_cases: 3,
  hold_kind: "quarantine_intake",
  hold_status: "active",
  isolation_class: "shop_return_intake",
  crate_id: "q1",
  crate_code: "QRN-01",
  location_role: "quarantine",
  zone_code: "QRN",
  zone_name: "Quarantine",
  lot_id: null,
  source_reservation_id: null,
  posted_transaction_id: null,
  created_at: "2026-10-26T12:00:00Z",
}

function wrap(element: ReactNode, path = "/damage/r1") {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path="/damage/:reportId" element={element} />
          <Route path="/damage/quarantine" element={element} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe("custody panel and dialog", () => {
  beforeEach(() => {
    confirmShopReturnCustody.mockReset()
    accessState.canRecord = true
    accessState.canVerify = true
  })

  it("opens the confirmation dialog and calls the custody RPC", async () => {
    const user = userEvent.setup()
    confirmShopReturnCustody.mockResolvedValue({
      ...shopReturn,
      physical_custody_confirmed: true,
    })
    const onConfirmed = vi.fn()
    render(
      <MemoryRouter>
        <DamageCustodyPanel report={shopReturn} onConfirmed={onConfirmed} />
      </MemoryRouter>,
    )
    await user.click(
      screen.getByRole("button", { name: /confirm physical custody/i }),
    )
    expect(screen.getByText(/does not submit the report/i)).toBeInTheDocument()
    await user.click(
      screen.getByRole("button", { name: /confirm physical custody now/i }),
    )
    await waitFor(() => {
      expect(confirmShopReturnCustody).toHaveBeenCalledWith("r1", 2)
    })
    expect(onConfirmed).toHaveBeenCalled()
  })

  it("hides confirmation when the user cannot verify", () => {
    accessState.canVerify = false
    render(
      <MemoryRouter>
        <DamageCustodyPanel report={shopReturn} onConfirmed={() => undefined} />
      </MemoryRouter>,
    )
    expect(
      screen.queryByRole("button", { name: /confirm physical custody/i }),
    ).not.toBeInTheDocument()
  })
})

describe("hold details and transfer dialog", () => {
  it("renders hold provenance without treating logical holds as quarantine", () => {
    render(
      <DamageHoldDetails
        holds={[
          {
            id: "h1",
            line_id: "l1",
            product_id: "p1",
            product_sku: "SKU-1",
            product_name: "Carton A",
            crate_id: "c1",
            crate_code: "CR-1",
            location_role: "storage",
            zone_code: "A",
            lot_id: null,
            quantity_cases: 2,
            hold_kind: "on_hand_deduction",
            status: "active",
            source_reservation_id: null,
            posted_transaction_id: null,
          },
        ]}
      />,
    )
    expect(screen.getByText("On-hand hold")).toBeInTheDocument()
    expect(screen.getByText("Held")).toBeInTheDocument()
    expect(
      screen.queryByText(/physically transferred/i),
    ).not.toBeInTheDocument()
  })

  it("describes a full-quantity quarantine transfer", () => {
    render(
      <DamageQuarantineTransferDialog
        report={{ ...shopReturn, scenario: "storage", status: "verified" }}
        open
        busy={false}
        sourceCases={2}
        onOpenChange={() => undefined}
        onConfirm={() => undefined}
      />,
    )
    expect(screen.getByText(/quantity cannot be partial/i)).toBeInTheDocument()
    expect(
      screen.getByRole("button", { name: /post quarantine transfer/i }),
    ).toBeInTheDocument()
  })
})

describe("lifecycle timeline", () => {
  it("shows rejected shop-return remaining in quarantine", () => {
    render(
      <DamageLifecycleTimeline
        report={{
          ...shopReturn,
          status: "rejected",
          physical_custody_confirmed: true,
          holds: [
            {
              id: "h1",
              line_id: "l1",
              product_id: "p1",
              crate_id: "q1",
              location_role: "quarantine",
              lot_id: null,
              quantity_cases: 3,
              hold_kind: "quarantine_intake",
              status: "active",
            },
          ],
        }}
      />,
    )
    expect(
      screen.getByText(/quarantined stock remains unavailable/i),
    ).toBeInTheDocument()
  })
})

describe("quarantine table and page", () => {
  beforeEach(() => {
    listDamageQuarantineInventory.mockReset()
    getDamageStockHoldReadyStatus.mockReset()
  })

  it("distinguishes isolation classes in the table", () => {
    render(
      <MemoryRouter>
        <DamageQuarantineTable
          rows={[
            quarantineRow,
            {
              ...quarantineRow,
              hold_id: "h2",
              isolation_class: "logical_hold",
              hold_kind: "on_hand_deduction",
              location_role: "storage",
              crate_code: "CR-1",
              zone_code: "A",
            },
          ]}
        />
      </MemoryRouter>,
    )
    expect(
      screen.getAllByText(/shop-return quarantine intake/i).length,
    ).toBeGreaterThan(0)
    expect(screen.getByText(/logical on-hand isolation/i)).toBeInTheDocument()
  })

  it("renders empty and error states for the quarantine page", async () => {
    getDamageStockHoldReadyStatus.mockResolvedValue({
      stock_hold_ready: false,
    })
    listDamageQuarantineInventory.mockResolvedValue({
      items: [],
      total: 0,
      page: 1,
      page_size: 25,
      totals: {
        hold_rows: 0,
        current_unavailable_cases: 0,
        logical_hold_cases: 0,
        reservation_converted_cases: 0,
        shop_return_intake_cases: 0,
        transferred_quarantine_cases: 0,
        written_off_cases: 0,
        returned_supplier_cases: 0,
        released_cases: 0,
      },
    })
    wrap(<DamageQuarantinePage />, "/damage/quarantine")
    await waitFor(() => {
      expect(screen.getByText("No quarantine inventory")).toBeInTheDocument()
    })
    expect(
      screen.getByText("Damage stock isolation not ready"),
    ).toBeInTheDocument()
  })

  it("shows filter-wide totals instead of summing the current page", async () => {
    getDamageStockHoldReadyStatus.mockResolvedValue({
      stock_hold_ready: false,
    })
    listDamageQuarantineInventory.mockResolvedValue({
      items: [
        {
          ...quarantineRow,
          quantity_cases: 2,
          isolation_class: "logical_hold",
          hold_kind: "on_hand_deduction",
          hold_status: "active",
        },
      ],
      total: 3,
      page: 1,
      page_size: 1,
      totals: {
        hold_rows: 3,
        current_unavailable_cases: 6,
        logical_hold_cases: 2,
        reservation_converted_cases: 1,
        shop_return_intake_cases: 3,
        transferred_quarantine_cases: 0,
        written_off_cases: 5,
        returned_supplier_cases: 4,
        released_cases: 0,
      },
    })
    wrap(<DamageQuarantinePage />, "/damage/quarantine")
    await waitFor(() => {
      expect(screen.getByText("Current unavailable")).toBeInTheDocument()
    })
    expect(screen.getByText("6 cases")).toBeInTheDocument()
    expect(screen.getByText("Written off (not current)")).toBeInTheDocument()
    expect(screen.getByText("5 cases")).toBeInTheDocument()
    expect(
      screen.getByText("Returned to supplier (not current)"),
    ).toBeInTheDocument()
    expect(screen.getByText("4 cases")).toBeInTheDocument()
    expect(screen.getByText(/3 matching holds/i)).toBeInTheDocument()
    expect(screen.getByText(/logical on-hand isolation/i)).toBeInTheDocument()
  })
})

describe("detail page custody section", () => {
  it("shows the custody panel on shop-return detail", async () => {
    getDamageReport.mockResolvedValue(shopReturn)
    wrap(<DamageReportDetailPage />)
    await waitFor(() => {
      expect(screen.getByText("Shop-return custody")).toBeInTheDocument()
    })
    expect(screen.getByText("Lifecycle")).toBeInTheDocument()
    expect(screen.getAllByText("Corner Shop").length).toBeGreaterThan(0)
  })
})
