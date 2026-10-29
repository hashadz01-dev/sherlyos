import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { SettingsPage } from "@/features/administration/SettingsPage"
import {
  APP_UPDATES_CHECKED_KEY,
  formatAppUpdateStamp,
  formatAssignedRoles,
} from "@/features/administration/settings"

vi.mock("@/hooks/use-document-title", () => ({
  useDocumentTitle: () => undefined,
}))

vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({
    session: { user: { id: "acct-1", email: "admin@example.com" } },
  }),
}))

vi.mock("@/lib/access/use-access", () => ({
  useAccess: () => ({
    loading: false,
    roles: ["admin"],
    permissions: [],
    can: () => false,
  }),
}))

vi.mock("@/lib/supabase/client", () => ({
  getSupabaseBrowserClient: () => ({
    from: () => ({
      select: () => ({
        eq: () => ({
          maybeSingle: async () => ({
            data: { full_name: "Admin", email: "admin@example.com" },
            error: null,
          }),
        }),
      }),
    }),
  }),
}))

function renderSettings() {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return render(
    <QueryClientProvider client={client}>
      <SettingsPage />
    </QueryClientProvider>,
  )
}

describe("settings helpers", () => {
  it("formats an empty check as not checked yet", () => {
    expect(formatAppUpdateStamp(null)).toBe("Not checked yet")
    expect(formatAppUpdateStamp("not-a-date")).toBe("Not checked yet")
  })

  it("formats assigned role codes for the profile card", () => {
    expect(formatAssignedRoles([])).toBe("No assigned role")
    expect(formatAssignedRoles(["admin", "godown_manager"])).toBe("Admin, Godown Manager")
  })
})

describe("settings page", () => {
  beforeEach(() => {
    localStorage.clear()
  })

  it("replaces the supabase box with app updates and profile", async () => {
    renderSettings()
    expect(screen.queryByRole("heading", { name: "Supabase" })).toBeNull()
    expect(screen.getByRole("heading", { name: "App updates" })).toBeTruthy()
    expect(screen.getByRole("heading", { name: "Profile" })).toBeTruthy()
    expect(await screen.findByText("Name: Admin")).toBeTruthy()
    expect(screen.getByText("Operations workspace")).toBeTruthy()
    expect(screen.getByText("Role: Admin")).toBeTruthy()
    expect(screen.getByText("Not checked yet")).toBeTruthy()
  })

  it("records the last app-update check", async () => {
    const user = userEvent.setup()
    renderSettings()
    await user.click(screen.getByRole("button", { name: "Check" }))
    const stored = localStorage.getItem(APP_UPDATES_CHECKED_KEY)
    expect(stored).toBeTruthy()
    expect(screen.getByText(formatAppUpdateStamp(stored))).toBeTruthy()
    expect(screen.queryByText("Not checked yet")).toBeNull()
  })
})
