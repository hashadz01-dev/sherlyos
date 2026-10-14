import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { AppModal } from "@/components/shared/AppModal"
import { StatusBadge } from "@/components/shared/StatusBadge"
import { notify } from "@/lib/utilities/notify"

vi.mock("sonner", () => ({
  toast: {
    info: vi.fn(),
    success: vi.fn(),
    error: vi.fn(),
  },
}))

describe("shared components", () => {
  it("renders a status badge", () => {
    render(<StatusBadge tone="warning">Not configured</StatusBadge>)
    expect(screen.getByText("Not configured")).toBeInTheDocument()
  })

  it("renders a modal title", () => {
    render(
      <AppModal open onOpenChange={() => undefined} title="Confirm later">
        <p>No stock action is available.</p>
      </AppModal>,
    )
    expect(screen.getByText("Confirm later")).toBeInTheDocument()
  })

  it("sends a toast through the shared helper", async () => {
    const { toast } = await import("sonner")
    notify.error("Could not sign in")
    expect(toast.error).toHaveBeenCalledWith("Could not sign in")
  })
})
