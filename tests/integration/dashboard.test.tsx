import { render, screen } from "@testing-library/react"
import { createMemoryRouter, RouterProvider } from "react-router"
import { describe, expect, it, vi } from "vitest"
import { AppShell } from "@/app/layouts/AppShell"
import { DashboardPage } from "@/pages/dashboard/DashboardPage"

vi.mock("@/lib/access/use-access", () => ({
  useAccess: () => ({
    loading: false,
    roles: [],
    permissions: [],
    can: () => false,
  }),
}))

vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({
    configured: true,
    loading: false,
    session: { user: { email: "ada@example.com" } },
    signIn: vi.fn(),
    signOut: vi.fn(),
  }),
}))

describe("dashboard", () => {
  it("shows the overview layout without sample operational figures", () => {
    const router = createMemoryRouter(
      [
        {
          path: "/",
          element: <AppShell />,
          children: [{ index: true, element: <DashboardPage /> }],
        },
      ],
      { initialEntries: ["/"] },
    )

    render(<RouterProvider router={router} />)

    expect(
      screen.getByRole("heading", { name: "Operations Overview" }),
    ).toBeInTheDocument()
    expect(screen.getByText("Orders Today")).toBeInTheDocument()
    expect(screen.getByText("Pending Delivery")).toBeInTheDocument()
    expect(screen.getByText("Stock Alerts")).toBeInTheDocument()
    expect(screen.getByText("Pending Approvals")).toBeInTheDocument()
    expect(screen.getAllByText("Not connected").length).toBeGreaterThan(0)
    expect(screen.getByText("No orders to show")).toBeInTheDocument()
    expect(screen.queryByText("ORD-001")).not.toBeInTheDocument()
    expect(screen.queryByText("48")).not.toBeInTheDocument()
    expect(
      screen.getByRole("navigation", { name: "Primary" }),
    ).toBeInTheDocument()
    expect(
      screen.getByRole("button", { name: "Notifications" }),
    ).toBeInTheDocument()
  })
})
