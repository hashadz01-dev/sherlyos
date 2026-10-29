import { describe, expect, it, vi } from "vitest"
import { POSTGREST_PAGE_SIZE, fetchAllRows } from "@/lib/supabase/fetch-all"

describe("fetchAllRows", () => {
  it("walks inclusive pages until a short page", async () => {
    const runPage = vi
      .fn()
      .mockResolvedValueOnce({
        data: Array.from({ length: POSTGREST_PAGE_SIZE }, (_, index) => index),
        error: null,
      })
      .mockResolvedValueOnce({ data: [POSTGREST_PAGE_SIZE], error: null })

    const rows = await fetchAllRows(runPage)
    expect(rows).toHaveLength(POSTGREST_PAGE_SIZE + 1)
    expect(runPage).toHaveBeenNthCalledWith(1, 0, POSTGREST_PAGE_SIZE - 1)
    expect(runPage).toHaveBeenNthCalledWith(
      2,
      POSTGREST_PAGE_SIZE,
      POSTGREST_PAGE_SIZE * 2 - 1,
    )
  })

  it("surfaces the page error", async () => {
    await expect(
      fetchAllRows(async () => ({ data: null, error: { message: "permission denied" } })),
    ).rejects.toThrow("permission denied")
  })
})
