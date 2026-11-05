import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { MemoryRouter } from "react-router"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { OpeningStockPage } from "@/features/inventory/OpeningStockPage"
import { postOpeningStock } from "@/lib/inventory/api"
import type { ProductSearchRow } from "@/lib/masters/product-search"

const CLASSIFY = "Classify this product expiry policy before lot-aware opening."

const { catalog, branchId, zoneId, crateId } = vi.hoisted(() => {
  const branchId = "11111111-1111-4111-8111-111111111111"
  const zoneId = "22222222-2222-4222-8222-222222222222"
  const crateId = "33333333-3333-4333-8333-333333333333"
  const catalog: ProductSearchRow[] = [
    {
      id: "902bb3b1-da30-4122-9b36-fed5b669b166",
      sku: "TEST-OTD-ONLY",
      name: "UAT Order-to-Delivery Test Product — do not sell",
      is_active: true,
      expiry_policy: "non_expiring",
      category_id: null,
      supplier_id: null,
    },
    {
      id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      sku: "TEST-EXP-ONLY",
      name: "Expiry controlled fixture",
      is_active: true,
      expiry_policy: "expiry_controlled",
      category_id: null,
      supplier_id: null,
    },
    {
      id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      sku: "TEST-UNC-ONLY",
      name: "Unclassified fixture",
      is_active: true,
      expiry_policy: null,
      category_id: null,
      supplier_id: null,
    },
  ]
  return { catalog, branchId, zoneId, crateId }
})

vi.mock("@/lib/access/use-access", () => ({
  useAccess: () => ({
    loading: false,
    roles: ["admin"],
    permissions: ["stock.opening.post", "stock.read"],
    can: (permission: string) =>
      permission === "stock.opening.post" || permission === "stock.read",
  }),
}))

vi.mock("@/lib/inventory/api", () => ({
  getStockLotCutoverState: () =>
    Promise.resolve({ dual_write_enabled: true, aggregate_only_blocked: true }),
  postOpeningStock: vi.fn(),
}))

vi.mock("@/features/inventory/location-options", () => ({
  useStockLocations: () => ({
    branches: {
      data: [{ id: branchId, code: "gd_1", name: "Godown-1", is_active: true }],
    },
    zones: {
      data: [
        {
          id: zoneId,
          branch_id: branchId,
          code: "uat_z1",
          name: "UAT Zone 1",
          is_active: true,
        },
      ],
    },
    crates: {
      data: [{ id: crateId, zone_id: zoneId, code: "uat_c1", name: null, is_active: true }],
    },
  }),
}))

vi.mock("@/lib/masters/product-search", () => ({
  productSearchLabel: (row: { sku: string; name: string }) => `${row.sku} · ${row.name}`,
  searchProducts: ({ query }: { query: string }) => {
    const needle = query.trim().toLowerCase()
    return Promise.resolve(
      catalog.filter(
        (row) =>
          needle.length === 0 ||
          row.sku.toLowerCase().includes(needle) ||
          row.name.toLowerCase().includes(needle),
      ),
    )
  },
  getProduct: (productId: string) =>
    Promise.resolve(catalog.find((row) => row.id === productId) ?? null),
}))

function renderPage() {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <OpeningStockPage />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

/** Lot-aware checks stay off until the cutover query writes dualWriteEnabled. */
async function waitForLotAwareOpening() {
  expect(await screen.findByText(/Lot-aware opening is active/)).toBeInTheDocument()
}

async function chooseProduct(user: ReturnType<typeof userEvent.setup>, sku: string) {
  const box = screen.getByRole("combobox", { name: "Product" })
  await user.click(box)
  await user.clear(box)
  await user.type(box, sku)
  const list = await screen.findByRole("listbox")
  // The option role is the row. The selection handler is on the button inside it.
  await user.click(await within(list).findByRole("button", { name: new RegExp(sku) }))
  await waitFor(() => {
    expect(
      (screen.getByRole("combobox", { name: "Product" }) as HTMLInputElement).value,
    ).toContain(sku)
  })
}

async function chooseLocation(user: ReturnType<typeof userEvent.setup>) {
  await user.selectOptions(screen.getByLabelText("Godown"), branchId)
  await screen.findByRole("option", { name: /uat_z1/ })
  await user.selectOptions(screen.getByLabelText("Zone"), zoneId)
  await screen.findByRole("option", { name: "uat_c1" })
  await user.selectOptions(screen.getByLabelText("Crate"), crateId)
}

describe("opening stock expiry validation", () => {
  beforeEach(() => {
    vi.mocked(postOpeningStock).mockReset()
  })

  it("does not warn when the selected product is non-expiring", async () => {
    const user = userEvent.setup()
    renderPage()
    await waitForLotAwareOpening()
    await chooseProduct(user, "TEST-OTD-ONLY")

    await waitFor(() => {
      expect(screen.queryByText(CLASSIFY)).not.toBeInTheDocument()
    })
    await chooseLocation(user)
    await user.type(screen.getByLabelText("Carton cases"), "3")
    await user.type(screen.getByLabelText("Manufacturer lot code (optional)"), "TEST-LOT-OTD01")
    await user.click(screen.getByRole("button", { name: "Review opening stock" }))

    expect(await screen.findByRole("dialog", { name: "Post opening stock?" })).toBeInTheDocument()
    expect(screen.queryByText(CLASSIFY)).not.toBeInTheDocument()
    expect(postOpeningStock).not.toHaveBeenCalled()
  })

  it("does not show the classification warning for an expiry-controlled product", async () => {
    const user = userEvent.setup()
    renderPage()
    await waitForLotAwareOpening()
    await chooseProduct(user, "TEST-EXP-ONLY")

    await waitFor(() => {
      expect(screen.queryByText(CLASSIFY)).not.toBeInTheDocument()
    })
    await chooseLocation(user)
    await user.type(screen.getByLabelText("Carton cases"), "1")
    await user.type(screen.getByLabelText(/^Expiry date/), "2027-01-01")
    await user.click(screen.getByRole("button", { name: "Review opening stock" }))

    expect(await screen.findByRole("dialog", { name: "Post opening stock?" })).toBeInTheDocument()
    expect(screen.queryByText(CLASSIFY)).not.toBeInTheDocument()
    expect(postOpeningStock).not.toHaveBeenCalled()
  })

  it("blocks an unclassified product with the classification error", async () => {
    const user = userEvent.setup()
    renderPage()
    await waitForLotAwareOpening()
    await chooseProduct(user, "TEST-UNC-ONLY")

    expect(await screen.findByText(CLASSIFY)).toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Review opening stock" }))
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    expect(postOpeningStock).not.toHaveBeenCalled()
  })

  it("clears the stale error after an unclassified product is replaced", async () => {
    const user = userEvent.setup()
    renderPage()
    await waitForLotAwareOpening()
    await chooseProduct(user, "TEST-UNC-ONLY")
    expect(await screen.findByText(CLASSIFY)).toBeInTheDocument()

    await chooseProduct(user, "TEST-OTD-ONLY")
    await waitFor(() => {
      expect(screen.queryByText(CLASSIFY)).not.toBeInTheDocument()
    })
    expect(postOpeningStock).not.toHaveBeenCalled()
  })

  it("raises the error when a classified product is replaced by an unclassified one", async () => {
    const user = userEvent.setup()
    renderPage()
    await waitForLotAwareOpening()
    await chooseProduct(user, "TEST-OTD-ONLY")
    await waitFor(() => {
      expect(screen.queryByText(CLASSIFY)).not.toBeInTheDocument()
    })

    await chooseProduct(user, "TEST-UNC-ONLY")
    expect(await screen.findByText(CLASSIFY)).toBeInTheDocument()
    expect(postOpeningStock).not.toHaveBeenCalled()
  })

  it("keeps quantity and expiry-date checks", async () => {
    const user = userEvent.setup()
    renderPage()
    await waitForLotAwareOpening()
    await chooseProduct(user, "TEST-OTD-ONLY")
    await chooseLocation(user)
    await user.type(screen.getByLabelText("Carton cases"), "0")
    await user.click(screen.getByRole("button", { name: "Review opening stock" }))

    expect(await screen.findByText("Enter a whole number of carton cases.")).toBeInTheDocument()
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()

    await user.clear(screen.getByLabelText("Carton cases"))
    await user.type(screen.getByLabelText("Carton cases"), "3")
    await user.type(screen.getByLabelText(/^Expiry date/), "2027-01-01")
    await user.click(screen.getByRole("button", { name: "Review opening stock" }))

    expect(
      await screen.findByText("Non-expiring products must not have an expiry date."),
    ).toBeInTheDocument()
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    expect(postOpeningStock).not.toHaveBeenCalled()
  })
})
