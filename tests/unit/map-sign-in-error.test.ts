import { describe, expect, it } from "vitest"
import { mapSignInError } from "@/lib/auth/map-sign-in-error"

describe("mapSignInError", () => {
  it("keeps credential errors unchanged", () => {
    expect(mapSignInError("Invalid login credentials")).toBe(
      "Invalid login credentials",
    )
  })

  it("explains a down local Auth API", () => {
    expect(
      mapSignInError("Failed to fetch", "http://127.0.0.1:54321"),
    ).toMatch(/local Supabase/)
  })

  it("explains a generic network failure", () => {
    expect(
      mapSignInError("Failed to fetch", "https://ypkfondrkhkydkgovwup.supabase.co"),
    ).toMatch(/Cannot reach Supabase/)
  })
})
