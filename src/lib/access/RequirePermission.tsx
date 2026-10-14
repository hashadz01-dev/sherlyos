import type { ReactNode } from "react"
import { LoadingScreen } from "@/components/shared/LoadingState"
import { useAccess } from "@/lib/access/use-access"
import { AccessDeniedPage } from "@/pages/errors/AccessDeniedPage"

export function RequirePermission({
  permission,
  children,
}: {
  permission: string
  children: ReactNode
}) {
  const { loading, can } = useAccess()

  if (loading) {
    return <LoadingScreen />
  }

  if (!can(permission)) {
    return <AccessDeniedPage />
  }

  return children
}
