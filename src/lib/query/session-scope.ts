import { QueryClient, hashKey, type QueryKey } from "@tanstack/react-query"

/**
 * Current signed-in user for cache hashing. Module state so QueryClient can
 * isolate entries without putting user id on every queryKey call site.
 */
let queryScopeUserId: string | null = null

export function setQueryScopeUserId(userId: string | null) {
  queryScopeUserId = userId
}

export function getQueryScopeUserId() {
  return queryScopeUserId
}

/** Hash includes the signed-in user so leftover cache cannot satisfy another identity. */
export function scopedQueryKeyHash(queryKey: QueryKey) {
  return hashKey([queryScopeUserId ?? "signed-out", queryKey])
}

export function createScopedQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        retry: false,
        refetchOnWindowFocus: false,
        queryKeyHashFn: scopedQueryKeyHash,
      },
    },
  })
}

/** Drop in-flight and cached protected queries when the signed-in user changes. */
export async function resetQueryClientForIdentityChange(queryClient: QueryClient) {
  await queryClient.cancelQueries()
  queryClient.clear()
}
