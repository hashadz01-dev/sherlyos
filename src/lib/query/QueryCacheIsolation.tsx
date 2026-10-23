import { useLayoutEffect, useRef } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { useAuth } from "@/hooks/use-auth"
import { resetQueryClientForIdentityChange } from "@/lib/query/session-scope"

/**
 * Clears TanStack Query when the signed-in user id changes, including logout.
 * Scope hashing already prevents reuse; this drops the previous user's rows from memory.
 */
export function QueryCacheIsolation() {
  const { session } = useAuth()
  const queryClient = useQueryClient()
  const userId = session?.user.id ?? null
  const previousUserId = useRef<string | null | undefined>(undefined)

  useLayoutEffect(() => {
    if (previousUserId.current === undefined) {
      previousUserId.current = userId
      return
    }
    if (previousUserId.current === userId) {
      return
    }
    previousUserId.current = userId
    void resetQueryClientForIdentityChange(queryClient)
  }, [queryClient, userId])

  return null
}
