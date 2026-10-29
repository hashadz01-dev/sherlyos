type RpcFailure = {
  message?: string
  code?: string
  details?: string
  hint?: string
}

const sqlLeakPattern =
  /\b(select|insert|update|delete|from public\.|pg_catalog|raise exception|permission denied for (table|function|schema))\b/i

/**
 * Map PostgREST / PostgreSQL failures to a short operator message.
 * Details and hints stay off the screen because they often contain SQL.
 */
export function toUserRpcMessage(error: RpcFailure | string) {
  const code = typeof error === "string" ? "" : error.code ?? ""
  const raw = (typeof error === "string" ? error : error.message ?? "").trim()

  if (
    code === "PGRST301" ||
    code === "PGRST303" ||
    /jwt expired|not authenticated|invalid jwt|session.*expired/i.test(raw)
  ) {
    return "Your session has ended. Sign in again."
  }

  if (code === "42501" || code === "PGRST301" || /permission denied/i.test(raw)) {
    return "You do not have permission to do that."
  }

  if (code === "PT409" || /changed by someone else|stale version/i.test(raw)) {
    return "This record changed. Refresh and try again."
  }

  // PostgREST PGRST202 means the connected API never loaded this RPC.
  // Local owner/isolated stacks have the functions; the development cloud does not.
  if (code === "PGRST202" || /schema cache/i.test(raw)) {
    return "This screen is not available on the connected database. Restart with npm run dev to use local Supabase."
  }

  if (!raw) {
    return "The request could not be completed. Try again or ask an administrator."
  }

  if (sqlLeakPattern.test(raw) || raw.length > 280) {
    return "The request could not be completed. Try again or ask an administrator."
  }

  return raw
}
