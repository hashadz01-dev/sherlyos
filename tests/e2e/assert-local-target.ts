import { existsSync, readFileSync } from "node:fs"
import { resolve } from "node:path"

function parseEnvFile(path: string) {
  if (!existsSync(path)) return {} as Record<string, string>
  const values: Record<string, string> = {}
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith("#")) continue
    const separator = trimmed.indexOf("=")
    if (separator < 1) continue
    const key = trimmed.slice(0, separator).trim()
    let value = trimmed.slice(separator + 1).trim()
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1)
    }
    values[key] = value
  }
  return values
}

/** Vite --mode overlay order. Later files win. Isolated M8.1C uses mode m81c. */
export function effectiveViteSupabaseUrl(root = process.cwd()) {
  const mode = process.env.SHERLYOS_VITE_MODE?.trim() || "m1s2"
  const files = [".env", ".env.local", `.env.${mode}`, `.env.${mode}.local`]
  let url = ""
  for (const file of files) {
    const next = parseEnvFile(resolve(root, file)).VITE_SUPABASE_URL
    if (next) url = next
  }
  return url.trim()
}

export function isLocalSupabaseHost(hostname: string) {
  return hostname === "127.0.0.1" || hostname === "localhost"
}

/**
 * Playwright write-path journeys must never target the development cloud.
 * Fail closed before the webServer starts if the effective URL is not local.
 */
export function assertLocalPlaywrightTarget(root = process.cwd()) {
  const url = effectiveViteSupabaseUrl(root)
  if (!url) {
    throw new Error(
      "Playwright requires gitignored .env.m1s2.local with VITE_SUPABASE_URL=http://127.0.0.1:54321.",
    )
  }
  let hostname = ""
  try {
    hostname = new URL(url).hostname
  } catch {
    throw new Error("Playwright refused to start because VITE_SUPABASE_URL is not a valid URL.")
  }
  if (!isLocalSupabaseHost(hostname)) {
    throw new Error(
      "Playwright refused to start because VITE_SUPABASE_URL is not the local Supabase API.",
    )
  }
  const port = new URL(url).port || "443"
  if (process.env.SHERLYOS_ISOLATED === "1" && port === "54321") {
    throw new Error("isolated Playwright refused the owner API port 54321")
  }
  if (process.env.SHERLYOS_M82C === "1" && port === "56321") {
    throw new Error("M8.2C Playwright refused the m81c cutover API port 56321")
  }
}
