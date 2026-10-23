import { afterEach, describe, expect, it } from "vitest"
import {
  createScopedQueryClient,
  resetQueryClientForIdentityChange,
  setQueryScopeUserId,
} from "@/lib/query/session-scope"

describe("query session scope", () => {
  afterEach(() => {
    setQueryScopeUserId(null)
  })

  it("does not serve one user's cached rows to a different user", async () => {
    setQueryScopeUserId("user-ada")
    const client = createScopedQueryClient()
    client.setQueryData(["stock-balances"], { secret: "ada-stock" })

    setQueryScopeUserId("user-lee")
    expect(client.getQueryData(["stock-balances"])).toBeUndefined()

    setQueryScopeUserId("user-ada")
    expect(client.getQueryData(["stock-balances"])).toEqual({ secret: "ada-stock" })

    await resetQueryClientForIdentityChange(client)
    expect(client.getQueryData(["stock-balances"])).toBeUndefined()
  })
})
