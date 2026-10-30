/**
 * supabase-js reports a dead Auth host as "Failed to fetch". Map that to a
 * message that names the target so operators do not retry a down local API.
 */
export function mapSignInError(
  message: string,
  supabaseUrl?: string | null,
): string {
  if (
    !/failed to fetch|networkerror|load failed|authretryablefetch/i.test(
      message,
    )
  ) {
    return message
  }

  let host = ""
  try {
    host = supabaseUrl ? new URL(supabaseUrl).host : ""
  } catch {
    host = ""
  }

  if (host === "127.0.0.1:54321" || /^localhost:\d+$/i.test(host)) {
    return "Cannot reach local Supabase. Start it, or remove .env.development.local so Sign in uses the development cloud."
  }

  return "Cannot reach Supabase. Check the network and VITE_SUPABASE_URL, then retry."
}
