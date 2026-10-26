import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { MemoryRouter, Route, Routes } from "react-router"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { NewDamageReportPage } from "@/features/damage/DamageReportEditorPage"

const {
  listDamageReportSources,
  createDamageReport,
  updateDamageReport,
  submitDamageReport,
  getDamageReport,
  getDamageStockHoldReadyStatus,
  notify,
  accessState,
} = vi.hoisted(() => ({
  listDamageReportSources: vi.fn(),
  createDamageReport: vi.fn(),
  updateDamageReport: vi.fn(),
  submitDamageReport: vi.fn(),
  getDamageReport: vi.fn(),
  getDamageStockHoldReadyStatus: vi.fn(),
  notify: { success: vi.fn(), error: vi.fn(), info: vi.fn() },
  accessState: {
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
    canMonitor: false,
    canTransitOnly: false,
    isAdminMonitor: false,
    showVerificationQueues: true,
    showDispositionQueues: true,
    showExceptionalQueues: true,
  },
}))

vi.mock("@/lib/damage/api", () => ({
  listDamageReportSources: (...args: unknown[]) =>
    listDamageReportSources(...args),
  createDamageReport: (...args: unknown[]) => createDamageReport(...args),
  updateDamageReport: (...args: unknown[]) => updateDamageReport(...args),
  submitDamageReport: (...args: unknown[]) => submitDamageReport(...args),
  getDamageReport: (...args: unknown[]) => getDamageReport(...args),
  getDamageStockHoldReadyStatus: (...args: unknown[]) =>
    getDamageStockHoldReadyStatus(...args),
  uploadDamagePhoto: vi.fn(),
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
  useDamageAccess: () => accessState,
}))

vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({ session: { user: { id: "u1" } } }),
}))

vi.mock("@/hooks/use-document-title", () => ({
  useDocumentTitle: () => undefined,
}))

vi.mock("@/lib/utilities/notify", () => ({
  notify,
}))

function renderCreate() {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/damage/new"]}>
        <Routes>
          <Route path="/damage/new" element={<NewDamageReportPage />} />
          <Route path="/damage/:reportId/edit" element={<p>edit-route</p>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe("damage create form", () => {
  beforeEach(() => {
    listDamageReportSources.mockReset()
    createDamageReport.mockReset()
    submitDamageReport.mockReset()
    getDamageReport.mockReset()
    getDamageStockHoldReadyStatus.mockReset()
    notify.success.mockReset()
    accessState.availableScenarios = [
      "refill_supply",
      "unloading",
      "storage",
      "loading",
      "transit",
      "shop_return",
    ]
    accessState.canCreate = true
    getDamageStockHoldReadyStatus.mockResolvedValue({ stock_hold_ready: false })
    listDamageReportSources.mockResolvedValue({
      total: 1,
      page: 1,
      page_size: 20,
      items: [
        {
          id: "rc1",
          kind: "receipt",
          label: "RCV-1",
          godown_id: "g1",
          receipt_id: "rc1",
          supplier_name: "Supplier",
          lines: [
            {
              receipt_line_id: "rl1",
              product_id: "p1",
              product_sku: "SKU-1",
              product_name: "Carton A",
              crate_id: "c1",
              crate_code: "CR-1",
              remaining_cases: 2,
            },
          ],
        },
      ],
      catalogs: {},
    })
  })

  it("renders the create form and scenario choices", async () => {
    renderCreate()
    expect(
      screen.getByRole("heading", { name: "New damage report" }),
    ).toBeInTheDocument()
    expect(screen.getByText(/DMG-01/i)).toBeInTheDocument()
    expect(screen.getByText(/DMG-05/i)).toBeInTheDocument()
  })

  it("disables scenarios the current user cannot record", () => {
    accessState.availableScenarios = ["transit"]
    renderCreate()
    const storage = screen.getByRole("radio", { name: /storage/i })
    expect(storage).toBeDisabled()
    expect(screen.getByRole("radio", { name: /transit/i })).toBeEnabled()
  })

  it("loads scenario sources after godown and scenario selection", async () => {
    const user = userEvent.setup()
    renderCreate()
    await user.selectOptions(screen.getByLabelText("Godown"), "g1")
    await user.click(screen.getByRole("radio", { name: /refill supply/i }))
    await waitFor(() => {
      expect(listDamageReportSources).toHaveBeenCalled()
    })
    expect(await screen.findByText("RCV-1")).toBeInTheDocument()
  })

  it("adds and removes a source line then blocks invalid quantities", async () => {
    const user = userEvent.setup()
    renderCreate()
    await user.selectOptions(screen.getByLabelText("Godown"), "g1")
    await user.click(screen.getByRole("radio", { name: /refill supply/i }))
    await waitFor(() => expect(listDamageReportSources).toHaveBeenCalled())
    await user.click(
      await screen.findByRole("button", { name: /Select source RCV-1/ }),
    )
    await user.click(await screen.findByRole("button", { name: "Add" }))
    const qty = screen.getByLabelText("Quantity (cases)")
    await user.clear(qty)
    await user.type(qty, "0")
    await user.type(screen.getByLabelText("Damage reason"), "crushed")
    await user.click(screen.getByRole("button", { name: "Save draft" }))
    expect(await screen.findByRole("alert")).toHaveTextContent(
      /whole number of carton cases/i,
    )
    await user.click(screen.getByRole("button", { name: "Remove" }))
    expect(screen.getByText("No damage lines yet.")).toBeInTheDocument()
  })

  it("saves a draft through create_damage_report", async () => {
    createDamageReport.mockResolvedValue({
      id: "r1",
      report_number: "DMG-1001",
      scenario: "refill_supply",
      godown_id: "g1",
      status: "draft",
      version: 1,
      reporter_user_id: "u1",
      evidence: [],
      lines: [],
    })
    const user = userEvent.setup()
    renderCreate()
    await user.selectOptions(screen.getByLabelText("Godown"), "g1")
    await user.click(screen.getByRole("radio", { name: /refill supply/i }))
    await waitFor(() => expect(listDamageReportSources).toHaveBeenCalled())
    await user.click(
      await screen.findByRole("button", { name: /Select source RCV-1/ }),
    )
    await user.click(await screen.findByRole("button", { name: "Add" }))
    await user.type(screen.getByLabelText("Damage reason"), "crushed")
    await user.click(screen.getByRole("button", { name: "Save draft" }))
    await waitFor(() => {
      expect(createDamageReport).toHaveBeenCalledTimes(1)
    })
    expect(createDamageReport.mock.calls[0]?.[0]).toEqual(
      expect.objectContaining({
        scenario: "refill_supply",
        targetGodown: "g1",
        receiptId: "rc1",
      }),
    )
  })

  it("keeps submit disabled until evidence and isolation rules pass", async () => {
    const user = userEvent.setup()
    renderCreate()
    await user.selectOptions(screen.getByLabelText("Godown"), "g1")
    await user.click(screen.getByRole("radio", { name: /storage/i }))
    expect(
      screen.getByRole("button", { name: "Review and submit" }),
    ).toBeDisabled()
    expect(
      screen.getByText(/Stock isolation is not ready/i),
    ).toBeInTheDocument()
  })

  it("shows backend rejection messages from save", async () => {
    createDamageReport.mockRejectedValue(
      new Error("receipt is not eligible for damage reporting"),
    )
    const user = userEvent.setup()
    renderCreate()
    await user.selectOptions(screen.getByLabelText("Godown"), "g1")
    await user.click(screen.getByRole("radio", { name: /refill supply/i }))
    await waitFor(() => expect(listDamageReportSources).toHaveBeenCalled())
    await user.click(
      await screen.findByRole("button", { name: /Select source RCV-1/ }),
    )
    await user.click(await screen.findByRole("button", { name: "Add" }))
    await user.type(screen.getByLabelText("Damage reason"), "crushed")
    await user.click(screen.getByRole("button", { name: "Save draft" }))
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "receipt is not eligible for damage reporting",
    )
  })
})
