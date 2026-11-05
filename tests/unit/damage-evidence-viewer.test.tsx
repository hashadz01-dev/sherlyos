import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"
import { DamageEvidencePanel } from "@/features/damage/components/DamageEvidencePanel"

vi.mock("@/lib/damage/api", () => ({
  damagePhotoPreview: vi.fn(async (id: string) => `https://example.test/${id}`),
}))

function renderPanel(
  evidence: Array<{
    id: string
    finalized: boolean
    mime_type: string | null
    uploaded_at: string
    note?: string | null
  }> = [],
  sessionPhotos: Array<{ id: string; url: string; name: string }> = [],
) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return render(
    <QueryClientProvider client={client}>
      <DamageEvidencePanel evidence={evidence} sessionPhotos={sessionPhotos} />
    </QueryClientProvider>,
  )
}

describe("damage evidence viewer", () => {
  it("keeps the empty state when nothing is viewable", () => {
    renderPanel()
    expect(
      screen.getByText("No finalized evidence is available for this report."),
    ).toBeInTheDocument()
  })

  it("opens a gallery and a single photo view for attached images", async () => {
    const user = userEvent.setup()
    renderPanel([], [
      { id: "a", url: "blob:photo-a", name: "carton-a.jpg" },
      { id: "b", url: "blob:photo-b", name: "carton-b.jpg" },
    ])

    const previews = screen.getAllByRole("button", { name: "Preview" })
    expect(previews).toHaveLength(2)
    expect(screen.getByText(/carton-a.jpg/)).toBeInTheDocument()
    expect(screen.getByText(/carton-b.jpg/)).toBeInTheDocument()
    await user.click(previews[0])
    expect(screen.getByRole("img", { name: "Photo 1" })).toHaveAttribute(
      "src",
      "blob:photo-a",
    )
    await user.click(previews[0])
    expect(screen.queryByRole("img", { name: "Photo 1" })).not.toBeInTheDocument()
  })

  it("exposes a delete control next to a single attached image", async () => {
    const user = userEvent.setup()
    const onRemove = vi.fn()
    const client = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    })
    render(
      <QueryClientProvider client={client}>
        <DamageEvidencePanel
          evidence={[]}
          sessionPhotos={[
            { id: "a", url: "blob:photo-a", name: "carton-a.jpg" },
          ]}
          onRemove={onRemove}
        />
      </QueryClientProvider>,
    )

    expect(
      screen.getByRole("button", { name: "Delete image" }),
    ).toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Delete image" }))
    expect(onRemove).toHaveBeenCalledWith(
      expect.objectContaining({ id: "a", src: "blob:photo-a" }),
    )
  })
})
