import { describe, expect, it } from "vitest"
import {
  DEVELOPMENT_SUPABASE_PROJECT_REF,
  DEVELOPMENT_SUPABASE_URL,
  assertDevelopmentReleaseEnv,
  supabaseProjectRefFromUrl,
} from "@/lib/supabase/release-env"

function unsignedJwt(role: string) {
  const encode = (value: object) =>
    btoa(JSON.stringify(value)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
  return `${encode({ alg: "none", typ: "JWT" })}.${encode({ role })}.sig`
}

describe("development release env", () => {
  it("reads the approved development project from its URL", () => {
    expect(supabaseProjectRefFromUrl(DEVELOPMENT_SUPABASE_URL)).toBe(
      DEVELOPMENT_SUPABASE_PROJECT_REF,
    )
    expect(supabaseProjectRefFromUrl("http://127.0.0.1:54321")).toBe("local")
  })

  it("allows a local build against localhost without Netlify", () => {
    expect(() =>
      assertDevelopmentReleaseEnv({
        url: "http://127.0.0.1:54321",
        publishableKey: "local-anon",
      }),
    ).not.toThrow()
  })

  it("allows a local build against the development project", () => {
    expect(() =>
      assertDevelopmentReleaseEnv({
        url: DEVELOPMENT_SUPABASE_URL,
        publishableKey: "dev-anon",
      }),
    ).not.toThrow()
  })

  it("rejects a different hosted project even for a local production build", () => {
    expect(() =>
      assertDevelopmentReleaseEnv({
        url: "https://aaaaaaaaaaaaaaaaaaaa.supabase.co",
        publishableKey: "other-anon",
      }),
    ).toThrow(/may not target a Supabase project other than/)
  })

  it("requires the development project on Netlify", () => {
    expect(() =>
      assertDevelopmentReleaseEnv({
        netlify: true,
        url: "",
        publishableKey: "",
      }),
    ).toThrow(/require VITE_SUPABASE_URL/)
    expect(() =>
      assertDevelopmentReleaseEnv({
        releaseTarget: "development",
        url: "https://aaaaaaaaaaaaaaaaaaaa.supabase.co",
        publishableKey: "anon",
      }),
    ).toThrow(new RegExp(DEVELOPMENT_SUPABASE_PROJECT_REF))
  })

  it("rejects a service-role browser credential without logging it", () => {
    expect(() =>
      assertDevelopmentReleaseEnv({
        url: DEVELOPMENT_SUPABASE_URL,
        publishableKey: unsignedJwt("service_role"),
      }),
    ).toThrow(/service-role JWT/)
    expect(() =>
      assertDevelopmentReleaseEnv({
        url: DEVELOPMENT_SUPABASE_URL,
        publishableKey: "anon",
        serviceRoleBrowserKey: "present",
      }),
    ).toThrow(/must not be exposed/)
  })
})
