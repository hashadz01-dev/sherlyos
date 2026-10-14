import { describe, expect, it } from "vitest"
import { parseSupabasePublicEnv } from "@/lib/supabase/env"

describe("parseSupabasePublicEnv", () => {
  it("returns null when the public configuration is missing", () => {
    expect(parseSupabasePublicEnv({ url: "", publishableKey: "" })).toBeNull()
    expect(
      parseSupabasePublicEnv({ url: undefined, publishableKey: undefined }),
    ).toBeNull()
  })

  it("accepts a project URL and publishable key", () => {
    expect(
      parseSupabasePublicEnv({
        url: " https://example.supabase.co ",
        publishableKey: " publishable-key ",
      }),
    ).toEqual({
      url: "https://example.supabase.co",
      publishableKey: "publishable-key",
    })
  })
})
