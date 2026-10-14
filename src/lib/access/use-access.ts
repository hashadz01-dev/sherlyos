import { useQuery } from "@tanstack/react-query"
import { useAuth } from "@/hooks/use-auth"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"

export type AccessState = {
  loading: boolean
  roles: string[]
  permissions: string[]
  can: (permission: string) => boolean
}

type RoleRow = { roles: { code: string } | { code: string }[] | null }
type GrantRow = { permissions: { code: string } | { code: string }[] | null }

function one<T>(value: T | T[] | null): T | null {
  if (!value) return null
  return Array.isArray(value) ? (value[0] ?? null) : value
}

async function loadAccess(userId: string) {
  const supabase = getSupabaseBrowserClient()
  if (!supabase) {
    return { roles: [] as string[], permissions: [] as string[] }
  }

  const memberships = await supabase
    .from("user_roles")
    .select("role_id, roles(code)")
    .eq("user_id", userId)

  if (memberships.error) {
    throw new Error(memberships.error.message)
  }

  const rows = (memberships.data ?? []) as unknown as (RoleRow & {
    role_id: string
  })[]
  const roles = rows
    .map((row) => one(row.roles)?.code)
    .filter((code): code is string => Boolean(code))
  const roleIds = rows.map((row) => row.role_id)

  if (roleIds.length === 0) {
    return { roles, permissions: [] as string[] }
  }

  const grants = await supabase
    .from("role_permissions")
    .select("permissions(code)")
    .in("role_id", roleIds)

  if (grants.error) {
    throw new Error(grants.error.message)
  }

  const permissions = [
    ...new Set(
      ((grants.data ?? []) as unknown as GrantRow[])
        .map((row) => one(row.permissions)?.code)
        .filter((code): code is string => Boolean(code)),
    ),
  ]

  return { roles, permissions }
}

export function useAccess(): AccessState {
  const { session, loading: authLoading } = useAuth()
  const userId = session?.user.id
  const query = useQuery({
    queryKey: ["access", userId],
    enabled: Boolean(userId),
    queryFn: () => loadAccess(userId!),
  })

  const permissions = query.data?.permissions ?? []
  const roles = query.data?.roles ?? []

  return {
    loading: authLoading || (Boolean(userId) && query.isLoading),
    roles,
    permissions,
    can: (permission) => permissions.includes(permission),
  }
}
