import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router"
import { describe, expect, it, vi } from "vitest"
import { AppFooter } from "@/components/layout/AppFooter"
import { LoadingBlock } from "@/components/shared/LoadingState"
import { PrivacyPage } from "@/pages/legal/PrivacyPage"
import { TermsPage } from "@/pages/legal/TermsPage"

vi.mock("@/hooks/use-document-title", () => ({
  useDocumentTitle: () => undefined,
}))

vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({ session: null }),
}))

describe("legal pages", () => {
  it("publishes terms and a privacy notice before sign-in", () => {
    const { rerender } = render(
      <MemoryRouter>
        <TermsPage />
      </MemoryRouter>,
    )
    expect(screen.getByRole("heading", { name: "Terms of use" })).toBeTruthy()
    expect(screen.getByRole("link", { name: "Privacy" })).toHaveAttribute("href", "/privacy")

    rerender(
      <MemoryRouter>
        <PrivacyPage />
      </MemoryRouter>,
    )
    expect(screen.getByRole("heading", { name: "Privacy notice" })).toBeTruthy()
    expect(screen.getByRole("link", { name: "Terms" })).toHaveAttribute("href", "/terms")
  })

  it("links the signed-in footer to both notices", () => {
    render(
      <MemoryRouter>
        <AppFooter />
      </MemoryRouter>,
    )
    expect(screen.getByRole("link", { name: "Terms" })).toHaveAttribute("href", "/terms")
    expect(screen.getByRole("link", { name: "Privacy" })).toHaveAttribute("href", "/privacy")
  })
})

describe("loading block", () => {
  it("reserves layout with skeleton bars while naming the wait", () => {
    const { container } = render(<LoadingBlock label="Loading operations overview" />)
    expect(screen.getByRole("status")).toHaveTextContent("Loading operations overview")
    expect(container.querySelectorAll("[data-slot=skeleton]").length).toBeGreaterThan(0)
  })
})
