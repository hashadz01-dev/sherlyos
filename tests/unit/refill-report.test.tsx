import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router"
import { describe, expect, it, vi } from "vitest"
import { ReportsPage } from "@/features/reports/ReportsPage"
import { canAny, refillReportPermissions } from "@/lib/reports/access"

vi.mock("@/lib/access/use-access", () => ({
  useAccess: () => ({
    loading: false,
    roles: ["accounts"],
    permissions: ["refill.request"],
    can: (permission: string) => permission === "refill.request",
  }),
}))

describe("refill report access", () => {
  it("gates refill reporting on refill.request or refill.approve", () => {
    const denied = {
      loading: false,
      roles: [],
      permissions: ["stock.read"],
      can: (permission: string) => permission === "stock.read",
    }
    const allowed = {
      ...denied,
      permissions: ["refill.request"],
      can: (permission: string) => permission === "refill.request",
    }
    expect(canAny(denied, refillReportPermissions)).toBe(false)
    expect(canAny(allowed, refillReportPermissions)).toBe(true)
  })

  it("shows the refill report card to Accounts without operations report grants", () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <ReportsPage />
        </MemoryRouter>
      </QueryClientProvider>,
    )
    expect(screen.getByRole("link", { name: /Stock refill/ })).toHaveAttribute(
      "href",
      "/reports/refill",
    )
    expect(screen.queryByRole("link", { name: /^Inventory$/ })).not.toBeInTheDocument()
  })
})
