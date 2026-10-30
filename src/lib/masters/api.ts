import { toUserRpcMessage } from "@/lib/rpc/user-error"
import { fetchAllRows } from "@/lib/supabase/fetch-all"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"

function client() {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) {
    throw new Error("Supabase is not configured.")
  }
  return supabase
}

export async function callRpc<T>(name: string, args: Record<string, unknown>) {
  const result = await client().rpc(name, args)
  if (result.error) {
    throw new Error(toUserRpcMessage(result.error))
  }
  return result.data as T
}

export async function loadRows<T>(table: string, columns: string, orderBy: string) {
  const supabase = client()
  try {
    // Page past PostgREST max_rows so shop/route filters are not first-page only.
    const rows = await fetchAllRows((from, to) =>
      supabase
        .from(table)
        .select(columns)
        .order(orderBy)
        .order("id")
        .range(from, to),
    )
    return rows as T[]
  } catch (error) {
    throw new Error(toUserRpcMessage(error instanceof Error ? error : { message: String(error) }))
  }
}

/** True when the connected database has not received the sales-route tables yet. */
export function isMissingDatabaseObject(error: unknown) {
  const message = error instanceof Error ? error.message : String(error)
  return /not available on the connected database|could not find the table|does not exist|PGRST205/i.test(
    message,
  )
}

export async function loadRowsIfPresent<T>(table: string, columns: string, orderBy: string) {
  try {
    return await loadRows<T>(table, columns, orderBy)
  } catch (error) {
    if (isMissingDatabaseObject(error)) return []
    throw error
  }
}