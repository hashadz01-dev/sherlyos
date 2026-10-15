import type { ReactNode } from "react"
import { LoadingScreen } from "@/components/shared/LoadingState"
import { useAccess } from "@/lib/access/use-access"
import { AccessDeniedPage } from "@/pages/errors/AccessDeniedPage"

export function RequireAnyPermission({
  permissions,
  children,
}: {
  permissions: string[]
  children: ReactNode
}) {
  const { loading, can } = useAccess()

  if (loading) {
    return <LoadingScreen />
  }

  if (!permissions.some((permission) => can(permission))) {
    return <AccessDeniedPage />
  }

  return children
}
