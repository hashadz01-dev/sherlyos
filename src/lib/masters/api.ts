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
    throw new Error(result.error.message)
  }
  return result.data as T
}

export async function loadRows<T>(table: string, columns: string, orderBy: string) {
  const result = await client().from(table).select(columns).order(orderBy)
  if (result.error) {
    throw new Error(result.error.message)
  }
  return (result.data ?? []) as T[]
}