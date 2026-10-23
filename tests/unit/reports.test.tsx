import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router"
import { describe, expect, it, vi } from "vitest"
import { ReportsPage } from "@/features/reports/ReportsPage"
import { utcDayEndExclusive, utcDayStart } from "@/lib/reports/format"
import { canAny, inventoryReportPermissions } from "@/lib/reports/access"
import { reportKeys } from "@/lib/reports/api"

vi.mock("@/lib/access/use-access", () => ({
  useAccess: () => ({
    loading: false,
    roles: ["admin"],
    permissions: ["stock.read", "operations.monitor", "dispatch.view"],
    can: (permission: string) =>
      ["stock.read", "operations.monitor", "dispatch.view"].includes(permission),
  }),
}))

describe("report helpers", () => {
  it("uses half-open UTC day bounds", () => {
    expect(utcDayStart("2026-10-23")).toBe("2026-10-23T00:00:00Z")
    expect(utcDayEndExclusive("2026-10-23")).toBe("2026-10-24T00:00:00.000Z")
    expect(utcDayStart("")).toBeNull()
  })

  it("scopes cached report queries by signed-in user", () => {
    expect(reportKeys.dashboard("user-a", "")).not.toEqual(reportKeys.dashboard("user-b", ""))
    expect(reportKeys.inventory("user-a", { page: 1 })).not.toEqual(
      reportKeys.inventory("user-b", { page: 1 }),
    )
  })

  it("uses exclusive UTC month and year bounds", () => {
    expect(utcDayEndExclusive("2026-10-31")).toBe("2026-11-01T00:00:00.000Z")
    expect(utcDayEndExclusive("2026-12-31")).toBe("2027-01-01T00:00:00.000Z")
  })

  it("gates inventory reports on stock.read or operations.monitor", () => {
    const denied = {
      loading: false,
      roles: [],
      permissions: ["deliveries.execute"],
      can: (permission: string) => permission === "deliveries.execute",
    }
    const allowed = {
      ...denied,
      permissions: ["stock.read"],
      can: (permission: string) => permission === "stock.read",
    }
    expect(canAny(denied, inventoryReportPermissions)).toBe(false)
    expect(canAny(allowed, inventoryReportPermissions)).toBe(true)
  })
})

describe("reports hub", () => {
  it("lists authorized report cards without sample figures", () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <ReportsPage />
        </MemoryRouter>
      </QueryClientProvider>,
    )
    expect(screen.getByRole("heading", { name: "Reports" })).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: /Inventory/ }).length).toBeGreaterThan(0)
    expect(screen.getAllByRole("link", { name: /Dispatch and delivery/ }).length).toBeGreaterThan(0)
    expect(screen.queryByText("ORD-001")).not.toBeInTheDocument()
  })
})
