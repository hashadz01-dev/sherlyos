export const DEVELOPMENT_SUPABASE_PROJECT_REF = "ypkfondrkhkydkgovwup"
export const DEVELOPMENT_SUPABASE_URL = `https://${DEVELOPMENT_SUPABASE_PROJECT_REF}.supabase.co`

export type ReleaseEnvInput = {
  url?: string
  publishableKey?: string
  /** Mistakenly prefixed secret. Presence is enough; the value is never logged. */
  serviceRoleBrowserKey?: string
  netlify?: boolean
  releaseTarget?: string
}

export class ReleaseEnvError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "ReleaseEnvError"
  }
}

export function supabaseProjectRefFromUrl(raw: string) {
  let host = ""
  try {
    host = new URL(raw.trim()).hostname
  } catch {
    return null
  }
  if (host === "127.0.0.1" || host === "localhost") return "local"
  const match = host.match(/^([a-z0-9]+)\.supabase\.co$/i)
  return match?.[1] ?? null
}

function looksLikeServiceRoleJwt(key: string) {
  const parts = key.trim().split(".")
  if (parts.length !== 3 || !parts[1]) return false
  try {
    const padded = parts[1].replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(parts[1].length / 4) * 4, "=")
    const payload = JSON.parse(atob(padded)) as { role?: string }
    return payload.role === "service_role" || payload.role === "supabase_admin"
  } catch {
    return false
  }
}

/**
 * Fail closed for Netlify/development releases that are not the approved
 * development project. Local 127.0.0.1 builds remain allowed for Playwright.
 */
export function assertDevelopmentReleaseEnv(input: ReleaseEnvInput) {
  if (input.serviceRoleBrowserKey) {
    throw new ReleaseEnvError(
      "A service-role key must not be exposed as a VITE_ browser variable.",
    )
  }

  const url = input.url?.trim() ?? ""
  const publishableKey = input.publishableKey?.trim() ?? ""
  const requireDevelopmentProject =
    Boolean(input.netlify) || input.releaseTarget === "development"

  if (publishableKey && looksLikeServiceRoleJwt(publishableKey)) {
    throw new ReleaseEnvError(
      "The browser credential looks like a service-role JWT. Use the publishable anon key.",
    )
  }

  if (requireDevelopmentProject) {
    if (!url || !publishableKey) {
      throw new ReleaseEnvError(
        "Netlify development builds require VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY.",
      )
    }
    const ref = supabaseProjectRefFromUrl(url)
    if (ref !== DEVELOPMENT_SUPABASE_PROJECT_REF) {
      throw new ReleaseEnvError(
        `Development frontend builds must use project ${DEVELOPMENT_SUPABASE_PROJECT_REF}.`,
      )
    }
    return
  }

  if (!url) return
  const ref = supabaseProjectRefFromUrl(url)
  if (ref && ref !== "local" && ref !== DEVELOPMENT_SUPABASE_PROJECT_REF) {
    throw new ReleaseEnvError(
      `This repository's frontend builds may not target a Supabase project other than ${DEVELOPMENT_SUPABASE_PROJECT_REF}.`,
    )
  }
}
