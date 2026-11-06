import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { isKnownAppPath, navigationItems } from "@/app/navigation"
import { EmailLink, PhoneLink } from "@/components/shared/ContactLinks"

describe("known app paths", () => {
  it("treats real screens as known and unknown addresses as missing", () => {
    expect(isKnownAppPath("/")).toBe(true)
    expect(isKnownAppPath("/orders")).toBe(true)
    expect(isKnownAppPath("/orders/abc")).toBe(true)
    expect(isKnownAppPath("/branches")).toBe(true)
    expect(isKnownAppPath("/ordersx")).toBe(false)
    expect(isKnownAppPath("/missing-page")).toBe(false)
  })

  it("keeps every sidebar link on a known path", () => {
    for (const item of navigationItems) {
      expect(isKnownAppPath(item.to)).toBe(true)
    }
  })
})

describe("contact links", () => {
  it("dials a phone number and leaves an empty value as text", () => {
    const { rerender } = render(<PhoneLink value="  +91 98470 11111 " />)
    expect(screen.getByRole("link", { name: "+91 98470 11111" })).toHaveAttribute(
      "href",
      "tel:+919847011111",
    )

    rerender(<PhoneLink value="" empty="No contact details" />)
    expect(screen.getByText("No contact details")).toBeTruthy()
    expect(screen.queryByRole("link")).toBeNull()
  })

  it("opens an email and ignores a value that is not an address", () => {
    render(<EmailLink value="ada@example.com" />)
    expect(screen.getByRole("link", { name: "ada@example.com" })).toHaveAttribute(
      "href",
      "mailto:ada@example.com",
    )
  })
})
