import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter, Route, Routes } from "react-router"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { CrateCapacityPage } from "@/features/administration/godowns/CrateCapacityPage"
import { GodownZonesPage } from "@/features/administration/godowns/GodownZonesPage"
import { GodownsPage } from "@/features/administration/godowns/GodownsPage"
import { PlannedCratePreviewPage } from "@/features/administration/godowns/PlannedCratePreviewPage"
import { PlannedZonePreviewPage } from "@/features/administration/godowns/PlannedZonePreviewPage"
import { ZoneCratesPage } from "@/features/administration/godowns/ZoneCratesPage"

const access = vi.hoisted(() => ({
  permissions: ["employees.read", "branches.manage"] as string[],
}))

const warehouse = vi.hoisted(() => ({
  current: null as null | Record<string, unknown>,
}))

vi.mock("@/lib/access/use-access", () => ({
  useAccess: () => ({
    loading: false,
    roles: ["admin"],
    permissions: access.permissions,
    can: (permission: string) => access.permissions.includes(permission),
  }),
}))

vi.mock("@/features/administration/godowns/use-warehouse", () => ({
  useWarehouseSnapshot: () => warehouse.current,
}))

const ready = {
  godowns: [
    { id: "g1", code: "gd_1", name: "Godown-1", is_active: true },
    { id: "g7", code: "gd_7", name: "Godown-7", is_active: true },
  ],
  zones: [
    {
      id: "z1",
      branch_id: "g1",
      code: "uat_z1",
      name: "UAT Zone 1",
      location_role: "storage",
      is_active: true,
    },
    {
      id: "zq",
      branch_id: "g1",
      code: "QRN",
      name: "Quarantine",
      location_role: "quarantine",
      is_active: true,
    },
  ],
  crates: [
    {
      id: "c1",
      zone_id: "z1",
      code: "uat_c1",
      name: "UAT Crate 1",
      location_role: "storage",
      is_active: true,
    },
    {
      id: "cq",
      zone_id: "zq",
      code: "QRN-01",
      name: "Quarantine crate",
      location_role: "quarantine",
      is_active: true,
    },
  ],
  balances: [
    {
      godown_id: "g1",
      godown_code: "gd_1",
      godown_name: "Godown-1",
      zone_id: "z1",
      zone_code: "uat_z1",
      zone_name: "UAT Zone 1",
      crate_id: "c1",
      crate_code: "uat_c1",
      crate_name: "UAT Crate 1",
      product_id: "p1",
      product_sku: "AAA",
      product_name: "Alpha",
      quantity: 53,
    },
  ],
  lots: [
    {
      lot_id: "l1",
      product_id: "p1",
      product_sku: "AAA",
      product_name: "Alpha",
      expiry_policy: "non_expiring",
      lot_status: "available",
      lot_origin: "receipt",
      manufacturer_lot_code: "LOT-A",
      manufactured_on: null,
      expiry_date: null,
      received_on: null,
      godown_id: "g1",
      godown_code: "gd_1",
      crate_id: "c1",
      crate_code: "uat_c1",
      quantity: 53,
    },
  ],
  reservations: [],
  holds: [],
  reservationsVisible: true,
  holdsVisible: true,
}

function loaded() {
  warehouse.current = {
    godowns: { data: ready.godowns, isLoading: false, error: null },
    zones: { data: ready.zones, isLoading: false, error: null },
    crates: { data: ready.crates, isLoading: false, error: null },
    balances: { data: ready.balances, isLoading: false, isSuccess: true, error: null },
    lots: { data: ready.lots, isLoading: false, isSuccess: true, error: null },
    reservations: { data: { visible: true, rows: [] }, isLoading: false, error: null },
    holds: { data: { visible: true, rows: [] }, isLoading: false, error: null },
    structureLoading: false,
    structureError: null,
    ready,
  }
}

function renderAt(path: string) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path="/godowns" element={<GodownsPage />} />
          <Route path="/godowns/:godownId/zones" element={<GodownZonesPage />} />
          <Route
            path="/godowns/:godownId/zones/:zoneId/crates"
            element={<ZoneCratesPage />}
          />
          <Route
            path="/godowns/:godownId/zones/planned/:zoneKey"
            element={<PlannedZonePreviewPage />}
          />
          <Route
            path="/godowns/:godownId/zones/planned/:zoneKey/crates/:slot"
            element={<PlannedCratePreviewPage />}
          />
          <Route
            path="/godowns/:godownId/zones/:zoneId/crates/preview/:slot"
            element={<PlannedCratePreviewPage />}
          />
          <Route
            path="/godowns/:godownId/zones/:zoneId/crates/:crateId"
            element={<CrateCapacityPage />}
          />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  access.permissions = ["employees.read", "branches.manage"]
  loaded()
})

describe("godown visual navigation", () => {
  it("shows reserve classification and hides creation without permission", () => {
    access.permissions = ["employees.read"]
    renderAt("/godowns")
    expect(screen.getByText("Godown-7")).toBeInTheDocument()
    expect(screen.getByText(/gd_7 · Reserve/)).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Create godown" })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open zones for Godown-1" })).toHaveAttribute(
      "href",
      "/godowns/g1/zones",
    )
  })

  it("opens a real zone from the whole card and keeps A–F as previews", async () => {
    const user = userEvent.setup()
    renderAt("/godowns/g1/zones")
    expect(screen.getAllByText("Not configured").length).toBe(6)
    expect(screen.getByRole("link", { name: "Preview Zone A, not configured" })).toHaveAttribute(
      "href",
      "/godowns/g1/zones/planned/A",
    )
    expect(screen.getByRole("heading", { name: "Quarantine · QRN" })).toBeInTheDocument()
    await user.click(screen.getByRole("link", { name: "Open crates for UAT Zone 1" }))
    expect(await screen.findByText("uat_c1 · UAT Crate 1")).toBeInTheDocument()
    expect(screen.getByText(/Over capacity by 3 cases/)).toBeInTheDocument()
    await user.click(screen.getByRole("link", { name: "Open capacity for uat_c1" }))
    expect(await screen.findByText(/overflow is 3 cases/)).toBeInTheDocument()
    expect(screen.getAllByRole("gridcell")).toHaveLength(50)
  })

  it("opens the quarantine crate without treating it as Zone F", async () => {
    const user = userEvent.setup()
    renderAt("/godowns/g1/zones")
    await user.click(screen.getByRole("link", { name: "Open crates for Quarantine" }))
    expect(await screen.findByText(/QRN-01/)).toBeInTheDocument()
    await user.click(screen.getByRole("link", { name: "Open capacity for QRN-01" }))
    expect(await screen.findByText(/not available for normal picking/)).toBeInTheDocument()
  })

  it("previews a planned zone and an empty 50-position crate", async () => {
    const user = userEvent.setup()
    renderAt("/godowns/g1/zones")
    await user.click(screen.getByRole("link", { name: "Preview Zone A, not configured" }))
    expect(await screen.findByRole("heading", { name: "Zone A preview" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Preview A-01, not configured" })).toBeInTheDocument()
    await user.click(screen.getByRole("link", { name: "Preview A-01, not configured" }))
    expect(await screen.findByRole("grid")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "Back to crates" })[0]).toHaveAttribute(
      "href",
      "/godowns/g1/zones/planned/A",
    )
    expect(screen.getAllByRole("gridcell")).toHaveLength(50)
    expect(screen.getByText("Preview occupancy: 0/50. Visualized allocation — not physically mapped.")).toBeInTheDocument()
    await user.click(screen.getByRole("gridcell", { name: /Position 01/ }))
    expect(screen.getByText("Empty capacity — no stock assigned.")).toBeInTheDocument()
    expect(screen.queryByText("Alpha")).not.toBeInTheDocument()
  })

  it("opens the 50-position grid and a product detail without assigning stock", async () => {
    const user = userEvent.setup()
    renderAt("/godowns/g1/zones/z1/crates/c1")
    expect(await screen.findByRole("grid")).toBeInTheDocument()
    expect(screen.getAllByRole("gridcell")).toHaveLength(50)
    expect(screen.getAllByText(/Visualized allocation — not physically mapped/).length).toBeGreaterThan(0)
    await user.click(screen.getByRole("gridcell", { name: /Position 01/ }))
    expect(screen.getAllByText(/Alpha/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/LOT-A/).length).toBeGreaterThan(0)
    expect(screen.queryByRole("button", { name: /allocate|move stock/i })).not.toBeInTheDocument()
  })
})
