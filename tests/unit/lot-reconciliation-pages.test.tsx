import type { ReactNode } from "react"
import { render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { createMemoryRouter, MemoryRouter, RouterProvider } from "react-router"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { SidebarNav } from "@/components/layout/SidebarNav"
import { LotReconciliationDetailPage } from "@/features/stock-lot-reconciliation/LotReconciliationDetailPage"
import { LotReconciliationPage } from "@/features/stock-lot-reconciliation/LotReconciliationPage"
import { NewLotReconciliationPage } from "@/features/stock-lot-reconciliation/NewLotReconciliationPage"
import {
  LotReconciliationRpcError,
  type LotReconciliationDetail,
  type LotReconciliationListRow,
} from "@/lib/lot-reconciliation/api"

const api = vi.hoisted(() => ({
  listLotReconciliations: vi.fn(),
  getLotReconciliation: vi.fn(),
  createLotReconciliation: vi.fn(),
  saveLotReconciliationCount: vi.fn(),
  saveLotReconciliationLots: vi.fn(),
  addLotReconciliationFoundProduct: vi.fn(),
  refreshLotReconciliationExpected: vi.fn(),
  submitLotReconciliation: vi.fn(),
  approveLotReconciliation: vi.fn(),
  rejectLotReconciliation: vi.fn(),
  reopenLotReconciliation: vi.fn(),
  cancelLotReconciliation: vi.fn(),
  getLotAttributionReadiness: vi.fn(),
  applyLegacyLotAttribution: vi.fn(),
}))

const access = vi.hoisted(() => ({
  permissions: ["stock.lots.physical_reconcile", "stock.lots.legacy.reconcile"],
  userId: "admin-1",
}))

vi.mock("@/lib/lot-reconciliation/api", async () => {
  const actual = await vi.importActual<typeof import("@/lib/lot-reconciliation/api")>(
    "@/lib/lot-reconciliation/api",
  )
  return {
    ...actual,
    ...api,
  }
})

vi.mock("@/lib/access/use-access", () => ({
  useAccess: () => ({
    loading: false,
    roles: ["admin"],
    permissions: access.permissions,
    can: (permission: string) => access.permissions.includes(permission),
  }),
}))

vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({
    configured: true,
    loading: false,
    session: { user: { id: access.userId, email: "admin@example.com" } },
    signIn: vi.fn(),
    signOut: vi.fn(),
  }),
}))

vi.mock("@/features/inventory/location-options", () => ({
  useStockLocations: () => ({
    branches: {
      isLoading: false,
      error: null,
      data: [{ id: "godown-1", code: "G1", name: "Main godown", is_active: true }],
    },
    zones: {
      isLoading: false,
      error: null,
      data: [{ id: "zone-1", branch_id: "godown-1", code: "Z1", name: "Zone 1", is_active: true }],
    },
    crates: {
      isLoading: false,
      error: null,
      data: [
        { id: "crate-1", zone_id: "zone-1", code: "C1", name: "Crate 1", is_active: true },
        { id: "crate-2", zone_id: "zone-1", code: "C2", name: "Crate 2", is_active: true },
      ],
    },
    products: {
      isLoading: false,
      error: null,
      data: [
        {
          id: "product-2",
          sku: "SKU-2",
          name: "Found tea",
          is_active: true,
          expiry_policy: "expiry_controlled",
        },
      ],
    },
  }),
}))

vi.mock("@/lib/utilities/notify", () => ({
  notify: { info: vi.fn(), success: vi.fn(), error: vi.fn() },
}))

function listRow(overrides: Partial<LotReconciliationListRow> = {}): LotReconciliationListRow {
  return {
    id: "session-1",
    session_number: "LR-20261022-0001",
    godown_id: "godown-1",
    status: "draft",
    version: 1,
    created_at: "2026-10-22T10:00:00Z",
    submitted_at: null,
    unmatched_lines: 0,
    godown_name: "Main godown (G1)",
    crate_count: 1,
    created_by: "admin-1",
    updated_at: "2026-10-22T10:05:00Z",
    ...overrides,
  }
}

function detail(overrides: Partial<LotReconciliationDetail> = {}): LotReconciliationDetail {
  return {
    id: "session-1",
    session_number: "LR-20261022-0001",
    godown_id: "godown-1",
    status: "draft",
    version: 3,
    notes: null,
    created_by: "admin-1",
    submitted_by: null,
    submitted_at: null,
    reviewed_by: null,
    reviewed_at: null,
    rejection_reason: null,
    review_notes: null,
    cancelled_by: null,
    cancelled_at: null,
    cancellation_reason: null,
    applied_by: null,
    applied_at: null,
    expected_frozen_at: "2026-10-22T10:00:00Z",
    created_at: "2026-10-22T10:00:00Z",
    updated_at: "2026-10-22T10:05:00Z",
    discrepancy: {
      uncounted_lines: 1,
      unmatched_lines: 0,
      found_product_lines: 0,
      unidentified_cases: 0,
      unclassified_products: 0,
    },
    crates: [
      {
        crate_id: "crate-1",
        crate_code: "C1",
        crate_name: "Crate 1",
        zone_id: "zone-1",
        zone_code: "Z1",
        holds_scope: true,
      },
    ],
    lines: [
      {
        id: "line-1",
        crate_id: "crate-1",
        product_id: "product-1",
        sku: "SKU-1",
        product_name: "Tea",
        expiry_policy: "expiry_controlled",
        expected_quantity: 4,
        counted_quantity: null,
        is_found_product: false,
        counted_by: null,
        counted_at: null,
        lots: [],
      },
    ],
    attributions: [],
    events: [
      {
        id: "event-1",
        event_type: "created",
        actor_id: "admin-1",
        from_status: null,
        to_status: "draft",
        session_version: 1,
        payload: { crate_count: 1 },
        created_at: "2026-10-22T10:00:00Z",
      },
    ],
    ...overrides,
  }
}

function renderPage(path: string, element: ReactNode) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const router = createMemoryRouter(
    [{ path, element }],
    { initialEntries: [path.replace(":sessionId", "session-1")] },
  )
  return render(
    <QueryClientProvider client={client}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  access.permissions = ["stock.lots.physical_reconcile", "stock.lots.legacy.reconcile"]
  access.userId = "admin-1"
  for (const fn of Object.values(api)) fn.mockReset()
  api.getLotReconciliation.mockResolvedValue(detail())
  api.listLotReconciliations.mockResolvedValue([listRow()])
  api.getLotAttributionReadiness.mockResolvedValue({
    session_id: "session-1",
    status: "approved",
    already_applied: false,
    eligible: false,
    blockers: ["Legacy lot seed must complete before attribution."],
    known_quantity: 0,
    unknown_quantity: 0,
    dual_write_enabled: false,
    aggregate_only_blocked: false,
  })
})

describe("lot reconciliation pages", () => {
  it("renders authorized sessions with loading and empty states", async () => {
    api.listLotReconciliations.mockResolvedValueOnce([listRow()])
    renderPage("/stock-lot-reconciliation", <LotReconciliationPage />)
    expect(screen.getByRole("status")).toHaveTextContent("Loading lot reconciliations")
    expect((await screen.findAllByText("LR-20261022-0001")).length).toBeGreaterThan(0)
    expect(screen.getAllByText("Main godown (G1)").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Count").length).toBeGreaterThan(0)
    expect(api.listLotReconciliations).toHaveBeenCalledTimes(1)
  })

  it("shows an empty state and an error state", async () => {
    api.listLotReconciliations.mockResolvedValueOnce([])
    renderPage("/stock-lot-reconciliation", <LotReconciliationPage />)
    expect(await screen.findByText("No lot reconciliations")).toBeInTheDocument()

    api.listLotReconciliations.mockRejectedValueOnce(new Error("not authorized"))
    renderPage("/stock-lot-reconciliation", <LotReconciliationPage />)
    expect(await screen.findByRole("alert")).toHaveTextContent("not authorized")
  })

  it("hides lot reconciliation from store keepers", () => {
    access.permissions = ["stock.count_assist"]
    render(
      <MemoryRouter>
        <SidebarNav />
      </MemoryRouter>,
    )
    expect(screen.queryByText("Lot reconciliation")).not.toBeInTheDocument()
  })

  it("shows lot reconciliation when physical reconcile is granted", () => {
    access.permissions = ["stock.lots.physical_reconcile"]
    render(
      <MemoryRouter>
        <SidebarNav />
      </MemoryRouter>,
    )
    expect(screen.getByText("Lot reconciliation")).toBeInTheDocument()
    expect(screen.queryByText("New session")).not.toBeInTheDocument()
  })

  it("validates crate selection on the admin create form", async () => {
    const user = userEvent.setup()
    api.createLotReconciliation.mockResolvedValue(detail({ id: "session-2", session_number: "LR-20261022-0002" }))
    renderPage("/stock-lot-reconciliation/new", <NewLotReconciliationPage />)
    expect(await screen.findByRole("heading", { name: "New lot reconciliation" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Create session" })).toBeDisabled()
    await user.selectOptions(screen.getByLabelText("Godown"), "godown-1")
    expect(screen.getByText("Select at least one crate.")).toBeInTheDocument()
    await user.click(screen.getByText("Z1 · C1 · Crate 1"))
    expect(screen.queryByText("Select at least one crate.")).not.toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Create session" }))
    await waitFor(() =>
      expect(api.createLotReconciliation).toHaveBeenCalledWith(
        expect.objectContaining({
          target_godown: "godown-1",
          crate_ids: ["crate-1"],
        }),
      ),
    )
    expect(api.createLotReconciliation.mock.calls[0]?.[0].idempotency_key).toMatch(/^lr-create-/)
  })

  it("saves a whole carton count", async () => {
    const user = userEvent.setup()
    api.saveLotReconciliationCount.mockResolvedValue(detail({ version: 4 }))
    renderPage("/stock-lot-reconciliation/:sessionId", <LotReconciliationDetailPage />)
    await screen.findByText("SKU-1 Tea")
    await user.type(screen.getByLabelText("Count SKU-1"), "4")
    await user.click(screen.getByRole("button", { name: "Save count" }))
    await waitFor(() =>
      expect(api.saveLotReconciliationCount).toHaveBeenCalledWith({
        target_session: "session-1",
        expected_version: 3,
        target_crate: "crate-1",
        target_product: "product-1",
        counted_quantity: 4,
      }),
    )
  })

  it("validates lot breakdown totals before calling the RPC", async () => {
    const user = userEvent.setup()
    api.getLotReconciliation.mockResolvedValue(
      detail({
        lines: [
          {
            id: "line-1",
            crate_id: "crate-1",
            product_id: "product-1",
            sku: "SKU-1",
            product_name: "Tea",
            expiry_policy: "expiry_controlled",
            expected_quantity: 4,
            counted_quantity: 4,
            is_found_product: false,
            counted_by: "gm-1",
            counted_at: "2026-10-22T11:00:00Z",
            lots: [],
          },
        ],
      }),
    )
    renderPage("/stock-lot-reconciliation/:sessionId", <LotReconciliationDetailPage />)
    await screen.findByText("Lot evidence missing")
    await user.click(screen.getByRole("button", { name: "Add lot" }))
    await user.type(screen.getByLabelText("Manufacturer lot SKU-1 1"), "BATCH-1")
    await user.type(screen.getByLabelText("Lot quantity SKU-1 1"), "1")
    await user.type(screen.getByLabelText("Expiry SKU-1 1"), "2027-01-01")
    await user.click(screen.getByRole("button", { name: "Save lots" }))
    expect(await screen.findByRole("alert")).toHaveTextContent("Lot carton quantities must equal the counted cases.")
    expect(api.saveLotReconciliationLots).not.toHaveBeenCalled()
  })

  it("marks unknown identity without generating a batch code", async () => {
    const user = userEvent.setup()
    api.getLotReconciliation.mockResolvedValue(
      detail({
        lines: [
          {
            id: "line-1",
            crate_id: "crate-1",
            product_id: "product-1",
            sku: "SKU-1",
            product_name: "Tea",
            expiry_policy: "expiry_controlled",
            expected_quantity: 4,
            counted_quantity: 4,
            is_found_product: false,
            counted_by: "gm-1",
            counted_at: "2026-10-22T11:00:00Z",
            lots: [],
          },
        ],
      }),
    )
    renderPage("/stock-lot-reconciliation/:sessionId", <LotReconciliationDetailPage />)
    await user.click(await screen.findByRole("button", { name: "Add unknown / legacy unattributed" }))
    expect(screen.getByText("Unknown / Legacy unattributed")).toBeInTheDocument()
    expect(screen.getByLabelText("Manufacturer lot SKU-1 1")).toBeDisabled()
    expect(screen.getByLabelText("Expiry SKU-1 1")).toBeDisabled()
    await user.click(screen.getByRole("button", { name: "Save lots" }))
    await waitFor(() => expect(api.saveLotReconciliationLots).toHaveBeenCalled())
    expect(api.saveLotReconciliationLots.mock.calls[0]?.[0].lots[0]).toMatchObject({
      manufacturer_lot_code: null,
      expiry_date: null,
      identity_unknown: true,
      quantity: 4,
    })
  })

  it("shows unexpected stock as a discrepancy", async () => {
    api.getLotReconciliation.mockResolvedValue(
      detail({
        discrepancy: {
          uncounted_lines: 0,
          unmatched_lines: 1,
          found_product_lines: 1,
          unidentified_cases: 0,
          unclassified_products: 0,
        },
        lines: [
          {
            id: "line-2",
            crate_id: "crate-1",
            product_id: "product-2",
            sku: "SKU-2",
            product_name: "Found tea",
            expiry_policy: "expiry_controlled",
            expected_quantity: 0,
            counted_quantity: 2,
            is_found_product: true,
            counted_by: "gm-1",
            counted_at: "2026-10-22T11:00:00Z",
            lots: [
              {
                id: "lot-1",
                manufacturer_lot_code: null,
                expiry_date: null,
                expiry_unknown: true,
                identity_unknown: true,
                quantity: 2,
                condition: "available",
              },
            ],
          },
        ],
      }),
    )
    renderPage("/stock-lot-reconciliation/:sessionId", <LotReconciliationDetailPage />)
    expect(await screen.findByText("Unexpected stock")).toBeInTheDocument()
    expect(
      screen.getByText(/does not add stock, post an adjustment, or create a lot/),
    ).toBeInTheDocument()
  })

  it("requires confirmation before refreshing expected stock", async () => {
    const user = userEvent.setup()
    api.refreshLotReconciliationExpected.mockResolvedValue(detail({ version: 4, lines: [] }))
    renderPage("/stock-lot-reconciliation/:sessionId", <LotReconciliationDetailPage />)
    await user.click(await screen.findByRole("button", { name: "Refresh expected stock" }))
    expect(
      screen.getByText(
        "Refreshing the expected stock snapshot will remove all existing counts and lot evidence for this session.",
      ),
    ).toBeInTheDocument()
    expect(api.refreshLotReconciliationExpected).not.toHaveBeenCalled()
    await user.click(screen.getByRole("button", { name: "Refresh and clear counts" }))
    await waitFor(() => expect(api.refreshLotReconciliationExpected).toHaveBeenCalledTimes(1))
  })

  it("refetches on PT409 and does not replay the stale count", async () => {
    const user = userEvent.setup()
    api.saveLotReconciliationCount.mockRejectedValueOnce(
      new LotReconciliationRpcError("lot reconciliation was changed by someone else", "PT409"),
    )
    renderPage("/stock-lot-reconciliation/:sessionId", <LotReconciliationDetailPage />)
    await screen.findByLabelText("Count SKU-1")
    await user.type(screen.getByLabelText("Count SKU-1"), "4")
    await user.click(screen.getByRole("button", { name: "Save count" }))
    expect(
      (await screen.findAllByText(/This session was changed by someone else/)).length,
    ).toBeGreaterThan(0)
    await waitFor(() => expect(api.getLotReconciliation.mock.calls.length).toBeGreaterThan(1))
    expect(api.saveLotReconciliationCount).toHaveBeenCalledTimes(1)
  })

  it("shows the submission summary and submits a complete draft", async () => {
    const user = userEvent.setup()
    api.getLotReconciliation.mockResolvedValue(
      detail({
        discrepancy: {
          uncounted_lines: 0,
          unmatched_lines: 0,
          found_product_lines: 0,
          unidentified_cases: 0,
          unclassified_products: 0,
        },
        lines: [
          {
            id: "line-1",
            crate_id: "crate-1",
            product_id: "product-1",
            sku: "SKU-1",
            product_name: "Tea",
            expiry_policy: "expiry_controlled",
            expected_quantity: 4,
            counted_quantity: 4,
            is_found_product: false,
            counted_by: "gm-1",
            counted_at: "2026-10-22T11:00:00Z",
            lots: [
              {
                id: "lot-1",
                manufacturer_lot_code: "B1",
                expiry_date: "2027-01-01",
                expiry_unknown: false,
                identity_unknown: false,
                quantity: 4,
                condition: "available",
              },
            ],
          },
        ],
      }),
    )
    api.submitLotReconciliation.mockResolvedValue(detail({ status: "submitted", version: 5 }))
    renderPage("/stock-lot-reconciliation/:sessionId", <LotReconciliationDetailPage />)
    expect(await screen.findByText("Counted lines 1")).toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Submit counts" }))
    await waitFor(() => expect(api.submitLotReconciliation).toHaveBeenCalledTimes(1))
  })

  it("lets another admin approve or reject and hides self-approval", async () => {
    const user = userEvent.setup()
    const submitted = detail({
      status: "submitted",
      submitted_by: "gm-1",
      submitted_at: "2026-10-22T12:00:00Z",
      discrepancy: {
        uncounted_lines: 0,
        unmatched_lines: 0,
        found_product_lines: 0,
        unidentified_cases: 0,
        unclassified_products: 0,
      },
    })
    api.getLotReconciliation.mockResolvedValue(submitted)
    api.approveLotReconciliation.mockResolvedValue({ ...submitted, status: "approved" })
    renderPage("/stock-lot-reconciliation/:sessionId", <LotReconciliationDetailPage />)
    expect(await screen.findByRole("button", { name: "Approve" })).toBeInTheDocument()
    await user.type(screen.getByLabelText("Rejection reason"), "Counts do not match the floor.")
    await user.click(screen.getByRole("button", { name: "Reject" }))
    await waitFor(() =>
      expect(api.rejectLotReconciliation).toHaveBeenCalledWith(
        expect.objectContaining({ reject_reason: "Counts do not match the floor." }),
      ),
    )
  })

  it("hides the approve button from the submitter", async () => {
    access.userId = "gm-1"
    api.getLotReconciliation.mockResolvedValue(
      detail({
        status: "submitted",
        submitted_by: "gm-1",
        submitted_at: "2026-10-22T12:00:00Z",
      }),
    )
    renderPage("/stock-lot-reconciliation/:sessionId", <LotReconciliationDetailPage />)
    expect(await screen.findByText(/Approval is unavailable for this user/)).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Approve" })).not.toBeInTheDocument()
  })

  it("reopens a rejected session and cancels only eligible states", async () => {
    const user = userEvent.setup()
    api.getLotReconciliation.mockResolvedValue(
      detail({ status: "rejected", rejection_reason: "Recount required." }),
    )
    api.reopenLotReconciliation.mockResolvedValue(detail({ status: "draft", version: 6 }))
    renderPage("/stock-lot-reconciliation/:sessionId", <LotReconciliationDetailPage />)
    await user.click(await screen.findByRole("button", { name: "Reopen rejected session" }))
    await waitFor(() => expect(api.reopenLotReconciliation).toHaveBeenCalledTimes(1))

    api.getLotReconciliation.mockResolvedValue(detail({ status: "rejected" }))
    renderPage("/stock-lot-reconciliation/:sessionId", <LotReconciliationDetailPage />)
    await user.click(await screen.findByRole("button", { name: "Cancel session" }))
    expect(screen.getByText(/releases the reserved crate scope/)).toBeInTheDocument()
    await user.type(screen.getByLabelText("Cancellation reason"), "Session opened on the wrong crates.")
    await user.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Cancel session" }))
    await waitFor(() => expect(api.cancelLotReconciliation).toHaveBeenCalledTimes(1))
  })

  it("keeps approved sessions immutable and still shows the audit timeline", async () => {
    api.getLotReconciliation.mockResolvedValue(
      detail({
        status: "approved",
        events: [
          {
            id: "event-9",
            event_type: "approved",
            actor_id: "admin-2",
            from_status: "submitted",
            to_status: "approved",
            session_version: 8,
            payload: { review_notes: "Matched" },
            created_at: "2026-10-22T13:00:00Z",
          },
        ],
      }),
    )
    renderPage("/stock-lot-reconciliation/:sessionId", <LotReconciliationDetailPage />)
    expect(await screen.findByText(/approved and locked/)).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Save count" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Cancel session" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Refresh expected stock" })).not.toBeInTheDocument()
    expect(screen.getByText("Audit history")).toBeInTheDocument()
    expect(screen.getByText(/Approved by/)).toBeInTheDocument()
    expect(await screen.findByText(/Attribution is not eligible yet/)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Apply attribution" })).toBeDisabled()
  })

  it("lets an Admin apply only when backend readiness is eligible", async () => {
    const user = userEvent.setup()
    api.getLotReconciliation.mockResolvedValue(detail({ status: "approved" }))
    api.getLotAttributionReadiness.mockResolvedValue({
      session_id: "session-1",
      status: "approved",
      already_applied: false,
      eligible: true,
      blockers: [],
      known_quantity: 4,
      unknown_quantity: 2,
      dual_write_enabled: false,
      aggregate_only_blocked: true,
    })
    api.applyLegacyLotAttribution.mockResolvedValue(
      detail({
        status: "applied",
        applied_by: "admin-1",
        applied_at: "2026-10-22T14:00:00Z",
        attributions: [
          {
            crate_id: "crate-1",
            product_id: "product-1",
            source_lot_id: "lot-1",
            remaining_unattributed: 2,
            attributed_quantity: 4,
            unknown_quantity: 2,
          },
        ],
      }),
    )
    renderPage("/stock-lot-reconciliation/:sessionId", <LotReconciliationDetailPage />)
    expect(await screen.findByText(/Known physical lots 4/)).toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Apply attribution" }))
    expect(screen.getByText(/cannot be undone from the application/)).toBeInTheDocument()
    await user.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Apply attribution" }))
    await waitFor(() => expect(api.applyLegacyLotAttribution).toHaveBeenCalledTimes(1))
  })

  it("hides attribution controls from Godown Manager", async () => {
    access.permissions = ["stock.lots.physical_reconcile"]
    api.getLotReconciliation.mockResolvedValue(detail({ status: "approved" }))
    renderPage("/stock-lot-reconciliation/:sessionId", <LotReconciliationDetailPage />)
    expect(await screen.findByText(/approved and locked/)).toBeInTheDocument()
    expect(screen.queryByRole("heading", { name: "Legacy lot attribution" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Apply attribution" })).not.toBeInTheDocument()
  })
})
