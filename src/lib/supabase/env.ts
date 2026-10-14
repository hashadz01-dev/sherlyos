import { z } from "zod"

const supabasePublicEnvSchema = z.object({
  url: z.url(),
  publishableKey: z.string().min(1),
})

export type SupabasePublicEnv = z.infer<typeof supabasePublicEnvSchema>

export function parseSupabasePublicEnv(source: {
  url: unknown
  publishableKey: unknown
}): SupabasePublicEnv | null {
  const parsed = supabasePublicEnvSchema.safeParse({
    url: typeof source.url === "string" ? source.url.trim() : source.url,
    publishableKey:
      typeof source.publishableKey === "string"
        ? source.publishableKey.trim()
        : source.publishableKey,
  })

  return parsed.success ? parsed.data : null
}

export function readSupabasePublicEnv(): SupabasePublicEnv | null {
  return parseSupabasePublicEnv({
    url: import.meta.env.VITE_SUPABASE_URL,
    publishableKey: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
  })
}
