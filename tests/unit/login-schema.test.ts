import { describe, expect, it } from "vitest"
import { loginSchema } from "@/lib/validations/login"

describe("loginSchema", () => {
  it("accepts an email and password", () => {
    const result = loginSchema.safeParse({
      email: "ada@example.com",
      password: "secret",
    })

    expect(result.success).toBe(true)
  })

  it("rejects a missing password and an invalid email", () => {
    const result = loginSchema.safeParse({
      email: "not-an-email",
      password: "",
    })

    expect(result.success).toBe(false)
    if (!result.success) {
      const fields = result.error.issues.map((issue) => issue.path[0])
      expect(fields).toContain("email")
      expect(fields).toContain("password")
    }
  })
})
