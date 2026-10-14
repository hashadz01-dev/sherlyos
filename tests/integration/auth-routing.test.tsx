import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { createMemoryRouter, RouterProvider } from "react-router"
import { describe, expect, it, vi } from "vitest"
import { appRouteObjects } from "@/app/router"
import { Providers } from "@/app/providers"

vi.mock("@/lib/supabase/client", () => ({
  getSupabaseBrowserClient: () => null,
}))

function renderAt(path: string) {
  const router = createMemoryRouter(appRouteObjects, { initialEntries: [path] })
  render(
    <Providers>
      <RouterProvider router={router} />
    </Providers>,
  )
  return router
}

describe("authentication routing", () => {
  it("sends protected routes to the login page when there is no session", async () => {
    renderAt("/orders")

    expect(
      await screen.findByRole("heading", { name: "Sign in" }),
    ).toBeInTheDocument()
    expect(
      screen.queryByText("Orders is not available yet"),
    ).not.toBeInTheDocument()
  })

  it("does not create a session from the login form when Supabase is not configured", async () => {
    const user = userEvent.setup()
    const router = renderAt("/login")

    expect(await screen.findByRole("status")).toHaveTextContent(
      "Supabase is not configured",
    )

    await user.type(screen.getByLabelText("Email"), "ada@example.com")
    await user.type(screen.getByLabelText("Password"), "secret")
    await user.click(screen.getByRole("button", { name: "Sign in" }))

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Supabase is not configured",
    )
    expect(router.state.location.pathname).toBe("/login")
    expect(screen.queryByText("Operations Overview")).not.toBeInTheDocument()
  })
})
