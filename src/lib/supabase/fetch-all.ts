/** PostgREST returns at most max_rows (1000 here) per request. */
export const POSTGREST_PAGE_SIZE = 1000

/**
 * Walk inclusive .range() pages until a short page. Callers must .order() so
 * pages stay stable; otherwise users created after the first 1000 never appear.
 */
export async function fetchAllRows<T>(
  runPage: (
    from: number,
    to: number,
  ) => Promise<{ data: T[] | null; error: { message: string } | null }>,
  pageSize = POSTGREST_PAGE_SIZE,
): Promise<T[]> {
  const rows: T[] = []
  let from = 0
  while (true) {
    const { data, error } = await runPage(from, from + pageSize - 1)
    if (error) throw new Error(error.message)
    const page = data ?? []
    rows.push(...page)
    if (page.length < pageSize) break
    from += pageSize
  }
  return rows
}
