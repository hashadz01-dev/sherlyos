import { Navigate, useLocation } from "react-router"

/**
 * Replaces an id address with the code address without adding a history entry.
 * Search and hash are kept so a shared link still lands on the same view.
 */
function decodedPath(value: string) {
  try {
    return decodeURIComponent(value)
  } catch {
    return value
  }
}

export function ReadableAddress({ to }: { to: string | null }) {
  const { pathname, search, hash } = useLocation()
  if (!to || decodedPath(pathname) === decodedPath(to)) return null
  return <Navigate to={`${to}${search}${hash}`} replace />
}
