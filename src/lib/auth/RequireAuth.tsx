import { Navigate, Outlet } from "react-router"
import { LoadingScreen } from "@/components/shared/LoadingState"
import { useAuth } from "@/hooks/use-auth"

export function RequireAuth() {
  const { loading, session } = useAuth()

  if (loading) {
    return <LoadingScreen />
  }

  if (!session) {
    return <Navigate to="/login" replace />
  }

  return <Outlet />
}
