import { createClient, type SupabaseClient } from "@supabase/supabase-js"
import { readSupabasePublicEnv } from "@/lib/supabase/env"

let browserClient: SupabaseClient | null | undefined

export function getSupabaseBrowserClient(): SupabaseClient | null {
  if (browserClient !== undefined) {
    return browserClient
  }

  const env = readSupabasePublicEnv()
  if (!env) {
    browserClient = null
    return browserClient
  }

  browserClient = createClient(env.url, env.publishableKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  })

  return browserClient
}
