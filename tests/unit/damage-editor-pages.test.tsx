import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { MemoryRouter, Route, Routes } from "react-router"
import { beforeEach, describe, expect, it, vi } from "vitest"
import {
  EditDamageReportPage,
  NewDamageReportPage,
} from "@/features/damage/DamageReportEditorPage"

const {
  listDamageReportSources,
  listDamageReports,
  createDamageReport,
  updateDamageReport,
  submitDamageReport,
  getDamageReport,
  getDamageStockHoldReadyStatus,
  uploadDamagePhoto,
  confirmShopReturnCustody,
  notify,
  accessState,
} = vi.hoisted(() => ({
  listDamageReportSources: vi.fn(),
  listDamageReports: vi.fn(),
  createDamageReport: vi.fn(),
  updateDamageReport: vi.fn(),
  submitDamageReport: vi.fn(),
  getDamageReport: vi.fn(),
  getDamageStockHoldReadyStatus: vi.fn(),
  uploadDamagePhoto: vi.fn(),
  confirmShopReturnCustody: vi.fn(),
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
    canDisposition: true,
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
  listDamageReports: (...args: unknown[]) => listDamageReports(...args),
  createDamageReport: (...args: unknown[]) => createDamageReport(...args),
  updateDamageReport: (...args: unknown[]) => updateDamageReport(...args),
  submitDamageReport: (...args: unknown[]) => submitDamageReport(...args),
  getDamageReport: (...args: unknown[]) => getDamageReport(...args),
  getDamageStockHoldReadyStatus: (...args: unknown[]) =>
    getDamageStockHoldReadyStatus(...args),
  uploadDamagePhoto: (...args: unknown[]) => uploadDamagePhoto(...args),
  confirmShopReturnCustody: (...args: unknown[]) =>
    confirmShopReturnCustody(...args),
  discardDamagePhoto: vi.fn(),
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
    listDamageReports.mockReset()
    createDamageReport.mockReset()
    updateDamageReport.mockReset()
    submitDamageReport.mockReset()
    getDamageReport.mockReset()
    getDamageStockHoldReadyStatus.mockReset()
    uploadDamagePhoto.mockReset()
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
    listDamageReports.mockResolvedValue({
      total: 0,
      page: 1,
      page_size: 50,
      items: [],
    })
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
              damaged_cases: 2,
              already_reported: 0,
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
    expect(screen.getByLabelText("Select photo")).toBeInTheDocument()
    expect(screen.getByText("Add damaged photo")).toBeInTheDocument()
  })

  it("saves a draft then uploads when a photo is chosen on an unsaved report", async () => {
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
    uploadDamagePhoto.mockResolvedValue("ev1")
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
    const photo = new File([new Uint8Array([137, 80, 78, 71])], "damage.png", {
      type: "image/png",
    })
    await user.upload(screen.getByLabelText("Select photo"), photo)
    await waitFor(() => {
      expect(createDamageReport).toHaveBeenCalledTimes(1)
    })
    await waitFor(() => {
      expect(uploadDamagePhoto).toHaveBeenCalledWith(
        "r1",
        photo,
        "",
        expect.any(Function),
      )
    })
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
      screen.getByText(/Storage submit is blocked/i),
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

  it("rejects quantity 10 immediately and keeps the typed value", async () => {
    const user = userEvent.setup()
    renderCreate()
    await user.selectOptions(screen.getByLabelText("Godown"), "g1")
    await user.click(screen.getByRole("radio", { name: /refill supply/i }))
    await waitFor(() => expect(listDamageReportSources).toHaveBeenCalled())
    await user.click(
      await screen.findByRole("button", { name: /Select source RCV-1/ }),
    )
    expect(screen.getByText(/Receipt damaged: 2 cases/i)).toBeInTheDocument()
    await user.click(await screen.findByRole("button", { name: "Add" }))
    const qty = screen.getByLabelText("Quantity (cases)")
    expect(qty).toHaveValue("2")
    await user.clear(qty)
    await user.type(qty, "10")
    expect(qty).toHaveValue("10")
    expect(
      screen.getAllByText(/only 2 damaged cases were recorded on this receipt/i)
        .length,
    ).toBeGreaterThan(0)
  })

  it("shows a claiming draft when remaining receipt damage is already reserved", async () => {
    listDamageReports.mockResolvedValue({
      total: 1,
      page: 1,
      page_size: 50,
      items: [
        {
          id: "r-draft",
          report_number: "DMG-20261102-000001",
          receipt_id: "rc1",
          status: "draft",
        },
      ],
    })
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
              damaged_cases: 2,
              already_reported: 2,
              remaining_cases: 0,
            },
          ],
        },
      ],
      catalogs: {},
    })
    const user = userEvent.setup()
    renderCreate()
    await user.selectOptions(screen.getByLabelText("Godown"), "g1")
    await user.click(screen.getByRole("radio", { name: /refill supply/i }))
    await user.click(
      await screen.findByRole("button", { name: /Select source RCV-1/ }),
    )
    expect(screen.getByText(/Available to report: 0 cases/i)).toBeInTheDocument()
    expect(screen.getByText(/already linked to damage report/i)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "DMG-20261102-000001" })).toHaveAttribute(
      "href",
      "/damage/r-draft/edit",
    )
    expect(screen.getByRole("button", { name: "Add" })).toBeDisabled()
  })

  it("clears incompatible lines when the source receipt changes", async () => {
    listDamageReportSources.mockResolvedValue({
      total: 2,
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
              damaged_cases: 2,
              already_reported: 0,
              remaining_cases: 2,
            },
          ],
        },
        {
          id: "rc2",
          kind: "receipt",
          label: "RCV-2",
          godown_id: "g1",
          receipt_id: "rc2",
          supplier_name: "Other",
          lines: [
            {
              receipt_line_id: "rl2",
              product_id: "p2",
              product_sku: "SKU-2",
              product_name: "Carton B",
              crate_id: "c2",
              crate_code: "CR-2",
              damaged_cases: 1,
              already_reported: 0,
              remaining_cases: 1,
            },
          ],
        },
      ],
      catalogs: {},
    })
    const user = userEvent.setup()
    renderCreate()
    await user.selectOptions(screen.getByLabelText("Godown"), "g1")
    await user.click(screen.getByRole("radio", { name: /refill supply/i }))
    await user.click(
      await screen.findByRole("button", { name: /Select source RCV-1/ }),
    )
    await user.click(await screen.findByRole("button", { name: "Add" }))
    expect(screen.getByLabelText("Quantity (cases)")).toHaveValue("2")
    await user.click(
      await screen.findByRole("button", { name: /Select source RCV-2/ }),
    )
    expect(screen.getByText("No damage lines yet.")).toBeInTheDocument()
    expect(screen.queryByLabelText("Quantity (cases)")).not.toBeInTheDocument()
  })

  it("asks to save the report before attaching evidence on an empty form", async () => {
    const user = userEvent.setup()
    renderCreate()
    const photo = new File([new Uint8Array([137, 80, 78, 71])], "damage.png", {
      type: "image/png",
    })
    await user.upload(screen.getByLabelText("Select photo"), photo)
    expect(
      await screen.findByText(/Please save the damage report before attaching evidence/i),
    ).toBeInTheDocument()
    expect(createDamageReport).not.toHaveBeenCalled()
    expect(uploadDamagePhoto).not.toHaveBeenCalled()
  })

  it("does not count a failed photo finalize as evidence", async () => {
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
    uploadDamagePhoto.mockRejectedValue(
      new Error("photo content could not be verified"),
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
    const photo = new File([new Uint8Array([137, 80, 78, 71])], "damage.png", {
      type: "image/png",
    })
    await user.upload(screen.getByLabelText("Select photo"), photo)
    expect(
      await screen.findByText(/evidence verification failed/i),
    ).toBeInTheDocument()
    expect(screen.getByText("Finalized evidence").closest("div")).toHaveTextContent(
      "0",
    )
    expect(screen.getByRole("button", { name: "Review and submit" })).toBeDisabled()
  })
})

describe("damage edit form inbound remaining", () => {
  beforeEach(() => {
    listDamageReportSources.mockReset()
    listDamageReports.mockReset()
    getDamageReport.mockReset()
    getDamageStockHoldReadyStatus.mockReset()
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
    listDamageReports.mockResolvedValue({
      total: 1,
      page: 1,
      page_size: 50,
      items: [
        {
          id: "r-draft",
          report_number: "DMG-20261102-000001",
          receipt_id: "rc1",
          status: "draft",
        },
      ],
    })
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
              damaged_cases: 2,
              already_reported: 2,
              remaining_cases: 0,
            },
          ],
        },
      ],
      catalogs: {},
    })
    getDamageReport.mockResolvedValue({
      id: "r-draft",
      report_number: "DMG-20261102-000001",
      scenario: "refill_supply",
      godown_id: "g1",
      receipt_id: "rc1",
      status: "draft",
      version: 1,
      reporter_user_id: "u1",
      notes: "The package has been broken",
      evidence: [{ id: "e1", finalized: false }],
      lines: [
        {
          id: "dl1",
          product_id: "p1",
          product_sku: "SKU-1",
          product_name: "Carton A",
          quantity_cases: 2,
          damage_reason: "broken pack",
          crate_id: "c1",
          crate_code: "CR-1",
          lot_id: null,
          notes: null,
          receipt_line_id: "rl1",
        },
      ],
    })
  })

  it("does not double-count this draft against remaining damaged cases", async () => {
    const client = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/damage/r-draft/edit"]}>
          <Routes>
            <Route
              path="/damage/:reportId/edit"
              element={<EditDamageReportPage />}
            />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>,
    )
    expect(
      await screen.findByRole("heading", { name: "Edit DMG-20261102-000001" }),
    ).toBeInTheDocument()
    expect(await screen.findByText(/Receipt damaged: 2 cases/i)).toBeInTheDocument()
    expect(screen.getByText(/This draft: 2 cases/i)).toBeInTheDocument()
    expect(screen.getByText(/Already claimed\/reserved: 0 cases/i)).toBeInTheDocument()
    expect(screen.getByText(/Available to report: 2 cases/i)).toBeInTheDocument()
    expect(screen.getByLabelText("Quantity (cases)")).toHaveValue("2")
    expect(screen.getByText("Finalized evidence").closest("div")).toHaveTextContent(
      "0",
    )
    expect(
      screen.getByText(/did not finish verification/i),
    ).toBeInTheDocument()
  })
})

describe("shop-return edit custody gate", () => {
  beforeEach(() => {
    listDamageReportSources.mockReset()
    listDamageReports.mockReset()
    getDamageReport.mockReset()
    getDamageStockHoldReadyStatus.mockReset()
    confirmShopReturnCustody.mockReset()
    accessState.canRecord = true
    accessState.canVerify = true
    accessState.canCreate = true
    accessState.availableScenarios = ["shop_return"]
    getDamageStockHoldReadyStatus.mockResolvedValue({ stock_hold_ready: true })
    listDamageReports.mockResolvedValue({
      total: 0,
      page: 1,
      page_size: 50,
      items: [],
    })
    listDamageReportSources.mockResolvedValue({
      total: 1,
      page: 1,
      page_size: 20,
      items: [
        {
          id: "s1",
          kind: "shop",
          label: "SHOPPE FRESH",
          godown_id: "g1",
          shop_id: "s1",
          lines: [],
        },
      ],
      catalogs: {
        products: [
          {
            product_id: "p1",
            product_sku: "TEST-DMG06-ONLY",
            product_name: "DMG06 Fixture",
          },
        ],
      },
    })
    getDamageReport.mockResolvedValue({
      id: "r-sr",
      report_number: "DMG-20261103-000018",
      scenario: "shop_return",
      godown_id: "g1",
      godown_name: "Godown-1",
      shop_id: "s1",
      shop_name: "SHOPPE FRESH",
      status: "draft",
      version: 2,
      reporter_user_id: "u1",
      notes: null,
      physical_custody_confirmed: false,
      evidence: [{ id: "e1", finalized: true }],
      lines: [
        {
          id: "dl1",
          product_id: "p1",
          product_sku: "TEST-DMG06-ONLY",
          product_name: "DMG06 Fixture",
          quantity_cases: 1,
          damage_reason: "Leakage",
          crate_id: null,
          crate_code: null,
          lot_id: null,
          notes: null,
          receipt_line_id: null,
        },
      ],
    })
  })

  it("shows custody panel and keeps submit blocked until custody is confirmed", async () => {
    const client = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/damage/r-sr/edit"]}>
          <Routes>
            <Route
              path="/damage/:reportId/edit"
              element={<EditDamageReportPage />}
            />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>,
    )
    expect(
      await screen.findByRole("heading", {
        name: "Edit DMG-20261103-000018",
      }),
    ).toBeInTheDocument()
    expect(screen.getByText("Shop-return custody")).toBeInTheDocument()
    expect(screen.getByText("Custody outstanding")).toBeInTheDocument()
    expect(
      screen.getByRole("button", { name: /confirm physical custody/i }),
    ).toBeInTheDocument()
    expect(
      screen.getByText(/Confirm physical custody at the receiving godown/i),
    ).toBeInTheDocument()
    expect(
      screen.getByRole("button", { name: "Review and submit" }),
    ).toBeDisabled()
  })

  it("refreshes readiness after a successful custody confirmation on edit", async () => {
    const user = userEvent.setup()
    confirmShopReturnCustody.mockResolvedValue({
      id: "r-sr",
      report_number: "DMG-20261103-000018",
      scenario: "shop_return",
      godown_id: "g1",
      godown_name: "Godown-1",
      shop_id: "s1",
      shop_name: "SHOPPE FRESH",
      status: "draft",
      version: 3,
      reporter_user_id: "u1",
      notes: null,
      physical_custody_confirmed: true,
      physical_custody_confirmed_at: "2026-11-03T13:00:00Z",
      evidence: [{ id: "e1", finalized: true }],
      lines: [
        {
          id: "dl1",
          product_id: "p1",
          product_sku: "TEST-DMG06-ONLY",
          product_name: "DMG06 Fixture",
          quantity_cases: 1,
          damage_reason: "Leakage",
          crate_id: null,
          crate_code: null,
          lot_id: null,
          notes: null,
          receipt_line_id: null,
        },
      ],
    })
    getDamageReport
      .mockResolvedValueOnce({
        id: "r-sr",
        report_number: "DMG-20261103-000018",
        scenario: "shop_return",
        godown_id: "g1",
        godown_name: "Godown-1",
        shop_id: "s1",
        shop_name: "SHOPPE FRESH",
        status: "draft",
        version: 2,
        reporter_user_id: "u1",
        notes: null,
        physical_custody_confirmed: false,
        evidence: [{ id: "e1", finalized: true }],
        lines: [
          {
            id: "dl1",
            product_id: "p1",
            product_sku: "TEST-DMG06-ONLY",
            product_name: "DMG06 Fixture",
            quantity_cases: 1,
            damage_reason: "Leakage",
            crate_id: null,
            crate_code: null,
            lot_id: null,
            notes: null,
            receipt_line_id: null,
          },
        ],
      })
      .mockResolvedValue({
        id: "r-sr",
        report_number: "DMG-20261103-000018",
        scenario: "shop_return",
        godown_id: "g1",
        godown_name: "Godown-1",
        shop_id: "s1",
        shop_name: "SHOPPE FRESH",
        status: "draft",
        version: 3,
        reporter_user_id: "u1",
        notes: null,
        physical_custody_confirmed: true,
        physical_custody_confirmed_at: "2026-11-03T13:00:00Z",
        evidence: [{ id: "e1", finalized: true }],
        lines: [
          {
            id: "dl1",
            product_id: "p1",
            product_sku: "TEST-DMG06-ONLY",
            product_name: "DMG06 Fixture",
            quantity_cases: 1,
            damage_reason: "Leakage",
            crate_id: null,
            crate_code: null,
            lot_id: null,
            notes: null,
            receipt_line_id: null,
          },
        ],
      })

    const client = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/damage/r-sr/edit"]}>
          <Routes>
            <Route
              path="/damage/:reportId/edit"
              element={<EditDamageReportPage />}
            />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>,
    )
    await screen.findByText("Custody outstanding")
    await user.click(
      screen.getByRole("button", { name: /confirm physical custody/i }),
    )
    expect(screen.getAllByText("SHOPPE FRESH").length).toBeGreaterThan(0)
    expect(screen.getAllByText(/TEST-DMG06-ONLY/).length).toBeGreaterThan(0)
    await user.click(
      screen.getByRole("button", { name: /confirm physical custody now/i }),
    )
    await waitFor(() => {
      expect(confirmShopReturnCustody).toHaveBeenCalledWith("r-sr", 2)
    })
    await waitFor(() => {
      expect(screen.getByText("Custody confirmed")).toBeInTheDocument()
    })
    await waitFor(() => {
      expect(
        screen.queryByText(/Confirm physical custody at the receiving godown/i),
      ).not.toBeInTheDocument()
    })
  })
})
